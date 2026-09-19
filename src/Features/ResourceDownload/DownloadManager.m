//
//  DownloadManager.m
//  7zz
//

#import "DownloadManager.h"
#import "RDLog.h"
#import "RDURLUtilities.h"
#import "RDNetworkValidation.h"
#import "HTTPPrivacyPolicy.h"
#import "RDStreamDownloadTask.h"
#import "PerformancePolicy.h"
#import "DNSResolver.h"
#import "IPAddressPolicy.h"
#import "DownloadCapabilityProbe.h"
#import "AdaptiveTransferScheduler.h"
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <errno.h>

// 分段停滞检测：单段在其余段正常推进的情况下，超过该秒数仍无任何字节增长，
// 即判定该段的连接被 CDN/代理晾住，取消并换连接重发该段（有界次数）。不能只靠
// 全任务 45s 看门狗——它只在上一条“任务级”数据里观察，单段停滞会被其他段的
// 进展掩盖。真实现场证据（2026-09-10 18:04，720p 8 段）：7 段 6.9s 完成，
// 第 8 段被晾 57s，总耗时 64.2s。
static NSTimeInterval RDSegmentStallThreshold(void) { return 3.0; }
// 首字节窗口：一个分段还没收到任何字节时，多半是 CDN 慢启动/排队，而不是“连接被晾住”。
// 判定是事件驱动的：按“多久没有新字节”算。
//
// 2026-09-11 真实站点交替对照（408113 与 408157 各 5 轮，同一探针只改本常量）：
//   8s（原值）：408113 中位 4.81MB/s、2/5 达标；408157 中位 4.96、2/4
//   6s（现值）：408113 中位 12.51MB/s、**5/5 达标**；408157 中位 6.22、**5/5**
//   3s（对照）：出现 58.8s + 6 次重发 ⇒ 过于激进会招致连接 churn 反被站点惩罚
// 因此取 6s：既显著缩短“被晾住的段白等”的时间，又不至于把 CDN 正常慢启动误判成停滞。
// 注意：已收到字节的段仍用 RDSegmentStallThreshold（3s），本窗口只作用于“零字节”的段。
static NSTimeInterval RDSegmentFirstByteStallThreshold(void) { return 6.0; }
// 单段停滞重发的有界上限：耗尽后停止重发该段，由全任务看门狗收口，绝不无休止重试。
static NSInteger RDSegmentStallAttemptLimit(void) { return 3; }
// 已经收到数据但持续低速时的自适应窗口。连续两个完整窗口低于该速率才换连接，
// 避免把首字节慢启动或单次回调抖动误判为慢段。
static double RDSegmentLowRateBytesPerSecond(void) { return 250000.0; }
static NSTimeInterval RDSegmentRateWindowSeconds(void) { return 3.0; }
static NSInteger RDSegmentLowRateWindowLimit(void) { return 2; }
// 整池被晾（多数在途段同时无数据＝服务器把整池连接一起晾住）的换连接轮次退避。
// 与单段重发额度严格隔离：整池发作不烧单段预算，额度留给“恢复后的单段被晾”。
// 现场发作窗口 5–40s，4 轮退避累计 45s 覆盖之；轮次耗尽后交回 45s 任务级看门狗收口。
static NSArray<NSNumber *> *RDSegmentPoolStallBackoffSeconds(void) { return @[@3, @6, @12, @24]; }

// 临时目录归属（跨实例安全）：
// 每个任务临时目录里有一个 `.rd-owner.lock`，**由持有该目录的进程用 flock 独占持有**，
// 直到该任务终态清理为止。判据不是 PID、也不是目录年龄：
//   · 锁被别的实例持有 → 目录是活的，任何清理都不得删除；
//   · 无人持锁（持锁进程崩溃/退出时内核自动释放）→ 目录是孤儿，可安全回收；
//   · 目录刚创建、锁文件还没落地 → 处于“创建/认领进行中”，在宽限期内一律保留，
//     避免清理与创建/恢复竞态把新目录删掉。
static NSTimeInterval RDTempDirClaimGraceSeconds(void) { return 60.0; }
static NSString *const RDTempDirClaimFileName = @".rd-owner.lock";
// 隔离区：待删除目录先被 rename 到这里（同卷内原子），再递归删除。
// 见 -quarantineAndRemoveOwnedTempDirectoryAtPath: 的 INV-3 说明。
static NSString *const RDTempDirQuarantineDirName = @".rd-trash";

// MARK: - 临时诊断日志（下载落盘/失败追溯）

// 2026-09-08 事故：用户下载 125.9 MB 视频失败，但下载链路零日志，失败原因
// 无法追溯。诊断日志同时写统一日志（log show 可查）与
// ~/Library/Logs/ResourceDetector.log（统一日志，用户可直接打开）。
// 统一日志：写入 RDLog（~/Library/Logs/ResourceDetector.log，[dl] 前缀）。
// URL 自动脱敏在 RDLogWrite 内完成；轮转由 RDLogRotateIfNeeded 负责（App 启动时调用）。
static void RDDownloadLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RDDownloadLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RDLogWrite(@"dl", @"%@", message);
}

static NSString *RDStateNameForJob(DownloadJob *job) {
    switch (job.state) {
        case DownloadJobStateQueued: return @"queued";
        case DownloadJobStateRunning: return @"running";
        case DownloadJobStatePaused: return @"paused";
        case DownloadJobStateCancelling: return @"cancelling";
        case DownloadJobStateCancelled: return @"cancelled";
        case DownloadJobStateFailed: return @"failed";
        case DownloadJobStateCompleted: return @"completed";
        case DownloadJobStateInterrupted: return @"interrupted";
    }
    return @"unknown";
}

// MARK: - 真实传输后端（NSURLSession）

// NSURLSessionTask 的控制 API 与 RDDownloadTask 协议不同。不能靠强制类型转换
// 冒充协议，否则错误清理时向系统任务发送 rd_cancel 会直接触发未识别 selector 崩溃。
@interface SessionDownloadTaskAdapter : NSObject <RDDownloadTask>
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
// 取消时要一并销毁“换连接重发”的一次性会话（主会话传 nil，不动主连接池）。
@property (nonatomic, copy, nullable) void (^cancelHook)(void);
@property BOOL validationComplete;
@property BOOL paused;
@property BOOL cancelled;
- (instancetype)initWithTask:(NSURLSessionDownloadTask *)task;
@end

@implementation SessionDownloadTaskAdapter

- (instancetype)initWithTask:(NSURLSessionDownloadTask *)task {
    self = [super init];
    if (self) _task = task;
    return self;
}

- (void)rd_cancel {
    self.cancelled = YES;
    [self.task cancel];
    if (self.cancelHook) { void (^hook)(void) = self.cancelHook; self.cancelHook = nil; hook(); }
}
- (void)rd_suspend { if (self.paused) return; self.paused = YES; if (self.validationComplete) [self.task suspend]; }
- (void)rd_resume { if (!self.paused || self.cancelled) return; self.paused = NO; if (self.validationComplete) [self.task resume]; }

@end

// A slot is retained until its backend completion has been observed.  In
// particular, cancellation does not release capacity just because cancel was
// requested: NSURLSession reports that asynchronously.
@interface RDDownloadTaskSlot : NSObject
@property (nonatomic, strong) id<RDDownloadTask> task;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *jobIdentifier;
@end

@implementation RDDownloadTaskSlot
@end

@interface SessionDownloadBackend : NSObject <RDDownloadBackend, NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
// 键 = "会话地址#taskIdentifier"：taskIdentifier 只在单个会话内唯一，而“换连接重发”
// 引入了第二个会话，必须把会话身份并入键，否则两个会话的同号任务会互相覆盖上下文。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *contexts;
// 换连接重发用的一次性会话（键同 contexts）：请求结束/取消即销毁，绝不把这条
// 新连接留给后续请求复用（否则又会骑回被晾住的连接）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLSession *> *reissueSessions;
@property (nonatomic, strong) URLPolicy *urlPolicy;
- (NSString *)contextKeyForSession:(NSURLSession *)session task:(NSURLSessionTask *)task;
- (void)invalidateReissueSessionForKey:(NSString *)key;
@end

static NSString *RDPeerIPFromMetricsAddress(NSString *address) {
    if (!address.length) return @"";
    NSString *s = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([s hasPrefix:@"["]) { NSRange close=[s rangeOfString:@"]"]; if (close.location!=NSNotFound) return [s substringWithRange:NSMakeRange(1, close.location-1)]; }
    // NSURLSession commonly reports IPv4 as "a.b.c.d:port".  Do not split
    // an unbracketed IPv6 address, which contains multiple colons.
    NSUInteger colons = [[s componentsSeparatedByString:@":"] count] - 1;
    if (colons == 1) return [s componentsSeparatedByString:@":"].firstObject;
    return s;
}

static BOOL RDPeerAddressAllowedForIPs(NSString *address, NSArray<NSString *> *allowed) {
    NSString *peer = RDPeerIPFromMetricsAddress(address);
    if (!peer.length || !allowed.count) return NO;
    for (NSString *ip in allowed) if ([peer caseInsensitiveCompare:ip] == NSOrderedSame) return YES;
    return NO;
}

@implementation SessionDownloadBackend

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPCookieStorage = nil; cfg.URLCredentialStorage = nil; cfg.HTTPShouldSetCookies = NO;
        // 下载页必须在无网络/失效 CDN 时快速给出结果，不能无限等待系统恢复连接。
        cfg.waitsForConnectivity = NO;
        cfg.discretionary = NO;
        // Twelve simultaneous videos can make a healthy CDN slow to deliver
        // its first packet. Eight seconds turned that startup variance into a
        // permanent failure, so allow a realistic idle window and let the
        // manager perform bounded retries for genuinely transient errors.
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 7 * 24 * 3600;
        cfg.networkServiceType = NSURLNetworkServiceTypeResponsiveData;
        cfg.HTTPMaximumConnectionsPerHost = [PerformancePolicy downloadConnections]; // 连接数只从 PerformancePolicy 获取
        // 测试逃生口（env 门控，默认不设置=系统代理，生产行为不变）：无 GUI 真实下载
        // 测试在系统代理环境下用 RD_SESSION_PROXY_OVERRIDE=direct 强制直连，
        // 否则对端地址校验只能看到代理地址（2026-09-19 现场证据：19/19 站下载被拒）。
        if ([NSProcessInfo.processInfo.environment[@"RD_SESSION_PROXY_OVERRIDE"] isEqualToString:@"direct"]) {
            cfg.connectionProxyDictionary = @{};
        }
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
        _contexts = [NSMutableDictionary dictionary];
        _reissueSessions = [NSMutableDictionary dictionary];
        _urlPolicy = [URLPolicy new];
    }
    return self;
}

- (NSString *)contextKeyForSession:(NSURLSession *)session task:(NSURLSessionTask *)task {
    return [NSString stringWithFormat:@"%p#%ld", (void *)session, (long)task.taskIdentifier];
}

- (void)invalidateReissueSessionForKey:(NSString *)key {
    if (!key.length) return;
    NSURLSession *session = self.reissueSessions[key];
    if (!session) return;
    [self.reissueSessions removeObjectForKey:key];
    [session finishTasksAndInvalidate];
}

// 停滞重发专用入口：脱离主连接池，在一次性 ephemeral 会话里重发同一请求。
// 本机实测（2026-09-10，本地服务器 ACCEPT 计数 + lsof）：新 NSURLSession 会新建
// TCP 连接，不复用主会话里那条可能已被 CDN 晾住的连接。用完即销毁该会话。
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request
                             writeToURL:(NSURL *)writeToURL
                               progress:(void (^)(int64_t, int64_t, int64_t))progress
                             completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPCookieStorage = nil; cfg.URLCredentialStorage = nil; cfg.HTTPShouldSetCookies = NO;
    cfg.waitsForConnectivity = NO;
    cfg.discretionary = NO;
    cfg.timeoutIntervalForRequest = 30;
    cfg.timeoutIntervalForResource = 7 * 24 * 3600;
    cfg.networkServiceType = NSURLNetworkServiceTypeResponsiveData;
    cfg.HTTPMaximumConnectionsPerHost = 1; // 一次重发只用这一条新连接
    // 与主会话同一测试逃生口：重发是新会话，若不跟随直连覆盖，系统代理路径下
    // 重试连接的对端校验必然失败（2026-09-19 现场：分段 7 重试被拒）。
    if ([NSProcessInfo.processInfo.environment[@"RD_SESSION_PROXY_OVERRIDE"] isEqualToString:@"direct"]) {
        cfg.connectionProxyDictionary = @{};
    }
    NSURLSession *fresh = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    NSMutableURLRequest *sanitized = [request mutableCopy];
    [HTTPPrivacyPolicy sanitizeMediaRequest:sanitized];
    NSURLSessionDownloadTask *task = [fresh downloadTaskWithRequest:sanitized];
    NSString *key = [self contextKeyForSession:fresh task:task];
    self.contexts[key] = [@{
        @"writeToURL": writeToURL,
        @"completion": [completion copy],
        @"progress": progress ? [progress copy] : [NSNull null],
        @"validatedIPs": [NSMutableDictionary dictionary],
        @"metricsReceived": @NO,
        @"metricsDeadline": [NSDate dateWithTimeIntervalSinceNow:1.0],
        @"done": @NO,
    } mutableCopy];
    self.reissueSessions[key] = fresh;
    SessionDownloadTaskAdapter *adapter = [[SessionDownloadTaskAdapter alloc] initWithTask:task];
    adapter.cancelHook = ^{ [self invalidateReissueSessionForKey:key]; };
    RDDownloadLog(@"换新连接重发：新建一次性会话 task=%ld 写入=%@", (long)task.taskIdentifier, writeToURL.path ?: @"");
    RDValidateNetworkURLWithIPs(request.URL,self.urlPolicy,nil,^(URLPolicyDecision *decision, NSArray *ips) {
        if (adapter.cancelled) { [self invalidateReissueSessionForKey:key]; return; }
        if (!decision.allowed) {
            NSError *error = [NSError errorWithDomain:@"RDNetworkPolicy" code:1 userInfo:@{NSLocalizedDescriptionKey:decision.userMessage ?: @"下载地址被安全策略拒绝"}];
            [self finishForSession:fresh task:task withURL:nil response:nil error:error];
            [adapter rd_cancel];
            return;
        }
        [(NSMutableDictionary *)self.contexts[key][@"validatedIPs"] setObject:ips ?: @[] forKey:request.URL.absoluteString ?: @""];
        adapter.validationComplete = YES;
        if (!adapter.paused) [task resume];
    });
    return adapter;
}

- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}

- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    NSMutableURLRequest *sanitized = [request mutableCopy];
    [HTTPPrivacyPolicy sanitizeMediaRequest:sanitized];
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:sanitized];
    NSString *contextKey = [self contextKeyForSession:self.session task:task];
    self.contexts[contextKey] = [@{
        @"writeToURL": writeToURL,
        @"completion": [completion copy],
        @"progress": progress ? [progress copy] : [NSNull null],
        @"validatedIPs": [NSMutableDictionary dictionary],
        @"metricsReceived": @NO,
        @"metricsDeadline": [NSDate dateWithTimeIntervalSinceNow:1.0],
        @"done": @NO,
    } mutableCopy];
    SessionDownloadTaskAdapter *adapter = [[SessionDownloadTaskAdapter alloc] initWithTask:task];
    RDValidateNetworkURLWithIPs(request.URL,self.urlPolicy,nil,^(URLPolicyDecision *decision, NSArray *ips) {
        if (adapter.cancelled) return;
        if (!decision.allowed) {
            NSError *error = [NSError errorWithDomain:@"RDNetworkPolicy" code:1 userInfo:@{NSLocalizedDescriptionKey:decision.userMessage ?: @"下载地址被安全策略拒绝"}];
            [self finishForSession:self.session task:task withURL:nil response:nil error:error]; [adapter rd_cancel]; return;
        }
        [(NSMutableDictionary *)self.contexts[contextKey][@"validatedIPs"] setObject:ips ?: @[] forKey:request.URL.absoluteString ?: @""];
        adapter.validationComplete = YES;
        if (!adapter.paused) [task resume];
    });
    return adapter;
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSDictionary *ctx = self.contexts[[self contextKeyForSession:session task:downloadTask]];
    id block = ctx[@"progress"];
    if (block && block != [NSNull null]) {
        ((void (^)(int64_t, int64_t, int64_t))block)(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSDictionary *ctx = self.contexts[[self contextKeyForSession:session task:downloadTask]];
    if (!ctx) return;
    NSURL *writeToURL = ctx[@"writeToURL"];
    NSNumber *receivedBytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil] objectForKey:NSFileSize];
    NSError *moveError = nil;
    // 绝不删除任何已存在文件（含临时路径）：目标已存在时改用唯一名落盘，
    // 由上层按业务决定最终命名，避免误删用户文件（hotfix: 下载目标丢失）。
    NSURL *dest = writeToURL;
    if ([[NSFileManager defaultManager] fileExistsAtPath:writeToURL.path]) {
        NSString *alt = [NSString stringWithFormat:@"%@-%@.tmp",
                         writeToURL.lastPathComponent.stringByDeletingPathExtension ?: @"part",
                         NSUUID.UUID.UUIDString];
        dest = [writeToURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:alt];
    }
    RDDownloadLog(@"task=%ld 传输完成：临时 %@（%lld 字节）→ move 至 %@%@",
                  (long)downloadTask.taskIdentifier, location.path, receivedBytes.longLongValue,
                  dest.path, [dest isEqual:writeToURL] ? @"" : @"（目标已存在，改用唯一名）");
    BOOL ok = [[NSFileManager defaultManager] moveItemAtURL:location toURL:dest error:&moveError];
    if (!ok) {
        RDDownloadLog(@"task=%ld move 失败：%@ → %@ 错误：%@", (long)downloadTask.taskIdentifier,
                      location.path, dest.path, moveError.localizedDescription ?: @"未知");
        [self finishForSession:session task:downloadTask withURL:nil response:(NSHTTPURLResponse *)downloadTask.response error:moveError];
        return;
    }
    NSMutableDictionary *m = [self.contexts[[self contextKeyForSession:session task:downloadTask]] mutableCopy];
    m[@"writtenURL"] = dest;
    m[@"writtenResponse"] = (NSHTTPURLResponse *)downloadTask.response ?: [NSNull null];
    if (m) self.contexts[[self contextKeyForSession:session task:downloadTask]] = m;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    NSString *key = [self contextKeyForSession:session task:task];
    NSMutableDictionary *ctx = [self.contexts[key] mutableCopy];
    if (!ctx) return;
    NSMutableDictionary *validated = ctx[@"validatedIPs"];
    BOOL ok = YES;
    for (NSURLSessionTaskTransactionMetrics *tx in metrics.transactionMetrics) {
        NSString *address = tx.remoteAddress;
        if (!address.length) { ok = NO; break; }
        // 经系统代理的连接：remoteAddress 是用户自己的代理地址（2026-09-19 实测
        // remoteAddress=127.0.0.1 isProxyConnection=YES），与目标 DNS 解析 IP 比对
        // 必然失配 —— 此前系统代理环境下所有下载 100% 被拒。代理场景下对端校验
        // 不适用；SSRF 防线仍由请求前的 DNS 预检 + IP 分类（fail-closed）承担。
        if (tx.isProxyConnection) continue;
        NSArray *ips = validated[tx.request.URL.absoluteString ?: @""];
        if (!RDPeerAddressAllowedForIPs(address, ips)) { ok = NO; break; }
    }
    ctx[@"peerValidated"] = @(ok && metrics.transactionMetrics.count > 0);
    ctx[@"metricsReceived"] = @YES;
    self.contexts[key] = ctx;
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
          newRequest:(NSURLRequest *)request
   completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *target = request.URL;
    NSURL *from = response.URL ?: task.currentRequest.URL;
    URLPolicyDecision *text = [self.urlPolicy evaluateRedirect:target fromURL:from];
    if (!text.allowed) {
        completionHandler(nil);
        return;
    }
    // Public transport headers survive redirects; sensitive headers are hop-local.
    NSMutableURLRequest *redirectRequest = [request mutableCopy];
    NSURLRequest *original = task.originalRequest;
    NSString *userAgent = [original valueForHTTPHeaderField:@"User-Agent"];
    if (userAgent.length) [redirectRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    NSString *acceptEncoding = [original valueForHTTPHeaderField:@"Accept-Encoding"];
    if (acceptEncoding.length) [redirectRequest setValue:acceptEncoding forHTTPHeaderField:@"Accept-Encoding"];
    NSMutableURLRequest *previous = [task.currentRequest mutableCopy];
    previous.URL = from;
    [HTTPPrivacyPolicy sanitizeRedirectRequest:redirectRequest fromRequest:previous];
    RDValidateNetworkURLWithIPs(target,self.urlPolicy,nil,^(URLPolicyDecision *decision, NSArray *ips) {
        if (decision.allowed) {
            NSString *key = [self contextKeyForSession:session task:task];
            NSMutableDictionary *ctx = [self.contexts[key] mutableCopy];
            if (ctx) {
                NSMutableDictionary *validated = [ctx[@"validatedIPs"] mutableCopy] ?: [NSMutableDictionary dictionary];
                validated[target.absoluteString ?: @""] = ips ?: @[];
                ctx[@"validatedIPs"] = validated;
                self.contexts[key] = ctx;
            }
        }
        completionHandler(decision.allowed ? redirectRequest : nil);
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *key = [self contextKeyForSession:session task:task];
    NSMutableDictionary *ctx = [self.contexts[key] mutableCopy];
    if (error) {
        RDDownloadLog(@"task=%ld 传输层错误：%ld %@（URL %@）", (long)task.taskIdentifier,
                      (long)error.code, error.localizedDescription ?: @"", RDRedactedURL(task.originalRequest.URL));
        [self finishForSession:session task:task withURL:nil response:(NSHTTPURLResponse *)task.response error:error];
    } else if (ctx) {
        // NSURLSession delivers metrics immediately around task completion;
        // allow the metrics delegate turn to arrive before deciding fail-closed.
        NSDate *metricsDeadline = ctx[@"metricsDeadline"];
        if (![ctx[@"metricsReceived"] boolValue] && metricsDeadline.timeIntervalSinceNow > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self URLSession:session task:task didCompleteWithError:nil];
            });
            return;
        }
        NSError *peerError = nil;
        if (![ctx[@"metricsReceived"] boolValue] || ![ctx[@"peerValidated"] boolValue]) {
            peerError = [NSError errorWithDomain:@"RDNetworkPolicy" code:2 userInfo:@{NSLocalizedDescriptionKey:@"无法确认下载连接的实际对端地址，已拒绝保存资源"}];
        }
        NSURL *written = ctx[@"writtenURL"];
        NSHTTPURLResponse *resp = ctx[@"writtenResponse"] == [NSNull null] ? nil : ctx[@"writtenResponse"];
        [self finishForSession:session task:task withURL:peerError ? nil : written response:resp error:peerError];
    }
    // 无错误且无 finish（已 didFinishDownloading）则忽略
}

- (void)finishForSession:(NSURLSession *)session task:(NSURLSessionTask *)task withURL:(NSURL *)url response:(NSHTTPURLResponse *)response error:(NSError *)error {
    NSString *key = [self contextKeyForSession:session task:task];
    NSDictionary *ctx = self.contexts[key];
    if (!ctx) return;
    if ([ctx[@"done"] boolValue]) return;
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:ctx];
    m[@"done"] = @YES;
    self.contexts[key] = m;
    void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *) = ctx[@"completion"];
    if (completion) completion(url, response, error);
    [self.contexts removeObjectForKey:key];
    // 一次性重发会话到此为止：销毁它，绝不复用这条（可能仍被晾住的）连接。
    [self invalidateReissueSessionForKey:key];
}

@end

// MARK: - DownloadManager

@interface DownloadManager ()
@property (nonatomic, strong) id<RDDownloadBackend> backend;
@property (nonatomic, strong) NSURL *tempRoot;
@property (nonatomic, strong) DownloadStore *store;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadJob *> *jobs;
@property (nonatomic, copy) NSString *latestEnqueuedJobIdentifier;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *activeTasks; // identifier -> [RDDownloadTask]
@property (nonatomic, strong) NSMutableSet<NSString *> *reservedNames;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTimer *> *progressWatchdogs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *segmentBytes;
// **本次尝试**已收字节（换连接重发即归零）。与 segmentBytes（跨尝试累计，供进度/整池恢复判定）
// 严格区分：停滞窗口必须按"本次尝试收到没有"选，否则刚换上的新连接会被旧尝试的累计字节
// 判成"有字节"，提前套用 3s 窗口、在无证据的情况下被再次取消。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *segmentAttemptBytes;
// BUG-006：每个段**实际落盘的那个文件**（后端在规范路径已存在时会改用旁路唯一名落盘）。
// 合并必须按这里登记的路径读取，不能假设「段 i 的内容一定在 NNN.part 里」——否则
// 一旦发生过旁路落盘（恢复时重排段数、换连接重发、迟到回调抢写），合并读到的就是
// 上一会话/上一次尝试的陈旧分片。缺失时回退规范路径，语义与修复前完全一致。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSURL *> *> *partURLsAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSDictionary *> *> *segmentRateSamples;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastProgressAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *transferSamples;
@property (nonatomic, strong) NSMutableArray<NSString *> *queuedJobIdentifiers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDDownloadTaskSlot *> *taskSlotsByToken;
@property (nonatomic, strong) NSMutableSet<RDDownloadTaskSlot *> *cancellingTaskSlots;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastDiskCheckAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *retryAttempts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *retryDeferrals;
// 每个任务的分段失败计数（键为“任务标识#index”），与任务级重试严格隔离。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *segmentRetryAttempts;
// 分段重试因全局连接占满而顺延的计数（键同上）：顺延等待不消耗重试预算，
// 只受独立上限约束（与任务级 retryDeferrals 同一语义）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *segmentRetryDeferrals;
// 分段停滞检测（键“任务#index”）：每段最近一次收到字节的时刻、当前在途任务的
// token、以及该段已被停滞重发的次数。token 用于丢弃“被取消旧任务”的迟到回调，
// 避免它把已换连接重发的任务误判失败。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSDate *> *> *segmentProgressAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSString *> *> *segmentTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *segmentStallAttempts;
// 整池被晾（多数在途段同时无数据）的换连接轮次与下次允许时刻（键=任务标识）。
// 与 segmentStallAttempts（单段重发额度）严格隔离：整池发作不烧单段预算。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *poolStallRounds;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *poolStallNextAllowedAt;
// 上一轮换连接时的“各段累计已收字节”基线：只有基线之后确实收到了新字节，
// 才认定这一轮整池发作结束并复位轮次——换连接本身（进度基准被刷新）不是恢复证据。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *poolStallBytesAtLastRound;
// 临时短响应（截断/少收字节）的任务级重试计数，同样有硬上限。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *shortBodyRetryAttempts;
@property (nonatomic, assign) NSInteger batchEnqueueDepth;
@property (nonatomic, assign) BOOL pumpingQueuedJobs;
@property (nonatomic, assign) BOOL queuePumpSuppressed;
@property (nonatomic, strong) DownloadCapabilityProbe *capabilityProbe;
@property (nonatomic, strong) NSMutableSet<NSString *> *capabilityProbePending;
@property (nonatomic, strong) NSMutableSet<NSString *> *capabilityProbeCompleted;
// 能力探测的瞬时失败（超时等）顺延重试计数（键为任务标识）。探测固定 10s 超时，
// 站点劣化时（实测 TCP 建连 20–86s、TTFB 21s）必然超时；超时是瞬态故障，
// 必须有限重试，绝不能像确定性答复（403/404、非媒体响应）那样永久降级为单连接。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *capabilityProbeAttempts;
@property (nonatomic, strong) AdaptiveTransferScheduler *transferScheduler;
// 本实例已认领的临时目录：目录路径 → 持有的 flock 文件描述符。持有期内该目录
// 对**任何**实例（含本进程内的其他 DownloadManager）都是“活的”，清理必须跳过。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *tempDirClaimDescriptors;
// 认领**失败**（被其他实例持有）的目录：本实例绝不对它们做写入、取消删除或恢复记录改写。
@property (nonatomic, strong) NSMutableSet<NSString *> *tempDirForeignPaths;
// BUG-013: merge and final move must not run on the AppKit main queue.
@property (nonatomic, strong) dispatch_queue_t finalizationQueue;
@end

@interface DownloadManager ()
@property NSMutableDictionary<NSString *, NSNumber *> *validatedEndpointGenerations;
@property NSMutableSet<NSString *> *endpointChecksPending;
// DNS 解析超时的端点复查顺延计数（键为任务标识）：超时是瞬态故障，允许
// 有限次顺延重查；与传输层重试预算无关，耗尽后按“DNS 解析超时”失败。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *endpointResolutionRetries;
@end

@implementation DownloadManager

+ (NSString *)sourceIdentityForURL:(NSURL *)url {
    return RDCanonicalResourceURL(url);
}

- (instancetype)initWithBackend:(id<RDDownloadBackend>)backend
                       tempRoot:(NSURL *)tempRoot
                          store:(DownloadStore *)store {
    self = [super init];
    if (self) {
        _backend = backend;
        _tempRoot = tempRoot;
        _store = store;
        _jobs = [NSMutableDictionary dictionary];
        _latestEnqueuedJobIdentifier = [store latestEnqueuedJobIdentifier];
        _activeTasks = [NSMutableDictionary dictionary];
        _reservedNames = [NSMutableSet set];
        _progressWatchdogs = [NSMutableDictionary dictionary];
        _segmentBytes = [NSMutableDictionary dictionary];
        _segmentAttemptBytes = [NSMutableDictionary dictionary];
        _partURLsAt = [NSMutableDictionary dictionary];
        _segmentRateSamples = [NSMutableDictionary dictionary];
        _lastProgressAt = [NSMutableDictionary dictionary];
        _transferSamples = [NSMutableDictionary dictionary];
        _queuedJobIdentifiers = [NSMutableArray array];
        _taskSlotsByToken = [NSMutableDictionary dictionary];
        _cancellingTaskSlots = [NSMutableSet set];
        _lastDiskCheckAt = [NSMutableDictionary dictionary];
        _retryAttempts = [NSMutableDictionary dictionary];
        _retryDeferrals = [NSMutableDictionary dictionary];
        _segmentRetryAttempts = [NSMutableDictionary dictionary];
        _segmentRetryDeferrals = [NSMutableDictionary dictionary];
        _segmentProgressAt = [NSMutableDictionary dictionary];
        _segmentTokens = [NSMutableDictionary dictionary];
        _segmentStallAttempts = [NSMutableDictionary dictionary];
        _poolStallRounds = [NSMutableDictionary dictionary];
        _poolStallNextAllowedAt = [NSMutableDictionary dictionary];
        _poolStallBytesAtLastRound = [NSMutableDictionary dictionary];
        _shortBodyRetryAttempts = [NSMutableDictionary dictionary];
        _tempDirClaimDescriptors = [NSMutableDictionary dictionary];
        _tempDirForeignPaths = [NSMutableSet set];
        _finalizationQueue = dispatch_queue_create("com.sevenzz.resourcedetector.download.finalization", DISPATCH_QUEUE_SERIAL);
        _capabilityProbe = [DownloadCapabilityProbe new];
        _capabilityProbePending = [NSMutableSet set];
        _capabilityProbeCompleted = [NSMutableSet set];
        _capabilityProbeAttempts = [NSMutableDictionary dictionary];
        _transferScheduler = [[AdaptiveTransferScheduler alloc] initWithInitialWindow:[PerformancePolicy downloadConnections]
                                                                  maximumWindow:[PerformancePolicy downloadConnections]];
        _batchEnqueueDepth = 0;
        // 下载入队不能同步等待系统 DNS；文本策略仍会拦截无效/私有地址。
        // 解析复查由调用方在不阻塞 UI 的场景显式开启。
        _rd_enableEndpointResolution = YES;
        _validatedEndpointGenerations = [NSMutableDictionary dictionary];
        _endpointChecksPending = [NSMutableSet set];
        _endpointResolutionRetries = [NSMutableDictionary dictionary];
        [[NSFileManager defaultManager] createDirectoryAtURL:tempRoot
                                 withIntermediateDirectories:YES
                                                  attributes:nil error:nil];
        NSDictionary *saved=[store interruptedRecords];
        [saved enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSDictionary *d, BOOL *stop){
            if (![d isKindOfClass:NSDictionary.class]) return;
            NSURL *source=[NSURL URLWithString:d[@"sourceURL"]], *dest=[NSURL URLWithString:d[@"destinationURL"]], *tmp=[NSURL URLWithString:d[@"tempRootURL"]];
            if (!source||!dest||!tmp||!source.host.length) return;
            DownloadJob *j=[DownloadJob new]; if ([d[@"enqueuedAt"] isKindOfClass:NSDate.class]) j.enqueuedAt=d[@"enqueuedAt"]; j.identifier=identifier; j.sourceURL=source; j.destinationURL=dest; j.tempRootURL=tmp; j.fileName=d[@"fileName"]?:dest.lastPathComponent; j.referer=d[@"referer"]; j.expectedContentLength=[d[@"expectedLength"] longLongValue]; j.authoritativeExpectedLength=j.expectedContentLength; j.etag=d[@"etag"]?:@""; j.lastModified=d[@"lastModified"]?:@""; j.acceptRanges=[d[@"acceptRanges"] boolValue]; j.resourceKind=[d[@"resourceKind"] integerValue]; j.segmented=[d[@"segmented"] boolValue]; j.segmentCount=[d[@"segmentCount"] integerValue]; j.finishedSegments=[d[@"finishedSegments"] integerValue]; j.streamMasterURL=d[@"streamMasterURL"]; j.sourcePageURL=d[@"sourcePageURL"]; j.qualityHint=d[@"qualityHint"]; j.resourceTitle=d[@"resourceTitle"]; [j transitionTo:DownloadJobStateInterrupted]; self.jobs[identifier]=j; [self.reservedNames addObject:j.fileName];
            // 恢复先于清理：中断任务的目录是**活的**，必须重新认领，绝不能被启动清理当孤儿删掉。
            [self claimTempDirectoryForJob:j];
            if (![self ownsTempDirectoryAtPath:j.tempRootURL.path]) {
                // R2：认领失败 = 目录被另一实例持有。保守处理：任务对用户可见、
                // 保持 Interrupted，但本实例绝不启动写入、不删除目录、不改写其恢复记录。
                j.errorText = @"该下载正由另一个实例处理，本实例不会改动它";
                RDDownloadLog(@"恢复冲突 id=%@ 目录由另一实例持有，本实例仅展示不操作", identifier);
            }
        }];
        // 孤儿清理必须在中断恢复**之后**：旧实现把清理放在恢复之前，此时 self.jobs 还是空的，
        // 会把所有历史任务目录（含即将恢复的中断任务目录）一并删除。
        [self cleanupOrphanTempDirs];
        // 恢复终态任务追溯记录（仅展示：完成/失败/取消的最终路径与状态）。
        // 绝不参与去重/续传；文件已被用户删除的完成任务仍允许重新下载。
        for (NSDictionary *record in [store finishedJobRecords]) {
            NSString *identifier = record[@"identifier"];
            NSString *destString = record[@"destinationURL"];
            if (identifier.length == 0) continue;
            DownloadJob *j = [DownloadJob new];
            j.identifier = identifier;
            j.sourceURL = [NSURL URLWithString:record[@"sourceURL"]] ?: [NSURL URLWithString:@""];
            j.destinationURL = destString.length ? [NSURL URLWithString:destString] : nil;
            j.fileName = record[@"fileName"] ?: j.destinationURL.lastPathComponent;
            j.expectedContentLength = [record[@"expectedLength"] longLongValue];
            j.authoritativeExpectedLength = j.expectedContentLength;
            j.errorText = record[@"errorText"];
            if ([record[@"enqueuedAt"] isKindOfClass:NSDate.class]) j.enqueuedAt = record[@"enqueuedAt"];
            else if ([record[@"finishedAt"] isKindOfClass:NSDate.class]) j.enqueuedAt = record[@"finishedAt"];
            NSInteger recordedState = [record[@"state"] integerValue];
            [j restoreTerminalState:(DownloadJobState)recordedState];
            if (j.state == DownloadJobStateCompleted) { j.progress = 1; j.transferredBytes = j.expectedContentLength; }
            if (j.state == DownloadJobStateQueued) continue; // 非法记录不进列表
            self.jobs[identifier] = j;
        }
        if ([store finishedJobRecords].count || saved.count) {
            RDDownloadLog(@"启动恢复：中断任务 %lu 个，终态历史 %lu 条",
                          (unsigned long)saved.count, (unsigned long)[store finishedJobRecords].count);
        }
    }
    return self;
}

+ (instancetype)sharedManager {
    static DownloadManager *mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"7zz-downloads"];
        SessionDownloadBackend *backend = [SessionDownloadBackend new];
        // 生产：叠加 curl 按跳回退后端（Cloudflare 系宿主按栈指纹 403/挂起原生
        // 传输时换栈重试，2026-09-19 真实站点根因）。运行时查类以保持本文件可被
        // 测试套件单独链接——套件不编译 App 层的 RDCurlFallbackBackend，查类为
        // nil 时即纯原生后端，行为与从前完全一致。
        Class fallbackClass = NSClassFromString(@"RDCurlFallbackBackend");
        id<RDDownloadBackend> effectiveBackend = backend;
        if (fallbackClass && [fallbackClass respondsToSelector:@selector(backendWithNativeBackend:)]) {
            id wrapper = [fallbackClass performSelector:@selector(backendWithNativeBackend:) withObject:backend];
            if (wrapper) effectiveBackend = wrapper;
        }
        // 独立 App 的完成/中断记录写入自身 bundle id 的 standard defaults，
        // 与 SevenZZ 主 App 完全解耦，换机后从空白记录开始。
        DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:[NSUserDefaults standardUserDefaults]];
        mgr = [[DownloadManager alloc] initWithBackend:effectiveBackend
                                             tempRoot:[NSURL fileURLWithPath:tmp]
                                                store:store];
    });
    return mgr;
}

#pragma mark - 能力探测结论分类

// 探测失败分两类，处理方式必须不同：
//   * 瞬时失败（超时 / 无正文响应）：站点此刻忙或网络抖动，重试即可恢复 ⇒ 有限重试。
//   * 确定性答复（403/404/410、非媒体响应等）：资源确实不支持分段 ⇒ 直接单连接，不重试。
// 旧代码把两类都当确定性答复：一旦超时就永久标记“探测已完成”并把任务降级成单连接
// （实测 1.67–2.01 MB/s），而站点劣化时探测几乎必然超时 ⇒ 分段提速被永久封死。
+ (BOOL)rd_isTransientProbeFailure:(ZZDownloadCapability *)cap {
    if (cap == nil) return YES;                 // 探测对象缺失：按瞬时处理
    if (cap.bodyResponsive) return NO;          // 已经收到正文：不是失败
    NSString *reason = cap.failureReason ?: @"";
    if ([reason containsString:@"超时"] || [reason containsString:@"timeout"]
        || [reason containsString:@"timed out"]) return YES;
    // 未拿到状态码且无正文 ⇒ 连接层面没走通，属瞬时
    if (cap.statusCode == 0) return YES;
    // 拿到 2xx 却没有任何正文：服务器接受了请求但没送数据，属瞬时
    if (cap.statusCode >= 200 && cap.statusCode < 300) return YES;
    return NO;                                  // 其余（4xx/5xx）不重试
}

#pragma mark - URL 安全校验（下载层防线）

// 统一入口：文本校验 + DNS 解析后全 IP 校验。返回非 nil 时表示被拒绝（含用户提示）。
- (nullable URLPolicyDecision *)rd_validateSourceURL:(NSURL *)url {
    URLPolicy *policy = self.urlPolicy ?: [URLPolicy new];
    if (url == nil || url.absoluteString.length == 0) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:@"地址无效"];
    }
    URLPolicyDecision *text = [policy evaluateTextURL:url.absoluteString];
    if (!text.allowed) return text;
    // DNS validation is asynchronous in startQueuedJobs; never block the main thread.
    return nil;
}

#pragma mark - 下载大小 / 磁盘限制（资源耗尽防护）

// 入队阶段限制检查：单文件大小、在途总大小（expectedContentLength 仅作提示性累计）、
// 目标卷剩余空间。返回非 nil 为拒绝原因。
- (nullable NSString *)rd_downloadLimitReasonForLength:(int64_t)length folder:(NSURL *)folder {
    if (length > [PerformancePolicy downloadMaxSingleFileBytes]) {
        return @"文件大小超过单文件下载上限";
    }
    int64_t total = MAX(0, length);
    for (DownloadJob *j in self.jobs.allValues) {
        if (j.state == DownloadJobStateRunning || j.state == DownloadJobStatePaused || j.state == DownloadJobStateQueued) {
            total += MAX(0, j.expectedContentLength);
        }
    }
    if (total > [PerformancePolicy downloadMaxTotalBytes]) {
        return @"在途下载总量超过上限";
    }
    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:folder.path error:nil];
    NSNumber *free = fs[NSFileSystemFreeSize];
    // 只有“确实读到剩余空间、且低于阈值”才拒绝。取不到卷信息时（目标目录尚未创建、
    // 卷暂时不可读/未挂载）绝不能把“未知”当成 0：现场证据（2026-09-10）目标目录
    // 不存在 → 明明可用 146Gi 却报“磁盘剩余空间不足，已停止下载”，入队即被拒。
    // 与运行期检查 checkRuntimeLimitsForJob 的 `free && …` 语义保持一致。
    if (free && free.longLongValue < [PerformancePolicy minimumFreeDiskSpace]) {
        return @"磁盘剩余空间不足，已停止下载";
    }
    return nil;
}

#pragma mark - 入队

- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url
                                   folder:(NSURL *)destinationFolder
                            preferredName:(NSString *)name
                                     etag:(NSString *)etag
                              lastModified:(NSString *)lastModified
                              acceptRanges:(BOOL)acceptRanges
                           expectedLength:(int64_t)length {
    // 修正：此前该便捷入口把 etag/lastModified/acceptRanges 静默丢弃，
    // 导致调用方带入的探测结果（Range 支持等）全部失效。
    return [self rd_enqueueItemWithSourceURL:url folder:destinationFolder preferredName:name
                               sourcePageURL:nil resourceKind:DownloadResourceVideo
                                        etag:etag lastModified:lastModified
                                acceptRanges:acceptRanges expectedLength:length];
}

- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url folder:(NSURL *)destinationFolder preferredName:(NSString *)name sourcePageURL:(NSString *)sourcePageURL resourceKind:(DownloadResourceKind)kind expectedLength:(int64_t)length {
    return [self rd_enqueueItemWithSourceURL:url folder:destinationFolder preferredName:name
                               sourcePageURL:sourcePageURL resourceKind:kind
                                        etag:@"" lastModified:@"" acceptRanges:NO expectedLength:length];
}

// 入队唯一实现：必须在任务启动（startQueuedJobs）之前带上全部探测参数，
// 否则同步启动会让事后回填永远失效。
- (DownloadJob *)rd_enqueueItemWithSourceURL:(NSURL *)url
                                      folder:(NSURL *)destinationFolder
                               preferredName:(NSString *)name
                                sourcePageURL:(NSString *)sourcePageURL
                                 resourceKind:(DownloadResourceKind)kind
                                         etag:(NSString *)etag
                                 lastModified:(NSString *)lastModified
                                 acceptRanges:(BOOL)acceptRanges
                               expectedLength:(int64_t)length {
    NSString *sourceIdentity=[DownloadManager sourceIdentityForURL:url];
    for(DownloadJob *existing in self.jobs.allValues){
        if(!sourceIdentity.length||![[DownloadManager sourceIdentityForURL:existing.sourceURL] isEqualToString:sourceIdentity])continue;
        BOOL inFlight=existing.state==DownloadJobStateQueued||existing.state==DownloadJobStateRunning||
            existing.state==DownloadJobStatePaused||existing.state==DownloadJobStateCancelling;
        BOOL completedFileStillExists=existing.state==DownloadJobStateCompleted&&
            [[NSFileManager defaultManager] fileExistsAtPath:existing.destinationURL.path];
        if(inFlight||completedFileStillExists)return existing;
    }
    DownloadJob *job = [[DownloadJob alloc] init];
    job.sourceURL = url;
    job.referer = sourcePageURL.length ? sourcePageURL : self.defaultReferer;
    job.sourcePageURL = sourcePageURL;
    job.resourceKind = kind;
    job.enqueuedAt = [NSDate date];
    self.latestEnqueuedJobIdentifier = job.identifier;
    [self.store setLatestEnqueuedJobIdentifier:job.identifier];
    job.etag = etag ?: @"";
    job.lastModified = lastModified ?: @"";
    job.acceptRanges = acceptRanges;
    job.expectedContentLength = length;
    job.authoritativeExpectedLength = length;

    // SSRF 防线：入队时文本 + DNS 解析后全 IP 校验，不通过直接失败（绝不发起传输）。
    URLPolicyDecision *rejected = [self rd_validateSourceURL:url];
    if (rejected) {
        job.errorText = rejected.userMessage.length ? rejected.userMessage : @"地址被安全策略阻止";
        [job transitionTo:DownloadJobStateFailed];
        // 拒绝的任务也必须留在任务列表里：否则 UI 只闪一下通知，
        // 下载列表永远看不到这次被拒绝的下载（失败任务丢失）。
        [self.jobs setObject:job forKey:job.identifier];
        RDDownloadLog(@"入队被拒 id=%@ url=%@ 原因：%@", job.identifier, RDRedactedURL(url), job.errorText);
        [self storeFinishedRecordForJob:job];
        [self notifyUpdate:job];
        [self notifyChange];
        return job;
    }
    // 资源耗尽防线：单文件大小 / 在途总量 / 磁盘剩余空间检查（expectedContentLength 仅作提示）
    NSString *limitReason = [self rd_downloadLimitReasonForLength:length folder:destinationFolder];
    if (limitReason) {
        job.errorText = limitReason;
        [job transitionTo:DownloadJobStateFailed];
        [self.jobs setObject:job forKey:job.identifier];
        RDDownloadLog(@"入队被拒 id=%@ url=%@ 原因：%@", job.identifier, RDRedactedURL(url), job.errorText);
        [self storeFinishedRecordForJob:job];
        [self notifyUpdate:job];
        [self notifyChange];
        return job;
    }

    // 原子预留唯一名（内存集合 + 磁盘，避免覆盖）。标题/URL 里的 HTML 实体
    // 与 `/` 必须先清洗，否则最终 move 会把目标拆成不存在的嵌套目录。
    NSString *preferred = name.length ? name : (url.lastPathComponent.length ? url.lastPathComponent : @"video.mp4");
    preferred = [DownloadJob sanitizedFileNameFromPreferred:preferred] ?: @"video.mp4";
    // 双保险：调用方忘加扩展名、或传了 unknown/域名尾巴这类伪扩展名时，
    // 在下载层强制保证媒体扩展名（优先源 URL 的扩展名），否则 Finder 会把
    // 文件显示成“文档”（2026-09-08 用户报告）。
    preferred = [DownloadJob fileNameByEnsuringMediaExtension:preferred
                                            fallbackExtension:(url.pathExtension.length ? url.pathExtension : @"mp4")];
    if (kind == DownloadResourceManifest) { preferred = [preferred.stringByDeletingPathExtension stringByAppendingPathExtension:@"mp4"]; job.expectedContentLength=0; job.authoritativeExpectedLength=0; }
    NSString *unique = [DownloadJob reserveUniqueNameForPreferred:preferred
                                                         inFolder:destinationFolder.path
                                                  againstReserved:self.reservedNames];
    job.fileName = unique;
    job.destinationURL = [destinationFolder URLByAppendingPathComponent:unique];
    job.tempRootURL = [self.tempRoot URLByAppendingPathComponent:job.identifier];
    [self claimTempDirectoryForJob:job];
    if (![self ownsTempDirectoryAtPath:job.tempRootURL.path]) {
        // R2：临时目录被另一实例占用（同名标识冲突，极罕见）→ 保守失败，绝不写入他人目录。
        job.errorText = @"下载临时目录正由另一个实例使用，已停止本次下载";
        [job transitionTo:DownloadJobStateFailed];
        [self.jobs setObject:job forKey:job.identifier];
        RDDownloadLog(@"入队被拒 id=%@ 原因：临时目录被其他实例占用", job.identifier);
        [self storeFinishedRecordForJob:job];
        [self notifyUpdate:job];
        [self notifyChange];
        return job;
    }

    [self.jobs setObject:job forKey:job.identifier];
    [self.queuedJobIdentifiers addObject:job.identifier];
    RDDownloadLog(@"入队 id=%@ url=%@ referer=%@ 目标目录=%@ 文件名=%@ 预期=%lld 字节",
                  job.identifier, RDRedactedURL(url), RDRedactedURL([NSURL URLWithString:job.referer ?: @""]),
                  destinationFolder.path ?: @"", unique, length);
    // 批量作用域内不逐条启动队列；endBatchEnqueue 统一按整批规划。
    if (self.batchEnqueueDepth == 0) [self startQueuedJobs];
    [self notifyUpdate:job];
    [self notifyChange];
    return job;
}

#pragma mark - 启动（分段 / 单连接）

// 分段硬上限只来自 PerformancePolicy（连接数唯一权威来源）。实际分段上限
// = MIN(硬上限 8, 总连接 ÷ 预期同时活动视频数)，同时保证：
// 1) 单个视频最多 8 个连接；2) 全局任何时刻不超过总连接预算；
// 3) 整批任务按比例均摊连接、互不饿死（例如 1 个大视频得 8 段，
// 4 个大视频各得 5 段，12 个大视频各得至少 1 段）。
- (NSInteger)fairSegmentCapForProspectiveVideos:(NSInteger)prospectiveVideos {
    NSInteger capacity = MAX(1, self.transferScheduler.window);
    NSInteger jobBudget = MAX(1, [PerformancePolicy concurrentDownloadJobs]);
    NSInteger videos = MIN(MAX(1, prospectiveVideos), jobBudget);
    NSInteger fairShare = MAX(1, capacity / videos);
    // 每个视频最多 8 段；20 条总连接在 5 个视频之间均分为 4 段/视频。
    // 少于 5 个视频时允许单视频使用更多连接，但始终受硬上限约束。
    NSInteger hardCap = [PerformancePolicy maximumSegmentsPerDownloadJob];
    return MIN(hardCap, fairShare);
}

// 本轮队列排空预计能同时启动的任务数：受排队规模与剩余任务预算双重限制。
// 批量入队时该值等于整批规模，分段计划因此感知整批任务数量。
- (NSInteger)startableQueuedJobCount {
    NSInteger budgetRemaining = MAX(1, [PerformancePolicy concurrentDownloadJobs]) - [self activeJobCount];
    if (budgetRemaining <= 0) return 0;
    NSInteger count = 0;
    for (NSString *identifier in self.queuedJobIdentifiers) {
        DownloadJob *job = self.jobs[identifier];
        if (!job || job.state != DownloadJobStateQueued) continue;
        count += 1;
        if (count >= budgetRemaining) break;
    }
    return count;
}

- (BOOL)shouldSegmentJob:(DownloadJob *)job {
    // 分段前提：当前模式允许提速 + 服务器允许 Range + 文件大小已知且达到门槛。
    return job.resourceKind != DownloadResourceManifest && [PerformancePolicy allowsSegmentedDownload]
        && job.acceptRanges
        && job.expectedContentLength >= 24LL * 1024 * 1024;
}

- (NSInteger)plannedTransferCountForJob:(DownloadJob *)job segmentCap:(NSInteger)segmentCap {
    if (![self shouldSegmentJob:job] || segmentCap < 2) return 1;
    int64_t length = job.expectedContentLength;
    // 约 6MB/段：在单个大文件上让健康 CDN 使用更多独立连接，
    // 同时仍受 fairSegmentCap 的全局连接预算与 8 段硬上限约束。
    NSInteger lengthBasedCount = MAX(2, (NSInteger)((length + 6LL * 1024 * 1024 - 1) / (6LL * 1024 * 1024)));
    return MIN(segmentCap, lengthBasedCount);
}

- (NSInteger)activeTransferCount {
    // Suspended tasks stay tracked for resume, but do not consume live slots.
    NSInteger count = 0;
    for (RDDownloadTaskSlot *slot in self.taskSlotsByToken.allValues) {
        DownloadJob *job = self.jobs[slot.jobIdentifier];
        if ([self.cancellingTaskSlots containsObject:slot] ||
            job.state == DownloadJobStateRunning || job.state == DownloadJobStateCancelling) count += 1;
    }
    return count;
}

- (NSInteger)activeJobCount {
    NSInteger count = 0;
    for (DownloadJob *job in self.jobs.allValues) {
        if (job.state == DownloadJobStateRunning || job.state == DownloadJobStatePaused) count += 1;
    }
    return count;
}

- (void)removeQueuedJobIdentifier:(NSString *)identifier {
    if (identifier.length) [self.queuedJobIdentifiers removeObject:identifier];
}

- (void)beginBatchEnqueue {
    self.batchEnqueueDepth += 1;
}

- (void)endBatchEnqueue {
    if (self.batchEnqueueDepth > 0) self.batchEnqueueDepth -= 1;
    if (self.batchEnqueueDepth == 0 && !self.queuePumpSuppressed) [self startQueuedJobs];
}

- (void)startQueuedJobs {
    if (self.queuePumpSuppressed || self.pumpingQueuedJobs) return;
    self.pumpingQueuedJobs = YES;
    @try {
        NSArray<NSString *> *queueSnapshot = [self.queuedJobIdentifiers copy];
        for (NSString *identifier in queueSnapshot) {
            if ([self activeJobCount] >= MAX(1, [PerformancePolicy concurrentDownloadJobs])) break;
            DownloadJob *job = self.jobs[identifier];
            if (!job || job.state != DownloadJobStateQueued) {
                [self.queuedJobIdentifiers removeObjectAtIndex:0];
                continue;
            }
            if (self.rd_enableEndpointResolution && [self.validatedEndpointGenerations[identifier] integerValue] != job.generation) {
                if (![self.endpointChecksPending containsObject:identifier]) {
                    [self.endpointChecksPending addObject:identifier];
                    NSInteger generation = job.generation;
                    RDValidateNetworkURL(job.sourceURL,self.urlPolicy,self.rd_resolver,^(URLPolicyDecision *decision) {
                        [self.endpointChecksPending removeObject:identifier];
                        if (job.state != DownloadJobStateQueued || job.generation != generation) { [self startQueuedJobs]; return; }
                        if (!decision.allowed) {
                            // DNS 解析超时是瞬态故障（慢 DNS/网络切换瞬间）：与“解析到
                            // 保留地址”是两回事。有限次顺延重查（2 次、间隔 2 秒），
                            // 期间任务保持排队；耗尽后才以“DNS 解析超时”失败，
                            // 绝不带保留地址文案终态。
                            if (decision.verdict == URLPolicyBlockedDNSTimeout || decision.verdict == URLPolicyBlockedDNSBusy) {
                                NSInteger retries = [self.endpointResolutionRetries[identifier] integerValue];
                                if (retries < 2) {
                                    self.endpointResolutionRetries[identifier] = @(retries + 1);
                                    job.errorText = decision.userMessage ?: @"DNS 解析超时";
                                    [self notifyUpdate:job];
                                    RDDownloadLog(@"端点解析超时 id=%@ 第 %ld/2 次顺延重查", identifier, (long)(retries + 1));
                                    [self.endpointChecksPending addObject:identifier]; // 顺延期间防止重复发起复查
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        [self.endpointChecksPending removeObject:identifier];
                                        [self startQueuedJobs];
                                    });
                                    return;
                                }
                                [self.endpointResolutionRetries removeObjectForKey:identifier];
                            }
                            [self failJob:job reason:decision.userMessage];
                        }
                        else {
                            self.validatedEndpointGenerations[identifier] = @(generation);
                            [self.endpointResolutionRetries removeObjectForKey:identifier];
                            [self startQueuedJobs];
                        }
                    });
                }
                continue;
            }
            // A fast click can arrive before the card-level metadata probe.
            // Do not silently commit the job to a slow single connection.
            BOOL nativeBackend = [NSStringFromClass([self.backend class]) isEqualToString:@"SessionDownloadBackend"];
            if (nativeBackend && job.resourceKind != DownloadResourceManifest && [PerformancePolicy allowsSegmentedDownload] &&
                (job.expectedContentLength <= 0 || !job.acceptRanges) &&
                ![self.capabilityProbePending containsObject:identifier] &&
                ![self.capabilityProbeCompleted containsObject:identifier]) {
                [self.capabilityProbePending addObject:identifier];
                __weak typeof(self) w = self;
                [self.capabilityProbe probeURL:job.sourceURL referer:job.referer completion:^(ZZDownloadCapability *cap) {
                    __strong typeof(w) s = w; if (!s) return;
                    [s.capabilityProbePending removeObject:identifier];
                    DownloadJob *current = s.jobs[identifier];
                    if (!current || current.state != DownloadJobStateQueued) return;
                    // 瞬时失败（超时等）≠ 确定性答复：不能永久降级。
                    if ([DownloadManager rd_isTransientProbeFailure:cap]) {
                        NSInteger attempts = [s.capabilityProbeAttempts[identifier] integerValue];
                        NSInteger maxAttempts = 2;              // 首次 + 最多 2 次顺延重试
                        if (attempts < maxAttempts) {
                            s.capabilityProbeAttempts[identifier] = @(attempts + 1);
                            current.errorText = [NSString stringWithFormat:@"能力探测暂不可用，正在重试（第 %ld/%ld 次）：%@",
                                                 (long)(attempts + 1), (long)maxAttempts,
                                                 cap.failureReason ?: @"探测超时"];
                            RDDownloadLog(@"能力探测瞬时失败，顺延重试 id=%@ 第 %ld/%ld 次（原因：%@）",
                                          identifier, (long)(attempts + 1), (long)maxAttempts,
                                          cap.failureReason ?: @"探测超时");
                            [s notifyUpdate:current];
                            NSInteger scheduled = attempts + 1;
                            __weak typeof(s) ws = s;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                __strong typeof(ws) ss = ws; if (!ss) return;
                                DownloadJob *still = ss.jobs[identifier];
                                // 只有“仍是同一代次、仍排队、且计数没被更晚的重试改写”才继续重探。
                                if (!still || still.state != DownloadJobStateQueued) return;
                                if ([ss.capabilityProbeAttempts[identifier] integerValue] != scheduled) return;
                                [ss startQueuedJobs];
                            });
                            return;
                        }
                        // 重试耗尽：接受单连接兜底，但保留可读原因。
                        RDDownloadLog(@"能力探测重试耗尽，改用单连接 id=%@（原因：%@）",
                                      identifier, cap.failureReason ?: @"探测超时");
                    }
                    // 确定性答复，或瞬时重试已耗尽：此刻的结论是最终结论。
                    [s.capabilityProbeCompleted addObject:identifier];
                    [s.capabilityProbeAttempts removeObjectForKey:identifier];
                    if (cap.contentLength > 0) {
                        current.expectedContentLength = cap.contentLength;
                        current.authoritativeExpectedLength = cap.contentLength;
                    }
                    if (cap.etag.length) current.etag = cap.etag;
                    if (cap.lastModified.length) current.lastModified = cap.lastModified;
                    // Range 响应头并不等于可用分段：首字节迟迟不返回时强行并发只会
                    // 堆积无吞吐连接，因此把正文响应性纳入分段准入条件。
                    current.acceptRanges = cap.rangeSupported && cap.bodyResponsive;
                    current.firstByteLatency = cap.firstByteLatency;
                    if (cap.failureReason.length && !cap.bodyResponsive) {
                        current.errorText = [NSString stringWithFormat:@"服务器响应慢，已禁用分段：%@", cap.failureReason];
                    }
                    [s notifyUpdate:current];
                    [s startQueuedJobs];
                }];
                [self notifyUpdate:job];
                continue;
            }
            NSInteger active = [self activeTransferCount];
            NSInteger capacity = MAX(1, self.transferScheduler.window);
            // 预期同时活动视频数 = 当前活动任务 + 本轮排空还能启动的排队任务
            // （含当前任务）。整批任务的分段计划因此一次算清，首个任务不会
            // 先占满连接而阻塞同批后续任务。
            NSInteger prospectiveVideos = [self activeJobCount] + MAX(1, [self startableQueuedJobCount]);
            NSInteger segmentCap = [self fairSegmentCapForProspectiveVideos:prospectiveVideos];
            NSInteger required = [self plannedTransferCountForJob:job segmentCap:segmentCap];
            // A queued large video must be allowed to consume the slots that
            // are actually free. Waiting for its ideal segment count would
            // starve the queue whenever an existing video releases only one
            // segment at a time; start with the available count instead.
            NSInteger available = MAX(0, capacity - active);
            if (available <= 0) break;
            // 大文件进入分段模式时，单独占用一个连接会把它永久降级成
            // 单连接任务：后续释放的槽位不会再补回 segmentCount。至少等到
            // 两个真实空槽同时可用，再一次性启动分段，避免队列饥饿和
            // “排队任务已运行但始终只有 1 段”的假提速状态。
            // Leave this large job waiting for a full segment slot set, but keep
            // pumping smaller jobs behind it while its capability probe has returned.
            if ([self shouldSegmentJob:job] && available < 3) continue;
            required = MIN(required, available);

            [self removeQueuedJobIdentifier:identifier];
            [job transitionTo:DownloadJobStateRunning];
            [self beginJob:job plannedTransfers:required];
            if (job.state == DownloadJobStateRunning) [self notifyUpdate:job];
        }
    } @finally {
        self.pumpingQueuedJobs = NO;
    }
}

- (void)beginJob:(DownloadJob *)job plannedTransfers:(NSInteger)plannedTransfers {
    if (job.state != DownloadJobStateRunning) return;
    if (plannedTransfers >= 2 && [self shouldSegmentJob:job]) {
        [self startSegmented:job plannedTransfers:plannedTransfers];
    } else {
        [self startSingle:job];
    }
}

- (void)startSingle:(DownloadJob *)job {
    job.segmented = NO;
    NSURL *singleTemp = [job.tempRootURL URLByAppendingPathComponent:@"single.tmp"];
    if(job.resourceKind==DownloadResourceManifest && ![job.destinationURL.pathExtension.lowercaseString isEqual:@"mp4"]){job.fileName=[job.fileName.stringByDeletingPathExtension stringByAppendingPathExtension:@"mp4"];job.destinationURL=[job.destinationURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:job.fileName];}
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:job.sourceURL];
    request.timeoutInterval = 30.0;
    [self applyCommonHeaders:request forJob:job];
    NSInteger gen = job.generation;
    NSString *token = NSUUID.UUID.UUIDString;
    __block BOOL completionObservedSynchronously = NO;
    [self startProgressWatchdogForJob:job];
    RDDownloadLog(@"启动单连接 id=%@ gen=%ld url=%@ referer=%@ 写入=%@",
                  job.identifier, (long)gen, RDRedactedURL(job.sourceURL),
                  RDRedactedURL([NSURL URLWithString:job.referer ?: @""]), singleTemp.path ?: @"");
    void (^progress)(int64_t, int64_t, int64_t) = ^(int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpected) {
        // R4：单连接路径同样按 generation 隔离——旧代次（链接刷新重启/重试）的迟到进度
        // 不得改写新代次任务的进度与速率窗口。
        if (gen != job.generation) return;
        [self updateSingleProgressForJob:job totalBytesWritten:totalBytesWritten totalBytesExpected:totalBytesExpected];
    };
    void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *) = ^(NSURL *written, NSHTTPURLResponse *resp, NSError *err) {
        completionObservedSynchronously = YES;
        [self observeTransferCompletionForJob:job token:token];
        if(job.resourceKind==DownloadResourceManifest && written && !err && gen==job.generation){int64_t actual=[[[NSFileManager defaultManager]attributesOfItemAtPath:written.path error:nil][NSFileSize]longLongValue];job.authoritativeExpectedLength=actual;job.expectedContentLength=actual;}
        [self handleSingleCompletion:job gen:gen writtenURL:written response:resp error:err];
        // 结果已定（完成/失败/转重试）且槽位已释放，此时才把空槽交给排队任务；
        // startQueuedJobs 自身会尊重 queuePumpSuppressed。
        [self startQueuedJobs];
    };
    id<RDDownloadTask> task = nil;
    if (job.resourceKind==DownloadResourceManifest) {
        NSURL *muxer=self.rd_streamMuxerURL ?: [[NSBundle mainBundle] URLForResource:@"ffmpeg" withExtension:nil subdirectory:@"MediaTools"];
        RDStreamDownloadTask *stream=[[RDStreamDownloadTask alloc]initWithBackend:self.backend request:request output:singleTemp muxer:muxer progress:progress completion:completion];
        // 界面选中具体 HLS 档位时：入口用主清单（解析分离音轨），并固定
        // 选中 sourceURL 对应的变体；普通清单任务两个字段保持 nil。
        if (job.streamMasterURL.length) {
            stream.startURL = [NSURL URLWithString:job.streamMasterURL];
            stream.pinnedVariantURL = job.sourceURL;
        }
        task=stream;dispatch_async(dispatch_get_main_queue(),^{[stream start];});
    } else if ([self.backend respondsToSelector:@selector(rd_startRequest:writeToURL:progress:completion:)]) {
        task = [self.backend rd_startRequest:request writeToURL:singleTemp progress:progress completion:completion];
    } else {
        task = [self.backend rd_startRequest:request writeToURL:singleTemp completion:completion];
    }
    if (task && !completionObservedSynchronously && job.state == DownloadJobStateRunning && job.generation == gen) {
        [self trackTask:task token:token forJob:job];
    } else if (!task && !completionObservedSynchronously && job.state == DownloadJobStateRunning && job.generation == gen) {
        [self failJob:job reason:@"无法创建下载任务"];
    }
}

#pragma mark - 分段布局守卫（BUG-006：恢复时绝不混用陈旧分片）

// 本次布局中第 i 段应有的字节数。与各段 Range（length*i/seg .. length*(i+1)/seg-1）
// 严格同源，是判断「磁盘上的分片是否属于本次布局」的唯一依据。
- (int64_t)partBytesForSegments:(NSInteger)seg total:(int64_t)length index:(NSInteger)i {
    if (seg <= 0 || length <= 0 || i < 0 || i >= seg) return 0;
    return length * (i + 1) / seg - length * i / seg;
}

// 规范分片名 NNN.part（恰好 3 位十进制）→ 段下标。旁路名 NNN-<UUID>.tmp 不在此列。
- (BOOL)canonicalPartIndexFromName:(NSString *)name index:(NSInteger *)outIndex {
    if (![name hasSuffix:@".part"]) return NO;
    NSString *stem = [name substringToIndex:name.length - 5];
    if (stem.length != 3) return NO;
    for (NSUInteger i = 0; i < stem.length; i++) {
        unichar c = [stem characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    if (outIndex) *outIndex = (NSInteger)stem.integerValue;
    return YES;
}

// 本任务临时目录里的「可作废草稿」：规范分片、后端旁路分片 NNN-<UUID>.tmp、
// 以及两处落盘目标的中间文件。所有权锁 .rd-owner.lock 与任何未知文件绝不动。
- (BOOL)isDiscardableSegmentScratchName:(NSString *)name {
    NSInteger idx = -1;
    if ([self canonicalPartIndexFromName:name index:&idx]) return YES;
    if ([name isEqualToString:@"merged.tmp"] || [name isEqualToString:@"single.tmp"]) return YES;
    if (![name hasSuffix:@".tmp"]) return NO;
    NSRange dash = [name rangeOfString:@"-"];
    if (dash.location == NSNotFound) return NO;
    return [self canonicalPartIndexFromName:[[name substringToIndex:dash.location] stringByAppendingString:@".part"] index:&idx];
}

// 分段布局守卫（BUG-006 的核心）：本次要用的布局一旦确定，磁盘上不属于该布局的分片
// 必须整体作废，绝不允许它们参与后续合并。
//  · 逐字节等于本次布局第 i 段应有长度的规范分片 → 判定为**可复用**（真续传）；
//  · 其余一切（上一会话旧段数的分片、长度不符的半截分片、后端旁路分片、
//    merged.tmp / single.tmp）→ 删除。
// 返回可复用的段下标集合。删除范围严格限于本任务临时目录内的上述草稿文件，
// 既不碰所有权锁，也不碰用户文件与下载记录。
- (NSIndexSet *)adoptSegmentedLayoutForJob:(DownloadJob *)job segments:(NSInteger)seg {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = job.tempRootURL.path;
    NSMutableIndexSet *reusable = [NSMutableIndexSet indexSet];
    if (!root.length || seg <= 0 || job.expectedContentLength <= 0) return reusable;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *discarded = [NSMutableArray array];
    int64_t reusableBytes = 0;
    for (NSString *name in entries) {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSInteger idx = -1;
        if ([self canonicalPartIndexFromName:name index:&idx] && idx >= 0 && idx < seg) {
            int64_t want = [self partBytesForSegments:seg total:job.expectedContentLength index:idx];
            int64_t have = [(NSNumber *)[fm attributesOfItemAtPath:path error:nil][NSFileSize] longLongValue];
            if (want > 0 && have == want) {
                [reusable addIndex:(NSUInteger)idx];
                reusableBytes += have;
                continue;
            }
        }
        if (![self isDiscardableSegmentScratchName:name]) continue;
        if ([fm removeItemAtPath:path error:nil]) [discarded addObject:name];
    }
    int64_t redownloadBytes = 0;
    for (NSInteger i = 0; i < seg; i++) {
        if (![reusable containsIndex:(NSUInteger)i])
            redownloadBytes += [self partBytesForSegments:seg total:job.expectedContentLength index:i];
    }
    RDDownloadLog(@"分段布局核对 id=%@ 段数=%ld 总长=%lld 复用段=%lu 复用字节=%lld 需重下字节=%lld 作废分片=[%@]",
                  job.identifier, (long)seg, job.expectedContentLength, (unsigned long)reusable.count,
                  reusableBytes, redownloadBytes,
                  discarded.count ? [discarded componentsJoinedByString:@","] : @"无");
    if (discarded.count) {
        RDDownloadLog(@"作废的陈旧分片（与本次布局不符，绝不参与合并）id=%@ 清单=[%@]",
                      job.identifier, [discarded componentsJoinedByString:@","]);
    }
    return reusable;
}

- (void)recordPartURL:(NSURL *)url forJob:(DownloadJob *)job index:(NSInteger)idx {
    if (!job.identifier.length || !url.path.length) return;
    NSMutableDictionary *m = self.partURLsAt[job.identifier];
    if (!m) { m = [NSMutableDictionary dictionary]; self.partURLsAt[job.identifier] = m; }
    m[@(idx)] = url;
}

// 合并读取的权威路径：优先用「该段实际落盘的文件」，未登记时回退规范路径
// （与修复前行为一致，保证未发生旁路落盘的普通路径完全不受影响）。
- (NSURL *)authoritativePartURLForJob:(DownloadJob *)job index:(NSInteger)idx {
    NSURL *url = self.partURLsAt[job.identifier][@(idx)];
    return url.path.length ? url : [job partFileURLForIndex:idx];
}

- (void)startSegmented:(DownloadJob *)job plannedTransfers:(NSInteger)seg {
    job.segmented = YES;
    int64_t length = job.expectedContentLength;
    // 使用与容量预留一致的整批规划值；各段范围由 length*i/seg 精确平铺
    // 整个文件（无重叠、无遗漏、末段边界为 length-1）。
    seg = MAX(2, seg);
    job.segmentCount = seg;
    job.finishedSegments = 0;
    [self startProgressWatchdogForJob:job];
    NSInteger startGeneration = job.generation;
    RDDownloadLog(@"启动分段 id=%@ gen=%ld 段数=%ld 总长=%lld url=%@",
                  job.identifier, (long)startGeneration, (long)seg, length, RDRedactedURL(job.sourceURL));
    // BUG-006：布局先定，再按布局核对磁盘。上一会话（或上一次尝试）留下的分片只有在
    // **逐字节符合本次布局**时才可复用；否则一律作废后重下，绝不新旧混拼。
    [self.partURLsAt removeObjectForKey:job.identifier];
    NSIndexSet *reusable = [self adoptSegmentedLayoutForJob:job segments:seg];
    NSMutableDictionary *parts = self.segmentBytes[job.identifier];
    if (!parts) { parts = [NSMutableDictionary dictionary]; self.segmentBytes[job.identifier] = parts; }
    int64_t reusedBytes = 0;
    for (NSUInteger i = reusable.firstIndex; i != NSNotFound; i = [reusable indexGreaterThanIndex:i]) {
        int64_t partBytes = [self partBytesForSegments:seg total:length index:(NSInteger)i];
        parts[@((NSInteger)i)] = @(partBytes);
        reusedBytes += partBytes;
        [self recordPartURL:[job partFileURLForIndex:(NSInteger)i] forJob:job index:(NSInteger)i];
    }
    if (reusedBytes > 0) {
        job.finishedSegments = (NSInteger)reusable.count;
        job.transferredBytes = MAX(job.transferredBytes, reusedBytes);
        if (length > 0) job.progress = MAX(job.progress, MIN(0.999, (double)reusedBytes / (double)length));
        RDDownloadLog(@"分段真续传 id=%@ 复用段=%lu 复用字节=%lld/%lld（%.1f%%）不再重下",
                      job.identifier, (unsigned long)reusable.count, reusedBytes, length,
                      length > 0 ? 100.0 * (double)reusedBytes / (double)length : 0.0);
        [self notifyUpdate:job];
    }
    for (NSInteger i = 0; i < seg; i++) {
        if (job.state != DownloadJobStateRunning || job.generation != startGeneration || !job.segmented) break;
        // 已按本次布局逐字节核对通过的段：直接复用，不重下。
        if ([reusable containsIndex:(NSUInteger)i]) continue;
        int64_t start = length * i / seg;
        int64_t end = length * (i + 1) / seg - 1;
        [self startSegmentForJob:job index:i start:start end:end generation:startGeneration attempt:0];
    }
    // 全部分段都在磁盘上且逐一核对通过：没有任何在途传输会触发合并，这里直接收口。
    if (job.state == DownloadJobStateRunning && job.generation == startGeneration && job.segmented
        && job.finishedSegments == job.segmentCount) {
        [self mergeSegments:job];
    }
}

- (void)startSegmentForJob:(DownloadJob *)job index:(NSInteger)idx start:(int64_t)start end:(int64_t)end generation:(NSInteger)gen attempt:(NSInteger)attempt {
    [self startSegmentForJob:job index:idx start:start end:end generation:gen attempt:attempt freshConnection:NO];
}

// freshConnection=YES：本次请求必须走**新连接**（停滞重发的唯一入口）。
- (void)startSegmentForJob:(DownloadJob *)job index:(NSInteger)idx start:(int64_t)start end:(int64_t)end generation:(NSInteger)gen attempt:(NSInteger)attempt freshConnection:(BOOL)freshConnection {
    if (job.state != DownloadJobStateRunning || job.generation != gen || !job.segmented) return;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:job.sourceURL]; request.timeoutInterval=30.0;
    [self applyCommonHeaders:request forJob:job];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld",start,end] forHTTPHeaderField:@"Range"];
    NSString *ifRange=job.etag.length?job.etag:job.lastModified; if(ifRange.length)[request setValue:ifRange forHTTPHeaderField:@"If-Range"];
    NSURL *partURL=[job partFileURLForIndex:idx]; NSString *token=NSUUID.UUID.UUIDString; __block BOOL sync=NO;
    [self recordSegmentStartForJob:job index:idx token:token];
    RDDownloadLog(@"启动分段传输 id=%@ 段%ld Range=bytes=%lld-%lld 写入=%@", job.identifier, (long)idx, start, end, partURL.path ?: @"");
    void (^progress)(int64_t,int64_t,int64_t)=^(int64_t bw,int64_t total,int64_t expected){
        // R4：progress 必须按 **当前 token + generation** 隔离。换连接/取消/代次推进后，
        // 旧任务的迟到回调绝不能写入新尝试的 attempt 字节、last-progress、速率窗口，
        // 也不能改写用户可见进度。token 在请求发出前已登记，同步回调仍然兼容。
        if (job.generation != gen) return;
        NSString *currentToken = [self currentSegmentTokenForJob:job index:idx];
        if (!currentToken.length || ![currentToken isEqualToString:token]) return;
        [self updateSegmentProgressForJob:job index:idx totalBytesWritten:total expectedBytes:(end-start+1)];
    };
    void (^completion)(NSURL *,NSHTTPURLResponse *,NSError *)=^(NSURL *written,NSHTTPURLResponse *resp,NSError *err){
        sync=YES; [self observeTransferCompletionForJob:job token:token];
        // 停滞重发会取消旧任务并换 token 重发该段：被取消旧任务的迟到回调绝不能
        // 再落到 handlePartCompletion（否则会把它误判成失败并连累整个任务）。
        NSString *current=[self currentSegmentTokenForJob:job index:idx];
        if (current.length && ![current isEqualToString:token]) return;
        BOOL replaced=[self handlePartCompletion:job index:idx start:start end:end gen:gen writtenURL:written response:resp error:err];
        if(!replaced)[self startQueuedJobs];
    };
    id<RDDownloadTask> task=nil;
    if (freshConnection && [self.backend respondsToSelector:@selector(rd_reissueRequest:writeToURL:progress:completion:)]) {
        // 换连接重发：走后端的一次性新连接通道（绝不复用被晾住的那条连接）。
        task=[self.backend rd_reissueRequest:request writeToURL:partURL progress:progress completion:completion];
    } else if ([self.backend respondsToSelector:@selector(rd_startRequest:writeToURL:progress:completion:)]) {
        task=[self.backend rd_startRequest:request writeToURL:partURL progress:progress completion:completion];
    } else {
        task=[self.backend rd_startRequest:request writeToURL:partURL completion:completion];
    }
    if(task&&!sync&&job.state==DownloadJobStateRunning&&job.generation==gen&&job.segmented)[self trackTask:task token:token forJob:job];
    else if(!task&&!sync&&job.state==DownloadJobStateRunning&&job.generation==gen&&job.segmented)[self failJob:job reason:@"无法创建分段下载任务"];
}

- (void)applyCommonHeaders:(NSMutableURLRequest *)request forJob:(DownloadJob *)job {
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (job.referer.length) [request setValue:job.referer forHTTPHeaderField:@"Referer"];
}

#pragma mark - 进度与无进展超时

- (void)startProgressWatchdogForJob:(DownloadJob *)job {
    if (!job.identifier.length) return;
    [self stopProgressWatchdogForJob:job];
    NSDate *now = [NSDate date];
    self.lastProgressAt[job.identifier] = now;
    job.bytesPerSecond = 0;
    job.estimatedRemainingSeconds = 0;
    job.lastRateSampleDate = nil;
    self.transferSamples[job.identifier] = @{@"bytes": @(job.transferredBytes), @"date": now, @"rate": @0};
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(progressWatchdogTick:)
                                                     userInfo:job.identifier
                                                      repeats:YES];
    self.progressWatchdogs[job.identifier] = timer;
}

- (void)stopProgressWatchdogForJob:(DownloadJob *)job {
    if (!job.identifier.length) return;
    [self.progressWatchdogs[job.identifier] invalidate];
    [self.progressWatchdogs removeObjectForKey:job.identifier];
    [self.lastProgressAt removeObjectForKey:job.identifier];
    [self.segmentBytes removeObjectForKey:job.identifier];
    [self.segmentAttemptBytes removeObjectForKey:job.identifier];
    [self.partURLsAt removeObjectForKey:job.identifier];
    [self.segmentRateSamples removeObjectForKey:job.identifier];
    [self.transferSamples removeObjectForKey:job.identifier];
    [self.segmentProgressAt removeObjectForKey:job.identifier];
    [self.segmentTokens removeObjectForKey:job.identifier];
    [self.segmentStallAttempts removeObjectForKey:job.identifier];
    [self.poolStallRounds removeObjectForKey:job.identifier];
    [self.poolStallNextAllowedAt removeObjectForKey:job.identifier];
    [self.poolStallBytesAtLastRound removeObjectForKey:job.identifier];
}

- (void)progressWatchdogTick:(NSTimer *)timer {
    NSString *identifier = timer.userInfo;
    DownloadJob *job = self.jobs[identifier];
    if (!job || job.state != DownloadJobStateRunning) {
        [timer invalidate];
        [self.progressWatchdogs removeObjectForKey:identifier];
        [self.segmentProgressAt removeObjectForKey:identifier];
        [self.segmentTokens removeObjectForKey:identifier];
        [self.segmentStallAttempts removeObjectForKey:identifier];
        [self.segmentAttemptBytes removeObjectForKey:identifier];
        [self.poolStallRounds removeObjectForKey:identifier];
        [self.poolStallNextAllowedAt removeObjectForKey:identifier];
        [self.poolStallBytesAtLastRound removeObjectForKey:identifier];
        return;
    }
    NSDate *last = self.lastProgressAt[identifier] ?: [NSDate date];
    if ([[NSDate date] timeIntervalSinceDate:last] >= 45.0) {
        [self failJob:job reason:@"连接超过 45 秒没有收到数据，已停止本次下载"];
        return;
    }
    // 单段停滞检测：其余段正常推进时，45s 全任务看门狗永远不触发，被晾住的那段
    // 会单独决定总时长（真实现场：7 段 6.9s + 1 段 57s = 64.2s）。这里按段超时
    // 取消并换连接重发，把最慢段压到健康水平。
    [self detectStalledSegmentsForJob:job];
}

- (void)markProgressForJob:(DownloadJob *)job {
    if (job.identifier.length) self.lastProgressAt[job.identifier] = [NSDate date];
}

#pragma mark - 分段停滞检测（单段被晾住时换连接重发）

- (NSMutableDictionary<NSNumber *, NSDate *> *)segmentProgressForJobIdentifier:(NSString *)identifier {
    NSMutableDictionary *m = self.segmentProgressAt[identifier];
    if (!m) { m = [NSMutableDictionary dictionary]; self.segmentProgressAt[identifier] = m; }
    return m;
}

- (NSMutableDictionary<NSNumber *, NSString *> *)segmentTokensForJobIdentifier:(NSString *)identifier {
    NSMutableDictionary *m = self.segmentTokens[identifier];
    if (!m) { m = [NSMutableDictionary dictionary]; self.segmentTokens[identifier] = m; }
    return m;
}

- (NSMutableDictionary<NSNumber *, NSNumber *> *)segmentStallAttemptsForJobIdentifier:(NSString *)identifier {
    NSMutableDictionary *m = self.segmentStallAttempts[identifier];
    if (!m) { m = [NSMutableDictionary dictionary]; self.segmentStallAttempts[identifier] = m; }
    return m;
}

// 每段第一次发出请求时登记“最近进展时刻 = 现在”与当前 token。
- (void)recordSegmentStartForJob:(DownloadJob *)job index:(NSInteger)idx token:(NSString *)token {
    if (!job.identifier.length) return;
    [self segmentProgressForJobIdentifier:job.identifier][@(idx)] = [NSDate date];
    [self segmentTokensForJobIdentifier:job.identifier][@(idx)] = token;
    // 本次尝试的字节计数归零：换连接重发后的新连接必须按「本次尝试零字节」走首字节窗口。
    // 旧尝试的累计字节仍留在 segmentBytes（供用户可见进度与整池恢复判定），两者口径严格分开。
    NSMutableDictionary *attemptParts = self.segmentAttemptBytes[job.identifier];
    if (!attemptParts) { attemptParts = [NSMutableDictionary dictionary]; self.segmentAttemptBytes[job.identifier] = attemptParts; }
    attemptParts[@(idx)] = @0;
}

- (void)noteSegmentProgressForJob:(DownloadJob *)job index:(NSInteger)idx {
    if (!job.identifier.length) return;
    [self segmentProgressForJobIdentifier:job.identifier][@(idx)] = [NSDate date];
}

- (NSString *)currentSegmentTokenForJob:(DownloadJob *)job index:(NSInteger)idx {
    return [self segmentTokensForJobIdentifier:job.identifier][@(idx)];
}

- (void)clearSegmentTrackingForJob:(DownloadJob *)job index:(NSInteger)idx {
    if (!job.identifier.length) return;
    [self.segmentProgressAt[job.identifier] removeObjectForKey:@(idx)];
    [self.segmentTokens[job.identifier] removeObjectForKey:@(idx)];
    [self.segmentStallAttempts[job.identifier] removeObjectForKey:@(idx)];
    [self.segmentAttemptBytes[job.identifier] removeObjectForKey:@(idx)];
}

// 取消某 token 对应的在途槽位并直接从任务登记里移除。停滞重发不依赖被取消任务
// 的回调（某些后端取消后不回调），所以这里必须同步清掉槽位，否则会泄漏连接槽。
- (void)cancelAndRemoveTaskSlotForToken:(NSString *)token job:(DownloadJob *)job {
    if (!token.length) return;
    RDDownloadTaskSlot *slot = self.taskSlotsByToken[token];
    if (!slot) return;
    [self.taskSlotsByToken removeObjectForKey:token];
    NSMutableArray *arr = self.activeTasks[job.identifier];
    [arr removeObjectIdenticalTo:slot];
    if (arr.count == 0) [self.activeTasks removeObjectForKey:job.identifier];
    // 不加入 cancellingTaskSlots：旧槽已被彻底移除，而替换段会立刻重新登记到
    // activeTasks，连接计数守恒（移除 1 段 + 登记 1 段）。否则会让 activeTransferCount
    // 被“已取消旧段”重复占用一个槽位。
    [self cancelTaskIfSupported:slot.task];
}

// 取消该段旧连接上的在途任务，并用**新连接**重发同一 Range。
// 换连接后该段重新登记 token/进度基准，旧任务的迟到回调由 token 校验丢弃。
- (void)reissueSegmentOnFreshConnectionForJob:(DownloadJob *)job index:(NSInteger)idx reason:(nullable NSString *)reason {
    if (!job.identifier.length || job.state != DownloadJobStateRunning || !job.segmented) return;
    NSString *token = [self currentSegmentTokenForJob:job index:idx];
    if (!token.length) return;
    int64_t length = job.expectedContentLength;
    NSInteger segmentCount = MAX(1, job.segmentCount);
    int64_t start = length * idx / segmentCount;
    int64_t end = length * (idx + 1) / segmentCount - 1;
    // 因果量化（续传设计的前置证据）：重发该段会丢弃旧连接上已收的字节。这里如实记录
    // 丢弃规模与重发 Range，供后续“是否值得做分段续传”的决策与验收复核。
    // 口径说明（不得夸大）：
    //   · 本次尝试已收 = 取消前**最后一次 progress 报告**的累计值，受取消竞争影响，
    //     不等于精确的网络浪费字节；
    //   · 本段跨尝试高水位 = segmentBytes 的 MAX(旧值, written)，是跨尝试的最高水位，
    //     不是各次尝试字节的求和。
    int64_t highWater = [self.segmentBytes[job.identifier][@(idx)] longLongValue];
    int64_t attemptBytes = [self.segmentAttemptBytes[job.identifier][@(idx)] longLongValue];
    RDDownloadLog(@"分段重发丢弃 id=%@ 段%ld 本次尝试已收=%lld 本段跨尝试高水位=%lld 重发Range=bytes=%lld-%lld",
                  job.identifier, (long)idx, MAX(0, attemptBytes), MAX(0, highWater), start, end);
    // 日志如实反映本次是否真的换了连接：后端未实现换连接通道时是回退到原连接，
    // 绝不能把“回退”写成“换新连接”（报告的判定依据就是这行日志）。
    BOOL freshSupported = [self.backend respondsToSelector:@selector(rd_reissueRequest:writeToURL:progress:completion:)];
    if (reason.length) RDDownloadLog(@"%@（%@）", reason, freshSupported ? @"换新连接" : @"后端未实现换连接，回退原连接");
    [self cancelAndRemoveTaskSlotForToken:token job:job];
    // 换连接 = 新连接重新证明自己：清掉旧连接积累的低速窗口计数，让重发后的段
    // 按新连接自己的完整窗口重新评估。否则旧计数（已 ≥2 个低速窗口）会在新连接
    // 首个窗口结算前就把它再次判成"连续低速"，约 1 秒内烧光全部重发额度——
    // 健康新连接被无证据地反复取消，重试预算形同虚设。
    [self.segmentRateSamples[job.identifier] removeObjectForKey:@(idx)];
    [self startSegmentForJob:job index:idx start:start end:end generation:job.generation attempt:0 freshConnection:YES];
}

// 遍历该任务仍在途的分段，把被服务器晾住的段换到新连接上重发。分层策略：
//  · 单段被晾（其余段仍在推进）→ 立刻换连接重发该段，额度 RDSegmentStallAttemptLimit 次；
//  · 整池被晾（多数在途段同时无数据）→ 判为服务器把整池连接一起晾住，按
//    RDSegmentPoolStallBackoffSeconds 分层退避换连接，**不消耗**单段重发额度，
//    轮次耗尽后交回 45s 任务级看门狗收口（有界，绝不无限等待、绝无重试风暴）。
- (void)detectStalledSegmentsForJob:(DownloadJob *)job {
    if (!job.segmented || job.state != DownloadJobStateRunning || !job.identifier.length) return;
    NSMutableDictionary<NSNumber *, NSString *> *tokens = self.segmentTokens[job.identifier];
    if (!tokens.count) return;
    NSDate *now = [NSDate date];
    NSMutableArray<NSNumber *> *stalled = [NSMutableArray array];
    for (NSNumber *idxKey in [tokens.allKeys copy]) {
        NSInteger idx = idxKey.integerValue;
        if (idx < 0 || idx >= MAX(1, job.segmentCount)) continue;
        NSDate *progressAt = self.segmentProgressAt[job.identifier][idxKey];
        if (!progressAt) continue;
        // 事件驱动的 idle 判定：**本次尝试**已收到字节的段按"多久没有新字节"算；
        // 还没拿到首字节的段（含刚换连接重发的）用更长的首字节窗口，避免把 CDN 慢启动
        // 或换连接后的握手/慢启动误判成"被晾"。旧尝试的累计字节不得参与这一判定。
        int64_t received = [self.segmentAttemptBytes[job.identifier][idxKey] longLongValue];
        NSTimeInterval limit = received > 0 ? RDSegmentStallThreshold() : RDSegmentFirstByteStallThreshold();
        BOOL idle = [now timeIntervalSinceDate:progressAt] >= limit;
        NSDictionary *rateSample = self.segmentRateSamples[job.identifier][idxKey];
        BOOL sustainedLow = received > 0 && [rateSample[@"lowWindows"] integerValue] >= RDSegmentLowRateWindowLimit();
        if (idle || sustainedLow) [stalled addObject:idxKey];
    }
    // 恢复判定：与上一轮换连接时相比确实收到了新字节，才算这一轮整池发作结束。
    // 换连接本身会刷新每段的进度基准（旧段被换掉了），那不是恢复证据——否则轮次
    // 预算会被每一轮自己重置成“永远用不完”，整池持续发作时无限换连接。
    NSNumber *baseline = self.poolStallBytesAtLastRound[job.identifier];
    if (baseline) {
        int64_t nowBytes = 0;
        NSDictionary<NSNumber *, NSNumber *> *parts = self.segmentBytes[job.identifier];
        for (NSNumber *value in parts.allValues) nowBytes += MAX((int64_t)0, value.longLongValue);
        if (nowBytes > baseline.longLongValue) {
            [self.poolStallRounds removeObjectForKey:job.identifier];
            [self.poolStallNextAllowedAt removeObjectForKey:job.identifier];
            [self.poolStallBytesAtLastRound removeObjectForKey:job.identifier];
        }
    }
    if (!stalled.count) return;
    NSInteger inFlight = (NSInteger)tokens.count;
    BOOL wholePool = (NSInteger)stalled.count >= MAX(2, (inFlight + 1) / 2);
    if (!wholePool) {
        // 没有空闲连接预算时顺延：换连接重发是 1:1 替换（先取消本段旧槽位、再登记
        // 新槽位，连接计数守恒）；但自适应调度收缩窗口后池可能已超出预算——此时
        // 不立即执行，等其余在途段完成（或进入整池路径）把池送回预算内再做，
        // 绝不把池推得更满，也绝不取消其他正常分段来腾位置。顺延不消耗重发额度。
        if ([self activeTransferCount] > MAX(1, self.transferScheduler.window)) return;
        NSInteger limit = RDSegmentStallAttemptLimit();
        for (NSNumber *idxKey in stalled) {
            NSInteger attempts = [self segmentStallAttemptsForJobIdentifier:job.identifier][idxKey].integerValue;
            if (attempts >= limit) continue; // 已尽力，交给全任务看门狗收口
            [self segmentStallAttemptsForJobIdentifier:job.identifier][idxKey] = @(attempts + 1);
            NSDate *progressAt = self.segmentProgressAt[job.identifier][idxKey];
            NSString *reason = [NSString stringWithFormat:@"分段停滞重发 id=%@ 段%ld（%.0fs 无数据，第 %ld/%ld 次）",
                                job.identifier, (long)idxKey.integerValue,
                                [now timeIntervalSinceDate:progressAt ?: now],
                                (long)(attempts + 1), (long)limit];
            [self reissueSegmentOnFreshConnectionForJob:job index:idxKey.integerValue reason:reason];
        }
        return;
    }
    NSArray<NSNumber *> *backoff = RDSegmentPoolStallBackoffSeconds();
    NSDate *nextAllowed = self.poolStallNextAllowedAt[job.identifier];
    if (nextAllowed && [now timeIntervalSinceDate:nextAllowed] < 0) return; // 本轮退避未到
    NSInteger round = [self.poolStallRounds[job.identifier] integerValue];
    if (round >= (NSInteger)backoff.count) return; // 轮次耗尽：交回 45s 看门狗收口
    NSInteger attempt = round + 1;
    NSTimeInterval wait = backoff[MIN(round, (NSInteger)backoff.count - 1)].doubleValue;
    self.poolStallRounds[job.identifier] = @(attempt);
    self.poolStallNextAllowedAt[job.identifier] = [now dateByAddingTimeInterval:wait];
    int64_t bytesAtRoundStart = 0;
    for (NSNumber *value in self.segmentBytes[job.identifier].allValues) bytesAtRoundStart += MAX((int64_t)0, value.longLongValue);
    self.poolStallBytesAtLastRound[job.identifier] = @(bytesAtRoundStart);
    // 换连接本身就是一次真实的新尝试：刷新任务级进度基准，让 45s 看门狗只在
    // “连换连接也用尽”之后才收口（绝对上限 = 退避总和 + 45s，有界）。
    [self markProgressForJob:job];
    BOOL poolFreshSupported = [self.backend respondsToSelector:@selector(rd_reissueRequest:writeToURL:progress:completion:)];
    RDDownloadLog(@"整池被晾：第 %ld/%lu 轮%@（退避 %.0fs，停滞 %lu 段）",
                  (long)attempt, (unsigned long)backoff.count,
                  poolFreshSupported ? @"换新连接" : @"换连接不可用（后端未实现），回退原连接",
                  wait, (unsigned long)stalled.count);
    for (NSNumber *idxKey in stalled) {
        [self reissueSegmentOnFreshConnectionForJob:job index:idxKey.integerValue reason:nil];
    }
}

- (void)updateTransferMetricsForJob:(DownloadJob *)job
                   transferredBytes:(int64_t)transferred
                   expectedTotal:(int64_t)expectedTotal {
    if (!job.identifier.length) return;
    transferred = MAX(0, transferred);
    NSDate *now = [NSDate date];
    NSDictionary *previous = self.transferSamples[job.identifier];
    int64_t previousBytes = [previous[@"bytes"] longLongValue];
    NSDate *previousDate = previous[@"date"];
    double previousRate = [previous[@"rate"] doubleValue];
    NSTimeInterval elapsed = previousDate ? [now timeIntervalSinceDate:previousDate] : 0;
    double rate = previousRate;
    BOOL hasNewBytes = transferred > previousBytes;
    // A replacement task has no prior sample after the previous task finishes.
    // Seed a bounded first sample immediately so the batch-rate label does not
    // flash "--" while waiting for the 120 ms smoothing window.
    if (hasNewBytes && previousRate <= 0 && elapsed > 0) {
        double initialElapsed = MAX(0.05, elapsed);
        rate = (double)(transferred - previousBytes) / initialElapsed;
        job.lastRateSampleDate = now;
    }
    if (!previousDate || elapsed >= 0.12) {
        if (elapsed >= 0.12 && transferred >= previousBytes) {
            double instant = (double)(transferred - previousBytes) / elapsed;
            if (instant > 0) {
                rate = previousRate > 0 ? previousRate * 0.65 + instant * 0.35 : instant;
                job.lastRateSampleDate = now;
            }
        }
        self.transferSamples[job.identifier] = @{@"bytes": @(transferred), @"date": now, @"rate": @(MAX(0, rate))};
    }
    job.transferredBytes = transferred;
    job.bytesPerSecond = MAX(0, rate);
    job.estimatedRemainingSeconds = (job.bytesPerSecond > 0 && expectedTotal > transferred)
        ? ((double)(expectedTotal - transferred) / job.bytesPerSecond) : 0;
}

- (BOOL)checkRuntimeLimitsForJob:(DownloadJob *)job {
    if (!job || job.state != DownloadJobStateRunning) return NO;
    NSDate *last = self.lastDiskCheckAt[job.identifier];
    if (!last || [[NSDate date] timeIntervalSinceDate:last] >= 1.0) {
        self.lastDiskCheckAt[job.identifier] = [NSDate date];
        NSURL *folder = job.destinationURL.URLByDeletingLastPathComponent ?: self.tempRoot;
        NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:folder.path error:nil];
        NSNumber *free = fs[NSFileSystemFreeSize];
        if (free && free.longLongValue < [PerformancePolicy minimumFreeDiskSpace]) {
            [self failJob:job reason:@"磁盘剩余空间不足，已停止下载"];
            return NO;
        }
    }

    int64_t total = 0;
    for (DownloadJob *candidate in self.jobs.allValues) {
        if (candidate.state == DownloadJobStateRunning ||
            candidate.state == DownloadJobStatePaused ||
            candidate.state == DownloadJobStateQueued) {
            total += MAX((int64_t)0, candidate.expectedContentLength);
        }
    }
    if (total > [PerformancePolicy downloadMaxTotalBytes]) {
        [self failJob:job reason:@"在途下载总量超过上限，已停止下载"];
        return NO;
    }
    return YES;
}

- (void)updateSingleProgressForJob:(DownloadJob *)job
                 totalBytesWritten:(int64_t)written
                totalBytesExpected:(int64_t)expected {
    if (job.state != DownloadJobStateRunning) return;
    if (![self checkRuntimeLimitsForJob:job]) return;
    [self markProgressForJob:job];
    int64_t knownExpected = expected > 0 ? expected : job.expectedContentLength;
    // 资源探测阶段不一定能拿到 Content-Length，但 NSURLSession 开始传输后
    // 常能给出准确总量。必须写回 job，否则 UI 虽能显示百分比，却永远
    // 无法用字节增量计算速度和剩余时间。
    // 例外：任务侧已有可信预期（探测/元数据给出）时不得被响应覆写——
    // 否则一个声明 143 字节的截断响应会把“预期几十 MB”抹掉，短文件校验失效。
    if (expected > 0 && job.expectedContentLength != expected) {
        if (job.authoritativeExpectedLength <= 0) {
            job.expectedContentLength = expected;
            if (![self checkRuntimeLimitsForJob:job]) return;
        }
    }
    if (knownExpected > 0) {
        job.progress = MIN(0.999, MAX(0.001, (double)written / (double)knownExpected));
    } else if (written > 0) {
        job.progress = MAX(job.progress, 0.01);
    }
    [self updateTransferMetricsForJob:job transferredBytes:written expectedTotal:knownExpected];
    [self.transferScheduler recordThroughput:job.bytesPerSecond error:NO throttled:NO streamIdentifier:job.identifier];
    if(written>0&&job.errorText.length)job.errorText=@"";
    [self notifyUpdate:job];
}

- (void)updateSegmentProgressForJob:(DownloadJob *)job
                               index:(NSInteger)index
                  totalBytesWritten:(int64_t)written
                       expectedBytes:(int64_t)expected {
    if (job.state != DownloadJobStateRunning) return;
    if (![self checkRuntimeLimitsForJob:job]) return;
    [self markProgressForJob:job];
    [self noteSegmentProgressForJob:job index:index];
    NSMutableDictionary *parts = self.segmentBytes[job.identifier];
    if (!parts) { parts = [NSMutableDictionary dictionary]; self.segmentBytes[job.identifier] = parts; }
    // 每段字节只增不减：迟到的较小回调（或分段重试从头计数）不得让已落账
    // 字节缩水，保证字节口径进度同样单调不倒退。这是**跨尝试累计**口径（用户可见）。
    parts[@(index)] = @(MAX([parts[@(index)] longLongValue], MAX(0, written)));
    // **本次尝试**口径：换连接重发即归零（见 recordSegmentStartForJob），停滞窗口据此判定。
    NSMutableDictionary *attemptParts = self.segmentAttemptBytes[job.identifier];
    if (!attemptParts) { attemptParts = [NSMutableDictionary dictionary]; self.segmentAttemptBytes[job.identifier] = attemptParts; }
    attemptParts[@(index)] = @(MAX([attemptParts[@(index)] longLongValue], MAX(0, written)));
    NSMutableDictionary *rateParts = self.segmentRateSamples[job.identifier];
    if (!rateParts) { rateParts = [NSMutableDictionary dictionary]; self.segmentRateSamples[job.identifier] = rateParts; }
    NSDictionary *old = rateParts[@(index)];
    NSDate *now = [NSDate date];
    // 低速窗口按**时间基准**结算：距上次窗口结算满 RDSegmentRateWindowSeconds 就结算
    // 一次「窗口内字节增量 → 有效速率」，与回调节奏无关。旧实现把窗口起点绑在
    // 「上一次进度回调」上，两个后果（T42，2026-09-11 确定性复现）：回调密集的
    // "活着但慢"段（CDN 慢传的真实形态）永远凑不满窗口间隔 ⇒ 低速检测成为死代码；
    // 回调一旦稀疏（≥3s）又会先撞上 3s idle 判定，低速路径同样不可达。
    int64_t windowBytes = [old[@"windowBytes"] longLongValue];
    NSDate *windowDate = old[@"windowDate"];
    NSInteger lowWindows = [old[@"lowWindows"] integerValue];
    if (windowDate) {
        NSTimeInterval windowElapsed = [now timeIntervalSinceDate:windowDate];
        if (windowElapsed >= RDSegmentRateWindowSeconds()) {
            double rate = (double)MAX((int64_t)0, written - windowBytes) / MAX(windowElapsed, 0.001);
            lowWindows = rate < RDSegmentLowRateBytesPerSecond() ? lowWindows + 1 : 0;
            windowDate = now;
            windowBytes = MAX((int64_t)0, written);
        }
    } else {
        windowDate = now;
        windowBytes = MAX((int64_t)0, written);
    }
    rateParts[@(index)] = @{ @"bytes": @(MAX((int64_t)0, written)), @"date": now, @"lowWindows": @(lowWindows),
                             @"windowBytes": @(windowBytes), @"windowDate": windowDate };
    int64_t total = 0;
    for (NSNumber *value in parts.allValues) total += value.longLongValue;
    int64_t expectedTotal = job.expectedContentLength > 0 ? job.expectedContentLength : expected * MAX(1, job.segmentCount);
    if (job.expectedContentLength <= 0 && expectedTotal > 0) {
        int64_t inferred = expectedTotal;
        job.expectedContentLength = inferred;
        if (![self checkRuntimeLimitsForJob:job]) return;
    }
    if (expectedTotal > 0) job.progress = MIN(0.999, MAX(0.001, (double)total / (double)expectedTotal));
    [self updateTransferMetricsForJob:job transferredBytes:total expectedTotal:expectedTotal];
    [self.transferScheduler recordThroughput:job.bytesPerSecond error:NO throttled:NO streamIdentifier:job.identifier];
    [self notifyUpdate:job];
}

#pragma mark - 完成处理

- (BOOL)isTransientDownloadError:(NSError *)error {
    if(![error.domain isEqualToString:NSURLErrorDomain])return NO;
    switch(error.code){
        case NSURLErrorTimedOut:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorDataNotAllowed:
            return YES;
        default:
            return NO;
    }
}

// DNS/主机类故障（-1003/-1004/-1006）：部分站点（如 hanime2）的 DNS 会以
// 几十秒为周期间歇性失败，普通瞬断的 2 次小预算必然撞死。这类错误单独给
// 5 次预算、5 秒间隔（约 30 秒窗口）；仍有硬上限，绝不无限重试。
- (BOOL)isDNSHostError:(NSError *)error {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorDNSLookupFailed:
            return YES;
        default:
            return NO;
    }
}

- (NSInteger)maxTransientRetriesForError:(NSError *)error {
    return [self isDNSHostError:error] ? 5 : 2;
}

// DNS 类错误退避固定 5 秒；普通瞬断维持原 1s/3s。
- (NSTimeInterval)transientRetryDelayForAttempt:(NSInteger)attempt error:(NSError *)error {
    return [self isDNSHostError:error] ? 5.0 : [self retryDelayForAttempt:attempt];
}

- (NSTimeInterval)retryDelayForAttempt:(NSInteger)attempt {
    return attempt<=1?1.0:3.0;
}

- (BOOL)scheduleTransientRetryForJob:(DownloadJob *)job error:(NSError *)error {
    if(![self isTransientDownloadError:error]||job.state!=DownloadJobStateRunning)return NO;
    NSInteger maxAttempts = [self maxTransientRetriesForError:error];
    NSInteger attempt=[self.retryAttempts[job.identifier] integerValue]+1;
    if(attempt>maxAttempts)return NO;
    self.retryAttempts[job.identifier]=@(attempt);
    NSTimeInterval delay = [self transientRetryDelayForAttempt:attempt error:error];
    [self stopProgressWatchdogForJob:job];
    job.progress=0;
    job.transferredBytes=0;
    job.bytesPerSecond=0;
    job.estimatedRemainingSeconds=0;
    job.errorText=[NSString stringWithFormat:@"网络波动，%ld 秒后自动重试（%ld/%ld）",
                   (long)ceil(delay),(long)attempt,(long)maxAttempts];
    [self notifyUpdate:job];
    [self notifyChange];
    NSInteger generation=job.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{
        [self fireScheduledRetryTransferForJob:job generation:generation];
    });
    return YES;
}

// 重试到期后与普通启动一样必须遵守全局连接上限：没有空闲槽位时按原延迟
// 有限次顺延；超过顺延上限仍无槽位则如实失败，绝不突破全局连接数。
- (void)fireScheduledRetryTransferForJob:(DownloadJob *)job generation:(NSInteger)generation {
    if (job.state != DownloadJobStateRunning || job.generation != generation) return;
    if (self.activeTasks[job.identifier].count) return;
    NSInteger capacity = MAX(1, self.transferScheduler.window);
    if ([self activeTransferCount] >= capacity) {
        NSInteger deferrals = [self.retryDeferrals[job.identifier] integerValue] + 1;
        if (deferrals > 90) {
            [self failJob:job reason:@"网络繁忙，自动重试未能获得空闲连接"];
            return;
        }
        self.retryDeferrals[job.identifier] = @(deferrals);
        NSTimeInterval delay = [self retryDelayForAttempt:MAX(1, [self.retryAttempts[job.identifier] integerValue])];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self fireScheduledRetryTransferForJob:job generation:generation];
        });
        return;
    }
    [self.retryDeferrals removeObjectForKey:job.identifier];
    job.errorText = @"";
    // 2026-09-03：网络波动重试保持“单连接重试”。此前改成重新分段实测会引入
    // 重试风暴（整任务重发全部段+等待）——在该站限流下反而更慢、甚至进度倒退回滚。
    // 单连接重试虽慢一点，但稳定、不放大失败。
    [self startSingle:job];
    [self notifyUpdate:job];
}

// 临时短响应（服务器声明 N 字节却提前干净收尾，或落盘字节数少于可信预期）
// 的有限重试：最多 2 次、遵守全局连接预算、到期无槽位有限顺延，绝不无限重试。
- (BOOL)scheduleShortBodyRetryForJob:(DownloadJob *)job {
    if (job.state != DownloadJobStateRunning) return NO;
    NSInteger attempt = [self.shortBodyRetryAttempts[job.identifier] integerValue] + 1;
    if (attempt > 2) return NO;
    self.shortBodyRetryAttempts[job.identifier] = @(attempt);
    RDDownloadLog(@"短响应重试 id=%@ 第 %ld/2 次", job.identifier, (long)attempt);
    [self stopProgressWatchdogForJob:job];
    job.progress = 0;
    job.transferredBytes = 0;
    job.bytesPerSecond = 0;
    job.estimatedRemainingSeconds = 0;
    job.errorText = [NSString stringWithFormat:@"下载不完整（服务器响应被截断），%ld 秒后自动重试（%ld/2）",
                     (long)ceil([self retryDelayForAttempt:attempt]), (long)attempt];
    [self notifyUpdate:job];
    [self notifyChange];
    NSInteger generation = job.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self retryDelayForAttempt:attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self fireScheduledShortBodyRetryForJob:job generation:generation];
    });
    return YES;
}

// 短响应重试到期后与网络波动重试一样必须遵守全局连接上限：没有空闲槽位时
// 按原延迟有限次顺延；超过顺延上限仍无槽位则如实失败。顺延不消耗重试次数。
- (void)fireScheduledShortBodyRetryForJob:(DownloadJob *)job generation:(NSInteger)generation {
    if (job.state != DownloadJobStateRunning || job.generation != generation) return;
    if ([self activeTransferCount] >= MAX(1, self.transferScheduler.window)) {
        NSInteger deferrals = [self.retryDeferrals[job.identifier] integerValue] + 1;
        if (deferrals > 90) {
            [self failJob:job reason:@"下载不完整，自动重试未能获得空闲连接"];
            return;
        }
        self.retryDeferrals[job.identifier] = @(deferrals);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self retryDelayForAttempt:1] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self fireScheduledShortBodyRetryForJob:job generation:generation];
        });
        return;
    }
    [self.retryDeferrals removeObjectForKey:job.identifier];
    job.errorText = @"";
    [self startSingle:job];
    [self notifyUpdate:job];
}

- (void)handleSingleCompletion:(DownloadJob *)job gen:(NSInteger)gen writtenURL:(NSURL *)written response:(NSHTTPURLResponse *)resp error:(NSError *)err {
    if (gen != job.generation) return; // 已取消/暂停后失效
    if (job.state != DownloadJobStateRunning) return;
    if (err) {
        if ([DownloadManager isLinkExpiryStatus:resp.statusCode]) { [self failJob:job reason:err.localizedDescription linkExpired:YES]; return; }
        BOOL throttled = (resp.statusCode == 429 || resp.statusCode == 503 || resp.statusCode == 509);
        [self.transferScheduler recordThroughput:job.bytesPerSecond error:YES throttled:throttled streamIdentifier:job.identifier];
        if([self scheduleTransientRetryForJob:job error:err])return;
        [self failJob:job reason:err.localizedDescription];
        return;
    }
    NSNumber *writtenSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:written.path error:nil] objectForKey:NSFileSize];
    RDDownloadLog(@"传输回调 id=%@ 状态=%ld MIME=%@ 落盘=%@ 字节=%lld（预期 %lld）",
                  job.identifier, (long)(resp.statusCode), resp.MIMEType ?: @"（无）",
                  written.path ?: @"（无）", writtenSize.longLongValue, job.expectedContentLength);
    if (![self verifySingleResponse:resp writtenURL:written job:job]) {
        NSString *reason = [self singleFailureReason:resp writtenURL:written job:job];
        RDDownloadLog(@"校验未通过 id=%@ 原因：%@", job.identifier, reason);
        // 短响应（截断/少收字节且正文不是 HTML 错误页）按临时故障做有限重试；
        // HTML/JSON/状态码/文件头错误是确定性错误，重试没有意义，直接失败。
        if ([self isTransientShortBodyFailure:resp writtenURL:written job:job] &&
            [self scheduleShortBodyRetryForJob:job]) return;
        BOOL linkExpired = [self isLinkExpiryFailureForResponse:resp writtenURL:written];
        // 落盘字节数对不上可信预期（链接内容被换/严重截断）也归入“链接失效类”，
        // 让上层单资源刷新能拿到新长度重启，而不是永远卡在“不是有效视频”。
        if (![DownloadJob isLikelyHTMLErrorFileAtURL:written] &&
            [self bodyIntegrityProblem:resp writtenURL:written job:job]) linkExpired = YES;
        [self failJob:job reason:reason linkExpired:linkExpired];
        return;
    }
    [self.shortBodyRetryAttempts removeObjectForKey:job.identifier];
    [self finalizeCompleted:job fromURL:written];
}

- (BOOL)scheduleSegmentRetryForJob:(DownloadJob *)job index:(NSInteger)idx start:(int64_t)start end:(int64_t)end generation:(NSInteger)gen error:(NSError *)error {
    if (![self isTransientDownloadError:error] || job.state != DownloadJobStateRunning || job.generation != gen) return NO;
    NSString *key=[NSString stringWithFormat:@"%@#%ld",job.identifier,(long)idx];
    NSInteger maxAttempts = [self maxTransientRetriesForError:error];
    NSInteger attempt=[self.segmentRetryAttempts[key] integerValue]+1; if(attempt>maxAttempts)return NO;
    self.segmentRetryAttempts[key]=@(attempt);
    NSTimeInterval delay = [self transientRetryDelayForAttempt:attempt error:error];
    job.errorText=[NSString stringWithFormat:@"分段 %ld 网络波动，仅重试该段（%ld/%ld）",(long)(idx+1),(long)attempt,(long)maxAttempts]; [self notifyUpdate:job];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [self fireScheduledSegmentRetryForJob:job index:idx start:start end:end generation:gen key:key];
    });
    return YES;
}

// 分段重试到期后与任务级重试同语义：等空闲连接槽位的顺延不消耗重试预算，
// 只受独立顺延上限约束；超过上限如实失败（failJob），绝不让分段被静默丢弃
// 而把任务挂在 Running 假死。
- (void)fireScheduledSegmentRetryForJob:(DownloadJob *)job index:(NSInteger)idx start:(int64_t)start end:(int64_t)end generation:(NSInteger)gen key:(NSString *)key {
    if(job.state!=DownloadJobStateRunning||job.generation!=gen||!job.segmented)return;
    if([self activeTransferCount]>=MAX(1,self.transferScheduler.window)){
        NSInteger deferrals = [self.segmentRetryDeferrals[key] integerValue] + 1;
        if (deferrals > 90) {
            [self.segmentRetryDeferrals removeObjectForKey:key];
            [self failJob:job reason:[NSString stringWithFormat:@"分段 %ld 重试失败：长期未获得空闲连接",(long)(idx+1)]];
            return;
        }
        self.segmentRetryDeferrals[key] = @(deferrals);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self retryDelayForAttempt:1]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            [self fireScheduledSegmentRetryForJob:job index:idx start:start end:end generation:gen key:key];
        });
        return;
    }
    [self.segmentRetryDeferrals removeObjectForKey:key];
    [self startSegmentForJob:job index:idx start:start end:end generation:gen attempt:[self.segmentRetryAttempts[key] integerValue]];
}

- (BOOL)handlePartCompletion:(DownloadJob *)job index:(NSInteger)idx start:(int64_t)start end:(int64_t)end gen:(NSInteger)gen writtenURL:(NSURL *)written response:(NSHTTPURLResponse *)resp error:(NSError *)err {
    if (gen != job.generation) return NO;
    if (job.state != DownloadJobStateRunning) return NO;
    [self clearSegmentTrackingForJob:job index:idx];
    if (err) {
        BOOL throttled = (resp.statusCode == 429 || resp.statusCode == 503 || resp.statusCode == 509);
        [self.transferScheduler recordThroughput:job.bytesPerSecond error:YES throttled:throttled streamIdentifier:job.identifier];
        if ([self scheduleSegmentRetryForJob:job index:idx start:start end:end generation:gen error:err]) return NO;
        [self failJob:job reason:[NSString stringWithFormat:@"分段 %ld 重试失败：%@",(long)(idx+1),err.localizedDescription?:@"网络错误"]];
        return NO;
    }
    // 校验分段响应：必须 206 + Content-Range 精确匹配 + 视频/字节流
    NSString *expected = [[NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, job.expectedContentLength] lowercaseString];
    NSString *contentRange = [[resp valueForHTTPHeaderField:@"Content-Range"] lowercaseString] ?: @"";
    NSString *mime = resp.MIMEType.lowercaseString ?: @"";
    BOOL mimeOK = (mime.length == 0) || [mime hasPrefix:@"video/"] || [mime isEqualToString:@"application/octet-stream"];
    if (resp.statusCode != 206 || ![contentRange isEqualToString:expected] || !mimeOK) {
        [self.transferScheduler recordThroughput:job.bytesPerSecond error:YES throttled:(resp.statusCode == 429 || resp.statusCode == 503 || resp.statusCode == 509) streamIdentifier:job.identifier];
        return [self fallbackSingle:job reason:@"服务器未返回稳定分段"];
    }
    // Content-Range 正确但正文缺字节（连接被干净提前关闭）是最典型的“短分段”：
    // 落盘字节数必须与声明区间长度完全一致，绝不允许残缺片段进入合并。
    int64_t expectedPartBytes = end - start + 1;
    NSNumber *partSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:written.path error:nil] objectForKey:NSFileSize];
    if (!partSize || partSize.longLongValue != expectedPartBytes) {
        [self.transferScheduler recordThroughput:job.bytesPerSecond error:YES throttled:NO streamIdentifier:job.identifier];
        return [self fallbackSingle:job reason:@"服务器分段响应不完整（字节数与 Content-Range 不符）"];
    }
    [self.segmentRetryAttempts removeObjectForKey:[NSString stringWithFormat:@"%@#%ld",job.identifier,(long)idx]];
    // BUG-006：登记该段**实际落盘的文件**。后端在规范路径已存在时会把本次数据写到
    // 旁路唯一名（见 didFinishDownloadingToURL 的目标已存在分支），此时规范路径上那份
    // 属于被本次尝试取代的旧数据——合并若仍按规范路径读取，就会把陈旧分片混进结果。
    [self recordPartURL:written forJob:job index:idx];
    NSURL *canonicalPart = [job partFileURLForIndex:idx];
    if (![written.path isEqualToString:canonicalPart.path]
        && [[NSFileManager defaultManager] fileExistsAtPath:canonicalPart.path]) {
        // 规范路径上的是已被本次尝试取代的陈旧分片：删除，磁盘上不留任何会被误用的旧分片。
        [[NSFileManager defaultManager] removeItemAtURL:canonicalPart error:nil];
        RDDownloadLog(@"段%ld 本次数据落在旁路文件 %@，已删除被取代的陈旧分片 %@",
                      (long)idx, written.lastPathComponent, canonicalPart.lastPathComponent);
    }
    job.finishedSegments += 1;
    // 进度口径统一为“实际已下载字节 / 总预期字节”。分段完成只推进 finishedSegments，
    // 并把该段字节数落账（落盘字节数已通过上面的 Content-Range 校验，以区间长度为准）；
    // 绝不能用 finishedSegments/segmentCount 覆盖进度——分段大小不等、大段先完成时
    // 那会让进度从高值倒退（如 900+100 两段：90% → 50%）。
    NSMutableDictionary *parts = self.segmentBytes[job.identifier];
    if (!parts) { parts = [NSMutableDictionary dictionary]; self.segmentBytes[job.identifier] = parts; }
    parts[@(idx)] = @(MAX(0, end - start + 1));
    int64_t transferred = 0;
    for (NSNumber *value in parts.allValues) transferred += value.longLongValue;
    if (job.expectedContentLength > 0) {
        double byteProgress = MIN(0.999, MAX(0.001, (double)transferred / (double)job.expectedContentLength));
        job.progress = MAX(job.progress, byteProgress);   // 单调：进度绝不倒退
        job.transferredBytes = transferred;
    } else {
        // 降级口径：总预期长度未知时才使用完成段数比例，同样保持单调不倒退。
        job.progress = MAX(job.progress, (double)job.finishedSegments / MAX(1, job.segmentCount));
        job.transferredBytes = MAX(job.transferredBytes, transferred);
    }
    [self notifyUpdate:job];
    if (job.finishedSegments == job.segmentCount) {
        [self mergeSegments:job];
    }
    return NO;
}

- (void)mergeSegments:(DownloadJob *)job {
    // BUG-013 targets multi-GB files. Small downloads finalize synchronously so
    // existing completion and cleanup semantics remain observable immediately.
    if (job.expectedContentLength < 128LL * 1024LL * 1024LL) {
        [self mergeSegmentsOnFinalizationQueue:job];
        return;
    }
    dispatch_async(self.finalizationQueue, ^{ [self mergeSegmentsOnFinalizationQueue:job]; });
}

- (void)mergeSegmentsOnFinalizationQueue:(DownloadJob *)job {
    NSURL *merged = [job mergedTempURL];
    [[NSFileManager defaultManager] createFileAtPath:merged.path contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingToURL:merged error:nil];
    BOOL ok = YES; NSString *reason = nil;
    @try {
        for (NSInteger i = 0; i < job.segmentCount; i++) {
            // BUG-006：按该段实际落盘的文件读取；未登记（如尚未发生任何旁路落盘）时
            // 回退规范路径 NNN.part，与修复前行为一致。
            NSURL *part = [self authoritativePartURLForJob:job index:i];
            NSFileHandle *in = [NSFileHandle fileHandleForReadingFromURL:part error:nil];
            if (!in) { ok = NO; reason = @"分段缺失"; break; }
            while (YES) {
                @autoreleasepool {
                    NSData *chunk = [in readDataOfLength:1024 * 1024];
                    if (!chunk.length) break;
                    [out writeData:chunk];
                }
            }
            [in closeFile];
        }
    } @catch (NSException *exception) {
        ok = NO; reason = exception.reason ?: @"合并失败";
    }
    [out closeFile];
    if (ok) {
        NSNumber *size = [[[NSFileManager defaultManager] attributesOfItemAtPath:merged.path error:nil] objectForKey:NSFileSize];
        if (size.longLongValue != job.expectedContentLength) { ok = NO; reason = @"合并后长度不一致"; }
    }
    if (ok && ![DownloadJob isLikelyVideoFileAtURL:merged]) { ok = NO; reason = @"文件内容不是有效视频"; }
    if (ok) {
        RDDownloadLog(@"分段合并成功 id=%@ 段数=%ld 合并大小=%lld", job.identifier, (long)job.segmentCount,
                      [((NSNumber *)[[[NSFileManager defaultManager] attributesOfItemAtPath:merged.path error:nil] objectForKey:NSFileSize]) longLongValue]);
        [self finalizeCompleted:job fromURL:merged];
    } else {
        RDDownloadLog(@"分段合并失败 id=%@ 原因：%@", job.identifier, reason ?: @"未知");
        dispatch_async(dispatch_get_main_queue(), ^{ [self failJob:job reason:reason]; });
    }
}

#pragma mark - 验证

- (BOOL)verifySingleResponse:(NSHTTPURLResponse *)resp writtenURL:(NSURL *)written job:(DownloadJob *)job {
    if (!written) return NO;
    if (resp && (resp.statusCode < 200 || resp.statusCode >= 300)) return NO;
    NSString *mime = resp.MIMEType.lowercaseString ?: @"";
    DownloadResourceKind verificationKind = job.resourceKind == DownloadResourceManifest ? DownloadResourceVideo : job.resourceKind;
    if (verificationKind == DownloadResourceImage) {
        if (mime.length && ![mime hasPrefix:@"image/"] && ![mime isEqual:@"application/octet-stream"] && ![mime isEqual:@"binary/octet-stream"]) return NO;
        if ([DownloadJob isLikelyHTMLErrorFileAtURL:written] || ![DownloadJob isLikelyImageFileAtURL:written]) return NO;
    } else if (verificationKind == DownloadResourceManifest) {
        NSData *d=[NSData dataWithContentsOfURL:written options:NSDataReadingMappedIfSafe error:nil];
        NSString *s=d.length ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        if (!s || !([s containsString:@"#EXTM3U"] || [s rangeOfString:@"<MPD" options:NSCaseInsensitiveSearch].location != NSNotFound)) return NO;
    } else {
        if (mime.length && ![mime hasPrefix:@"video/"] &&
            ![mime isEqualToString:@"application/octet-stream"] &&
            ![mime isEqual:@"binary/octet-stream"]) return NO;
        if (![DownloadJob isLikelyVideoFileAtURL:written]) return NO;
    }
    // 长度完整性：Content-Length / Content-Range / 可信预期长度与实际落盘字节
    // 交叉校验。带合法视频头的截断文件（如预期几十 MB 却只到 143 字节）必须在这里失败。
    if ([self bodyIntegrityProblem:resp writtenURL:written job:job]) return NO;
    return YES;
}

// 正文长度完整性校验。返回 nil 表示通过；返回非 nil 为中文失败原因。
// 只核对“字节数”这一维度：状态码 / MIME / 文件头由 verifySingleResponse 负责。
- (nullable NSString *)bodyIntegrityProblem:(NSHTTPURLResponse *)resp
                                 writtenURL:(NSURL *)written
                                        job:(DownloadJob *)job {
    if (!written) return @"未收到文件";
    NSNumber *sizeAttr = [[[NSFileManager defaultManager] attributesOfItemAtPath:written.path error:nil] objectForKey:NSFileSize];
    int64_t actual = sizeAttr ? sizeAttr.longLongValue : -1;
    if (actual < 0) return @"无法读取已下载的临时文件";
    if (actual == 0) return @"服务器返回成功状态但未收到任何数据";
    int64_t declared = resp ? resp.expectedContentLength : 0;   // 200=全量；206=本段
    if (declared > 0 && actual != declared) {
        return [NSString stringWithFormat:@"下载不完整：服务器声明 %lld 字节，实际只收到 %lld 字节", declared, actual];
    }
    if (resp && resp.statusCode == 206) {
        // 单连接下载从未发送 Range 头，服务器却回 206：Content-Range 的总长
        // 就是完整文件长度，落盘字节数必须等于总长，否则只是文件的一小段。
        NSString *contentRange = [resp valueForHTTPHeaderField:@"Content-Range"] ?: @"";
        NSRange slash = [contentRange rangeOfString:@"/"];
        if (slash.location != NSNotFound && slash.location + 1 < contentRange.length) {
            int64_t total = [[contentRange substringFromIndex:slash.location + 1] longLongValue];
            if (total > 0 && actual != total) {
                return [NSString stringWithFormat:@"下载不完整：文件总长 %lld 字节，实际只收到 %lld 字节", total, actual];
            }
        }
    } else if (job) {
        int64_t trusted = job.authoritativeExpectedLength > 0 ? job.authoritativeExpectedLength : job.expectedContentLength;
        if (trusted > 0 && actual < trusted) {
            return [NSString stringWithFormat:@"下载不完整：预期至少 %lld 字节，实际只收到 %lld 字节", trusted, actual];
        }
    }
    return nil;
}

// 是否属于可重试的临时短响应：2xx 成功状态下字节数不足，且正文不是 HTML
// 错误页。HTML/JSON 错误页与 4xx/5xx 是确定性错误，重试没有意义。
- (BOOL)isTransientShortBodyFailure:(NSHTTPURLResponse *)resp writtenURL:(NSURL *)written job:(DownloadJob *)job {
    if (resp && (resp.statusCode < 200 || resp.statusCode >= 300)) return NO;
    if ([DownloadJob isLikelyHTMLErrorFileAtURL:written]) return NO;
    return [self bodyIntegrityProblem:resp writtenURL:written job:job] != nil;
}

- (NSString *)singleFailureReason:(NSHTTPURLResponse *)resp writtenURL:(NSURL *)written job:(DownloadJob *)job {
    if (!written) return @"未收到文件";
    if (resp && (resp.statusCode < 200 || resp.statusCode >= 300))
        return [NSString stringWithFormat:@"网站返回 %ld（网站方限制或链接失效，非应用故障），下载中止", (long)resp.statusCode];
    NSString *mime = resp.MIMEType.lowercaseString ?: @"";
    DownloadResourceKind verificationKind = job.resourceKind == DownloadResourceManifest ? DownloadResourceVideo : job.resourceKind;
    BOOL isVideoKind = verificationKind != DownloadResourceImage && verificationKind != DownloadResourceManifest;
    if (mime.length && isVideoKind && ![mime hasPrefix:@"video/"] &&
        ![mime isEqualToString:@"application/octet-stream"] &&
        ![mime isEqual:@"binary/octet-stream"])
        return [NSString stringWithFormat:@"网站返回 %@，不是视频文件（网站方限制，非应用故障）", mime];
    if ([DownloadJob isLikelyHTMLErrorFileAtURL:written] && isVideoKind)
        return @"保存的内容是网页/错误页，不是视频文件（网站方未提供视频，非应用故障）";
    NSString *integrity = [self bodyIntegrityProblem:resp writtenURL:written job:job];
    if (integrity) return integrity;
    return isVideoKind ? @"文件内容不是有效视频（网站方未提供有效内容，非应用故障）" : @"文件内容与预期格式不符";
}

#pragma mark - 完成 / 失败 / 取消

// 终态追溯记录：完成/失败/取消时写入最终路径与状态（持久化），并清掉该任务
// 的中断记录——否则下次启动会同时出现幽灵中断任务和终态历史。入队即被拒的
// 任务没有 destinationURL，记录仅含 sourceURL 供追溯。
- (void)storeFinishedRecordForJob:(DownloadJob *)job {
    if (!job || !job.identifier.length) return;
    [self.store removeInterruptedRecord:job.identifier];
    if (job.state != DownloadJobStateCompleted && job.state != DownloadJobStateFailed &&
        job.state != DownloadJobStateCancelled) return;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"identifier"] = job.identifier;
    record[@"state"] = @(job.state);
    if (job.enqueuedAt) record[@"enqueuedAt"] = job.enqueuedAt;
    if (job.sourceURL.absoluteString.length) record[@"sourceURL"] = job.sourceURL.absoluteString;
    if (job.destinationURL.absoluteString.length) record[@"destinationURL"] = job.destinationURL.absoluteString;
    if (job.fileName.length) record[@"fileName"] = job.fileName;
    if (job.errorText.length) record[@"errorText"] = job.errorText;
    if (job.expectedContentLength > 0) record[@"expectedLength"] = @(job.expectedContentLength);
    [self.store recordFinishedJob:record];
    RDDownloadLog(@"终态记录 id=%@ state=%@ path=%@%@", job.identifier, RDStateNameForJob(job),
                  job.destinationURL.path ?: @"（未预留目标路径）",
                  job.errorText.length ? [NSString stringWithFormat:@" 错误：%@", job.errorText] : @"");
}

- (void)finalizeCompleted:(DownloadJob *)job fromURL:(NSURL *)tempFile {
    if (job.expectedContentLength < 128LL * 1024LL * 1024LL) {
        [self finalizeCompletedOnFinalizationQueue:job fromURL:tempFile];
        return;
    }
    dispatch_async(self.finalizationQueue, ^{ [self finalizeCompletedOnFinalizationQueue:job fromURL:tempFile]; });
}

- (void)finalizeCompletedOnFinalizationQueue:(DownloadJob *)job fromURL:(NSURL *)tempFile {
    if (job.state != DownloadJobStateRunning) return;
    // 交付前再次做 DNS 预检查；这不是已下载连接的 peer-IP 证据，
    // 无法证明下载期间没有 rebinding，也不能替代连接级地址绑定。
    URLPolicyDecision *rejected = [self rd_validateSourceURL:job.sourceURL];
    if (rejected) {
        [self failJob:job reason:(rejected.userMessage.length ? rejected.userMessage : @"地址安全复查未通过")];
        return;
    }
    // 完成阶段实际大小检查：临时文件超单文件上限则失败（不落盘到目标）
    NSNumber *actualSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:tempFile.path error:nil] objectForKey:NSFileSize];
    if (actualSize.longLongValue > [PerformancePolicy downloadMaxSingleFileBytes]) {
        [self failJob:job reason:@"下载文件超过单文件大小上限"];
        return;
    }
    // Some CDNs omit or misstate Content-Length during probing.  The validated
    // file is authoritative at this point, so reconcile both byte counters
    // before the UI observes this task as completed.
    if (actualSize.longLongValue > 0) {
        job.expectedContentLength = actualSize.longLongValue;
        job.transferredBytes = actualSize.longLongValue;
    }
    BOOL destinationExistedBefore = [[NSFileManager defaultManager]
                                     fileExistsAtPath:job.destinationURL.path];
    NSError *moveError = nil;
    // 入队时虽然已预留文件名，但下载期间外部程序仍可能创建同名文件。
    // 完成阶段再次检查并改名，绝不删除后来出现的用户文件。
    if ([[NSFileManager defaultManager] fileExistsAtPath:job.destinationURL.path]) {
        NSString *unique=[DownloadJob reserveUniqueNameForPreferred:job.fileName
                                                           inFolder:job.destinationURL.URLByDeletingLastPathComponent.path
                                                    againstReserved:self.reservedNames];
        RDDownloadLog(@"完成阶段改名：%@ 已被占用 → %@", job.destinationURL.path ?: @"", unique);
        job.fileName=unique;
        job.destinationURL=[job.destinationURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:unique];
    }
    RDDownloadLog(@"最终 move：%@（%lld 字节）→ %@", tempFile.path, actualSize.longLongValue, job.destinationURL.path ?: @"");
    BOOL ok = [[NSFileManager defaultManager] moveItemAtURL:tempFile toURL:job.destinationURL error:&moveError];
    if (!ok) {
        RDDownloadLog(@"最终 move 失败：%@", moveError.localizedDescription ?: @"未知错误");
        // Only a target created by this failed move may be removed; an existing
        // user file is left untouched.
        if (!destinationExistedBefore &&
            [[NSFileManager defaultManager] fileExistsAtPath:job.destinationURL.path]) {
            NSError *cleanupError = nil;
            if ([[NSFileManager defaultManager] removeItemAtURL:job.destinationURL
                                                          error:&cleanupError]) {
                RDDownloadLog(@"已清理最终 move 留下的半截目标文件：%@", job.destinationURL.path);
            } else {
                RDDownloadLog(@"半截目标文件清理失败：%@", cleanupError.localizedDescription ?: @"未知错误");
            }
        }
        [self failJob:job reason:moveError.localizedDescription ?: @"无法保存文件"];
        return;
    }
    // 完成状态只在最终文件真实落盘且大小一致后才允许设置。
    NSNumber *finalSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:job.destinationURL.path error:nil] objectForKey:NSFileSize];
    if (!finalSize || finalSize.longLongValue != actualSize.longLongValue) {
        RDDownloadLog(@"落盘校验失败：%@ 不存在或大小不符（期望 %lld）", job.destinationURL.path ?: @"", actualSize.longLongValue);
        [self failJob:job reason:@"文件保存后校验失败"];
        return;
    }
    job.progress = 1.0;
    [job transitionTo:DownloadJobStateCompleted];
    RDDownloadLog(@"完成 id=%@ 最终路径=%@ 大小=%lld 字节", job.identifier, job.destinationURL.path ?: @"", finalSize.longLongValue);
    [self.retryAttempts removeObjectForKey:job.identifier];
    [self.retryDeferrals removeObjectForKey:job.identifier];
    [self.endpointResolutionRetries removeObjectForKey:job.identifier];
    [self cleanupAccountingForJob:job.identifier];
    [self stopProgressWatchdogForJob:job];
    [self.store recordCompletedURL:job.sourceURL]; // 仅验证通过后记录
    [self storeFinishedRecordForJob:job];
    [self removeTempRootForJob:job];
    [self.activeTasks removeObjectForKey:job.identifier];
    [self removeQueuedJobIdentifier:job.identifier];
    [self notifyUpdate:job];
    [self notifyChange];
    [self startQueuedJobs];
}

- (void)failJob:(DownloadJob *)job reason:(NSString *)reason {
    [self failJob:job reason:reason linkExpired:NO];
}

// linkExpired=YES 表示失败原因是“远程链接失效类”（401/403/404/410、
// 伪媒体 HTML 响应等）。只有这类失败才允许上层做单资源重新探测；
// 本地磁盘不足、权限、用户取消等绝不触发链接刷新。
- (void)failJob:(DownloadJob *)job reason:(NSString *)reason linkExpired:(BOOL)linkExpired {
    if (job.state == DownloadJobStateFailed || job.state == DownloadJobStateCompleted ||
        job.state == DownloadJobStateCancelled) return;
    [job transitionTo:DownloadJobStateFailed];
    job.errorText = reason ?: @"未知错误";
    RDDownloadLog(@"失败 id=%@ state=%@ url=%@ 目标=%@ 原因：%@%@",
                  job.identifier, RDStateNameForJob(job), RDRedactedURL(job.sourceURL),
                  job.destinationURL.path ?: @"（未预留目标路径）", reason ?: @"未知错误",
                  linkExpired ? @"（链接失效类）" : @"");
    [self.retryAttempts removeObjectForKey:job.identifier];
    [self.retryDeferrals removeObjectForKey:job.identifier];
    [self.shortBodyRetryAttempts removeObjectForKey:job.identifier];
    [self.endpointResolutionRetries removeObjectForKey:job.identifier];
    [self cleanupAccountingForJob:job.identifier];
    [self stopProgressWatchdogForJob:job];
    [self cancelActiveTasksForJob:job];
    // Preserve completed segment files while the current fallback is active;
    // the fallback writes into a separate file inside a new root.
    [self.activeTasks removeObjectForKey:job.identifier];
    [self removeQueuedJobIdentifier:job.identifier];
    // 失败即终态：删除本任务临时目录（短文件/坏片段就地销毁），绝不把残缺
    // 内容留给用户、也绝不让残缺文件进入目标文件夹。链接刷新重启会用全新
    // 临时目录（-rf / -fb），不受此处清理影响。
    [self removeTempRootForJob:job];
    [self storeFinishedRecordForJob:job];
    [self notifyUpdate:job];
    [self notifyChange];
    // 链接失效回调只在任务真正停在 Failed 终态时触发；用户若在此之前
    // 已取消（Failed->Cancelled），回调不会把任务恢复。
    if (linkExpired && job.state == DownloadJobStateFailed && self.linkRefreshHandler) {
        self.linkRefreshHandler(job, reason ?: @"未知错误");
    }
    [self startQueuedJobs];
}

// 链接失效判定：401/403/404/410、text/* MIME、或“200 但内容是 HTML
// 错误页”（伪媒体响应）。本地错误与普通校验失败返回 NO。
- (BOOL)isLinkExpiryFailureForResponse:(NSHTTPURLResponse *)resp writtenURL:(NSURL *)written {
    if (resp) {
        if ([DownloadManager isLinkExpiryStatus:resp.statusCode]) return YES;
        NSString *mime = resp.MIMEType.lowercaseString ?: @"";
        if (mime.length && [mime hasPrefix:@"text/"]) return YES;
        // 2026-09-03：部分站点把高画质伪装成 .mp4 名、实际返回 HLS 流媒体
        // （application/vnd.apple.mpegurl）。把它归入“链接失效/伪媒体”类，以便
        // 上层自动降到更低画质重试（否则该档永远报“不是视频文件”且不触发刷新）。
        if (mime.length && [mime containsString:@"mpegurl"]) return YES;
    }
    if (written && [DownloadJob isLikelyHTMLErrorFileAtURL:written]) return YES;
    return NO;
}

+ (BOOL)isLinkExpiryStatus:(NSInteger)statusCode {
    return statusCode == 401 || statusCode == 403 || statusCode == 404 || statusCode == 410;
}

// 下载链接刷新后的原地重启：只替换失效 URL，保留 identifier/文件名/目标
// 路径与既有排队语义。绝不创建第二个任务（不经过 enqueue 的预留名流程），
// 也绝不重置连接预算——重启任务与普通任务一样走 startQueuedJobs 的
// 全局连接上限（单视频 4、全局 12 不变）。
- (BOOL)restartFailedJobWithIdentifier:(NSString *)identifier
                             sourceURL:(NSURL *)newSourceURL
                         expectedLength:(int64_t)length
                                   etag:(NSString *)etag
                            lastModified:(NSString *)lastModified
                           acceptRanges:(BOOL)acceptRanges {
    DownloadJob *job = self.jobs[identifier];
    if (!job || job.state != DownloadJobStateFailed) return NO;
    if (!newSourceURL.absoluteString.length) return NO;
    // SSRF 防线不得降低：新地址与首次入队执行同样的文本+DNS 校验。
    URLPolicyDecision *rejected = [self rd_validateSourceURL:newSourceURL];
    if (rejected) {
        job.errorText = rejected.userMessage.length ? rejected.userMessage : @"新地址被安全策略阻止";
        [self notifyUpdate:job];
        return NO;
    }
    job.generation += 1; // 旧回调（含刷新前的迟到回调）全部作废
    job.sourceURL = newSourceURL;
    job.etag = etag ?: @"";
    job.lastModified = lastModified ?: @"";
    job.acceptRanges = acceptRanges;
    job.expectedContentLength = length > 0 ? length : 0;
    job.authoritativeExpectedLength = job.expectedContentLength;
    job.errorText = @"";
    job.progress = 0;
    job.transferredBytes = 0;
    job.bytesPerSecond = 0;
    job.estimatedRemainingSeconds = 0;
    job.lastRateSampleDate = nil;
    job.segmented = NO;
    job.segmentCount = 0;
    job.finishedSegments = 0;
    job.fallbackUsed = NO;
    // 清除首次尝试的能力探测记录：新 URL 的服务器/链路可能已不同，必须让
    // startQueuedJobs 重新探测决定是否分段，否则重启任务被永久降级为单连接。
    [self.capabilityProbeCompleted removeObject:identifier];
    [self.capabilityProbePending removeObject:identifier];
    // 重启是全新尝试：探测瞬时失败的顺延计数同样清零（与端点解析顺延同一语义）。
    [self.capabilityProbeAttempts removeObjectForKey:identifier];
    // 链接刷新重启是全新尝试：旧 URL 遗留的端点解析超时顺延计数一并清除。
    [self.endpointResolutionRetries removeObjectForKey:identifier];
    // 失败路径已清理旧临时目录；重建独立临时目录，沿用原目标文件名，
    // 不重新预留名字 → 不产生第二个文件。
    job.tempRootURL = [self.tempRoot URLByAppendingPathComponent:
                       [NSString stringWithFormat:@"%@-rf", job.identifier]];
    [self claimTempDirectoryForJob:job];
    if (![self ownsTempDirectoryAtPath:job.tempRootURL.path]) {
        // R2：重启目录被另一实例占用 → 保守失败，绝不写入他人目录。
        [job transitionTo:DownloadJobStateFailed];
        job.errorText = @"重启下载的临时目录正由另一个实例使用";
        [self storeFinishedRecordForJob:job];
        [self notifyUpdate:job];
        [self notifyChange];
        return NO;
    }
    if (![self.queuedJobIdentifiers containsObject:identifier]) {
        [self.queuedJobIdentifiers addObject:identifier];
    }
    [job transitionTo:DownloadJobStateQueued]; // 状态机显式例外：链接刷新原地重启
    RDDownloadLog(@"链接刷新重启 id=%@ 新URL=%@ 目标=%@", identifier, RDRedactedURL(newSourceURL), job.destinationURL.path ?: @"");
    [self notifyUpdate:job];
    [self notifyChange];
    [self startQueuedJobs];
    return (job.state == DownloadJobStateQueued || job.state == DownloadJobStateRunning);
}

- (void)finalizeCancelled:(DownloadJob *)job {
    if (job.state != DownloadJobStateCancelling) return;
    [job transitionTo:DownloadJobStateCancelled];
    RDDownloadLog(@"取消 id=%@ 目标=%@", job.identifier, job.destinationURL.path ?: @"（未预留目标路径）");
    [self.retryAttempts removeObjectForKey:job.identifier];
    [self.retryDeferrals removeObjectForKey:job.identifier];
    [self.shortBodyRetryAttempts removeObjectForKey:job.identifier];
    [self.endpointResolutionRetries removeObjectForKey:job.identifier];
    [self cleanupAccountingForJob:job.identifier];
    [self stopProgressWatchdogForJob:job];
    [self removeTempRootForJob:job];
    [self storeFinishedRecordForJob:job];
    [self.activeTasks removeObjectForKey:job.identifier];
    [self removeQueuedJobIdentifier:job.identifier];
    [self notifyUpdate:job];
    [self notifyChange];
    [self startQueuedJobs];
}

// 返回 YES 表示已同步启动回退单连接并占用了刚释放的槽位（调用方因此
// 不应再把该槽位交给排队任务）；返回 NO 表示未启动回退（任务失败、
// 状态失效或二次回退转 Failed），槽位交由调用方处理。
- (BOOL)fallbackSingle:(DownloadJob *)job reason:(NSString *)reason {
    if (job.state != DownloadJobStateRunning) return NO;
    if (job.fallbackUsed) { RDDownloadLog(@"回退失败 id=%@ 原因：%@", job.identifier, reason); [self failJob:job reason:reason]; return NO; }
    RDDownloadLog(@"分段回退单连接 id=%@ 原因：%@", job.identifier, reason);
    job.fallbackUsed = YES;
    job.generation += 1; // 旧分段回调失效

    // The failed part's slot was released in the completion wrapper but is not
    // offered to queued work until this handler returns. Keep the pump closed
    // while cancelling the remaining parts so neither synchronous cancellation
    // callbacks nor the queue can steal that slot: the fallback single
    // transfer below reuses it, keeping real occupancy within the budget even
    // when deferred cancellation completions still hold their slots.
    BOOL wasPumpSuppressed = self.queuePumpSuppressed;
    self.queuePumpSuppressed = YES;
    [self cancelActiveTasksForJob:job];
    // Keep already completed segment files; the fallback transfer uses a
    // separate root and must not erase bytes received before the failure.
    NSURL *segmentRootURL = job.tempRootURL;
    job.tempRootURL = [self.tempRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-fb", job.identifier]];
    [self claimTempDirectoryForJob:job];
    if (![self ownsTempDirectoryAtPath:job.tempRootURL.path]) {
        // R2：回退目录被另一实例占用 → 保守失败，绝不写入他人目录。
        job.segmented = NO; job.segmentCount = 0; job.finishedSegments = 0;
        [job transitionTo:DownloadJobStateFailed];
        job.errorText = @"回退下载的临时目录正由另一个实例使用";
        // BUG-027：原分段目录仍归本实例时必须回收；被别的实例持有的目录绝不触碰。
        job.tempRootURL = segmentRootURL;
        if ([self ownsTempDirectoryAtPath:job.tempRootURL.path]) [self removeTempRootForJob:job];
        [self storeFinishedRecordForJob:job];
        [self notifyUpdate:job];
        [self notifyChange];
        return NO;
    }
    job.segmented = NO;
    job.segmentCount = 0;
    job.finishedSegments = 0;
    job.progress = 0;
    job.transferredBytes = 0;
    job.bytesPerSecond = 0;
    job.estimatedRemainingSeconds = 0;
    [self startSingle:job];
    self.queuePumpSuppressed = wasPumpSuppressed;
    [self notifyUpdate:job];
    if (!wasPumpSuppressed) [self startQueuedJobs];
    return YES;
}

#pragma mark - 控制

- (void)pauseJob:(NSString *)identifier {
    DownloadJob *job = self.jobs[identifier];
    if (!job || job.state != DownloadJobStateRunning) return;
    [job transitionTo:DownloadJobStatePaused];
    job.bytesPerSecond = 0;
    job.estimatedRemainingSeconds = 0;
    for (RDDownloadTaskSlot *slot in self.activeTasks[identifier]) {
        [self suspendTaskIfSupported:slot.task];
    }
    [self notifyUpdate:job];
}

- (void)resumeJob:(NSString *)identifier {
    DownloadJob *job = self.jobs[identifier];
    if (!job || (job.state != DownloadJobStatePaused && job.state != DownloadJobStateInterrupted)) return;
    // R2：先尝试接管所有权；拿不到（另一实例持有）才拒绝启动写入。
    if (![self ensureOwnershipForJob:job]) {
        RDDownloadLog(@"恢复被拒 id=%@ 临时目录由另一实例持有", identifier);
        job.errorText = @"该下载正由另一个实例处理，本实例无法继续";
        [self notifyUpdate:job];
        return;
    }
    BOOL hasLiveTransfers = self.activeTasks[identifier].count > 0;
    // 原传输已全部结束的暂停任务需要重新发起传输；仅当全局存在空闲槽位时
    // 才恢复，绝不为恢复动作突破连接上限。无空闲槽位时保持 Paused，
    // 待有槽位释放后用户可再次继续。
    if (!hasLiveTransfers && [self activeTransferCount] >= MAX(1, [PerformancePolicy downloadConnections])) return;
    [job transitionTo:DownloadJobStateRunning];
    if (!hasLiveTransfers) {
        job.errorText=@"";
        // 中断恢复的任务临时目录可能在启动清理时被删除，传输写入前必须重建并重新认领。
        [self claimTempDirectoryForJob:job];
        [job transitionTo:DownloadJobStateQueued];
        [self.validatedEndpointGenerations removeObjectForKey:identifier];
        if (![self.queuedJobIdentifiers containsObject:identifier]) [self.queuedJobIdentifiers addObject:identifier];
        [self startQueuedJobs];
    } else {
        // 暂停期间进度看门狗已因“非 Running”被注销；恢复存活传输必须重建，
        // 否则恢复后的停滞连接只能等 7 天资源超时，任务假死。
        [self markProgressForJob:job];
        [self startProgressWatchdogForJob:job];
    }
    for (RDDownloadTaskSlot *slot in self.activeTasks[identifier]) {
        [self resumeTaskIfSupported:slot.task];
    }
    [self notifyUpdate:job];
}

- (void)cancelJob:(NSString *)identifier {
    DownloadJob *job = self.jobs[identifier];
    if (!job) return;
    // 终态任务：重复取消必须是无副作用的空操作。
    // 此处必须在任何“取得所有权”之前返回：认领会以 createIfMissing:YES 把终态
    // 清理时已删除的临时目录重新建出来并重新登记所有权（目录 + fd 泄漏），
    // 而且会把已 Cancelled 的任务再次推进状态机。
    if (job.state == DownloadJobStateCancelled || job.state == DownloadJobStateCompleted) return;
    // R2：目录不归本实例所有时，取消动作不得推进其状态、不得删除他人目录或清除其恢复记录。
    //
    // 取消**不得创建目录**：这里以 createIfMissing:NO 尝试接管。
    //   · 目录在、锁空闲  ⇒ 接管（含 markInterruptedOnTerminate 释放后再取消）；
    //   · 目录在、他人持锁 ⇒ 接管失败 ⇒ 拒绝，不改状态、不删目录（R2）；
    //   · 目录不存在      ⇒ 无目录可管，取消只需改写状态与记录
    //                        （取消失败项、取消目录已被启动清理回收的暂停项，均不重建目录）。
    [self claimTempDirectoryAtURL:job.tempRootURL createIfMissing:NO];
    BOOL directoryExists = [[NSFileManager defaultManager] fileExistsAtPath:
                            [job.tempRootURL URLByStandardizingPath].path];
    if (directoryExists && ![self ownsTempDirectoryAtPath:job.tempRootURL.path]) {
        RDDownloadLog(@"取消被拒 id=%@ 临时目录由另一实例持有，本实例不改写其状态", identifier);
        [self notifyUpdate:job];
        return;
    }
    if (job.state == DownloadJobStateFailed) {
        // 链接刷新期间用户显式取消失败项：直接进入取消终态，任何迟到的
        // 刷新回调都不得恢复任务（不得“取消后状态复活”）。
        job.cancelledIntentionally = YES;
        job.generation += 1;
        [job transitionTo:DownloadJobStateCancelled];
        [self storeFinishedRecordForJob:job];
        [self notifyUpdate:job];
        [self notifyChange];
        return;
    }
    job.cancelledIntentionally = YES;
    job.generation += 1; // 取消后任何迟到成功/失败回调都不得落盘或改写状态。
    [job transitionTo:DownloadJobStateCancelling];
    [self cancelActiveTasksForJob:job];
    [self finalizeCancelled:job];
}

- (void)cancelAll {
    self.queuePumpSuppressed = YES;
    for (NSString *id in [self.jobs.allKeys copy]) [self cancelJob:id];
    self.queuePumpSuppressed = NO;
    [self startQueuedJobs];
}

- (void)markInterruptedOnTerminate {
    // A native task may invoke its cancellation completion synchronously. Keep
    // the queue closed until every queued job has been marked interrupted.
    BOOL wasPumpSuppressed = self.queuePumpSuppressed;
    self.queuePumpSuppressed = YES;
    NSMutableDictionary<NSString *, NSDictionary *> *records = [NSMutableDictionary dictionary];
    // 退出时需要释放的归属锁：**必须等中断记录持久化之后**再释放。
    // 若先释放再落盘，中间窗口里另一实例的启动清理会看到「锁文件仍在、但无人持锁」的
    // 目录，把它当孤儿回收，用户可续传的分段数据就丢了。这与 P1-A/P1-B 同属一套
    // 所有权协议，因此顺序固定为「先落盘、后放锁」。
    NSMutableArray<NSString *> *claimPathsToRelease = [NSMutableArray array];
    @try {
        for (DownloadJob *job in self.jobs.allValues) {
            // R2：目录不归本实例所有的任务，其恢复记录归另一实例所有——
            // 本实例绝不改写、不清除，也不把它算进本实例的中断清单。
            if (![self ownsTempDirectoryAtPath:job.tempRootURL.path]) continue;
            // 已是 Interrupted 的任务（上次会话遗留、用户未续传）也必须重新写入：
            // 否则一次空退出就会把未完成任务的恢复记录整体覆盖丢失。
            if (job.state == DownloadJobStateRunning || job.state == DownloadJobStatePaused || job.state == DownloadJobStateQueued) {
                [job transitionTo:DownloadJobStateInterrupted];
                job.bytesPerSecond = 0;
                job.estimatedRemainingSeconds = 0;
                job.generation += 1;
                [self stopProgressWatchdogForJob:job];
                [self cancelActiveTasksForJob:job];
                [self removeQueuedJobIdentifier:job.identifier];
                [self cleanupAccountingForJob:job.identifier];
                [self notifyUpdate:job];
            }
            if (job.state == DownloadJobStateInterrupted) {
                // 管理器随进程退出：稍后显式释放所有权锁，让下一次启动（或其他实例）能正常接管。
                // 只释放、不删除目录——中断任务的数据必须留给续传。
                records[job.identifier] = @{ @"sourceURL":job.sourceURL.absoluteString?:@"", @"destinationURL":job.destinationURL.absoluteString?:@"", @"tempRootURL":job.tempRootURL.absoluteString?:@"", @"fileName":job.fileName?:@"", @"referer":job.referer?:@"", @"expectedLength":@(job.expectedContentLength), @"enqueuedAt":job.enqueuedAt ?: [NSDate date], @"etag":job.etag?:@"", @"lastModified":job.lastModified?:@"", @"acceptRanges":@(job.acceptRanges), @"resourceKind":@(job.resourceKind), @"segmented":@(job.segmented), @"segmentCount":@(job.segmentCount), @"finishedSegments":@(job.finishedSegments), @"streamMasterURL":job.streamMasterURL?:@"", @"sourcePageURL":job.sourcePageURL?:@"", @"qualityHint":job.qualityHint?:@"", @"resourceTitle":job.resourceTitle?:@"" };
                [claimPathsToRelease addObject:job.tempRootURL.path];
            }
        }
        // R2：多实例安全合并——其他实例写入的中断记录原样保留，绝不因本实例退出而丢失。
        NSMutableDictionary<NSString *, NSDictionary *> *mergedRecords = [NSMutableDictionary dictionary];
        NSDictionary *existing = [self.store interruptedRecords] ?: @{};
        for (NSString *identifier in existing) {
            if (records[identifier]) continue;
            NSDictionary *record = existing[identifier];
            if (![record isKindOfClass:NSDictionary.class]) continue;
            NSString *recordPath = [[NSURL URLWithString:record[@"tempRootURL"]] URLByStandardizingPath].path;
            if (recordPath.length && self.tempDirClaimDescriptors[recordPath]) continue;   // 本实例仍拥有
            mergedRecords[identifier] = record;
        }
        [records addEntriesFromDictionary:mergedRecords];
        // ① 先落盘：持久化期间本实例仍持有全部归属锁，其他实例的孤儿清理不会回收这些目录。
        [self.store setInterruptedRecords:records];
        // ② 后放锁：此时下一次启动已经能读到中断记录，可以安全接管。
        for (NSString *path in claimPathsToRelease) {
            [self releaseTempDirClaimForPath:path];
        }
        RDDownloadLog(@"退出标记：中断任务 %lu 个已持久化", (unsigned long)records.count);
        [self notifyChange];
    } @finally {
        self.queuePumpSuppressed = wasPumpSuppressed;
    }
}

#pragma mark - 辅助

// BUG-026：终态必须同时清任务级键和复合键记账项；中断按“本次会话终态”处理，
// 恢复任务会从磁盘分片重建进度，不依赖这些内存计数。
- (void)cleanupAccountingForJob:(NSString *)identifier {
    if (!identifier.length) return;
    NSArray<id> *accountingCollections = @[
        self.segmentBytes, self.segmentAttemptBytes, self.partURLsAt,
        self.segmentRateSamples, self.lastProgressAt, self.transferSamples,
        self.lastDiskCheckAt, self.retryAttempts, self.retryDeferrals,
        self.segmentRetryAttempts, self.segmentRetryDeferrals,
        self.segmentProgressAt, self.segmentTokens, self.segmentStallAttempts,
        self.poolStallRounds, self.poolStallNextAllowedAt,
        self.poolStallBytesAtLastRound, self.shortBodyRetryAttempts,
        self.capabilityProbeAttempts, self.validatedEndpointGenerations,
        self.endpointChecksPending, self.endpointResolutionRetries,
    ];
    for (id collection in accountingCollections) {
        if ([collection respondsToSelector:@selector(removeObjectForKey:)])
            [(NSMutableDictionary *)collection removeObjectForKey:identifier];
        else if ([collection respondsToSelector:@selector(removeObject:)])
            [(NSMutableSet *)collection removeObject:identifier];
    }
    [self.transferScheduler removeStreamIdentifier:identifier];
}

- (void)trackTask:(id<RDDownloadTask>)task token:(NSString *)token forJob:(DownloadJob *)job {
    if (!task || !token.length || !job.identifier.length) return;
    RDDownloadTaskSlot *slot = [RDDownloadTaskSlot new];
    slot.task = task;
    slot.token = token;
    slot.jobIdentifier = job.identifier;
    NSMutableArray *arr = self.activeTasks[job.identifier];
    if (!arr) { arr = [NSMutableArray array]; self.activeTasks[job.identifier] = arr; }
    [arr addObject:slot];
    self.taskSlotsByToken[token] = slot;
}

- (void)observeTransferCompletionForJob:(DownloadJob *)job token:(NSString *)token {
    RDDownloadTaskSlot *slot = self.taskSlotsByToken[token];
    if (!slot) return; // A backend may complete synchronously before it returns its task.
    [self.cancellingTaskSlots removeObject:slot];
    [self.taskSlotsByToken removeObjectForKey:token];
    NSMutableArray *arr = self.activeTasks[job.identifier];
    [arr removeObjectIdenticalTo:slot];
    if (arr.count == 0) [self.activeTasks removeObjectForKey:job.identifier];

    // A slot is released only after the backend reports completion. If this was
    // a normal late cancellation (rather than fallback), pump now so queued
    // work cannot remain stranded after the slot becomes genuinely free.
    if (!self.queuePumpSuppressed && job.state != DownloadJobStateRunning) [self startQueuedJobs];
}

- (void)cancelTaskIfSupported:(id<RDDownloadTask>)task {
    if ([task respondsToSelector:@selector(rd_cancel)]) {
        [task rd_cancel];
    } else if ([(id)task respondsToSelector:@selector(cancel)]) {
        [(id)task cancel];
    }
}

- (void)suspendTaskIfSupported:(id<RDDownloadTask>)task {
    if ([task respondsToSelector:@selector(rd_suspend)]) {
        [task rd_suspend];
    } else if ([(id)task respondsToSelector:@selector(suspend)]) {
        [(NSURLSessionTask *)task suspend];
    }
}

- (void)resumeTaskIfSupported:(id<RDDownloadTask>)task {
    if ([task respondsToSelector:@selector(rd_resume)]) {
        [task rd_resume];
    } else if ([(id)task respondsToSelector:@selector(resume)]) {
        [(NSURLSessionTask *)task resume];
    }
}

- (void)cancelActiveTasksForJob:(DownloadJob *)job {
    NSMutableArray *arr = self.activeTasks[job.identifier];
    NSArray<RDDownloadTaskSlot *> *slots = [arr copy];
    [self.activeTasks removeObjectForKey:job.identifier];
    for (RDDownloadTaskSlot *slot in slots) [self.cancellingTaskSlots addObject:slot];
    for (RDDownloadTaskSlot *slot in slots) [self cancelTaskIfSupported:slot.task];
}

- (void)removeTempRootForJob:(DownloadJob *)job {
    // R2/P1：拿到所有权才删除；另一实例持锁时绝不删除（那会毁掉它正在写入的数据）。
    // 删除本身走 INV-3：取锁 → 原子改名到隔离区 → 释放锁 → 删除隔离目录，
    // 绝不“先解锁再删”（P1-A），也绝不就地 unlink（P1-B）。
    [self removeOwnedTempRootAtPath:job.tempRootURL.path allowClaim:YES jobIdentifier:job.identifier];

    // 分段回退（-fb）与链接刷新重启（-rf）会把 tempRootURL 切到变体目录；
    // 终态清理必须把该任务的全部临时根变体一起回收，否则回退前已完成的
    // 分片会作为孤儿遗留到下次启动。
    if (!job.identifier.length || !self.tempRoot) return;
    for (NSString *suffix in @[@"", @"-fb", @"-rf"]) {
        NSURL *variant = [self.tempRoot URLByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@%@", job.identifier, suffix]];
        if ([variant.path isEqual:job.tempRootURL.path]) continue;
        // 变体只清理本实例**已经拥有**的；绝不在变体路径上重新认领（认领会重建目录）。
        [self removeOwnedTempRootAtPath:variant.path allowClaim:NO jobIdentifier:job.identifier];
    }
}

// 统一的临时根删除入口。
//   allowClaim=YES：未持有时允许重新认领（主要用于 job.tempRootURL：目录可能已被启动清理删掉，
//                    也可能在 markInterruptedOnTerminate 释放锁后由本实例再次接管）。
//   allowClaim=NO ：只清理**已经拥有**的路径（-fb/-rf 变体），绝不重建目录。
- (void)removeOwnedTempRootAtPath:(NSString *)rawPath
                       allowClaim:(BOOL)allowClaim
                    jobIdentifier:(NSString *)identifier {
    NSString *path = [[NSURL fileURLWithPath:rawPath ?: @""] URLByStandardizingPath].path;
    if (!path.length) return;
    if (![self ownsTempDirectoryAtPath:path]) {
        // 目录已不存在 ⇒ 没有可删的东西；顺手清掉可能残留的陈旧登记（绝不重建目录）。
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [self releaseTempDirClaimForPath:path];
            return;
        }
        if (!allowClaim) return;   // 变体：未拥有就不碰，留给下一次启动的孤儿清理
        [self claimTempDirectoryAtURL:[NSURL fileURLWithPath:path] createIfMissing:NO];
        if (![self ownsTempDirectoryAtPath:path]) {
            RDDownloadLog(@"跳过临时目录清理 id=%@ 目录由另一实例持有", identifier ?: @"");
            return;
        }
    }
    [self quarantineAndRemoveOwnedTempDirectoryAtPath:path];
}

- (NSArray<DownloadJob *> *)allJobs {
    return self.jobs.allValues;
}

+ (NSArray<DownloadJob *> *)activeJobsForJobs:(NSArray<DownloadJob *> *)jobs {
    NSMutableArray<DownloadJob *> *active = [NSMutableArray array];
    for (DownloadJob *job in jobs) {
        switch (job.state) {
            case DownloadJobStateQueued:
            case DownloadJobStateRunning:
            case DownloadJobStatePaused:
            case DownloadJobStateCancelling:
                [active addObject:job];
                break;
            default:
                break;
        }
    }
    return active;
}

+ (double)overallProgressForJobs:(NSArray<DownloadJob *> *)jobs {
    if (jobs.count == 0) return 0;

    long double knownBytes = 0;
    NSUInteger knownCount = 0;
    for (DownloadJob *job in jobs) {
        if (job.expectedContentLength > 0) {
            knownBytes += job.expectedContentLength;
            knownCount += 1;
        }
    }
    long double estimatedUnknownBytes = knownCount > 0 ? knownBytes / knownCount : 1;
    long double weightedProgress = 0;
    long double totalWeight = 0;
    for (DownloadJob *job in jobs) {
        long double weight = job.expectedContentLength > 0 ? job.expectedContentLength : estimatedUnknownBytes;
        BOOL terminal = job.state == DownloadJobStateCompleted ||
                        job.state == DownloadJobStateFailed ||
                        job.state == DownloadJobStateCancelled ||
                        job.state == DownloadJobStateInterrupted;
        double fraction = terminal ? 1.0 : MAX(0, MIN(1, job.progress));
        weightedProgress += weight * fraction;
        totalWeight += weight;
    }
    return totalWeight > 0 ? (double)(weightedProgress / totalWeight) : 0;
}

+ (NSDictionary<NSString *, NSNumber *> *)aggregateMetricsForJobs:(NSArray<DownloadJob *> *)jobs {
    if (jobs.count == 0) {
        return @{
            @"expectedBytes": @0,
            @"transferredBytes": @0,
            @"remainingBytes": @0,
            @"bytesPerSecond": @0,
            @"estimatedRemainingSeconds": @0,
            @"hasKnownExpected": @NO,
            @"unknownExpectedCount": @0,
        };
    }

    int64_t knownBytes = 0;
    NSUInteger knownCount = 0;
    int64_t transferred = 0;
    double speed = 0;
    NSUInteger activeCount = 0;
    double recentCompletedSpeed = 0;
    NSDate *now = [NSDate date];
    for (DownloadJob *job in jobs) {
        if (job.expectedContentLength > 0) {
            knownBytes += job.expectedContentLength;
            knownCount += 1;
        }
        transferred += MAX((int64_t)0, job.transferredBytes);
        // 行摘要只在 Running 显示 /s，聚合速率与之保持一致；Cancelling 不再制造假活动速率。
        if (job.state == DownloadJobStateRunning) {
            activeCount += 1;
            speed += MAX(0.0, job.bytesPerSecond);
        } else if (job.state == DownloadJobStateCompleted && job.bytesPerSecond > 0 &&
                   job.lastRateSampleDate && [now timeIntervalSinceDate:job.lastRateSampleDate] <= 1.5) {
            // Only bridge the handoff to a newly-started task.  Never retain a
            // completed transfer's rate once there is no active transfer, nor
            // past this short grace period.
            recentCompletedSpeed += job.bytesPerSecond;
        }
    }
    if (speed <= 0 && activeCount > 0) speed = recentCompletedSpeed;

    // Keep the displayed total consistent with the weighted overall progress:
    // unknown-length jobs use the average known file size until their response
    // provides a real Content-Length.
    int64_t estimatedUnknownBytes = knownCount > 0 ? knownBytes / (int64_t)knownCount : 0;
    NSUInteger unknownCount = jobs.count - knownCount;
    int64_t expected = knownBytes + estimatedUnknownBytes * (int64_t)unknownCount;
    NSTimeInterval remaining = 0;
    if (expected > 0 && speed > 0) {
        int64_t outstanding = MAX((int64_t)0, expected - transferred);
        remaining = (double)outstanding / speed;
    }
    return @{
        @"expectedBytes": @(expected),
        @"transferredBytes": @(transferred),
        @"remainingBytes": @(MAX((int64_t)0, expected - transferred)),
        @"bytesPerSecond": @(speed),
        @"estimatedRemainingSeconds": @(remaining),
        @"hasKnownExpected": @(knownCount > 0),
        @"unknownExpectedCount": @(unknownCount),
    };
}

#pragma mark - 临时目录归属（跨实例安全，见 RDTempDirClaimGraceSeconds 注释）

// ============================ 统一归属协议 ============================
// 认领 / 恢复 / 孤儿判定 / 普通删除 / 变体删除 / 路径重建共用**同一套**规则。
//
// 不变量（协议的全部保证都落在这四条上）：
//   INV-1 唯一──任意时刻，最多一个实例持有某个 `.rd-owner.lock` **当前 inode**上的独占 flock。
//   INV-2 身份──实例「拥有路径 P」当且仅当它持有的 fd 满足：
//                 fstat(fd).st_ino == stat(P/.rd-owner.lock).st_ino
//                 且 st_dev 相同、且 fstat(fd).st_nlink ≥ 1。
//               **flock 成功本身不是所有权**：已被 unlink 的旧 inode 仍能加锁成功。
//   INV-3 删除──对 P 的删除必须在持有满足 INV-2 的 fd 期间，且**先把 P 原子改名到隔离目录**，
//              然后才释放锁、最后删除隔离目录。绝不「先解锁再删」，也绝不就地 unlink 删除。
//   INV-4 变更──认领 / 写入 / 恢复 / 变体清理同样以 INV-2 为前提。
//
// 为什么删除必须「先改名」（这是 P1-A 与 P1-B 的共同根因）：
//   就地删除目录时，`.rd-owner.lock` 会先被 unlink、目录本体后消失。在这段窗口里，
//   另一实例可以在**同一路径**上 O_CREAT 出新 inode 的锁文件并成功加锁（它锁的是新
//   inode），于是它「合法地」认领了一个我们正在销毁的旧目录，数据随后被我们删掉。
//   原子改名之后，原路径**立刻不存在**：并发认领者只能重建一个全新目录，与旧目录
//   再无任何共享 inode。改名与删除都在同一卷内完成（隔离区位于临时根目录下）。
//
// 关键并发时序（验收反例直接对应）：
//   S-A 普通清理 vs 并发认领（P1-A）
//     A: 取得 INV-2 锁 → rename(P→Q) → 释放 → 删 Q
//     B: 在 rename 之前/之后 claim(P) 都会失败或拿到全新目录；永不可能在旧目录上「成功认领」
//   S-B 陈旧 inode 认领（P1-B）
//     A: open(P/.rd-owner.lock)=I1，暂停（未 flock）
//     C: 持 I1 锁 → rename(P→Q) → 删除 Q → 释放
//     B: 重建 P → open=​I2 → flock → INV-2 成立 → 写数据
//     A: 恢复后 flock(I1) 成功，但 INV-2 复核失败（nlink=0 / 路径 inode=I2≠I1）
//        ⇒ 拒绝据此宣称所有权，重试后拿到 I2 并被 B 的锁挡下 ⇒ 绝不删除 B 的数据
//   S-C 孤儿接管
//     取锁（无锁文件则 O_CREAT 建立）→ INV-2 复核 → 改名隔离 → 释放 → 删除；拿不到锁即放弃
//
// 判据是内核锁 + inode 身份，不是 PID、不是目录年龄；进程崩溃/被杀时内核自动释放锁。

// INV-2 判定：fd 是否仍然“钉住”当前路径上的锁文件。fd < 0 或任一 stat 失败 ⇒ 不成立。
static BOOL RDTempDirLockPinsPath(int fd, NSString *lockPath) {
    if (fd < 0 || lockPath.length == 0) return NO;
    struct stat held = {0}, current = {0};
    if (fstat(fd, &held) != 0) return NO;
    if (held.st_nlink < 1) return NO;                       // 已被 unlink
    if ((held.st_mode & S_IFMT) != S_IFREG) return NO;      // 不是普通锁文件
    if (stat(lockPath.fileSystemRepresentation, &current) != 0) return NO;
    if ((current.st_mode & S_IFMT) != S_IFREG) return NO;
    return held.st_ino == current.st_ino && held.st_dev == current.st_dev;
}

// 尝试取得“钉住当前路径”的独占锁：成功返回 fd（调用方负责 close），失败返回 -1。
// 不修改本实例归属表。createDirectoryIfMissing=YES 时在重试前重建目录。
- (int)acquireTempDirLockPinningPath:(NSString *)path createDirectoryIfMissing:(BOOL)createDirectoryIfMissing {
    if (!path.length) return -1;
    NSString *lockPath = [path stringByAppendingPathComponent:RDTempDirClaimFileName];
    for (int attempt = 0; attempt < 4; attempt++) {
        int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
        if (fd < 0) return -1;
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }   // 他人持有 ⇒ 不可用
        if (RDTempDirLockPinsPath(fd, lockPath)) return fd;               // INV-2 成立
        // 锁是真的，却钉在一个已被 unlink / 已被替换的旧 inode 上 ⇒ 不构成所有权。
        close(fd);
        if (!createDirectoryIfMissing) return -1;
        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                 withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return -1;
}

// 认领的统一入口（INV-2 + INV-4）。返回 YES = 本实例确实拥有该路径。
- (BOOL)claimTempDirectoryAtURL:(NSURL *)directoryURL createIfMissing:(BOOL)createIfMissing {
    if (!directoryURL.path.length) return NO;
    NSString *path = [directoryURL URLByStandardizingPath].path;
    if (!path.length) return NO;

    // 已登记且身份仍成立 ⇒ 幂等成功。
    NSNumber *existing = self.tempDirClaimDescriptors[path];
    if (existing) {
        NSString *lockPath = [path stringByAppendingPathComponent:RDTempDirClaimFileName];
        if (RDTempDirLockPinsPath(existing.intValue, lockPath)) return YES;
        // 目录被外部删除 / 换名 ⇒ 旧 fd 已不代表当前路径，绝不能据此继续写入或删除。
        [self releaseTempDirClaimForPath:path];
    }

    if (createIfMissing) {
        [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                 withIntermediateDirectories:YES attributes:nil error:nil];
    }
    int fd = [self acquireTempDirLockPinningPath:path createDirectoryIfMissing:createIfMissing];
    if (fd < 0) {
        [self markTempDirectory:path foreign:YES];
        return NO;
    }
    [self.tempDirForeignPaths removeObject:path];
    self.tempDirClaimDescriptors[path] = @(fd);
    return YES;
}

// 认领。结果用 ownsTempDirectoryAtPath: 查询（YES = 本实例持有，可写入/删除）。
- (void)claimTempDirectoryForJob:(DownloadJob *)job {
    [self claimTempDirectoryAtURL:job.tempRootURL createIfMissing:YES];
}

- (void)markTempDirectory:(NSString *)rawPath foreign:(BOOL)foreign {
    NSString *path = [[NSURL fileURLWithPath:rawPath ?: @""] URLByStandardizingPath].path;
    if (!path.length) return;
    if (foreign) [self.tempDirForeignPaths addObject:path];
    else [self.tempDirForeignPaths removeObject:path];
}

// INV-2 查询：登记存在 **且** fd 仍然钉住当前路径上的锁文件。
// 「拿到某个 fd 的锁」绝不等同于「拥有当前路径指向的目录」。
- (BOOL)ownsTempDirectoryAtPath:(NSString *)rawPath {
    NSString *path = [[NSURL fileURLWithPath:rawPath ?: @""] URLByStandardizingPath].path;
    if (!path.length) return NO;
    NSNumber *holder = self.tempDirClaimDescriptors[path];
    if (!holder) return NO;
    NSString *lockPath = [path stringByAppendingPathComponent:RDTempDirClaimFileName];
    return RDTempDirLockPinsPath(holder.intValue, lockPath);
}

// 确保本实例持有该目录：已持有 → 直接返回；未持有 → 幂等地重新认领（例如
// markInterruptedOnTerminate 释放后用户又取消，或恢复路径）。拿不到（另一实例持有）
// 才返回 NO，此时绝不能写入/删除。
- (BOOL)ensureOwnershipForJob:(DownloadJob *)job {
    if ([self ownsTempDirectoryAtPath:job.tempRootURL.path]) return YES;
    [self claimTempDirectoryForJob:job];
    return [self ownsTempDirectoryAtPath:job.tempRootURL.path];
}

- (void)releaseTempDirClaimForPath:(NSString *)rawPath {
    NSString *path = [[NSURL fileURLWithPath:rawPath ?: @""] URLByStandardizingPath].path;
    NSNumber *holder = path.length ? self.tempDirClaimDescriptors[path] : nil;
    if (!holder) return;
    [self.tempDirClaimDescriptors removeObjectForKey:path];
    close((int)holder.intValue);   // 关闭 fd 即释放 flock
}

// 该目录是否被**别人**认领（含同进程内的另一个 DownloadManager）。
// 返回 YES = 活的，绝不可删。不带锁文件的目录返回 NO，由调用方按宽限期决定。
// 注意：本方法内部会短暂取锁再释放，因此结果**只可用于提前跳过**，
// 删除的安全性一律由 -quarantineAndRemoveOwnedTempDirectoryAtPath: 的
// “取锁 + INV-2 + 原子改名”决定，不得仅凭本方法的返回值删除任何目录。
- (BOOL)tempDirectoryIsClaimedByAnotherInstance:(NSURL *)directory {
    NSString *lockPath = [directory.path stringByAppendingPathComponent:RDTempDirClaimFileName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:lockPath]) return NO;
    int fd = open(lockPath.fileSystemRepresentation, O_RDWR, 0644);
    if (fd < 0) return YES;   // 打不开锁文件：保守视为活目录
    BOOL held = (flock(fd, LOCK_EX | LOCK_NB) != 0);
    if (!held) flock(fd, LOCK_UN);
    close(fd);                // 未持有锁时立刻释放，绝不顺带占住别人的目录
    return held;
}

// 目录最近修改时间是否仍在“创建/认领进行中”的宽限期内（无锁文件时的兜底）。
- (BOOL)tempDirectoryWithinClaimGrace:(NSURL *)directory {
    NSNumber *isDir = nil;
    NSDate *modified = nil;
    [directory getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    [directory getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
    if (!modified) return YES;   // 取不到时间：保守保留
    return -modified.timeIntervalSinceNow < RDTempDirClaimGraceSeconds();
}

// 隔离区里的一次性唯一目标路径（同卷内，rename 原子）。
- (NSString *)newQuarantinePath {
    NSString *trash = [[self.tempRoot URLByStandardizingPath].path
                       stringByAppendingPathComponent:RDTempDirQuarantineDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:trash
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return [trash stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
}

// 清空隔离区残留（改名成功但删除前崩溃/退出）。隔离区内容与路径命名空间已脱钩，
// 没有任何实例会把它们当作工作目录，重复删除也是安全的。
- (void)purgeQuarantineDirectoryAtPath:(NSString *)trashPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:trashPath]
                         includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *entry in entries) [fm removeItemAtURL:entry error:nil];
}

// INV-3：销毁一个**本实例拥有**的目录。
// 前置：self.tempDirClaimDescriptors[path] 存在且满足 INV-2。
// 步骤：rename(path → 隔离区) → release（统一出口，绝不泄漏 fd）→ 递归删除隔离目录。
// 无论成败都会释放所有权登记；返回 YES 仅表示目录确已从原路径移走。
- (BOOL)quarantineAndRemoveOwnedTempDirectoryAtPath:(NSString *)rawPath {
    NSString *path = [[NSURL fileURLWithPath:rawPath ?: @""] URLByStandardizingPath].path;
    if (!path.length) return NO;
    NSNumber *holder = self.tempDirClaimDescriptors[path];
    if (!holder) return NO;
    NSString *lockPath = [path stringByAppendingPathComponent:RDTempDirClaimFileName];
    BOOL pinned = RDTempDirLockPinsPath(holder.intValue, lockPath);

    BOOL renamed = NO;
    NSString *quarantinePath = pinned ? [self newQuarantinePath] : nil;
    if (quarantinePath && rename(path.fileSystemRepresentation, quarantinePath.fileSystemRepresentation) == 0) {
        renamed = YES;
    } else {
        // 改名失败（不存在 / 跨卷 / 异常）：**绝不**退化为“就地 unlink 删除”——
        // 那会重新暴露 INV-3 要封死的竞态。放弃本次删除，交由下一次启动的孤儿清理。
        RDDownloadLog(@"隔离改名失败 path=%@ errno=%d，已放弃本次删除", path, errno);
    }
    [self releaseTempDirClaimForPath:path];   // 统一出口：原路径已不可达或已放弃，绝不泄漏 fd
    if (renamed) {
        [[NSFileManager defaultManager] removeItemAtURL:[NSURL fileURLWithPath:quarantinePath] error:nil];
    }
    return renamed;
}

- (void)clearAllDownloadRecords {
    NSMutableArray *remove = [NSMutableArray array];
    for (NSString *identifier in self.jobs) {
        DownloadJob *job = self.jobs[identifier];
        if (job.state == DownloadJobStateCompleted || job.state == DownloadJobStateFailed ||
            job.state == DownloadJobStateCancelled || job.state == DownloadJobStateInterrupted) [remove addObject:identifier];
    }
    [self.jobs removeObjectsForKeys:remove];
    [self.store clearAllDownloadRecords];
    [self.delegate downloadManagerDidChange:self];
}

- (void)cleanupOrphanTempDirs {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *rootStd = [self.tempRoot URLByStandardizingPath];
    NSString *rootPath = rootStd.path;
    if (rootPath.length == 0) return;
    NSArray *contents = [fm contentsOfDirectoryAtURL:self.tempRoot
                          includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                             options:0 error:nil];
    NSSet *liveIDs = [NSSet setWithArray:self.jobs.allKeys];
    for (NSURL *url in contents) {
        // TOCTOU 加固：删除前逐项重新校验标准化路径、目录内归属、类型与文件状态，
        // 绝不删除临时根目录之外的任何路径（防符号链接/路径逃逸/竞态替换）。
        NSURL *std = [url URLByStandardizingPath];
        NSString *p = std.path;
        if (!p.length) continue;
        // 必须在临时根目录内且是直接子项（防路径逃逸）
        if (![p hasPrefix:rootPath] || p.length <= rootPath.length) continue;
        NSNumber *isDir = nil, *isLink = nil;
        [std getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        [std getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!isDir.boolValue || isLink.boolValue) continue;   // 仅清理普通目录
        if ([std.lastPathComponent isEqualToString:RDTempDirQuarantineDirName]) {
            [self purgeQuarantineDirectoryAtPath:p];          // 崩溃遗留的隔离区残留
            continue;
        }
        if ([liveIDs containsObject:std.lastPathComponent]) continue;
        if ([self ownsTempDirectoryAtPath:p]) continue;       // 本实例的活跃目录
        // 明确被其他实例持锁的目录：提前跳过（仅用于跳过；删除裁决不依赖本次检查）。
        if ([self tempDirectoryIsClaimedByAnotherInstance:std]) continue;
        // 宽限期只覆盖“目录已建、锁文件还没落地”的创建/认领窗口。
        // 已有锁文件的目录以 flock 为准（锁无人持 ⇒ 孤儿，无论目录多新都可回收）。
        NSString *lockPath = [p stringByAppendingPathComponent:RDTempDirClaimFileName];
        if (![fm fileExistsAtPath:lockPath] && [self tempDirectoryWithinClaimGrace:std]) continue;
        // 原子接管：取锁 → INV-2 → 改名隔离 → 释放 → 删除。拿不到锁即放弃。
        int handle = [self acquireTempDirLockPinningPath:p createDirectoryIfMissing:NO];
        if (handle < 0) continue;                             // 已被认领 / 不存在 / 打不开
        self.tempDirClaimDescriptors[p] = @(handle);          // 临时登记，复用统一销毁出口
        [self.tempDirForeignPaths removeObject:p];
        [self quarantineAndRemoveOwnedTempDirectoryAtPath:p]; // 内部释放登记
    }
}

- (void)dealloc {
    // R3：析构必须关闭所有权描述符（进程内反复创建/销毁 manager 不得泄漏 fd 与锁）。
    // 只关 fd，**不删除任何目录**——这些目录可能需要由其他实例或下一次启动恢复。
    for (NSNumber *descriptor in self.tempDirClaimDescriptors.allValues) {
        close((int)descriptor.intValue);
    }
    [self.tempDirClaimDescriptors removeAllObjects];
    [self.tempDirForeignPaths removeAllObjects];
}

- (void)notifyUpdate:(DownloadJob *)job {
    void (^notify)(void) = ^{
        if ([self.delegate respondsToSelector:@selector(downloadManager:didUpdateJob:)])
            [self.delegate downloadManager:self didUpdateJob:job];
    };
    if ([NSThread isMainThread]) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}

- (void)notifyChange {
    void (^notify)(void) = ^{
        if ([self.delegate respondsToSelector:@selector(downloadManagerDidChange:)])
            [self.delegate downloadManagerDidChange:self];
    };
    if ([NSThread isMainThread]) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}

@end
