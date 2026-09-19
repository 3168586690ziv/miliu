//
//  RealSiteProbe.m — 真实网址现场复现/验收工具（不进自动门禁，可手动运行）
//
//  与其它专项测试同款：直接编译生产源码（App main 改名），不做任何网络替身，
//  用真实 WebKit + 真实 HTTP 跑生产调用链，因此结果是"真实网址现场"证据。
//
//  用法：
//    RealSiteProbe app     <url>                 # 生产 App 全链：探测→左侧行→详情→画质→入队
//    RealSiteProbe static  <url>                 # 只跑静态 HTML 探针
//    RealSiteProbe dynamic <url>                 # 只跑动态 WebKit 探针
//    RealSiteProbe hybrid  <url>                 # 生产 RDHybridPageProbe（静态+动态合并）
//    RealSiteProbe download <url> <referer> <title> [expectHeight] [destDir]
//                                                # 真实下载 + 本地文件分辨率/可播放校验
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "WebProbe.h"
#import "StaticHTMLDiscoveryPageProbe.h"
#import "RDHybridPageProbe.h"
#import "URLPolicy.h"
#import "ResourceURLGate.h"
#import "DownloadCapabilityProbe.h"
#import <objc/runtime.h>

static NSMutableArray<NSString *> *gFailures;
static double gRSStart;

// 隔离夹具策略（仅测试）：只放行**解析到 127.0.0.1** 的目标，其余一律交回生产策略判定。
// 之所以按“解析结果”而不是按主机名放行：本地模型服务器需要一个像公网主机名的
// 名字（即让一个主机名通配解析到 127.0.0.1）才能同时通过探针与后端两处独立的 URLPolicy 实例，
// 并让 TLS 证书校验通过。生产默认不安装本策略——SSRF 防护在正式路径上原样生效。
@interface RDProbeLoopbackFixturePolicy : URLPolicy
@end
@implementation RDProbeLoopbackFixturePolicy
- (BOOL)rd_isLoopbackFixtureURL:(NSURL *)url {
    if ([url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"]) return YES;
    NSArray<NSString *> *ips = [DNSResolver resolveIPsForHost:url.host];
    return ips.count == 1 && [ips.firstObject isEqualToString:@"127.0.0.1"];
}
- (URLPolicyDecision *)evaluateTextURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow] : [super evaluateTextURL:urlString];
}
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips {
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow] : [super evaluateResolvedURL:url resolvedIPs:ips];
}
// 运行期默认走带 status 出参的变体，必须一并覆盖，否则夹具在该路径上不生效。
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips
                          resolutionStatus:(DNSResolutionStatus)status {
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow]
                                              : [super evaluateResolvedURL:url resolvedIPs:ips resolutionStatus:status];
}
- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current {
    return [self rd_isLoopbackFixtureURL:target] ? [URLPolicyDecision allow] : [super evaluateRedirect:target fromURL:current];
}
@end

// 把夹具策略同时装到 manager 与**后端**上。两者各自持有独立的 URLPolicy 实例
// （后端在 -init 里自建），manager 的 urlPolicy 不会传播到后端，因此只装 manager 时
// 分段请求仍会被后端按生产 SSRF 策略拒绝（实测报「本地回环地址不可探测」）。
// 本函数只在 RD_PROBE_ALLOW_LOOPBACK=1 时调用，只改测试进程内的对象，不碰生产代码。
static void RSInstallLoopbackFixtureOnBackend(DownloadManager *manager) {
    id backend = [manager valueForKey:@"backend"];    // 走 KVC：不依赖 ivar 的物理名字
    if (!backend) { printf("RS-WARN 后端尚未创建\n"); return; }
    Ivar policyIvar = class_getInstanceVariable([backend class], "urlPolicy");
    if (!policyIvar) policyIvar = class_getInstanceVariable([backend class], "_urlPolicy");
    if (!policyIvar) { printf("RS-WARN 后端未持有 urlPolicy ivar（%s）\n", class_getName([backend class])); return; }
    object_setIvar(backend, policyIvar, [RDProbeLoopbackFixturePolicy new]);
    printf("RS-NOTE 夹具策略已同时装入 manager 与后端（%s）\n", class_getName([backend class]));
}

// 直接给 SessionDownloadBackend 挂上“接受本地自签证书”的挑战处理。
// RealSiteProbe 是没有 bundle 的裸二进制，没有 Info.plist 可以声明 ATS 例外，
// 因此访问 https 本地模型服务器必须先过 TLS 校验这一关。
// 只对解析到 127.0.0.1 的目标放行；其余一律交回系统默认处理（真实站点不受影响）。
static void RSInstallLocalTrustOnBackend(DownloadManager *manager) {
    id backend = [manager valueForKey:@"backend"];
    if (!backend) { printf("RS-WARN 后端尚未创建（TLS 夹具未安装）\n"); return; }
    Class cls = [backend class];
    SEL sel = @selector(URLSession:didReceiveChallenge:completionHandler:);
    IMP imp = imp_implementationWithBlock(^void(id self_, NSURLSession *session,
                                                NSURLAuthenticationChallenge *challenge,
                                                void (^completion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)) {
        NSString *host = challenge.protectionSpace.host ?: @"";
        BOOL isLocal = [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"] ||
                       [host hasSuffix:@".nip.io"];
        if (isLocal && [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            completion(NSURLSessionAuthChallengeUseCredential,
                       [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
        } else {
            completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
    });
    class_addMethod(cls, sel, imp, "v@:@@@");
    printf("RS-NOTE 已为后端安装本地自签证书信任（仅本地目标；生产不生效）\n");

    // 能力探测用的是**另一个**会话与 delegate（ZZCapabilityDelegate），
    // 不装这一份就会在探测阶段报 -1202，任务被降级成单连接。
    Class probeCls = NSClassFromString(@"ZZCapabilityDelegate");
    if (probeCls) {
        class_addMethod(probeCls, sel, imp, "v@:@@@");
        printf("RS-NOTE 已为能力探测 delegate 安装本地自签证书信任\n");
    }
}

// 诊断：包住 DownloadCapabilityProbe 的 probeURL:referer:completion:，打印探测结果。
// 分段是否启用完全取决于这次探测；没有它就无法判断“为什么退化成单连接”。
// 能力探测自己也有一个独立的 URLPolicy 实例（DownloadCapabilityProbe 在 -init 里自建，
// manager.urlPolicy 同样不会传播过去）。不装这一份，探测会因本地回环被 SSRF 策略拒绝。
static void RSInstallLoopbackFixtureOnCapabilityProbe(DownloadManager *manager) {
    id probe = [manager valueForKey:@"capabilityProbe"];
    if (!probe) { printf("RS-WARN capabilityProbe 尚未创建\n"); return; }
    Class cls = [probe class];
    Class cur = cls;
    Ivar iv = NULL;
    while (cur && !iv) { iv = class_getInstanceVariable(cur, "urlPolicy") ?: class_getInstanceVariable(cur, "_urlPolicy"); cur = class_getSuperclass(cur); }
    if (!iv) { printf("RS-WARN capabilityProbe 未持有 urlPolicy ivar\n"); return; }
    object_setIvar(probe, iv, [RDProbeLoopbackFixturePolicy new]);
    printf("RS-NOTE 夹具策略已装入 capabilityProbe\n");
}

static void RSInstrumentCapabilityProbe(DownloadManager *manager) {
    id probe = [manager valueForKey:@"capabilityProbe"];
    if (!probe) { printf("RS-WARN capabilityProbe 尚未创建\n"); return; }
    Class cls = [probe class];
    SEL sel = NSSelectorFromString(@"probeURL:referer:completion:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { printf("RS-WARN 未找到 probeURL:referer:completion:\n"); return; }
    IMP orig = method_getImplementation(m);
    IMP replacement = imp_implementationWithBlock(^void(id self_, NSURL *url, NSString *referer,
                                                       void (^completion)(ZZDownloadCapability *)) {
        void (^wrapped)(ZZDownloadCapability *) = ^(ZZDownloadCapability *cap) {
            printf("RS-CAP status=%ld len=%lld range=%d body=%d firstByte=%.2f reason=%s\n",
                   (long)cap.statusCode, (long long)cap.contentLength, (int)cap.rangeSupported,
                   (int)cap.bodyResponsive, cap.firstByteLatency,
                   cap.failureReason.length ? cap.failureReason.UTF8String : "-");
            fflush(stdout);
            if (completion) completion(cap);
        };
        ((void (*)(id, SEL, NSURL *, NSString *, void (^)(ZZDownloadCapability *)))orig)(self_, sel, url, referer, wrapped);
    });
    method_setImplementation(m, replacement);
    printf("RS-NOTE 已为 capabilityProbe 安装结果诊断\n");
}

static void RSCheck(BOOL ok, NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!gFailures) gFailures = [NSMutableArray array];
    if (ok) { printf("RS-PASS %s\n", message.UTF8String); }
    else { printf("RS-FAIL %s\n", message.UTF8String); [gFailures addObject:message]; }
    fflush(stdout);
}
static void RSSummary(void) {
    if (gFailures.count) {
        printf("RS-RESULT FAIL 共 %lu 项未通过（首项：%s）\n", (unsigned long)gFailures.count, gFailures.firstObject.UTF8String);
        exit(1);
    }
    printf("RS-RESULT PASS 全部现场验收项通过\n");
}
static BOOL RSWait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}

// 有界异步等待（不阻塞 runloop）：在主线程泵 run loop 直到条件成立或超时。
// 安全读取链的 DNS 校验回调可能回到主线程，因此**不能**用信号量把主线程睡死，
// 否则会死锁；这里始终让 run loop 转起来。返回 NO = 期限内未满足。
static BOOL RSPumpUntil(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        if (done()) return YES;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return done();
}

// 有界等待（测试侧共享）：反复执行 onTick（可为 nil）直到 condition 成立或超时。
// 与 RSWait 的区别是允许在每次尝试之间推进一个动作（例如重新选行），用于替代
// “单次动作 + 固定 sleep”这种靠不住的做法。返回 NO 表示期限内未满足——调用方
// 必须把它当失败处理，不得 skip。
static BOOL RSWaitUntil(NSTimeInterval seconds, BOOL (^condition)(void), void (^onTick)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        if (condition()) return YES;
        if (onTick) onTick();
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return condition();
}
static double RSTicks(void) { return [NSDate date].timeIntervalSince1970; }

// 打印 URL 时隐藏签名参数值（只保留键名），避免把临时令牌写进日志/报告。
static NSString *RSRedactedURL(NSString *raw) {
    if (!raw.length) return @"";
    if (getenv("RD_NO_REDACT")) return raw;   // 本地诊断：完整 URL 只写本地日志
    NSURLComponents *c = [NSURLComponents componentsWithString:raw];
    if (!c) return raw;
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (NSURLQueryItem *q in c.queryItems ?: @[]) [items addObject:[NSString stringWithFormat:@"%@=***", q.name]];
    c.query = items.count ? [items componentsJoinedByString:@"&"] : nil;
    NSString *out = c.string ?: raw;
    return out.length > 160 ? [[out substringToIndex:160] stringByAppendingString:@"…"] : out;
}
static NSString *RSVariants(DetectedMedia *m) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *v in m.declaredVariants) {
        NSString *label = [v[@"label"] isKindOfClass:NSString.class] ? v[@"label"] : @"?";
        [parts addObject:label];
    }
    return parts.count ? [parts componentsJoinedByString:@","] : @"-";
}
static void RSDumpMedia(NSString *tag, NSArray<DetectedMedia *> *media) {
    printf("RS-%s media=%lu\n", tag.UTF8String, (unsigned long)media.count);
    NSUInteger i = 0;
    for (DetectedMedia *m in media) {
        printf("RS-%s [%lu] src=%s fam=%s variants=[%s] kind=%ld fmt=%s url=%s\n",
               tag.UTF8String, (unsigned long)i++,
               (m.discoverySource ?: @"?").UTF8String,
               (m.videoFamilyID.length ? @"yes" : @"no").UTF8String,
               RSVariants(m).UTF8String,
               (long)m.resourceKind,
               (m.format ?: @"?").UTF8String,
               RSRedactedURL(m.mediaURL).UTF8String);
    }
    fflush(stdout);
}

#pragma mark - 计数传输（真实网络；只统计请求次数，用于缓存命中证据）

@interface RSCountingTransport : NSObject <RDMetadataTransporting>
@property (nonatomic, strong) RDMetadataTransport *inner;
@property (nonatomic, strong) NSMutableArray<NSString *> *requests;
@end
@implementation RSCountingTransport
- (instancetype)init {
    if ((self = [super init])) { _inner = [RDMetadataTransport new]; _requests = [NSMutableArray array]; }
    return self;
}
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout
                  completion:(void (^)(RDMetadataResponse *))completion {
    double t0 = RSTicks();
    NSString *range = [request valueForHTTPHeaderField:@"Range"] ?: @"-";
    NSString *method = request.HTTPMethod ?: @"?";
    NSString *url = RSRedactedURL(request.URL.absoluteString);
    [self.requests addObject:[NSString stringWithFormat:@"%@ %@ range=%@", method, url, range]];
    printf("RS-NET-START +%.3fs %s %s range=%s\n", t0 - gRSStart, method.UTF8String, url.UTF8String, range.UTF8String);
    fflush(stdout);
    return [self.inner request:request budget:budget timeout:timeout completion:^(RDMetadataResponse *r) {
        printf("RS-NET-END   +%.3fs (%.3fs) %s %s range=%s -> status=%ld bytes=%lu err=%s\n",
               RSTicks() - gRSStart, RSTicks() - t0,
               method.UTF8String, url.UTF8String, range.UTF8String,
               (long)r.response.statusCode, (unsigned long)r.data.length,
               (r.error.localizedDescription ?: @"-").UTF8String);
        fflush(stdout);
        if (completion) completion(r);
    }];
}
@end

#pragma mark - 入队记录（不真正下载，仅记录 App 实际选择的下载对象）

@interface RSEnqueueSpy : DownloadManager
// 记录属性名必须与父类内部存储区分开：DownloadManager 在 .m 的类扩展里私有持有
// `jobs`（NSMutableDictionary），其 `-allJobs` 实现为 `self.jobs.allValues`。
// 若本替身也声明名为 `jobs` 的属性，子类自动合成的 `-jobs` getter 会**遮蔽**父类 getter，
// 使继承来的 `-allJobs` 对一个 NSMutableArray 调 `allValues` → NSInvalidArgumentException
// 崩溃（真实发生：某多档 HLS 站点，picker 2 档时进入入队分支）。
// 因此这里用独立属性 `recordedJobs` 记录替身入队对象，父类的存储契约保持原样。
@property (nonatomic, strong) NSMutableArray<DownloadJob *> *recordedJobs;
@end
@implementation RSEnqueueSpy
- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url folder:(NSURL *)folder preferredName:(NSString *)name
                            sourcePageURL:(NSString *)sourcePageURL resourceKind:(DownloadResourceKind)kind
                           expectedLength:(int64_t)length {
    DownloadJob *job = [DownloadJob new];
    job.sourceURL = url; job.fileName = name; job.resourceKind = kind; job.sourcePageURL = sourcePageURL;
    if (!self.recordedJobs) self.recordedJobs = [NSMutableArray array];
    [self.recordedJobs addObject:job];
    return job;
}
@end

#pragma mark - 本地文件真实分辨率/可播放校验（AVFoundation，不依赖外部工具）

static void RSInspectLocalFile(NSString *path, NSString **outSummary) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSArray<NSString *> *keys = @[@"playable", @"tracks", @"duration"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));

    BOOL playable = NO;
    NSError *e = nil;
    if ([asset statusOfValueForKey:@"playable" error:&e] == AVKeyValueStatusLoaded) playable = asset.playable;
    NSMutableString *video = [NSMutableString string];
    if ([asset statusOfValueForKey:@"tracks" error:&e] == AVKeyValueStatusLoaded) {
        for (AVAssetTrack *track in asset.tracks) {
            if (![track.mediaType isEqualToString:AVMediaTypeVideo]) continue;
            CGSize s = track.naturalSize;
            [video appendFormat:@"video=%dx%d", (int)lround(s.width), (int)lround(s.height)];
        }
        for (AVAssetTrack *track in asset.tracks) {
            if ([track.mediaType isEqualToString:AVMediaTypeAudio]) { [video appendString:video.length ? @" audio=yes" : @"audio=yes"]; break; }
        }
    }
    double duration = 0;
    if ([asset statusOfValueForKey:@"duration" error:&e] == AVKeyValueStatusLoaded) duration = CMTimeGetSeconds(asset.duration);
    *outSummary = [NSString stringWithFormat:@"playable=%@ %@ duration=%.1fs", playable ? @"yes" : @"no", video.length ? video : @"no-video-track", duration];
}

#pragma mark - 只跑探测链（static / dynamic / hybrid）

// 生产 WebView loader（WebProbe.h 已声明）直接抓取真实 DOM HTML。
static int RSRunDOMDump(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    RDWebViewProbeLoader *loader = [RDWebViewProbeLoader new];
    __block NSString *html = nil;
    double domStart = RSTicks();
    [loader loadPageAtURL:url policy:[URLPolicy new] maxHTMLBytes:8 * 1024 * 1024
               completion:^(NSString *h, AppError *e) {
        printf("RS-TIMING dom elapsed=%.3fs\n", RSTicks() - domStart);
        html = h; printf("RS-DOM error=%s\n", (e.message ?: @"-").UTF8String); }];
    RSWait(^BOOL { return html != nil; }, 90);
    if (!html) { printf("RS-RESULT FAIL dom 抓取超时\n"); return 1; }
    NSString *path = [NSString stringWithFormat:@"/tmp/rd_dom_%lu.html", (unsigned long)urlString.hash];
    [html writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("RS-DOM bytes=%lu file=%s\n", (unsigned long)[html lengthOfBytesUsingEncoding:NSUTF8StringEncoding], path.UTF8String);
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:url];
    RSDumpMedia(@"DOM", r.media);
    return 0;
}

static int RSRunProbeChain(NSString *mode, NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) { printf("RS-RESULT FAIL 网址无效\n"); return 2; }
    // 三条页面探针各自持有独立的 URLPolicy 实例，生产默认拒绝回环地址（SSRF 防护）。
    // 仅在 RD_PROBE_ALLOW_LOOPBACK=1 的手动夹具运行下把回环夹具策略装进页面探针，
    // 使本地边界用例实验室（outputs/probe-test-kit/lab）可被探测；不带该环境变量
    // 时行为与生产完全一致。
    URLPolicy *probePolicy = [[[NSProcessInfo processInfo] environment][@"RD_PROBE_ALLOW_LOOPBACK"] isEqualToString:@"1"]
        ? (URLPolicy *)[RDProbeLoopbackFixturePolicy new] : [URLPolicy new];
    __block NSArray<DetectedMedia *> *result = nil;
    double t0 = RSTicks();
    if ([mode isEqualToString:@"static"]) {
        StaticHTMLDiscoveryPageProbe *probe = [[StaticHTMLDiscoveryPageProbe alloc] initWithPolicy:probePolicy];
        [probe probePageURL:url completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
            printf("RS-STATIC error=%s\n", (error.localizedDescription ?: @"-").UTF8String);
            result = media ?: @[];
        }];
    } else if ([mode isEqualToString:@"dynamic"]) {
        WebProbe *probe = [[WebProbe alloc] initWithPolicy:probePolicy];
        [probe probeURL:urlString completion:^(RDProbeResult *r, AppError *error, NSUInteger gen) {
            printf("RS-DYNAMIC error=%s gen=%lu\n", (error.message ?: @"-").UTF8String, (unsigned long)gen);
            result = r.media ?: @[];
        }];
    } else {
        RDHybridPageProbe *probe = [[RDHybridPageProbe alloc] initWithPolicy:probePolicy];
        [probe probePageURL:url completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
            printf("RS-HYBRID error=%s\n", (error.localizedDescription ?: @"-").UTF8String);
            result = media ?: @[];
        }];
    }
    RSWait(^BOOL { return result != nil; }, 90);
    printf("RS-TIMING %s elapsed=%.3fs\n", mode.UTF8String, RSTicks() - t0);
    if (!result) { printf("RS-RESULT FAIL %s 超时无结果\n", mode.UTF8String); return 1; }
    RSDumpMedia(mode.uppercaseString, result);
    return 0;
}

#pragma mark - 画质档位独立 oracle（只读源主清单；不复用产品档位归一化）

// 标准档位口径：480p / 720p / 1080p。这里按**源清单声明的分辨率**独立归档，
// 与产品的 RDQualityTier 分开实现——目的是当"独立第二意见"，不是复制其算法。
static NSArray<NSNumber *> *RSTiers(void) { return @[@480, @720, @1080]; }

// 短边 → 标准档位；相对偏差 ≤ 10% 才归档，否则返回 0（无法归档，绝不从文件名猜）。
// 与产品文档口径一致（854x480/1280x720/1920x1080 命中；960x540/480x270 不命中）。
static NSInteger RSTierForShortSide(double shortSide) {
    if (!(shortSide > 0) || shortSide > 100000) return 0;
    for (NSNumber *t in RSTiers()) {
        double target = t.doubleValue;
        if (fabs(shortSide - target) <= target * 0.10) return t.integerValue;
    }
    return 0;
}

// 独立解析 HLS 主清单：把 `#EXT-X-STREAM-INF:...RESOLUTION=WxH...` 与其后紧随的 URI 行
// 配成一个变体，并按 RESOLUTION 短边归档。**没有 RESOLUTION 声明的变体（含自动档）
// 一律不参与档位判定**，既不归档也不猜测——文件名不构成档位证据。
static NSArray<NSDictionary *> *RSParseMasterVariants(NSString *playlist, NSURL *baseURL) {
    if (playlist.length == 0) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    __block double pendingW = 0, pendingH = 0;
    __block BOOL pendingResolution = NO;
    [playlist enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([t hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            pendingW = 0; pendingH = 0; pendingResolution = NO;
            NSRange r = [t rangeOfString:@"RESOLUTION="];
            if (r.location != NSNotFound) {
                NSString *rest = [t substringFromIndex:NSMaxRange(r)];
                NSRange comma = [rest rangeOfString:@","];
                NSString *res = comma.location == NSNotFound ? rest : [rest substringToIndex:comma.location];
                NSArray<NSString *> *wh = [res componentsSeparatedByCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"xX×"]];
                if (wh.count == 2) {
                    pendingW = [wh[0] doubleValue];
                    pendingH = [wh[1] doubleValue];
                    pendingResolution = (pendingW > 0 && pendingH > 0);
                }
            }
            return;
        }
        if (t.length == 0 || [t hasPrefix:@"#"]) return;
        if (!pendingResolution) return;
        NSURL *u = [NSURL URLWithString:t relativeToURL:baseURL];
        [out addObject:@{ @"url": u.absoluteString ?: t,
                          @"width": @(pendingW), @"height": @(pendingH),
                          @"tier": @(RSTierForShortSide(MIN(pendingW, pendingH))) }];
        pendingResolution = NO;
    }];
    return out;
}

// URL 等价：复用产品的资源身份规范化（URL 规范化工具，非被测的画质算法）。
static BOOL RSSameURL(NSString *a, NSString *b) {
    if (a.length == 0 || b.length == 0) return NO;
    return [[DetectedMedia dedupKeyForURL:a] isEqual:[DetectedMedia dedupKeyForURL:b]];
}

// 独立 oracle 给出的「属于该标准档位」的全部候选 URL（同档可能确有多个候选，
// 例如同一分辨率的 live 与非 live 变体；这里**不**复刻产品的择优规则）。
static NSArray<NSString *> *RSTierCandidateURLs(NSArray<NSDictionary *> *variants, NSInteger tier) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSDictionary *v in variants) {
        if ([v[@"tier"] integerValue] != tier) continue;
        NSString *u = v[@"url"];
        if (u.length && ![out containsObject:u]) [out addObject:u];
    }
    return out;
}

// 独立 oracle 取源（安全版，2026-09-18 修复 B1）：**不复用裸 NSURLSession**，改为复用生产
// 安全链 URLPolicy + ResourceURLGate，并自建受控会话：
//   · 初始 URL 与**每一跳重定向**都过 URLPolicy：scheme 白名单、缺省凭据 URL 拒绝、
//     内网/环回/链路本地/保留地址拒绝、HTTPS→HTTP 降级拒绝（URLPolicy 内建），
//     跳转目标再经 ResourceURLGate 做 DNS 后逐 IP 校验（fail-closed）；
//   · 响应体**流式**字节上限：didReceiveData 累计超限即刻 cancel，绝不先载入再检查；
//   · 仅接受主清单：MIME 允许集（HLS/DASH 清单）或正文以 #EXTM3U 开头；其余一律拒绝，
//     **不会**把任意媒体 URL 整文件读进内存；
//   · 不读 Cookie / 凭据（HTTPCookieStorage=nil、URLCredentialStorage=nil、HTTPShouldSetCookies=NO）；
//   · protocolClasses 可注入，供离线 NSURLProtocol 受控反例使用。
typedef NS_ENUM(NSInteger, RSManifestFetchStatus) {
    RSManifestFetchOK = 0,
    RSManifestFetchBadURL = 1,          // 非 http/https 或空主机
    RSManifestFetchBlockedByPolicy = 2, // 文本/内网/降级/非法跳转被策略拒绝
    RSManifestFetchBlockedByDNS = 3,    // 解析后逐 IP 校验拒绝
    RSManifestFetchTimeout = 4,
    RSManifestFetchTransport = 5,       // 传输错误 / 非 2xx
    RSManifestFetchTooLarge = 6,        // 流式超限（未读完整文件）
    RSManifestFetchNotManifest = 7,     // MIME 非清单且非 #EXTM3U
};

static NSString *RSManifestFetchStatusText(RSManifestFetchStatus s) {
    switch (s) {
        case RSManifestFetchOK: return @"OK";
        case RSManifestFetchBadURL: return @"BAD_URL";
        case RSManifestFetchBlockedByPolicy: return @"BLOCKED_BY_POLICY";
        case RSManifestFetchBlockedByDNS: return @"BLOCKED_BY_DNS";
        case RSManifestFetchTimeout: return @"TIMEOUT";
        case RSManifestFetchTransport: return @"TRANSPORT_ERROR";
        case RSManifestFetchTooLarge: return @"TOO_LARGE";
        case RSManifestFetchNotManifest: return @"NOT_MANIFEST";
    }
    return @"UNKNOWN";
}

static BOOL RSIsSupportedManifestMIME(NSString *contentType) {
    NSString *m = contentType.lowercaseString ?: @"";
    NSRange semi = [m rangeOfString:@";"];
    if (semi.location != NSNotFound) m = [m substringToIndex:semi.location];
    m = [m stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    static NSSet<NSString *> *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSSet setWithArray:@[@"application/vnd.apple.mpegurl", @"application/x-mpegurl",
                                        @"application/mpegurl", @"audio/mpegurl", @"audio/x-mpegurl",
                                        @"application/dash+xml", @"application/vnd.mpeg.dash.mpd"]];
    });
    return [allowed containsObject:m];
}

typedef void (^RSManifestFetchCompletion)(RSManifestFetchStatus status, NSString * _Nullable text, NSString * _Nullable detail);

// 受控取源会话：逐跳策略校验 + 流式上限 + 清单 MIME 闸门。
@interface RSManifestFetcher : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) URLPolicy *policy;
@property (nonatomic, strong) ResourceURLGate *gate;
@property (nonatomic, assign) NSUInteger maxBytes;    // 默认 2 MiB（主清单远小于此，媒体文件立即触顶）
@property (nonatomic, assign) NSTimeInterval timeout; // 默认 20s
@property (nonatomic, copy, nullable) NSArray<Class> *protocolClasses; // 仅离线测试注入
@property (nonatomic, assign) NSUInteger redirectCount;
@property (nonatomic, assign) NSUInteger policyChecks;   // 文本/策略校验次数（含每一跳）
@property (nonatomic, assign) NSUInteger dnsChecks;      // DNS 后 IP 校验次数
- (RSManifestFetchStatus)fetchSynchronously:(NSURL *)url text:(NSString **)outText detail:(NSString **)outDetail;
@end

@implementation RSManifestFetcher {
    NSMutableData *_body;
    NSString *_contentType;
    RSManifestFetchStatus _status;
    NSString *_detail;
    volatile BOOL _finished;   // 由 URLSession 后台 delegate 队列写、主线程读
    volatile BOOL _tooLarge;
    volatile BOOL _notManifest;
    volatile BOOL _redirectBlocked;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _policy = [URLPolicy new];
        _gate = [ResourceURLGate new];
        _gate.policy = _policy;   // 与文本策略同一实例，避免两套口径
        _maxBytes = 2 * 1024 * 1024;
        _timeout = 20;
        _status = RSManifestFetchOK;
    }
    return self;
}

- (void)finishWithStatus:(RSManifestFetchStatus)status detail:(NSString *)detail {
    if (_finished) return;
    _status = status;
    _detail = detail;
    _finished = YES;   // 等待方在主线程泵 run loop 观察本标记，不使用信号量阻塞
}

// 初始 URL 与每一跳共用：文本策略 + DNS 后逐 IP 校验（异步完成后再放行该跳）。
- (void)verifyURL:(NSURL *)url fromURL:(NSURL *)from completion:(void (^)(BOOL allowed, NSString *detail))completion {
    self.policyChecks++;
    URLPolicyDecision *text = from ? [self.policy evaluateRedirect:url fromURL:from]
                                   : [self.policy evaluateTextURL:url.absoluteString ?: @""];
    if (!text.allowed) {
        completion(NO, [NSString stringWithFormat:@"策略拒绝(%ld)", (long)text.verdict]);
        return;
    }
    NSURL *copy = [url copy];
    [self.gate verifyURLAsync:copy completion:^(URLPolicyDecision * _Nullable d) {
        self.dnsChecks++;
        if (d == nil || !d.allowed) {
            completion(NO, [NSString stringWithFormat:@"DNS 后校验拒绝(%ld)", (long)(d ? d.verdict : -1)]);
            return;
        }
        completion(YES, @"");
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
        completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    self.redirectCount++;
    if (self.redirectCount > 5) {
        _redirectBlocked = YES;
        completionHandler(nil);
        return;
    }
    NSURL *target = request.URL;
    NSURL *from = response.URL ?: task.currentRequest.URL;
    [self verifyURL:target fromURL:from completion:^(BOOL allowed, NSString *detail) {
        if (!allowed) {
            self->_redirectBlocked = YES;
            self->_detail = [NSString stringWithFormat:@"重定向被拒绝:%@", detail];
            completionHandler(nil);
            return;
        }
        completionHandler(request);
    }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
                                 didReceiveResponse:(NSURLResponse *)response
                                 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger code = ((NSHTTPURLResponse *)response).statusCode;
        _contentType = ((NSHTTPURLResponse *)response).MIMEType;
        if (code < 200 || code >= 300) {
            _detail = [NSString stringWithFormat:@"HTTP %ld", (long)code];
            completionHandler(NSURLSessionResponseCancel);
            [self finishWithStatus:RSManifestFetchTransport detail:_detail];
            return;
        }
    }
    // 提前按 MIME 判定：非清单类型直接取消，避免把媒体正文继续拉取。
    if (_contentType.length && !RSIsSupportedManifestMIME(_contentType)) {
        _notManifest = YES;
        completionHandler(NSURLSessionResponseCancel);
        [self finishWithStatus:RSManifestFetchNotManifest
                        detail:[NSString stringWithFormat:@"MIME=%@", _contentType]];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [_body appendData:data];
    if (_body.length > self.maxBytes) {   // 流式超限：立即取消，绝不先读完整
        _tooLarge = YES;
        [dataTask cancel];
        [self finishWithStatus:RSManifestFetchTooLarge
                        detail:[NSString stringWithFormat:@"已接收>%luB", (unsigned long)self.maxBytes]];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_finished) return;
    // 先判重定向被策略拒绝：取消跳转会以 NSURLErrorCancelled 结束，不能被当成普通传输错误。
    if (_redirectBlocked) {
        [self finishWithStatus:RSManifestFetchBlockedByPolicy detail:_detail ?: @"redirect"];
        return;
    }
    if (error) {
        BOOL timedOut = (error.code == NSURLErrorTimedOut);
        [self finishWithStatus:(timedOut ? RSManifestFetchTimeout : RSManifestFetchTransport)
                        detail:error.localizedDescription ?: @"transport"];
        return;
    }
    NSString *text = [[NSString alloc] initWithData:_body encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        [self finishWithStatus:RSManifestFetchNotManifest detail:@"空正文"];
        return;
    }
    // 双闸：MIME 缺失/宽松时必须靠魔数证明这是清单；仍不接受任意媒体正文。
    if (!RSIsSupportedManifestMIME(_contentType)) {
        NSString *head = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![head hasPrefix:@"#EXTM3U"]) {
            [self finishWithStatus:RSManifestFetchNotManifest
                            detail:[NSString stringWithFormat:@"MIME=%@ 且正文非 #EXTM3U", _contentType ?: @"(无)"]];
            return;
        }
    }
    [self finishWithStatus:RSManifestFetchOK detail:text];   // 正文经 detail 传出（outText）
}

- (RSManifestFetchStatus)fetchSynchronously:(NSURL *)url text:(NSString **)outText detail:(NSString **)outDetail {
    _body = [NSMutableData data];
    _finished = NO; _tooLarge = NO; _notManifest = NO; _redirectBlocked = NO;
    self.redirectCount = 0; self.policyChecks = 0; self.dnsChecks = 0;
    if (outText) *outText = nil;
    if (outDetail) *outDetail = nil;
    if (![url isKindOfClass:NSURL.class] || url.host.length == 0) {
        return RSManifestFetchBadURL;
    }
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return RSManifestFetchBadURL;
    }
    // 初始 URL 必须先过策略（同步文本）+ DNS 后逐 IP 校验（异步等齐）。
    __block BOOL verifyDone = NO;
    __block BOOL initialAllowed = NO;
    __block NSString *initialDetail = nil;
    [self verifyURL:url fromURL:nil completion:^(BOOL allowed, NSString *detail) {
        initialAllowed = allowed; initialDetail = detail; verifyDone = YES;
    }];
    RSPumpUntil(self.timeout + 5, ^{ return verifyDone; });   // 泵 run loop，不阻塞主线程
    if (!verifyDone || !initialAllowed) {
        if (outDetail) *outDetail = initialDetail ?: @"DNS 校验未在期限内完成";
        return verifyDone ? RSManifestFetchBlockedByPolicy : RSManifestFetchBlockedByDNS;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.HTTPCookieStorage = nil;
    cfg.URLCredentialStorage = nil;
    cfg.HTTPShouldSetCookies = NO;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.timeoutIntervalForRequest = self.timeout;
    if (self.protocolClasses.count) cfg.protocolClasses = self.protocolClasses;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = self.timeout;
    [[session dataTaskWithRequest:req] resume];
    RSPumpUntil(self.timeout + 5, ^{ return self->_finished; });   // 泵 run loop，不阻塞主线程
    if (!_finished) {
        [self finishWithStatus:RSManifestFetchTimeout detail:@"等待超时"];
    }
    [session invalidateAndCancel];
    if (outText && _status == RSManifestFetchOK) *outText = _detail;
    if (outDetail) *outDetail = (_status == RSManifestFetchOK) ? nil : (_detail ?: @"");
    return _status;
}
@end



// 画质档位映射判定（app 模式与离线自检共用**同一实现**，避免两套口径）。
//   expectedURLs : 独立解析源主清单得到的、属于该档位的候选 URL 集合（空 = 清单未声明该档位）
//   pickerURL    : UI 下拉「720p」项实际代表的 URL
//   detailLink   : 详情直链
//   jobURL       : 实际入队 URL
// 判定要求四者一致：UI 声称的档位候选、详情直链、入队对象都必须落在清单该档位候选集合内，
// 且入队对象就是 UI 所选那一个（不允许同档内错位到另一个候选）。
typedef NS_ENUM(NSInteger, RSQualityVerdict) {
    RSQualityVerdictPass = 0,
    RSQualityVerdictFail = 1,
    RSQualityVerdictUnsupported = 2,   // 源清单未声明该档位（或仅自动档）→ 该语义未覆盖
};
static RSQualityVerdict RSQualityTierMappingVerdict(NSArray<NSString *> *expectedURLs,
                                                    NSString *pickerURL, NSString *detailLink, NSString *jobURL,
                                                    NSString **outReason) {
    if (expectedURLs.count == 0) {
        if (outReason) *outReason = @"源主清单未声明该标准档位（或仅自动档，无 RESOLUTION 声明）";
        return RSQualityVerdictUnsupported;
    }
    BOOL pickerOK = NO, linkOK = NO, jobOK = NO;
    for (NSString *u in expectedURLs) {
        if (RSSameURL(u, pickerURL)) pickerOK = YES;
        if (RSSameURL(u, detailLink)) linkOK = YES;
        if (RSSameURL(u, jobURL)) jobOK = YES;
    }
    if (!pickerOK) {
        if (outReason) *outReason = [NSString stringWithFormat:@"UI 所选档位代表的 URL 不在清单该档位候选内（%@）", pickerURL ?: @"-"];
        return RSQualityVerdictFail;
    }
    if (!linkOK) {
        if (outReason) *outReason = [NSString stringWithFormat:@"详情直链不在清单该档位候选内（%@）", detailLink ?: @"-"];
        return RSQualityVerdictFail;
    }
    if (!jobOK) {
        if (outReason) *outReason = [NSString stringWithFormat:@"入队 URL 不在清单该档位候选内（%@）", jobURL ?: @"-"];
        return RSQualityVerdictFail;
    }
    if (!(RSSameURL(jobURL, pickerURL) && RSSameURL(jobURL, detailLink))) {
        if (outReason) *outReason = @"入队 URL 与 UI 所选档位/详情直链不是同一个候选（同档内映射错位）";
        return RSQualityVerdictFail;
    }
    if (outReason) *outReason = @"";
    return RSQualityVerdictPass;
}

// 调用方级判定（app/variantcheck 与离线自检共用同一实现）：目标档位**必须**被核实。
// 取源失败、清单未声明该档位、映射错位一律 FAIL；只有映射一致才 PASS。
typedef NS_ENUM(NSInteger, RSQualityCheckOutcome) {
    RSQualityCheckOutcomePass = 0,
    RSQualityCheckOutcomeFail = 1,
};
static RSQualityCheckOutcome RSQualityRequiredTierOutcome(RSManifestFetchStatus fetch,
                                                          RSQualityVerdict verdict,
                                                          NSString **outReason) {
    if (fetch != RSManifestFetchOK) {
        if (outReason) *outReason = [NSString stringWithFormat:@"无法独立取得源主清单（%@）", RSManifestFetchStatusText(fetch)];
        return RSQualityCheckOutcomeFail;
    }
    if (verdict == RSQualityVerdictUnsupported) {
        if (outReason) *outReason = @"源清单未声明该标准档位（或仅自动档）——UI 存在该档位，无法核实即失败";
        return RSQualityCheckOutcomeFail;
    }
    if (verdict == RSQualityVerdictFail) {
        if (outReason) *outReason = @"映射与源清单声明不一致";
        return RSQualityCheckOutcomeFail;
    }
    if (outReason) *outReason = @"";
    return RSQualityCheckOutcomePass;
}

#pragma mark - 选行 / 档位就绪的覆盖判定（app 与离线自检共用同一实现）

// app 模式旧实现用固定 40×0.15s 重试选行，HLS 动态腿约 8s 时重试耗尽 → selectedRow=-1 →
// 多档整段不进入却仍 RS-RESULT PASS（2026-09-18 独立验收复现 1/2）。现改为与 vc 相同的
// 有界等待，并把「是否必须执行多档断言」显式判定：
//   · 选行未生效            → NotReady（失败）
//   · 模型声明 ≥2 档位但下拉未就绪 → NotReady（失败）
//   · 就绪                  → Ready（执行多档/oracle/入队断言）
//   · 真实单档/无档位        → NotApplicable（明确不适用，不产生绿灯式覆盖）
typedef NS_ENUM(NSInteger, RSSelectionCoverageState) {
    RSSelectionCoverageNotApplicable = 0,
    RSSelectionCoverageReady = 1,
    RSSelectionCoverageNotReady = 2,
};

static RSSelectionCoverageState RSSelectionCoverageDecision(BOOL selectionSucceeded,
                                                            NSInteger declaredVariantCount,
                                                            BOOL pickerReady,
                                                            NSInteger pickerItems,
                                                            BOOL pickerVisible,
                                                            NSString **outReason) {
    if (!selectionSucceeded) {
        if (outReason) *outReason = @"选行在有界等待期限内未生效（selectedRow 未到达目标行）";
        return RSSelectionCoverageNotReady;
    }
    if (pickerReady || (pickerVisible && pickerItems >= 2)) {
        if (outReason) *outReason = @"多档就绪";
        return RSSelectionCoverageReady;
    }
    if (declaredVariantCount >= 2) {
        if (outReason) *outReason = [NSString stringWithFormat:
            @"模型声明 %ld 个档位但画质下拉未就绪（items=%ld hidden=%d）：多档断言无法执行",
            (long)declaredVariantCount, (long)pickerItems, pickerVisible ? 0 : 1];
        return RSSelectionCoverageNotReady;
    }
    if (outReason) *outReason = [NSString stringWithFormat:
        @"真实单档/无档位（declaredVariants=%ld，picker items=%ld）：多档一致性断言不适用",
        (long)declaredVariantCount, (long)pickerItems];
    return RSSelectionCoverageNotApplicable;
}

// 只有「选行失败 / 预期多档却未就绪」算失败；不适用不算失败。
static BOOL RSSelectionCoverageIsFailure(RSSelectionCoverageState state) {
    return state == RSSelectionCoverageNotReady;
}

// 从**当前**菜单里解析档位索引：生产在 selectDeclaredVariant / 快照合并时会 removeAllItems
// 重建菜单，任何缓存下来的 count/索引都会越界（2026-09-18 站 11 NSMenu itemAtIndex: 崩溃）。
// 因此每次都用「标题优先、其次计划 URL 身份」重新解析live菜单；解析不到返回 NSNotFound，
// 由调用方判 FAIL，绝不越界、不静默跳过。
static NSInteger RSMenuIndexForTier(NSPopUpButton *picker, NSString *title, NSString *plannedURL,
                                    NSString **outTitle, NSString **outURL) {
    NSInteger n = (NSInteger)picker.numberOfItems;
    NSInteger titleOnly = NSNotFound;
    for (NSInteger i = 0; i < n; i++) {
        NSMenuItem *item = [picker itemAtIndex:i];
        NSString *t = item.title ?: @"";
        NSDictionary *rep = [item.representedObject isKindOfClass:NSDictionary.class] ? item.representedObject : nil;
        NSString *u = [rep[@"url"] isKindOfClass:NSString.class] ? rep[@"url"] : @"";
        if (title.length && ![t isEqualToString:title]) continue;
        if (plannedURL.length && u.length && RSSameURL(u, plannedURL)) {
            if (outTitle) *outTitle = t;
            if (outURL) *outURL = u;
            return i;
        }
        if (titleOnly == NSNotFound) titleOnly = i;
    }
    if (titleOnly != NSNotFound) {
        NSMenuItem *item = [picker itemAtIndex:titleOnly];
        NSDictionary *rep = [item.representedObject isKindOfClass:NSDictionary.class] ? item.representedObject : nil;
        if (outTitle) *outTitle = item.title ?: @"";
        if (outURL) *outURL = [rep[@"url"] isKindOfClass:NSString.class] ? rep[@"url"] : @"";
    }
    return titleOnly;
}

// 有界重解析：菜单会在动作后异步重建，允许一个短窗口；超时返回 NSNotFound（调用方判 FAIL）。
static NSInteger RSWaitMenuIndexForTier(NSPopUpButton *picker, NSString *title, NSString *plannedURL,
                                       NSTimeInterval seconds, NSString **outTitle, NSString **outURL) {
    // 注意：块内**不得**捕获 NSString** 出参（-Wblock-capture-autoreleasing，会引入悬垂指针），
    // 因此用 __block 强引用局部量承接结果，块外再写回出参。
    __block NSInteger idx = NSNotFound;
    __block NSString *foundTitle = nil;
    __block NSString *foundURL = nil;
    RSWaitUntil(seconds, ^BOOL {
        NSString *t = nil, *u = nil;
        idx = RSMenuIndexForTier(picker, title, plannedURL, &t, &u);
        if (idx != NSNotFound) { foundTitle = t; foundURL = u; }
        return idx != NSNotFound;
    }, nil);
    if (idx != NSNotFound) {
        if (outTitle) *outTitle = foundTitle;
        if (outURL) *outURL = foundURL;
    }
    return idx;
}

#pragma mark - 离线自检（无网络）：真实检查逻辑正反用例 + spy 契约独立性

// 自检专用 no-op 测试后端：只为「用真实指定初始化构造一个隔离 DownloadManager」提供
// 依赖。自检**从不在该实例上入队**，因此本后端永远不会被调用，不会发起任何网络请求。
@interface RSNoopDownloadBackend : NSObject <RDDownloadBackend>
@end
@implementation RSNoopDownloadBackend
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                           writeToURL:(NSURL *)writeToURL
                           completion:(void (^)(NSURL * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable))completion {
    if (completion) completion(nil, nil, [NSError errorWithDomain:@"RSNoopDownloadBackend" code:0 userInfo:nil]);
    return nil;
}
@end

// 受控 NSURLProtocol（仅离线自检注入）：按路径返回受控响应，用来离线验证安全链，
// 不产生任何真实网络请求。合法用例的“公网主机”用公网 IP 字面量，使其能通过生产
// URLPolicy 的文本阶段与 DNS 后逐 IP 校验（IP 字面量解析为自身），无需伪造放行策略。
@interface RSManifestTestURLProtocol : NSURLProtocol
@end
@implementation RSManifestTestURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *p = request.URL.path ?: @"";
    return [p hasSuffix:@".m3u8"] || [p hasSuffix:@".mp4"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)stopLoading {}
- (void)respondWithCode:(NSInteger)code mime:(NSString *)mime body:(NSData *)body {
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:code
                                                     HTTPVersion:@"HTTP/1.1"
                                                    headerFields:@{ @"Content-Type": mime }];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length) [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)redirectTo:(NSString *)location {
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302
                                                     HTTPVersion:@"HTTP/1.1"
                                                    headerFields:@{ @"Location": location }];
    [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:location]]
            redirectResponse:r];
}
- (void)startLoading {
    NSString *path = self.request.URL.path ?: @"";
    NSString *host = self.request.URL.host ?: @"";
    NSString *scheme = self.request.URL.scheme ?: @"https";
    if ([path hasSuffix:@"redir-private.m3u8"]) { [self redirectTo:@"http://10.0.0.1/x.m3u8"]; return; }
    if ([path hasSuffix:@"redir-downgrade.m3u8"]) { [self redirectTo:[NSString stringWithFormat:@"http://%@/ok.m3u8", host]]; return; }
    if ([path hasSuffix:@"redir-ok.m3u8"]) { [self redirectTo:[NSString stringWithFormat:@"%@://%@/ok.m3u8", scheme, host]]; return; }
    if ([path hasSuffix:@"media.mp4"]) {
        [self respondWithCode:200 mime:@"video/mp4" body:[@"NOT-A-PLAYLIST-PAYLOAD" dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    if ([path hasSuffix:@"big.m3u8"]) {
        // 先给清单 MIME 的响应头，再分块灌入远超上限的数据：验证“流式超限立即取消”。
        NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{ @"Content-Type": @"application/vnd.apple.mpegurl" }];
        [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        NSData *chunk = [NSMutableData dataWithLength:64 * 1024];
        for (int i = 0; i < 16; i++) [self.client URLProtocol:self didLoadData:chunk];   // 1 MiB ≫ 256 KiB 上限
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    [self respondWithCode:200 mime:@"application/vnd.apple.mpegurl"
                     body:[@"#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\na.m3u8\n" dataUsingEncoding:NSUTF8StringEncoding]];
}
@end

// 负向对照：刻意复现修复前「子类用同名数组属性遮蔽父类字典存储」的形态，
// 用于证明检查确实能发现该缺陷（避免空过）。仅自检使用。
@interface RSOldStyleShadowSpy : DownloadManager
@property (nonatomic, strong) NSMutableArray<DownloadJob *> *jobs;
@end
@implementation RSOldStyleShadowSpy
@end

#pragma mark - 测试进程内隔离：替换 +[DownloadManager sharedManager]（仅探针进程、不改生产）

// B3：app/variantcheck 等入口经 applicationDidFinishLaunching → [DownloadManager sharedManager]，
// 真实实现以 NSTemporaryDirectory()/7zz-downloads 为 tempRoot，init 会清理该共享根与 .rd-trash；
// 该路径与用户 App 相同，且 TMPDIR 覆盖已被证实对 NSTemporaryDirectory() 无效。故在**本测试进程**内
// 用运行时替换把 +sharedManager 指向一个隔离替身（指定初始化 + noop backend + 独立 suite + 明确私有
// tempRoot），使真实初始化与本进程彻底无关。生产源码不改；appdl（刻意做真实下载的模式）除外。
static DownloadManager *gRSIsolatedSharedManager = nil;
static IMP gRSRealSharedManagerIMP = NULL;
static NSInteger gRSSharedManagerCalls = 0;

static NSString *RSTestSandboxRoot(void) {
    NSString *root = NSProcessInfo.processInfo.environment[@"RD_PROBE_SANDBOX_ROOT"];
    if (root.length == 0) {
        root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"rs-probe-sandbox-%d", (int)getpid()]];
    }
    return root;
}

static id RSIsolatedSharedManagerIMP(Class cls, SEL cmd) {
    gRSSharedManagerCalls++;
    if (!gRSIsolatedSharedManager) {
        NSString *suite = @"com.sevenzz.probe.isolated-shared";
        // 只清本测试自己的 suite 域（与用户 App 域无关），保证每轮从空白开始。
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
        DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:
                                [[NSUserDefaults alloc] initWithSuiteName:suite]];
        NSURL *root = [NSURL fileURLWithPath:[RSTestSandboxRoot() stringByAppendingPathComponent:@"7zz-probe-isolated-downloads"]];
        gRSIsolatedSharedManager = [[DownloadManager alloc] initWithBackend:[RSNoopDownloadBackend new]
                                                                  tempRoot:root
                                                                     store:store];
    }
    return gRSIsolatedSharedManager;
}

static void RSInstallIsolatedSharedManager(void) {
    Method m = class_getClassMethod(DownloadManager.class, @selector(sharedManager));
    if (m == NULL) return;
    gRSRealSharedManagerIMP = method_getImplementation(m);
    method_setImplementation(m, (IMP)RSIsolatedSharedManagerIMP);
}

static BOOL RSAllJobsThrows(id manager) {
    @try { (void)[manager allJobs]; return NO; }
    @catch (NSException *e) { return YES; }
}

static int RSSelfCheck(void) {
    printf("RS-SELFCHECK begin\n");
    NSURL *base = [NSURL URLWithString:@"https://example.invalid/test/master.m3u8"];
    NSString *reason = nil;
    NSString *u4 = @"https://example.invalid/test/rate_4.m3u8";
    NSString *u5 = @"https://example.invalid/test/rate_5.m3u8";

    // 用例1：路径不含 "720p" 但清单声明 1280x720 → 必须通过
    NSString *fixtureA = @"#EXTM3U\n"
                          "#EXT-X-STREAM-INF:BANDWIDTH=1325000,RESOLUTION=480x270\nrate_2.m3u8\n"
                          "#EXT-X-STREAM-INF:BANDWIDTH=5095000,RESOLUTION=1280x720\nrate_4.m3u8\n"
                          "#EXT-X-STREAM-INF:BANDWIDTH=10525000,RESOLUTION=1920x1080\nrate_5.m3u8\n";
    NSArray<NSDictionary *> *vA = RSParseMasterVariants(fixtureA, base);
    NSArray<NSString *> *t720A = RSTierCandidateURLs(vA, 720);
    RSQualityVerdict q1 = RSQualityTierMappingVerdict(t720A, u4, u4, u4, &reason);
    printf("RS-SELFCHECK case1 manifestVariants=%lu tier720=%lu verdict=%ld\n",
           (unsigned long)vA.count, (unsigned long)t720A.count, (long)q1);
    RSCheck(q1 == RSQualityVerdictPass,
            @"[用例1] 路径不含 \"720p\" 但清单声明 1280x720 → 判定通过（%@）", reason.length ? reason : @"一致");
    RSCheck(![u4.lowercaseString containsString:@"720p"],
            @"[用例1对照] 旧断言判据（路径含字面 \"720p\"）在该真实命名上为假 → 旧断言必然误报失败");

    // 用例2：入队错换成 1080 变体 → 必须失败
    RSQualityVerdict q2 = RSQualityTierMappingVerdict(t720A, u4, u4, u5, &reason);
    RSCheck(q2 == RSQualityVerdictFail, @"[用例2] 入队错换成 1080 变体 → 判定失败（%@）", reason);

    // 用例3：被错换的 1080 变体即使路径含 "720p" 也必须失败
    NSString *fixtureB = @"#EXTM3U\n"
                          "#EXT-X-STREAM-INF:RESOLUTION=1280x720\nmovie-480p.m3u8\n"
                          "#EXT-X-STREAM-INF:RESOLUTION=1920x1080\nmovie-720p.m3u8\n";
    NSArray<NSDictionary *> *vB = RSParseMasterVariants(fixtureB, base);
    NSArray<NSString *> *t720B = RSTierCandidateURLs(vB, 720);
    NSString *uB1080 = @"https://example.invalid/test/movie-720p.m3u8";
    RSQualityVerdict q3 = RSQualityTierMappingVerdict(t720B, uB1080, uB1080, uB1080, &reason);
    printf("RS-SELFCHECK case3 tier720=%lu（=1280x720 那条）\n", (unsigned long)t720B.count);
    RSCheck([uB1080 containsString:@"720p"], @"[用例3前提] 被错换的 1080 变体路径确实含字面 \"720p\"");
    RSCheck(q3 == RSQualityVerdictFail,
            @"[用例3] 错换 1080 变体即使路径含 \"720p\" 也判定失败（%@）", reason);

    // 用例4：同档存在多个候选时，UI 选 A 而实际入队 B → 映射错位必须失败
    NSString *fixtureC = @"#EXTM3U\n"
                          "#EXT-X-STREAM-INF:RESOLUTION=1280x720\nrate_4_live.m3u8\n"
                          "#EXT-X-STREAM-INF:RESOLUTION=1280x720\nrate_4.m3u8\n";
    NSArray<NSDictionary *> *vC = RSParseMasterVariants(fixtureC, base);
    NSArray<NSString *> *t720C = RSTierCandidateURLs(vC, 720);
    NSString *live = @"https://example.invalid/test/rate_4_live.m3u8";
    RSQualityVerdict q4 = RSQualityTierMappingVerdict(t720C, live, live, u4, &reason);
    printf("RS-SELFCHECK case4 tier720=%lu（同档两候选）\n", (unsigned long)t720C.count);
    RSCheck(t720C.count == 2 && q4 == RSQualityVerdictFail,
            @"[用例4] UI 选同档 live 候选而实际入队另一候选 → 映射错位判定失败（%@）", reason);

    // 用例5：清单未声明该档位 → 标记未覆盖（既非通过也非失败）
    NSArray<NSString *> *t720D = RSTierCandidateURLs(RSParseMasterVariants(
        @"#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1920x1080\nonly1080.m3u8\n", base), 720);
    RSQualityVerdict q5 = RSQualityTierMappingVerdict(t720D, u4, u4, u4, &reason);
    RSCheck(q5 == RSQualityVerdictUnsupported, @"[用例5] 源清单未声明 720 档 → 标记该语义未覆盖（%@）", reason);

    // 用例6：只有自动档（无 RESOLUTION 声明）→ 不据文件名猜档位
    NSArray<NSDictionary *> *vE = RSParseMasterVariants(
        @"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nauto-720p.m3u8\n", base);
    RSQualityVerdict q6 = RSQualityTierMappingVerdict(RSTierCandidateURLs(vE, 720), u4, u4, u4, &reason);
    RSCheck(vE.count == 0 && q6 == RSQualityVerdictUnsupported,
            @"[用例6] 只有自动档且文件名含 \"720p\" → 不据文件名猜档位，标记未覆盖");

    // 用例7/8：调用方级策略（UI 已存在该档位 ⇒ 必须核实）。unsupported 只是 verdict 层的分类，
    // 在「需要核实」的场景必须转为 FAIL；取源失败同样 FAIL。这就是 app/vc 实际调用的同一函数。
    NSString *callerReason = nil;
    RSQualityCheckOutcome o1 = RSQualityRequiredTierOutcome(RSManifestFetchOK, RSQualityVerdictUnsupported, &callerReason);
    RSCheck(o1 == RSQualityCheckOutcomeFail,
            @"[用例7] UI 存在档位但清单未声明该档位 → 调用方判定 FAIL（%@）", callerReason);
    RSQualityCheckOutcome o2 = RSQualityRequiredTierOutcome(RSManifestFetchTimeout, RSQualityVerdictFail, &callerReason);
    RSCheck(o2 == RSQualityCheckOutcomeFail,
            @"[用例8] 取源失败 → 调用方判定 FAIL（%@）", callerReason);
    RSQualityCheckOutcome o3 = RSQualityRequiredTierOutcome(RSManifestFetchOK, RSQualityVerdictPass, &callerReason);
    RSCheck(o3 == RSQualityCheckOutcomePass, @"[用例9] 正确映射 → 调用方判定 PASS");
    RSQualityCheckOutcome o4 = RSQualityRequiredTierOutcome(RSManifestFetchOK, RSQualityVerdictFail, &callerReason);
    RSCheck(o4 == RSQualityCheckOutcomeFail, @"[用例10] 同档错位 → 调用方判定 FAIL（%@）", callerReason);

    // —— 安全清单取源：受控 NSURLProtocol 离线反例（不触网）——
    // 全程使用生产 URLPolicy + ResourceURLGate（不做任何放宽），仅注入协议类产生受控响应。
    {
        RSManifestFetcher *f = [RSManifestFetcher new];
        f.protocolClasses = @[ RSManifestTestURLProtocol.class ];
        f.maxBytes = 256 * 1024;      // 缩小上限便于用小体积反例验证“流式超限”
        f.timeout = 5;
        NSString *t = nil, *d = nil;
        RSManifestFetchStatus s;

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://93.184.216.34/ok.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchOK && [t hasPrefix:@"#EXTM3U"],
                @"[sec-1] 合法有限主清单可取得（status=%s policyChecks=%lu dnsChecks=%lu）",
                RSManifestFetchStatusText(s).UTF8String, (unsigned long)f.policyChecks, (unsigned long)f.dnsChecks);

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://93.184.216.34/big.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchTooLarge,
                @"[sec-2] 响应体流式超限被拒（status=%s detail=%s，未读完整文件）",
                RSManifestFetchStatusText(s).UTF8String, (d ?: @"").UTF8String);

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://10.0.0.1/ok.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchBlockedByPolicy,
                @"[sec-3] 初始 URL 为内网地址被策略拒绝（status=%s）", RSManifestFetchStatusText(s).UTF8String);

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://93.184.216.34/redir-private.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchBlockedByPolicy && f.redirectCount >= 1,
                @"[sec-4] 重定向到内网被逐跳策略拒绝（status=%s redirects=%lu detail=%s）",
                RSManifestFetchStatusText(s).UTF8String, (unsigned long)f.redirectCount, (d ?: @"").UTF8String);

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://93.184.216.34/redir-downgrade.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchBlockedByPolicy,
                @"[sec-5] HTTPS→HTTP 降级重定向被拒（status=%s detail=%s）",
                RSManifestFetchStatusText(s).UTF8String, (d ?: @"").UTF8String);

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://93.184.216.34/media.mp4"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchNotManifest,
                @"[sec-6] 非清单 MIME（video/mp4）被拒，不把媒体正文读入内存（status=%s detail=%s）",
                RSManifestFetchStatusText(s).UTF8String, (d ?: @"").UTF8String);

        s = [f fetchSynchronously:[NSURL URLWithString:@"https://93.184.216.34/redir-ok.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchOK && f.policyChecks >= 2,
                @"[sec-7] 合法 https 跳转仍可用（status=%s redirects=%lu policyChecks=%lu）",
                RSManifestFetchStatusText(s).UTF8String, (unsigned long)f.redirectCount, (unsigned long)f.policyChecks);

        s = [f fetchSynchronously:[NSURL URLWithString:@"ftp://93.184.216.34/ok.m3u8"] text:&t detail:&d];
        RSCheck(s == RSManifestFetchBadURL,
                @"[sec-8] 非 http/https 输入直接拒绝（status=%s）", RSManifestFetchStatusText(s).UTF8String);
    }

    // —— spy 契约：父类 allJobs 与 recordedJobs 相互独立 ——
    // 事实前提（本自检一并验证）：DownloadManager 未覆写 -init；[RSEnqueueSpy new] 走
    // NSObject 的 init，父类 `_jobs` 字典**未初始化**（nil），故改名后 -allJobs 返回 nil。
    // nil 不是"有效空集合"，不能当通过；因此下面分别验证「空集合」与「非空集合」两种形态。
    Method mInitBase = class_getInstanceMethod(DownloadManager.class, @selector(init));
    Method mInitNSObject = class_getInstanceMethod(NSObject.class, @selector(init));
    RSCheck(mInitBase != NULL && mInitBase == mInitNSObject,
            @"[spy-0] DownloadManager 未覆写 -init（与 NSObject 同一个实现）→ [spy new] 未经指定初始化");

    RSEnqueueSpy *spy = [RSEnqueueSpy new];
    RSCheck(!RSAllJobsThrows(spy), @"[spy-1] 修复后的 spy 调 -allJobs 不抛异常");
    Method mJobsSpy = class_getInstanceMethod(RSEnqueueSpy.class, @selector(jobs));
    Method mJobsBase = class_getInstanceMethod(DownloadManager.class, @selector(jobs));
    RSCheck(mJobsBase != NULL && mJobsSpy == mJobsBase,
            @"[spy-2] spy 未遮蔽父类 -jobs（与 DownloadManager 同一个实现）");
    Method mAllSpy = class_getInstanceMethod(RSEnqueueSpy.class, @selector(allJobs));
    Method mAllBase = class_getInstanceMethod(DownloadManager.class, @selector(allJobs));
    RSCheck(mAllBase != NULL && mAllSpy == mAllBase,
            @"[spy-3] spy 未覆盖 -allJobs（沿用父类实现，不使用假数据）");

    // 「空集合」形态：用真实指定初始化（测试 noop backend + 隔离 suite 的 DownloadStore +
    // 临时 root）构造一个真正的 DownloadManager。**不入队**，因此不会触网、不会启动下载、
    // 不会写任何 store。这条断言要求 allJobs 返回**非 nil 的空数组**，证明父类字典存储可用。
    NSString *scSuite = @"com.sevenzz.probe.selfcheck";
    DownloadStore *scStore = [[DownloadStore alloc] initWithUserDefaults:[[NSUserDefaults alloc] initWithSuiteName:scSuite]];
    NSURL *scRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"7zz-probe-selfcheck"]];
    DownloadManager *scMgr = [[DownloadManager alloc] initWithBackend:[RSNoopDownloadBackend new]
                                                             tempRoot:scRoot store:scStore];
    NSArray<DownloadJob *> *scAll = [scMgr allJobs];
    RSCheck(scAll != nil && scAll.count == 0,
            @"[spy-4] 真实指定初始化的 DownloadManager（隔离 store，未入队）：allJobs 为非 nil 的空集合（%@，count=%lu）",
            scAll ? @"array" : @"nil", (unsigned long)scAll.count);
    RSCheck(!RSAllJobsThrows(scMgr), @"[spy-5] 真实指定初始化实例调 -allJobs 不抛异常");

    // 「非空集合」形态：spy 的记录集合必须非空且内容正确；同时父类 allJobs 不受其影响。
    for (NSInteger i = 0; i < 2; i++) {
        [spy enqueueItemWithSourceURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://example.invalid/v%ld.m3u8", (long)i]]
                               folder:[NSURL fileURLWithPath:NSTemporaryDirectory()]
                        preferredName:[NSString stringWithFormat:@"rs-selfcheck-%ld", (long)i]
                        sourcePageURL:@"https://example.invalid/"
                         resourceKind:DownloadResourceVideo
                       expectedLength:0];
    }
    RSCheck(spy.recordedJobs.count == 2, @"[spy-6] recordedJobs 为非空集合且计数正确（期望 2，实际 %lu）",
            (unsigned long)spy.recordedJobs.count);
    RSCheck([spy.recordedJobs.lastObject.sourceURL.absoluteString containsString:@"v1.m3u8"],
            @"[spy-7] recordedJobs 末项内容正确（确为最后一次入队对象 %s）",
            RSRedactedURL(spy.recordedJobs.lastObject.sourceURL.absoluteString).UTF8String);
    NSArray<DownloadJob *> *spyAll = [spy allJobs];
    RSCheck(scAll.count == 0 && (spyAll == nil || spyAll.count == 0),
            @"[spy-8] 父类 allJobs 与 recordedJobs 相互独立（记录非空 %lu 项时 allJobs 仍 %@）",
            (unsigned long)spy.recordedJobs.count, spyAll ? @"空数组" : @"nil");

    // 负向对照：修复前的遮蔽形态必须被检测出来（证明检查非空过）。
    // 关键前提：遮蔽数组必须**先非空**——修复前真实崩溃时 RSEnqueueSpy 的覆盖实现已把
    // 入队对象写进自己的 `jobs` 数组（非 nil）；若数组为 nil，`[nil allValues]` 不抛异常，
    // 负向对照会假通过（首轮实测即栽在这里）。这里直接置入与修复前同形态的非空数组：
    // 走生产 -enqueueItem… 会被 URL 策略拦截而不写该数组，无法建立前提，故直接赋值。
    RSOldStyleShadowSpy *old = [RSOldStyleShadowSpy new];
    old.jobs = [NSMutableArray array];
    [old.jobs addObject:[DownloadJob new]];
    RSCheck(old.jobs.count == 1, @"[spy-9前提] 负向对照替身的遮蔽数组已置为非空（与修复前崩溃时形态一致，count=%lu）",
            (unsigned long)old.jobs.count);
    RSCheck(RSAllJobsThrows(old),
            @"[spy-10] 负向对照：修复前的遮蔽形态在数组非空时确实触发 allJobs 异常（检查可发现该缺陷）");

    // —— 选行/档位就绪覆盖判定：3 个离线用例（执行的是 app 分支使用的同一判定函数）——
    {
        NSString *covReason = nil;
        // cov-1：选行到截止仍未生效 → 必须判 FAIL（旧实现会静默跳过整段且仍 PASS）
        __block NSInteger covAttempts = 0;
        BOOL neverSelected = RSWaitUntil(0.5, ^BOOL { return NO; }, ^{ covAttempts++; });
        RSSelectionCoverageState c1 = RSSelectionCoverageDecision(neverSelected, 2, NO, 0, NO, &covReason);
        printf("RS-SELFCHECK cov-1 neverSelected=%d attempts=%ld state=%ld\n",
               neverSelected ? 1 : 0, (long)covAttempts, (long)c1);
        RSCheck(neverSelected == NO && c1 == RSSelectionCoverageNotReady && RSSelectionCoverageIsFailure(c1),
                @"[cov-1] 选行到截止仍未生效 → 判定 FAIL 而非 PASS（尝试 %ld 次；%@）", (long)covAttempts, covReason);

        // cov-2：就绪迟于 6.5s（旧固定 40×0.15s=6s 会耗尽）→ 有界等待必须最终就绪并执行多档断言
        NSDate *covT0 = [NSDate date];
        BOOL lateReady = RSWaitUntil(12.0, ^BOOL { return -[covT0 timeIntervalSinceNow] >= 6.5; }, nil);
        double covWaited = -[covT0 timeIntervalSinceNow];
        RSSelectionCoverageState c2 = RSSelectionCoverageDecision(YES, 2, lateReady, lateReady ? 2 : 0,
                                                                  lateReady, &covReason);
        printf("RS-SELFCHECK cov-2 waited=%.2fs ready=%d state=%ld\n", covWaited, lateReady ? 1 : 0, (long)c2);
        RSCheck(lateReady && covWaited >= 6.4 && covWaited > 6.0 && c2 == RSSelectionCoverageReady,
                @"[cov-2] 就绪迟于旧 6s 上限（实测等待 %.2fs）→ 仍判就绪，多档断言必须执行", covWaited);

        // cov-3：真实单档/无档位 → 明确不适用，不算失败
        RSSelectionCoverageState c3 = RSSelectionCoverageDecision(YES, 1, NO, 0, NO, &covReason);
        RSCheck(c3 == RSSelectionCoverageNotApplicable && !RSSelectionCoverageIsFailure(c3),
                @"[cov-3] 真实单档/无档位 → 明确不适用且不算失败（%@）", covReason);

        // —— 菜单重建/重排安全：离线用真实 NSPopUpButton 复现生产 removeAllItems 重建形态 ——
        {
            NSPopUpButton *pk = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 20) pullsDown:NO];
            void (^build)(NSArray<NSString *> *, NSArray<NSString *> *) = ^(NSArray<NSString *> *titles, NSArray<NSString *> *urls) {
                [pk removeAllItems];
                for (NSUInteger i = 0; i < titles.count; i++) {
                    [pk addItemWithTitle:titles[i]];
                    pk.lastItem.representedObject = @{ @"url": urls[i] };
                }
            };
            NSArray *t3 = @[@"480p", @"720p", @"1080p"];
            NSArray *u3 = @[@"https://x/rate_2.m3u8", @"https://x/rate_4.m3u8", @"https://x/rate_5.m3u8"];
            build(t3, u3);

            // 1) 三档初态：按标题+URL 精确解析，索引必须在范围内
            NSInteger i480 = RSMenuIndexForTier(pk, @"480p", u3[0], NULL, NULL);
            NSInteger i720 = RSMenuIndexForTier(pk, @"720p", u3[1], NULL, NULL);
            NSInteger i1080 = RSMenuIndexForTier(pk, @"1080p", u3[2], NULL, NULL);
            RSCheck(i480 == 0 && i720 == 1 && i1080 == 2,
                    @"[menu-1] 三档菜单按标题+URL 解析正确（%ld/%ld/%ld）", (long)i480, (long)i720, (long)i1080);

            // 2) 错选防护：计划标题 720p 但携带 1080p 的 URL → 不得选到其它档位
            NSString *gotTitle = nil, *gotURL = nil;
            NSInteger wrong = RSMenuIndexForTier(pk, @"720p", u3[2], &gotTitle, &gotURL);
            RSCheck(wrong == 1 && [gotTitle isEqualToString:@"720p"] && RSSameURL(gotURL, u3[1]),
                    @"[menu-2] 计划 URL 与标题不符时仍按标题定位且返回该档真实 URL（错选必须失败）");

            // 3) 重建为 1 档（生产 removeAllItems 后只回填一个）：解析缺失档位不得越界/崩溃
            build(@[@"480p"], @[u3[0]]);
            NSInteger only480 = RSMenuIndexForTier(pk, @"480p", u3[0], NULL, NULL);
            NSInteger gone1080 = RSMenuIndexForTier(pk, @"1080p", u3[2], NULL, NULL);
            RSCheck(only480 == 0 && gone1080 == NSNotFound,
                    @"[menu-3] 菜单缩到 1 档：可解析档返回新索引，缺失档返回 NSNotFound（不越界）");

            // 4) 重建回 3 档但**重排**：必须重新解析出新的真实索引
            build(@[@"1080p", @"720p", @"480p"], @[u3[2], u3[1], u3[0]]);
            NSInteger reordered480 = RSMenuIndexForTier(pk, @"480p", u3[0], NULL, NULL);
            NSInteger reordered720 = RSMenuIndexForTier(pk, @"720p", u3[1], NULL, NULL);
            RSCheck(reordered480 == 2 && reordered720 == 1,
                    @"[menu-4] 菜单重排后按当前菜单重新解析（480p→%ld, 720p→%ld，非旧索引）",
                    (long)reordered480, (long)reordered720);

            // 5) 预期档位彻底消失：NSNotFound（调用方判 FAIL），且绝不越界
            build(@[@"480p", @"1080p"], @[u3[0], u3[2]]);
            NSInteger missing720 = RSMenuIndexForTier(pk, @"720p", u3[1], NULL, NULL);
            RSCheck(missing720 == NSNotFound,
                    @"[menu-5] 预期档位消失 → NSNotFound（明确 FAIL，不崩溃不跳过）");

            // 6) 延迟重建（模拟详情异步回填）：0.6s 后才出现 3 档，有界重解析必须成功
            build(@[@"480p"], @[u3[0]]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ build(t3, u3); });
            NSString *lateTitle = nil;
            NSInteger lateIdx = RSWaitMenuIndexForTier(pk, @"1080p", u3[2], 5.0, &lateTitle, NULL);
            RSCheck(lateIdx == 2 && [lateTitle isEqualToString:@"1080p"],
                    @"[menu-6] 菜单延迟 0.6s 重建 → 有界重解析最终命中（idx=%ld）", (long)lateIdx);

            // 7) 单档直链行（无画质档）：解析任意档位都是 NSNotFound，且 numberOfItems 未被改动
            build(@[@"原始文件"], @[@"https://x/direct.mp4"]);
            NSInteger singleProbe = RSMenuIndexForTier(pk, @"720p", @"", NULL, NULL);
            RSCheck(singleProbe == NSNotFound && pk.numberOfItems == 1,
                    @"[menu-7] 单档/无档位行：解析 720p 为 NSNotFound 且菜单未被改动（items=%ld）",
                    (long)pk.numberOfItems);
        }

        // cov-4：模型声明多档但 picker 未就绪 → 必须 FAIL
        RSSelectionCoverageState c4 = RSSelectionCoverageDecision(YES, 3, NO, 0, NO, &covReason);
        RSCheck(c4 == RSSelectionCoverageNotReady && RSSelectionCoverageIsFailure(c4),
                @"[cov-4] 模型声明 3 档但画质下拉未就绪 → 必须 FAIL（%@）", covReason);
    }

    // —— B3 共享临时根隔离：证明真实 +[DownloadManager sharedManager] 初始化未被触发 ——
    // 做法（安全、不碰真实用户目录、不放哨兵、不触发清理）：
    //  ① 断言 +sharedManager 的实现已被替换（IMP 改变）；
    //  ② 真实共享根（NSTemporaryDirectory()/7zz-downloads）在调用前后**存在性与 mtime 不变**
    //     —— 真实 init 会创建该目录并清理 .rd-trash，若被执行必然留下痕迹；
    //  ③ 私有沙盒内按共享根布局放 canary，调用后必须原样存在（未被删除）；
    //  ④ 替身 tempRoot 必须位于私有沙盒内且不等于真实共享根。
    {
        Method sm = class_getClassMethod(DownloadManager.class, @selector(sharedManager));
        IMP nowIMP = sm ? method_getImplementation(sm) : NULL;
        RSCheck(gRSRealSharedManagerIMP != NULL && nowIMP == (IMP)RSIsolatedSharedManagerIMP
                && nowIMP != gRSRealSharedManagerIMP,
                @"[iso-2] +[DownloadManager sharedManager] 已在本进程被替换（真实 IMP 不再可达）");

        NSString *realRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"7zz-downloads"];
        NSString *realTrash = [NSTemporaryDirectory() stringByAppendingPathComponent:@".rd-trash"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *a1 = [fm attributesOfItemAtPath:realRoot error:nil];
        NSDictionary *a2 = [fm attributesOfItemAtPath:realTrash error:nil];
        NSString *realFingerprintBefore = [NSString stringWithFormat:@"%@|%@|%@|%@",
            a1 ? @"exists" : @"absent", a1[NSFileModificationDate] ?: @"-",
            a2 ? @"exists" : @"absent", a2[NSFileModificationDate] ?: @"-"];

        // 私有沙盒：模拟共享根布局 + canary
        NSString *sandbox = RSTestSandboxRoot();
        NSString *canaryRoot = [sandbox stringByAppendingPathComponent:@"7zz-downloads"];
        NSString *canaryTrash = [sandbox stringByAppendingPathComponent:@".rd-trash"];
        [fm createDirectoryAtPath:canaryRoot withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:canaryTrash withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *canaryFile = [canaryRoot stringByAppendingPathComponent:@"CANARY"];
        NSString *trashCanaryFile = [canaryTrash stringByAppendingPathComponent:@"CANARY"];
        [@"CANARY-PRIVATE-SANDBOX" writeToFile:canaryFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"CANARY-TRASH" writeToFile:trashCanaryFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

        DownloadManager *m1 = [DownloadManager sharedManager];
        DownloadManager *m2 = [DownloadManager sharedManager];
        RSCheck(m1 != nil && m1 == m2 && m1 == gRSIsolatedSharedManager,
                @"[iso-3] sharedManager 返回隔离替身且单例稳定（调用计数=%ld）", (long)gRSSharedManagerCalls);
        NSArray<DownloadJob *> *isoJobs = [m1 allJobs];
        RSCheck(isoJobs != nil && isoJobs.count == 0,
                @"[iso-4] 替身 allJobs 契约正确：非 nil 空集合（%@）", isoJobs ? @"array" : @"nil");
        RSCheck(!RSAllJobsThrows(m1), @"[iso-5] 替身调 -allJobs 不抛异常");
        // 替身 tempRoot 为私有沙盒路径：以“私有 root 目录被 init 创建”作正证（不访问私有属性）。
        NSString *isoPrivateRoot = [sandbox stringByAppendingPathComponent:@"7zz-probe-isolated-downloads"];
        RSCheck([fm fileExistsAtPath:isoPrivateRoot],
                @"[iso-6] 隔离替身使用私有 tempRoot 且其目录已由指定初始化创建（%s）", isoPrivateRoot.UTF8String);

        NSDictionary *b1 = [fm attributesOfItemAtPath:realRoot error:nil];
        NSDictionary *b2 = [fm attributesOfItemAtPath:realTrash error:nil];
        NSString *realFingerprintAfter = [NSString stringWithFormat:@"%@|%@|%@|%@",
            b1 ? @"exists" : @"absent", b1[NSFileModificationDate] ?: @"-",
            b2 ? @"exists" : @"absent", b2[NSFileModificationDate] ?: @"-"];
        RSCheck([realFingerprintBefore isEqualToString:realFingerprintAfter],
                @"[iso-7] 真实共享根与 .rd-trash 在调用前后存在性/mtime 不变（真实清理未触发）");
        RSCheck([fm fileExistsAtPath:canaryFile] && [fm fileExistsAtPath:trashCanaryFile],
                @"[iso-8] 私有沙盒模拟共享根的 canary 未被删除");
        NSString *canaryBody = [NSString stringWithContentsOfFile:canaryFile encoding:NSUTF8StringEncoding error:nil];
        RSCheck([canaryBody isEqualToString:@"CANARY-PRIVATE-SANDBOX"],
                @"[iso-9] canary 内容未被改写");
    }

    // —— 偏好域隔离（哨兵法，只报告 present/absent，不读取任何用户记录或设置值）——
    // 裸可执行文件的 standardUserDefaults 应绑定到**进程名域**，而不是用户 App 的
    // bundle id 域。做法：向标准域写入一枚一次性随机哨兵键，再分别通过标准域与
    // 用户 App 域（suite == bundle id）查询它；两者结果必须不同才算隔离成立。
    NSString *sentinelKey = [NSString stringWithFormat:@"RSDomainSentinel.%@", NSUUID.UUID.UUIDString];
    [[NSUserDefaults standardUserDefaults] setObject:@"1" forKey:sentinelKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSString *probeDomainValue = [[NSUserDefaults standardUserDefaults] stringForKey:sentinelKey];
    NSString *appDomainValue = [[[NSUserDefaults alloc] initWithSuiteName:@"com.sevenzz.resource-detector"]
                                stringForKey:sentinelKey];
    printf("RS-SELFCHECK domain sentinel: standardDomain=%s appDomain=%s\n",
           probeDomainValue.length ? "present" : "absent", appDomainValue.length ? "present" : "absent");
    RSCheck(probeDomainValue.length > 0 && appDomainValue.length == 0,
            @"[iso-1] standardUserDefaults 绑定本进程自己的域：哨兵只在标准域可见，用户 App 域不可见");
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:sentinelKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 边界（只报告，不越权改生产）：DownloadManager.sharedManager 硬编码
    // standardUserDefaults，src 内无任何 suite/域注入点（已 grep 确认），因此本进程内
    // **无法**把真实 sharedManager 的 store 换成每轮临时 suite——除非改生产 src（禁止）。
    // 本任务据此采用两条可证边界：① 本进程标准域 == 自己的域（上面 iso-1）；
    // ② app 模式把 delegate.downloadManager 换成 spy，真实 manager 从不被要求入队，
    //    故不启动下载、不写记录（下面 spy-* 与同站运行日志共同证明）。
    printf("RS-SELFCHECK isolation scope: sharedManager 不可注入（src 无 suite 钩子）→ 采用进程自有域 + 禁自动下载边界\n");

    RSSummary();
    return 0;
}

#pragma mark - 生产 App 全链（真实界面对象 + 真实网络）

static BOOL gRealDownload = NO;
static NSString *gDownloadDir = nil;

static int RSRunApp(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) { printf("RS-RESULT FAIL 网址无效\n"); return 2; }

    // 避免 ⌘空格 授权弹窗阻塞无人值守运行。
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZZHotkeyGuideAnswered"];

    ResourceDetectorAppDelegate *delegate = [ResourceDetectorAppDelegate new];
    [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:@"RSLaunch" object:nil]];
    if ([[[NSProcessInfo processInfo] environment][@"RD_PROBE_HEADLESS"] isEqualToString:@"1"]) {
        [delegate.window orderOut:nil];
    }

    RSCountingTransport *transport = [RSCountingTransport new];
    delegate.metadataService = [[RDMetadataService alloc] initWithTransport:transport];
    RSEnqueueSpy *spy = [RSEnqueueSpy new];
    if (gRealDownload) {
        // 清掉上一次验收留下的任务记录，避免同一资源身份被判为"已存在"而跳过下载。
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        for (NSString *key in @[@"CompletedResourceURLs", @"InterruptedDownloadJobs", @"FinishedDownloadJobs"])
            [defaults removeObjectForKey:key];
        [defaults synchronize];
    }
    DownloadManager *realManager = gRealDownload ? [DownloadManager sharedManager] : nil;
    delegate.downloadManager = gRealDownload ? realManager : spy;
    if (gRealDownload && gDownloadDir.length) {
        // 真实下载落到可写目录（沙箱不允许写 ~/Downloads）。
        [delegate.downloadSettings setCustomDirectoryURL:[NSURL fileURLWithPath:gDownloadDir]];
        delegate.downloadSettings.downloadDestination = ResourceDownloadDestinationCustom;
    }

    double t0 = RSTicks();
    delegate.urlField.stringValue = urlString;
    [delegate scan:nil];
    // 首屏列表（临时结果，静态取页腿先回来）：用户口径的“左侧资源列表出现”。
    // 关键：行数/条数必须在这一刻取样——再往后等任务结束就变成最终结果的数字了。
    BOOL previewed = RSWait(^BOOL { return delegate.results.count > 0; }, 120);
    double firstListSeconds = RSTicks() - t0;
    NSUInteger firstListCount = delegate.results.count;
    NSArray<DetectedMedia *> *previewRows = [delegate visibleMedia];
    NSUInteger firstListRows = previewRows.count;
    printf("RS-TIMING probe first-list=%s elapsed=%.3fs rows=%lu media=%lu\n",
           (previewed ? @"yes" : @"no").UTF8String, firstListSeconds,
           (unsigned long)firstListRows, (unsigned long)firstListCount);
    // 首屏列表的首行身份：临时结果（静态取页腿）与最终合并结果的顺序可能不同，
    // 直接影响用户第一眼看到什么、详情首测测的是哪一行。
    if (previewRows.count > 0) {
        DetectedMedia *firstPreview = previewRows.firstObject;
        printf("RS-PREVIEW-ROW0 kind=%s variants=[%s] url=%s\n",
               (firstPreview.resourceKind == RDResourceKindImage ? "image" : "video"),
               RSVariants(firstPreview).UTF8String, RSRedactedURL(firstPreview.mediaURL).UTF8String);
        NSUInteger previewVideoRows = 0;
        for (DetectedMedia *m in previewRows) if (m.resourceKind != RDResourceKindImage) previewVideoRows++;
        printf("RS-PREVIEW-VIDEOROWS count=%lu\n", (unsigned long)previewVideoRows);
    }
    // 任务完成（动态 WebKit 腿也回来、列表补齐）：探测真正的终态。
    BOOL finished = RSWait(^BOOL { return delegate.scanning == NO; }, 120);
    double probeSeconds = RSTicks() - t0;
    printf("RS-TIMING probe finished=%s complete=%.3fs status=%s\n", (finished ? @"yes" : @"no").UTF8String, probeSeconds,
           (delegate.statusNote.stringValue ?: @"").UTF8String);

    NSArray<DetectedMedia *> *media = [delegate.results copy];
    RSDumpMedia(@"APP", media);
    NSArray<DetectedMedia *> *rows = [delegate visibleMedia];
    printf("RS-ROWS count=%lu media=%lu\n", (unsigned long)rows.count, (unsigned long)media.count);
    RSCheck(media.count >= firstListCount,
            @"最终资源数不少于首屏列表条数、没有丢条目（首屏 %lu / 最终 %lu）",
            (unsigned long)firstListCount, (unsigned long)media.count);
    for (NSUInteger i = 0; i < rows.count; i++) {
        DetectedMedia *m = rows[i];
        printf("RS-ROW [%lu] title=%s fam=%s variants=[%s] url=%s\n", (unsigned long)i,
               (m.title ?: @"").UTF8String, (m.videoFamilyID.length ? @"yes" : @"no").UTF8String,
               RSVariants(m).UTF8String, RSRedactedURL(m.mediaURL).UTF8String);
    }
    fflush(stdout);

    // 用户口径：重复项只针对视频。同一部影片在左侧只允许一个视频选项；
    // 图片各占一行属于正常结果，不参与该判定。
    NSMutableArray<DetectedMedia *> *videoRows = [NSMutableArray array];
    for (DetectedMedia *m in rows) if (m.resourceKind != RDResourceKindImage) [videoRows addObject:m];
    printf("RS-VIDEOROWS count=%lu\n", (unsigned long)videoRows.count);
    for (NSUInteger i = 0; i < videoRows.count; i++)
        printf("RS-VIDEOROW [%lu] fam=%s variants=[%s] url=%s\n", (unsigned long)i,
               (videoRows[i].videoFamilyID.length ? @"yes" : @"no").UTF8String,
               RSVariants(videoRows[i]).UTF8String, RSRedactedURL(videoRows[i].mediaURL).UTF8String);
    NSUInteger filmRows = 0;
    for (DetectedMedia *m in videoRows) if (m.declaredVariants.count >= 2) filmRows++;
    // 断言修正（2026-09-18）：原写法 `filmRows == 1` 隐含了「页面必须至少有一部带画质
    // 声明的影片」，这在单画质页、直链媒体、纯图片页上都会误报 FAIL —— 直链媒体只有
    // 一个变体（declaredVariants 为空），实测 filmRows=0。本断言的真正意图是
    // 「同一部影片不能出现两个视频选项」，属上界约束，故改为 <= 1。
    RSCheck(filmRows <= 1, @"同一部影片至多一个视频选项（带画质声明的视频行 %lu，视频行合计 %lu）",
            (unsigned long)filmRows, (unsigned long)videoRows.count);

    RSCheck(finished, @"真实网址探测在 120s 内完成（%.1fs）", probeSeconds);
    RSCheck(media.count > 0, @"真实网址探测到媒体资源（%lu）", (unsigned long)media.count);
    if (rows.count == 0) { RSSummary(); return 0; }

    // 选中第一行：走生产 tableViewSelectionDidChange → configureDetailForMedia。
    // 必须反复选到真正生效为止（2026-09-18 修正）：扫描收尾会 reloadData，而 reload
    // 会把刚设的选中清成 selectedRow=-1，导致详情流程根本没触发，探针却在上面的
    // 等待里白等 60s 并误报「详情拿不到元数据」。实测 selectedRow=-1 后定位到此。
    double tSelect = RSTicks();
    // 选行：与 vc 相同的**有界等待**（复用 RSWaitUntil），并打印 attempts 实证。
    // 旧实现固定 40×0.15s（6s），HLS 动态腿 ~8s 时重试耗尽 → selectedRow=-1 → 整段多档断言
    // 被静默跳过却仍 PASS（独立验收复现 1/2）。选行必须成功，未生效按 FAIL 处理。
    // 统一呈现（生产）在 commit 前 `numberOfRows` 恒为 0（探索期一行都不给，见
    // ResourceDetectorApp numberOfRowsInTableView），此时 selectRowIndexes: 是空操作，
    // selectedRow 永远是 -1 —— 这正是直链单档页 12s 选不中的原因（不是单档“不适用”）。
    // 故先有界等待**列表真正出现行**；生产对不满足就绪条件的行有 60s 安全兜底提交，
    // 因此这里的上限必须大于该兜底（取 90s），否则会把产品有界等待误判成失败。
    NSDate *tableWaitStart = [NSDate date];
    BOOL tableReady = RSWaitUntil(90.0, ^BOOL { return delegate.table.numberOfRows >= 1; }, nil);
    printf("RS-TABLE rows=%ld visible=%lu results=%lu scanning=%d ready=%d waited=%.1fs\n",
           (long)delegate.table.numberOfRows, (unsigned long)[delegate visibleMedia].count,
           (unsigned long)delegate.results.count, delegate.scanning ? 1 : 0,
           tableReady ? 1 : 0, -[tableWaitStart timeIntervalSinceNow]);
    if (!tableReady) {
        printf("RS-COVER selection_ready=0 selectedRow=%ld attempts=0 picker_state=unknown variant_checks=0\n",
               (long)delegate.table.selectedRow);
        RSCheck(NO, @"统一呈现后列表在 90s 内出现行（numberOfRows=%ld，visibleMedia=%lu）—— 选行无法开始",
                (long)delegate.table.numberOfRows, (unsigned long)[delegate visibleMedia].count);
        RSSummary();
        return 1;
    }
    __block NSInteger selectAttempts = 0;
    BOOL selectionSucceeded = RSWaitUntil(12.0,
        ^BOOL { return delegate.table.selectedRow == 0; },
        ^{ selectAttempts++;
           [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; });
    printf("RS-SELECT selectedRow=%ld attempts=%ld ok=%d\n",
           (long)delegate.table.selectedRow, (long)selectAttempts, selectionSucceeded ? 1 : 0);
    if (!selectionSucceeded) {
        printf("RS-COVER selection_ready=0 selectedRow=%ld attempts=%ld picker_state=unknown variant_checks=0\n",
               (long)delegate.table.selectedRow, (long)selectAttempts);
        RSCheck(NO, @"首行选中在有界等待内生效（selectedRow=%ld，尝试 %ld 次）",
                (long)delegate.table.selectedRow, (long)selectAttempts);
        RSSummary();
        return 1;
    }

    printf("RS-DIM hidden=%s text=%s frame=%.0f,%.0f\n",
           (delegate.dimensionValue.hidden ? @"yes" : @"no").UTF8String,
           (delegate.dimensionValue.stringValue ?: @"").UTF8String,
           delegate.dimensionValue.frame.origin.x, delegate.dimensionValue.frame.origin.y);

    // 详情读取耗时（首行）：直到四个字段全部终态。tSelect 已在上方选行前取，
    // 因此该耗时包含「选行生效 + 详情订阅 + 元数据取回」的完整用户等待。
    RSWait(^BOOL {
        RDMetadataSnapshot *s = delegate.metadataSnapshot;
        if (!s) return NO;
        return s.duration.state != RDMetadataLoading && s.size.state != RDMetadataLoading
            && s.dimensions.state != RDMetadataLoading && s.preview.state != RDMetadataLoading;
    }, 60);
    printf("RS-TIMING detail-first-row elapsed=%.3fs duration=%s size=%s dim=%s preview=%s\n",
           RSTicks() - tSelect,
           (delegate.durationValue.stringValue ?: @"").UTF8String,
           (delegate.sizeValue.stringValue ?: @"").UTF8String,
           (delegate.dimensionValue.stringValue ?: @"").UTF8String,
           (delegate.thumbView.image ? @"image" : @"none").UTF8String);

    // 诊断（2026-09-18 新增）：上面这次等待若超时（实测曾稳定 60s），必须能区分两种
    // 完全不同的原因 —— ① 产品详情面板真的不更新；② 探针自身的等待条件永不满足。
    // 这里打印快照是否存在 + 四个字段各自的真实状态码。
    // 状态码见 RDMetadataState：0=Known 1=Unknown 2=Unsupported 3=Timeout 4=Failed
    // 5=Loading；snapshot=NONE 表示连快照都没有。
    {
        RDMetadataSnapshot *snapAfter = delegate.metadataSnapshot;
        printf("RS-DETAIL-STATE snapshot=%s duration=%d size=%d dim=%d preview=%d selectedRow=%ld detailMedia=%s token=%s\n",
               (snapAfter ? "yes" : "NONE"),
               snapAfter ? (int)snapAfter.duration.state : -1,
               snapAfter ? (int)snapAfter.size.state : -1,
               snapAfter ? (int)snapAfter.dimensions.state : -1,
               snapAfter ? (int)snapAfter.preview.state : -1,
               (long)delegate.table.selectedRow,
               (delegate.detailMedia ? "yes" : "NONE"),
               (delegate.metadataToken ? "yes" : "NONE"));
    }

    // 档位就绪（按**实际模型**判定，不使用旧的就绪前快照）：
    // 生产模型声明的档位数决定“是否必须执行多档断言”；picker 就绪用有界等待（动态腿约 8s）。
    __block NSInteger declaredVariants = 0;
    {
        DetectedMedia *dm = delegate.detailMedia ?: delegate.currentDownloadMedia;
        declaredVariants = (NSInteger)(dm.declaredVariants.count);
        for (DetectedMedia *m in delegate.results)
            if ((NSInteger)m.declaredVariants.count > declaredVariants) declaredVariants = (NSInteger)m.declaredVariants.count;
    }
    BOOL pickerReady = RSWaitUntil(12.0,
        ^BOOL { return delegate.variantPicker.numberOfItems >= 2 && !delegate.variantPicker.hidden; }, nil);
    NSUInteger pickerItems = delegate.variantPicker.numberOfItems;
    BOOL pickerVisible = !delegate.variantPicker.hidden;
    NSMutableArray<NSString *> *pickerTitles = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)pickerItems; i++) [pickerTitles addObject:[delegate.variantPicker itemAtIndex:i].title ?: @""];
    printf("RS-DETAIL pickerHidden=%s items=%lu titles=[%s] link=%s\n",
           (pickerVisible ? @"no" : @"yes").UTF8String, (unsigned long)pickerItems,
           [pickerTitles componentsJoinedByString:@","].UTF8String,
           RSRedactedURL(delegate.linkField.stringValue).UTF8String);
    NSString *coverageReason = nil;
    RSSelectionCoverageState coverage = RSSelectionCoverageDecision(YES, declaredVariants, pickerReady,
                                                                    (NSInteger)pickerItems, pickerVisible, &coverageReason);
    __block NSInteger variantChecks = 0;   // 实际执行的多档/入队/oracle 断言条数

    // 画质切换：每个档位都必须让链接与下载对象同步
    if (coverage == RSSelectionCoverageReady) {
        // 档位计划：在选行后从当前菜单快照「标题 + URL」。此后**每一步都重新解析当前菜单**
        // （生产会重建菜单），绝不再用缓存 count 直接索引。
        NSMutableArray<NSDictionary *> *tierPlan = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)delegate.variantPicker.numberOfItems; i++) {
            NSMenuItem *item = [delegate.variantPicker itemAtIndex:i];
            NSDictionary *rep = [item.representedObject isKindOfClass:NSDictionary.class] ? item.representedObject : nil;
            [tierPlan addObject:@{ @"title": item.title ?: @"",
                                   @"url": ([rep[@"url"] isKindOfClass:NSString.class] ? rep[@"url"] : @"") }];
        }
        for (NSDictionary *plan in tierPlan) {
            NSString *wantTitle = plan[@"title"], *wantURL = plan[@"url"];
            NSString *liveTitle = nil, *liveURL = nil;
            NSInteger idx = RSWaitMenuIndexForTier(delegate.variantPicker, wantTitle, wantURL, 8.0, &liveTitle, &liveURL);
            if (idx == NSNotFound) {
                // 重建后该档位缺失/重排到解析不到：明确 FAIL（不是崩溃，也不是静默跳过）。
                NSMutableArray<NSString *> *liveTitles = [NSMutableArray array];
                for (NSInteger k = 0; k < (NSInteger)delegate.variantPicker.numberOfItems; k++)
                    [liveTitles addObject:[delegate.variantPicker itemAtIndex:k].title ?: @""];
                printf("RS-VARIANT-MISSING planned=%s plannedURL=%s liveItems=%ld liveTitles=[%s] declaredVariants=%ld\n",
                       wantTitle.UTF8String, RSRedactedURL(wantURL).UTF8String,
                       (long)delegate.variantPicker.numberOfItems,
                       [liveTitles componentsJoinedByString:@","].UTF8String,
                       (long)((delegate.detailMedia ?: delegate.currentDownloadMedia).declaredVariants.count));
                RSCheck(NO, @"档位 %@（计划 URL=%@）在菜单重建后仍可解析", wantTitle,
                        RSRedactedURL(wantURL));
                variantChecks++;
                continue;
            }
            [delegate.variantPicker selectItemAtIndex:idx];
            [delegate selectDeclaredVariant:nil];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            NSString *label = liveTitle;
            NSString *link = delegate.linkField.stringValue;
            DetectedMedia *current = delegate.currentDownloadMedia;
            printf("RS-VARIANT label=%s idx=%ld link=%s current=%s\n", label.UTF8String, (long)idx,
                   RSRedactedURL(link).UTF8String, RSRedactedURL(current.mediaURL).UTF8String);
            RSCheck(link.length > 0 && current.mediaURL.length > 0
                    && [[DetectedMedia dedupKeyForURL:link] isEqual:[DetectedMedia dedupKeyForURL:current.mediaURL]],
                    @"画质 %@：详情直链与下载对象一致", label);
            variantChecks++;
            // 该档位的真实下载分辨率（入队对象 → 实际 URL）
            NSString *path = [NSURL URLWithString:current.mediaURL].path.lowercaseString ?: @"";
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{3,4})p" options:0 error:nil];
            NSTextCheckingResult *m = [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
            if (m.numberOfRanges >= 2) {
                NSString *declared = [path substringWithRange:[m rangeAtIndex:1]];
                RSCheck([label hasPrefix:declared],
                        @"画质 %@ 对应下载地址声明 %@p（%@）", label, declared, RSRedactedURL(current.mediaURL));
            }
        }
        // 回到 720p（若存在）后入队，检查入队对象：索引同样从**当前菜单**重新解析。
        NSString *p720Title = nil, *picker720URL = nil;
        NSInteger target = RSWaitMenuIndexForTier(delegate.variantPicker, @"720p", @"", 8.0, &p720Title, &picker720URL);
        if (target == NSNotFound) {
            {
                NSMutableArray<NSString *> *liveTitles2 = [NSMutableArray array];
                for (NSInteger k = 0; k < (NSInteger)delegate.variantPicker.numberOfItems; k++)
                    [liveTitles2 addObject:[delegate.variantPicker itemAtIndex:k].title ?: @""];
                printf("RS-VARIANT-MISSING planned=720p liveItems=%ld liveTitles=[%s] declaredVariants=%ld\n",
                       (long)delegate.variantPicker.numberOfItems,
                       [liveTitles2 componentsJoinedByString:@","].UTF8String,
                       (long)((delegate.detailMedia ?: delegate.currentDownloadMedia).declaredVariants.count));
            }
            RSCheck(NO, @"720p 档位在菜单重建后可解析（用于入队核验）");
            variantChecks++;
        }
        if (target != NSNotFound) {
            picker720URL = picker720URL ?: @"";
            [delegate.variantPicker selectItemAtIndex:target];
            [delegate selectDeclaredVariant:nil];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            [delegate downloadSelected:nil];
            DownloadJob *job = gRealDownload ? realManager.allJobs.lastObject : spy.recordedJobs.lastObject;
            printf("RS-DOWNLOAD enqueued=%lu url=%s name=%s qualityHint=%s master=%s\n",
                   (unsigned long)spy.recordedJobs.count, RSRedactedURL(job.sourceURL.absoluteString).UTF8String,
                   (job.fileName ?: @"").UTF8String, (job.qualityHint ?: @"-").UTF8String,
                   RSRedactedURL(job.streamMasterURL).UTF8String);
            RSCheck(job != nil, @"下载入队成功（%@）", gRealDownload ? @"真实下载" : @"入队记录");
            variantChecks++;
            if (job) {
                RSCheck([[DetectedMedia dedupKeyForURL:job.sourceURL.absoluteString]
                         isEqual:[DetectedMedia dedupKeyForURL:delegate.linkField.stringValue]],
                        @"入队对象与界面显示直链一致（%@）", RSRedactedURL(job.sourceURL.absoluteString));
                variantChecks++;
                // 独立 oracle（2026-09-18 修正 B1/B2）：测试**自己**经安全链取回源主清单并按清单声明的
                // RESOLUTION 归档，构造「720p 档」候选集合，核对 UI 所选档位 URL / 详情直链 / 入队对象
                // 是否都落在该集合内且为同一候选。UI 已有 720p 档位 ⇒ 该语义**必须被核实**：
                // 取源失败、清单未声明该档位、映射错位一律 RSCheck 失败（RSSummary 非零），不再 RS-SKIP 绿灯。
                // 不再回退到任意媒体 URL（避免把非清单正文整文件读入内存）。
                NSString *masterURL = job.streamMasterURL.length ? job.streamMasterURL
                                     : (delegate.currentDownloadMedia.parentMediaURL ?: @"");
                NSString *reason = nil;
                RSQualityVerdict qv = RSQualityVerdictFail;
                RSManifestFetchStatus fs = RSManifestFetchBadURL;
                if (masterURL.length == 0) {
                    reason = @"详情未提供源主清单地址（无 streamMasterURL / parentMediaURL）";
                    printf("RS-MANIFEST master=(缺失)\n");
                } else {
                    RSManifestFetcher *fetcher = [RSManifestFetcher new];
                    NSString *playlist = nil, *fetchDetail = nil;
                    fs = [fetcher fetchSynchronously:[NSURL URLWithString:masterURL] text:&playlist detail:&fetchDetail];
                    printf("RS-MANIFEST master=%s status=%s policyChecks=%lu dnsChecks=%lu redirects=%lu detail=%s\n",
                           RSRedactedURL(masterURL).UTF8String, RSManifestFetchStatusText(fs).UTF8String,
                           (unsigned long)fetcher.policyChecks, (unsigned long)fetcher.dnsChecks,
                           (unsigned long)fetcher.redirectCount, (fetchDetail ?: @"").UTF8String);
                    if (fs == RSManifestFetchOK) {
                        NSArray<NSDictionary *> *manifestVariants =
                            RSParseMasterVariants(playlist, [NSURL URLWithString:masterURL]);
                        NSArray<NSString *> *tier720 = RSTierCandidateURLs(manifestVariants, 720);
                        printf("RS-MANIFEST variants=%lu tier720candidates=%lu\n",
                               (unsigned long)manifestVariants.count, (unsigned long)tier720.count);
                        qv = RSQualityTierMappingVerdict(tier720, picker720URL,
                                                         delegate.linkField.stringValue,
                                                         job.sourceURL.absoluteString, &reason);
                    }
                }
                RSQualityCheckOutcome qo = RSQualityRequiredTierOutcome(fs, qv, &reason);
                RSCheck(qo == RSQualityCheckOutcomePass,
                        @"入队对象属于源清单声明的 720p 档（UI 已存在该档位，必须核实；%@）", reason);
                variantChecks++;
            }
        }
    } else if (RSSelectionCoverageIsFailure(coverage)) {
        // 预期多档却未就绪 / 选行失败：必须 FAIL，绝不能静默跳过仍 PASS。
        RSCheck(NO, @"多档覆盖判定：%@", coverageReason ?: @"未就绪");
    } else {
        // 真实单档/无档位：多档一致性断言**不适用**（明确记录，不产生覆盖绿灯）。
        printf("RS-NOTE 多档一致性断言不适用：%s\n", (coverageReason ?: @"").UTF8String);
    }
    printf("RS-COVER selection_ready=1 selectedRow=%ld attempts=%ld picker_state=%s declaredVariants=%ld pickerItems=%lu variant_checks=%ld coverage=%s\n",
           (long)delegate.table.selectedRow, (long)selectAttempts,
           (coverage == RSSelectionCoverageReady ? "ready" : (coverage == RSSelectionCoverageNotApplicable ? "single_or_none" : "not_ready")),
           (long)declaredVariants, (unsigned long)pickerItems, (long)variantChecks,
           (coverage == RSSelectionCoverageReady ? "executed" : (coverage == RSSelectionCoverageNotApplicable ? "not_applicable" : "failed")));

    // 缓存命中：切到第二行再切回第一行，必须同步恢复且不新增网络请求
    if (rows.count >= 2) {
        DetectedMedia *first = rows[0];
        // 选行同样必须反复选到生效为止（2026-09-18 修正，与首行选中同一处缺陷）：
        // 单次 selectRowIndexes: 会被列表 reload 清成未选中，导致「切到第二行」实际
        // 没切换、后面的同步缓存判定必然失败 —— 那是探针没切成功，不是缓存坏了。
        for (int attempt = 0; attempt < 40 && delegate.table.selectedRow != 1; attempt++) {
            [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        }
        RSWait(^BOOL { return delegate.metadataSnapshot != nil; }, 30);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        NSUInteger before = transport.requests.count;
        double tBack = RSTicks();
        for (int attempt = 0; attempt < 40 && delegate.table.selectedRow != 0; attempt++) {
            [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        }
        BOOL thumbOK = delegate.thumbView.image != nil;
        NSString *durText = delegate.durationValue.stringValue ?: @"";
        BOOL durOK = ![durText isEqualToString:@"获取中…"];
        BOOL synchronous = thumbOK && durOK;
        // 诊断（2026-09-18 新增，只打印不改变断言）：区分“缓存未命中(有新请求)”与
        // “缓存命中但缩略图/时长其中之一未同步恢复”，并给出 metadata 缓存快照的存在与字段状态。
        id svc = delegate.metadataService;
        RDMetadataSnapshot *cachedFirst = [svc respondsToSelector:@selector(cachedSnapshotForMedia:)]
            ? [svc cachedSnapshotForMedia:first] : nil;
        printf("RS-CACHE-DIAG thumb=%s durationText=%s durationOK=%d cachedSnapshot=%s previewState=%d durationState=%d newRequests=%lu\n",
               (thumbOK ? @"image" : @"nil").UTF8String, durText.UTF8String, durOK ? 1 : 0,
               cachedFirst ? "yes" : "NONE",
               cachedFirst ? (int)cachedFirst.preview.state : -1,
               cachedFirst ? (int)cachedFirst.duration.state : -1,
               (unsigned long)(transport.requests.count - before));
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        printf("RS-CACHE sync-restore=%s elapsed=%.3fs newRequests=%lu first=%s\n",
               (synchronous ? @"yes" : @"no").UTF8String, RSTicks() - tBack,
               (unsigned long)(transport.requests.count - before), RSRedactedURL(first.mediaURL).UTF8String);
        RSCheck(synchronous, @"切回同一影片时同步命中缓存（缩略图+时长已显示）");
        RSCheck(transport.requests.count - before <= 1, @"切回缓存命中后未重复读取成功字段（新增请求 %lu）",
                (unsigned long)(transport.requests.count - before));
    }
    // 重复请求统计：同一方法+URL 出现多次即为 App 侧重复读取。
    NSCountedSet *requestCounts = [NSCountedSet setWithArray:transport.requests];
    NSUInteger duplicates = 0;
    for (NSString *request in requestCounts) {
        NSUInteger n = [requestCounts countForObject:request];
        if (n > 1) { duplicates++; printf("RS-DUP x%lu %s\n", (unsigned long)n, request.UTF8String); }
    }
    printf("RS-DUPS total=%lu kinds=%lu requests=%lu\n", (unsigned long)duplicates,
           (unsigned long)requestCounts.count, (unsigned long)transport.requests.count);

    if (gRealDownload && realManager.allJobs.count) {
        DownloadJob *job = realManager.allJobs.lastObject;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1800];
        double t0 = RSTicks();
        while (job.state != DownloadJobStateCompleted && job.state != DownloadJobStateFailed &&
               job.state != DownloadJobStateCancelled && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }
        printf("RS-TIMING download elapsed=%.3fs state=%ld\n", RSTicks() - t0, (long)job.state);
        if (job.state != DownloadJobStateCompleted) {
            printf("RS-DOWNLOAD-FAIL state=%ld error=%s\n", (long)job.state, (job.errorText ?: @"-").UTF8String);
            RSCheck(NO, @"真实下载完成（state=%ld error=%@）", (long)job.state, job.errorText ?: @"-");
        } else {
            NSString *path = job.destinationURL.path;
            unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
            NSString *summary = @"";
            RSInspectLocalFile(path, &summary);
            printf("RS-FILE path=%s size=%llu %s\n", path.UTF8String, size, summary.UTF8String);
            RSCheck([[NSFileManager defaultManager] fileExistsAtPath:path], @"下载文件存在：%@", path);
            RSCheck([summary containsString:@"playable=yes"], @"下载文件可播放（%@）", summary);
            RSCheck([summary containsString:@"video="], @"下载文件含视频轨道（%@）", summary);
            // AVFoundation 报的是显示尺寸（720x1278 可能显示为 719x1278），
            // 以短边判定档位，容差 ±5 像素，并明确排除另一档。
            NSRegularExpression *sizeRe = [NSRegularExpression regularExpressionWithPattern:@"video=(\\d+)x(\\d+)" options:0 error:nil];
            NSTextCheckingResult *sizeMatch = [sizeRe firstMatchInString:summary options:0 range:NSMakeRange(0, summary.length)];
            NSInteger shortSide = 0;
            if (sizeMatch.numberOfRanges >= 3) {
                NSInteger w = [[summary substringWithRange:[sizeMatch rangeAtIndex:1]] integerValue];
                NSInteger h = [[summary substringWithRange:[sizeMatch rangeAtIndex:2]] integerValue];
                shortSide = MIN(w, h);
            }
            if ([job.sourceURL.path containsString:@"720p"])
                RSCheck(labs(shortSide - 720) <= 5, @"实际下载文件确实是 720p（短边 %ld，%@）", (long)shortSide, summary);
            if ([job.sourceURL.path containsString:@"480p"])
                RSCheck(labs(shortSide - 480) <= 5, @"实际下载文件确实是 480p（短边 %ld，%@）", (long)shortSide, summary);
        }
    }

    RSSummary();
    return 0;
}

#pragma mark - 真实下载 + 本地文件校验

// 每次现场测量必须是新鲜网络样本：隔离生产单例的终态记录，避免复用上次运行的
// 完成任务/输出路径而把缓存命中误报为下载耗时。download 与 appdl 两条入口都必须
// 清理——2026-09-10 现场证据：appdl 未清理时返回 elapsed=0.000s 且落盘路径指向
// 上一次运行留下的目录，被误当成一次“极快下载”。
static void RSClearTerminalDownloadRecords(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"CompletedResourceURLs", @"InterruptedDownloadJobs", @"FinishedDownloadJobs"])
        [defaults removeObjectForKey:key];
    [defaults synchronize];
}

static int RSRunDownload(NSString *urlString, NSString *referer, NSString *title, double expectHeight, NSString *destDir) {
    RSClearTerminalDownloadRecords();
    // 生产单例：真实 SessionDownloadBackend（分段/单连接、并发槽位、校验、落盘）。
    // 隔离夹具（RD_PROBE_ALLOW_LOOPBACK=1）已在 main 里更早安装，此处不再重复。
    DownloadManager *manager = [DownloadManager sharedManager];
    manager.defaultReferer = referer;
    NSURL *folder = destDir.length ? [NSURL fileURLWithPath:destDir] : [NSURL fileURLWithPath:NSTemporaryDirectory()];
    // 与真实 UI 流程对齐（downloadSelected:）：清单地址按 Manifest 入队并保留
    // streamMasterURL，走 RDStreamDownloadTask；否则单连接路径会拒绝 m3u8/mpd
    //（"audio/mpegurl，不是视频文件"）——那是真实 App 的正确防呆，不是缺陷。
    NSURL *source = [NSURL URLWithString:urlString];
    DownloadResourceKind kind = DownloadResourceVideo;
    NSString *srcPath = (source.path ?: @"").lowercaseString;
    if ([srcPath hasSuffix:@".m3u8"] || [srcPath hasSuffix:@".mpd"]) {
        kind = DownloadResourceManifest;
    }
    DownloadJob *job = [manager enqueueItemWithSourceURL:source folder:folder
                                           preferredName:title sourcePageURL:referer resourceKind:kind
                                          expectedLength:0];
    if (kind == DownloadResourceManifest) job.streamMasterURL = source.absoluteString;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:900];
    double t0 = RSTicks();
    while (job.state != DownloadJobStateCompleted && job.state != DownloadJobStateFailed
           && job.state != DownloadJobStateCancelled && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    printf("RS-TIMING download elapsed=%.3fs state=%ld\n", RSTicks() - t0, (long)job.state);
    if (job.state != DownloadJobStateCompleted) {
        printf("RS-RESULT FAIL 下载未完成 state=%ld error=%s\n", (long)job.state, (job.errorText ?: @"-").UTF8String);
        return 1;
    }
    NSString *path = job.destinationURL.path;
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    NSString *summary = @"";
    RSInspectLocalFile(path, &summary);
    printf("RS-FILE path=%s size=%llu %s\n", path.UTF8String, size, summary.UTF8String);
    RSCheck([[NSFileManager defaultManager] fileExistsAtPath:path], @"下载文件存在：%@", path);
    RSCheck([summary containsString:@"playable=yes"], @"下载文件可播放（%@）", summary);
    if (expectHeight > 0) {
        NSString *expect = [NSString stringWithFormat:@"video=.*x%ld", (long)expectHeight];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:expect options:0 error:nil];
        BOOL ok = [re firstMatchInString:summary options:0 range:NSMakeRange(0, summary.length)] != nil;
        RSCheck(ok, @"下载文件实际高度为 %ld（%@）", (long)expectHeight, summary);
    }
    RSSummary();
    return 0;
}

#pragma mark - 画质选择 → 入队 URL 端到端一致性（只读边界观测，不修改生产代码）

// 打印“选择器显示什么 / 链接是什么 / 详情对象是谁 / 入队对象是谁”四项快照。
// 用于区分：选择器被异步回调改回（A）/ 显示与实际选中不属于同一对象（B）/ 入队用了错对象（C）。
static void RSLogVariantState(ResourceDetectorAppDelegate *d, const char *tag) {
    DetectedMedia *cur = d.currentDownloadMedia;
    DetectedMedia *det = d.detailMedia;
    NSInteger idx = d.variantPicker.indexOfSelectedItem;
    NSString *picked = (idx >= 0 && idx < (NSInteger)d.variantPicker.numberOfItems)
        ? [d.variantPicker itemAtIndex:idx].title : @"(none)";
    NSDictionary *v = (idx >= 0 && idx < (NSInteger)d.variantPicker.numberOfItems)
        ? [d.variantPicker itemAtIndex:idx].representedObject : nil;
    NSString *pickedURL = [v isKindOfClass:NSDictionary.class] ? v[@"url"] : @"";
    DetectedMedia *sel = d.selectedVariantMedia;
    BOOL linkEqCur = (d.linkField.stringValue.length && cur.mediaURL.length)
        && [[DetectedMedia dedupKeyForURL:d.linkField.stringValue] isEqual:[DetectedMedia dedupKeyForURL:cur.mediaURL]];
    BOOL pickerEqCur = (pickedURL.length && cur.mediaURL.length)
        && [[DetectedMedia dedupKeyForURL:pickedURL] isEqual:[DetectedMedia dedupKeyForURL:cur.mediaURL]];
    printf("RS-VCHK %s picker=%s(%ld) link=%s detail=%s current=%s sel=%s dim=%s(%ldx%ld) size=%s bytes=%lld linkEqCurrent=%d pickerEqCurrent=%d\n",
           tag, picked.UTF8String, (long)idx,
           RSRedactedURL(d.linkField.stringValue).UTF8String,
           RSRedactedURL(det.mediaURL).UTF8String,
           RSRedactedURL(cur.mediaURL).UTF8String,
           RSRedactedURL(sel.mediaURL).UTF8String,
           (d.dimensionValue.stringValue ?: @"").UTF8String,
           (long)cur.pixelWidth, (long)cur.pixelHeight,
           (d.sizeValue.stringValue ?: @"").UTF8String,
           (long long)cur.sizeBytes, linkEqCur ? 1 : 0, pickerEqCur ? 1 : 0);
    fflush(stdout);
}

static int RSRunVariantCheck(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) { printf("RS-RESULT FAIL 网址无效\n"); return 2; }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZZHotkeyGuideAnswered"];
    RSCountingTransport *transport = [RSCountingTransport new];
    ResourceDetectorAppDelegate *delegate = [ResourceDetectorAppDelegate new];
    [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:@"RSLaunch" object:nil]];
    if ([[[NSProcessInfo processInfo] environment][@"RD_PROBE_HEADLESS"] isEqualToString:@"1"]) {
        [delegate.window orderOut:nil];
    }
    delegate.metadataService = [[RDMetadataService alloc] initWithTransport:transport];
    RSEnqueueSpy *spy = [RSEnqueueSpy new];
    delegate.downloadManager = spy;
    delegate.urlField.stringValue = urlString;
    [delegate scan:nil];
    BOOL finished = RSWait(^BOOL { return delegate.scanning == NO; }, 120);
    printf("RS-VCHK probe-finished=%d\n", finished ? 1 : 0);
    NSArray<DetectedMedia *> *rows = [delegate visibleMedia];
    printf("RS-VCHK rows=%lu\n", (unsigned long)rows.count);
    if (rows.count == 0) { printf("RS-RESULT FAIL 无可选行\n"); return 1; }
    NSUInteger videoRow = NSNotFound;
    for (NSUInteger i = 0; i < rows.count; i++) if (rows[i].resourceKind != RDResourceKindImage) { videoRow = i; break; }
    if (videoRow == NSNotFound) { RSCheck(NO, @"[VCHK] 存在视频行"); RSSummary(); return 1; }
    // 选行必须反复重试直到真正生效（与 app 模式同一缺陷：reloadData 会把选中清成 -1），
    // 并打印实证；超时按失败处理，绝不 skip。
    __block NSInteger selectAttempts = 0;
    BOOL rowSelected = RSWaitUntil(10.0,
        ^BOOL { return delegate.table.selectedRow == (NSInteger)videoRow; },
        ^{ selectAttempts++; [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:videoRow] byExtendingSelection:NO]; });
    printf("RS-VCHK row-select videoRow=%lu selectedRow=%ld attempts=%ld ok=%d\n",
           (unsigned long)videoRow, (long)delegate.table.selectedRow, (long)selectAttempts, rowSelected ? 1 : 0);
    RSCheck(rowSelected, @"[VCHK] 行选中在 10s 内生效（期望 selectedRow=%lu，实际 %ld，尝试 %ld 次）",
            (unsigned long)videoRow, (long)delegate.table.selectedRow, (long)selectAttempts);
    if (!rowSelected) { RSSummary(); return 1; }
    // 画质下拉就绪（不靠固定 sleep）：行选中后详情/选择器由异步腿回填，需有界等待。
    BOOL pickerReady = RSWaitUntil(10.0,
        ^BOOL { return delegate.variantPicker.numberOfItems >= 2 && !delegate.variantPicker.hidden; }, nil);
    NSMutableArray<NSString *> *vTitles = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)delegate.variantPicker.numberOfItems; i++)
        [vTitles addObject:[delegate.variantPicker itemAtIndex:i].title ?: @""];
    printf("RS-VCHK picker-ready items=%ld hidden=%d ok=%d titles=[%s]\n",
           (long)delegate.variantPicker.numberOfItems, delegate.variantPicker.hidden ? 1 : 0,
           pickerReady ? 1 : 0, [vTitles componentsJoinedByString:@","].UTF8String);
    RSCheck(pickerReady, @"[VCHK] 画质下拉在 10s 内就绪（items=%ld hidden=%d）",
            (long)delegate.variantPicker.numberOfItems, delegate.variantPicker.hidden ? 1 : 0);
    if (!pickerReady) { RSSummary(); return 1; }
    RSLogVariantState(delegate, "row-selected");

    NSInteger target = -1;
    for (NSInteger i = 0; i < (NSInteger)delegate.variantPicker.numberOfItems; i++)
        if ([[delegate.variantPicker itemAtIndex:i].title isEqualToString:@"1080p"]) target = i;
    if (target < 0) {
        RSCheck(NO, @"[VCHK] 选择器存在 1080p 档位（实际 titles=[%s]）", [vTitles componentsJoinedByString:@","].UTF8String);
        RSSummary();
        return 1;
    }
    // 模拟用户操作：先改选择器当前项，再触发生产 action
    [delegate.variantPicker selectItemAtIndex:target];
    [delegate selectDeclaredVariant:nil];
    RSLogVariantState(delegate, "t+0s");

    // 关键：用户选完到点下载之间会有异步元数据/清单腿回来，在这里按时间点采样
    double marks[] = {1.0, 3.0, 6.0, 10.0, 15.0};
    double prev = 0;
    for (int i = 0; i < 5; i++) {
        double wait = marks[i] - prev; prev = marks[i];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
        char tag[32]; snprintf(tag, sizeof(tag), "t+%.0fs", marks[i]);
        RSLogVariantState(delegate, tag);
    }

    // 真实入队路径（spy：不产生网络下载、不改用户记录）
    [delegate downloadSelected:nil];
    DownloadJob *job = spy.recordedJobs.lastObject;
    NSDictionary *v = (target >= 0 && target < (NSInteger)delegate.variantPicker.numberOfItems)
        ? [delegate.variantPicker itemAtIndex:target].representedObject : nil;
    NSString *pickedURL = [v isKindOfClass:NSDictionary.class] ? v[@"url"] : @"";
    printf("RS-VCHK enqueue url=%s expected=%lld quality=%s name=%s\n",
           RSRedactedURL(job.sourceURL.absoluteString).UTF8String, (long long)job.expectedContentLength,
           (job.qualityHint ?: @"-").UTF8String, (job.fileName ?: @"").UTF8String);
    RSCheck(job != nil, @"1080p 选择后确实入队了一个任务");
    RSCheck(job != nil && pickedURL.length
            && [[DetectedMedia dedupKeyForURL:job.sourceURL.absoluteString] isEqual:[DetectedMedia dedupKeyForURL:pickedURL]],
            @"入队 sourceURL 等于用户选中的 1080p 档位（实际入队=%s）",
            RSRedactedURL(job.sourceURL.absoluteString).UTF8String);
    // 独立 oracle 交叉核对（与 app 模式共用 RSQualityTierMappingVerdict 同一实现）：
    // 期望的 1080p 高度/URL 来自测试自己经安全链取回并解析的源主清单，不是 UI 或入队对象自身，
    // 因此不是"两个同源对象互比"。UI 已有 1080p 档位 ⇒ 必须核实：取源失败/清单未声明该档位/
    // 映射错位一律 RSCheck 失败（B2）。不再回退任意媒体 URL。
    NSString *vMaster = job.streamMasterURL.length ? job.streamMasterURL
                       : (delegate.currentDownloadMedia.parentMediaURL ?: @"");
    NSString *vReason = nil;
    RSQualityVerdict vq = RSQualityVerdictFail;
    RSManifestFetchStatus vfs = RSManifestFetchBadURL;
    if (vMaster.length == 0) {
        printf("RS-MANIFEST master=(缺失)\n");
    } else {
        RSManifestFetcher *vFetcher = [RSManifestFetcher new];
        NSString *vPlaylist = nil, *vDetail = nil;
        vfs = [vFetcher fetchSynchronously:[NSURL URLWithString:vMaster] text:&vPlaylist detail:&vDetail];
        printf("RS-MANIFEST master=%s status=%s policyChecks=%lu dnsChecks=%lu redirects=%lu detail=%s\n",
               RSRedactedURL(vMaster).UTF8String, RSManifestFetchStatusText(vfs).UTF8String,
               (unsigned long)vFetcher.policyChecks, (unsigned long)vFetcher.dnsChecks,
               (unsigned long)vFetcher.redirectCount, (vDetail ?: @"").UTF8String);
        if (vfs == RSManifestFetchOK) {
            NSArray<NSDictionary *> *mv = RSParseMasterVariants(vPlaylist, [NSURL URLWithString:vMaster]);
            NSArray<NSString *> *tier1080 = RSTierCandidateURLs(mv, 1080);
            printf("RS-MANIFEST variants=%lu tier1080candidates=%lu\n",
                   (unsigned long)mv.count, (unsigned long)tier1080.count);
            vq = RSQualityTierMappingVerdict(tier1080, pickedURL, delegate.linkField.stringValue,
                                             job.sourceURL.absoluteString, &vReason);
        }
    }
    RSQualityCheckOutcome vOutcome = RSQualityRequiredTierOutcome(vfs, vq, &vReason);
    RSCheck(vOutcome == RSQualityCheckOutcomePass,
            @"[VCHK] 入队对象属于源清单声明的 1080p 档（UI 已存在该档位，必须核实；%@）", vReason);
    RSSummary();
    return 0;
}

// 真实站点竞态复现：在**临时结果（首屏）阶段**就选中 1080p，随后让异步腿返回并整体
// 重建结果列表。修复前：重建后 currentDownloadMedia 被换成 480p 行对象，界面仍显示
// 1080p，入队却是 480p。修复后：选择器 / 链接 / 详情 / 入队目标四者同步在 1080p。
static int RSRunVariantRace(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) { printf("RS-RESULT FAIL 网址无效\n"); return 2; }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZZHotkeyGuideAnswered"];
    RSCountingTransport *transport = [RSCountingTransport new];
    ResourceDetectorAppDelegate *delegate = [ResourceDetectorAppDelegate new];
    [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:@"RSLaunch" object:nil]];
    if ([[[NSProcessInfo processInfo] environment][@"RD_PROBE_HEADLESS"] isEqualToString:@"1"]) {
        [delegate.window orderOut:nil];
    }
    delegate.metadataService = [[RDMetadataService alloc] initWithTransport:transport];
    RSEnqueueSpy *spy = [RSEnqueueSpy new];
    delegate.downloadManager = spy;
    delegate.urlField.stringValue = urlString;
    [delegate scan:nil];
    // 只等首屏临时列表出现（此时扫描仍在进行，异步腿还没回来）
    BOOL preview = RSWait(^BOOL { return delegate.results.count > 0; }, 60);
    printf("RS-RACE preview=%d scanning=%d rows=%lu\n", preview ? 1 : 0, delegate.scanning ? 1 : 0,
           (unsigned long)[delegate visibleMedia].count);
    if (!preview) { printf("RS-RESULT FAIL 首屏未出现\n"); return 1; }
    NSArray<DetectedMedia *> *rows = [delegate visibleMedia];
    NSUInteger videoRow = NSNotFound;
    for (NSUInteger i = 0; i < rows.count; i++) if (rows[i].resourceKind != RDResourceKindImage) { videoRow = i; break; }
    if (videoRow == NSNotFound) { printf("RS-RESULT FAIL 首屏无视频行\n"); return 1; }
    [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:videoRow] byExtendingSelection:NO];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSInteger target = -1;
    for (NSInteger i = 0; i < (NSInteger)delegate.variantPicker.numberOfItems; i++)
        if ([[delegate.variantPicker itemAtIndex:i].title isEqualToString:@"1080p"]) target = i;
    printf("RS-RACE picker-before-select items=%ld target1080=%ld scanning=%d\n",
           (long)delegate.variantPicker.numberOfItems, (long)target, delegate.scanning ? 1 : 0);
    if (target < 0) { printf("RS-RESULT FAIL 首屏选择器无 1080p\n"); return 1; }
    [delegate.variantPicker selectItemAtIndex:target];
    [delegate selectDeclaredVariant:nil];
    RSLogVariantState(delegate, "race-selected");
    // 等最终结果重建列表（异步腿返回）
    BOOL finished = RSWait(^BOOL { return delegate.scanning == NO; }, 120);
    printf("RS-RACE finished=%d\n", finished ? 1 : 0);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
    RSLogVariantState(delegate, "race-after-reload");
    [delegate downloadSelected:nil];
    DownloadJob *job = spy.recordedJobs.lastObject;
    printf("RS-RACE enqueue url=%s expected=%lld\n",
           RSRedactedURL(job.sourceURL.absoluteString).UTF8String, (long long)job.expectedContentLength);
    RSCheck(job != nil && [job.sourceURL.path containsString:@"1080p"],
            @"竞态下入队目标仍是用户选中的 1080p（实际 %s）",
            RSRedactedURL(job.sourceURL.absoluteString).UTF8String);
    RSCheck(delegate.currentDownloadMedia == nil ? NO :
            ([[DetectedMedia dedupKeyForURL:delegate.currentDownloadMedia.mediaURL]
              isEqual:[DetectedMedia dedupKeyForURL:delegate.linkField.stringValue]]),
            @"竞态后 currentDownloadMedia 与链接仍一致");
    RSCheck([delegate.variantPicker.selectedItem.title isEqualToString:@"1080p"],
            @"竞态后选择器仍显示 1080p（实际 %s）", delegate.variantPicker.selectedItem.title.UTF8String);
    RSSummary();
    return 0;
}

// 生产下载后端只在 DownloadManager.m 内声明；探针需要它来建隔离下载管理器。
// 仅测试夹具使用，不改变生产可见接口。
@interface SessionDownloadBackend : NSObject <RDDownloadBackend>
@end

// 完全隔离的真实下载：不碰用户记录/偏好，用独立 tempRoot + store:nil。
// 目的：证明“选中 1080p ⇒ 下载的 URL 与最终文件分辨率都是 1080p”。
static int RSRunDownloadIsolated(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) { printf("RS-RESULT FAIL 网址无效\n"); return 2; }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZZHotkeyGuideAnswered"];
    RSCountingTransport *transport = [RSCountingTransport new];
    ResourceDetectorAppDelegate *delegate = [ResourceDetectorAppDelegate new];
    [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:@"RSLaunch" object:nil]];
    if ([[[NSProcessInfo processInfo] environment][@"RD_PROBE_HEADLESS"] isEqualToString:@"1"]) {
        [delegate.window orderOut:nil];
    }
    delegate.metadataService = [[RDMetadataService alloc] initWithTransport:transport];
    RSEnqueueSpy *spy = [RSEnqueueSpy new];
    delegate.downloadManager = spy;
    delegate.urlField.stringValue = urlString;
    [delegate scan:nil];
    BOOL preview = RSWait(^BOOL { return delegate.results.count > 0; }, 60);
    if (!preview) { printf("RS-RESULT FAIL 首屏未出现\n"); return 1; }
    NSArray<DetectedMedia *> *rows = [delegate visibleMedia];
    NSUInteger videoRow = NSNotFound;
    for (NSUInteger i = 0; i < rows.count; i++) if (rows[i].resourceKind != RDResourceKindImage) { videoRow = i; break; }
    if (videoRow == NSNotFound) { printf("RS-RESULT FAIL 无视频行\n"); return 1; }
    [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:videoRow] byExtendingSelection:NO];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    // 竞态：临时结果阶段就选 1080p
    NSInteger target = -1;
    for (NSInteger i = 0; i < (NSInteger)delegate.variantPicker.numberOfItems; i++)
        if ([[delegate.variantPicker itemAtIndex:i].title isEqualToString:@"1080p"]) target = i;
    if (target < 0) { printf("RS-RESULT FAIL 无 1080p\n"); return 1; }
    [delegate.variantPicker selectItemAtIndex:target];
    [delegate selectDeclaredVariant:nil];
    RSWait(^BOOL { return delegate.scanning == NO; }, 120);
    // 等 1080p 元数据回填（真实节奏：用户看到大小再下载）
    RSWait(^BOOL { return delegate.currentDownloadMedia.sizeBytes > 0; }, 30);
    RSLogVariantState(delegate, "iso-before-download");
    DetectedMedia *media = delegate.currentDownloadMedia;
    RSCheck(media != nil && [media.mediaURL containsString:@"1080p"],
            @"入队前选中的确实是 1080p 档位（%s）", RSRedactedURL(media.mediaURL).UTF8String);

    // 输出目录可用环境变量 RD_REALSITE_OUT 覆盖，未设置时相对当前工作目录取 build/quality-20260912
    NSString *base = NSProcessInfo.processInfo.environment[@"RD_REALSITE_OUT"];
    if (base.length == 0) { base = @"build/quality-20260912"; }
    NSURL *isoTmp = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"iso-tmp"]];
    NSURL *dest = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"iso-dest"]];
    [[NSFileManager defaultManager] createDirectoryAtURL:dest withIntermediateDirectories:YES attributes:nil error:nil];
    // 隔离 store：独立 suite，绝不触碰用户真实下载记录。
    NSString *isoSuite = @"com.sevenzz.probe.iso-1080p";
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:isoSuite];
    DownloadStore *isoStore = [[DownloadStore alloc] initWithUserDefaults:[[NSUserDefaults alloc] initWithSuiteName:isoSuite]];
    DownloadManager *iso = [[DownloadManager alloc] initWithBackend:[SessionDownloadBackend new]
                                                           tempRoot:isoTmp store:isoStore];
    iso.defaultReferer = urlString;
    DownloadJob *job = [iso enqueueItemWithSourceURL:[NSURL URLWithString:media.mediaURL]
                                             folder:dest
                                      preferredName:@"iso-1080p"
                                      sourcePageURL:urlString
                                       resourceKind:DownloadResourceVideo
                                     expectedLength:media.sizeBytes];
    printf("RS-ISO enqueue url=%s expected=%lld\n",
           RSRedactedURL(job.sourceURL.absoluteString).UTF8String, (long long)job.expectedContentLength);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1800];
    double t0 = RSTicks();
    while (job.state != DownloadJobStateCompleted && job.state != DownloadJobStateFailed
           && job.state != DownloadJobStateCancelled && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    printf("RS-TIMING iso-download elapsed=%.3fs state=%ld\n", RSTicks() - t0, (long)job.state);
    RSCheck(job.state == DownloadJobStateCompleted, @"隔离下载完成（state=%ld error=%@）",
            (long)job.state, job.errorText ?: @"-");
    if (job.state == DownloadJobStateCompleted) {
        NSString *path = job.destinationURL.path;
        unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
        NSString *summary = nil;
        RSInspectLocalFile(path, &summary);
        printf("RS-FILE path=%s size=%llu %s\n", path.UTF8String, size, summary.UTF8String);
        RSCheck([summary containsString:@"playable=yes"], @"隔离下载文件可播放（%@）", summary);
        RSCheck([summary containsString:@"video=1920x1080"], @"最终文件分辨率确实是 1920x1080（%@）", summary);
    }
    RSSummary();
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 3) {
            printf("usage: RealSiteProbe <app|static|dynamic|hybrid> <url>\n");
            printf("       RealSiteProbe download <url> <referer> <title> [expectHeight] [destDir]\n");
            printf("       RealSiteProbe selfcheck <忽略的占位参数>   # 离线自检（无网络）：画质档位判定正反用例 + spy 契约\n");
            return 2;
        }
        // 必须在任何 applicationDidFinishLaunching / sharedManager 调用之前安装（含下面
        // 的 RD_PROBE_ALLOW_LOOPBACK 夹具块）。appdl 是刻意进行真实下载的模式，保持原样。
        {
            NSString *m0 = [NSString stringWithUTF8String:argv[1]];
            // 逃生 env 不得“继承即生效”：无论外部是否设置，先在本测试进程内清除，
            // 并且只允许 appdl（刻意真实下载模式）保留真实 sharedManager；其余模式
            // （含 app/variantcheck/variantrace/downloadiso/selfcheck）一律强制隔离。
            BOOL envEscapeWasSet =
                [NSProcessInfo.processInfo.environment[@"RD_PROBE_ALLOW_REAL_SHARED_MANAGER"] length] > 0;
            if (envEscapeWasSet) {
                unsetenv("RD_PROBE_ALLOW_REAL_SHARED_MANAGER");
                printf("RS-NOTE 已清除继承的 RD_PROBE_ALLOW_REAL_SHARED_MANAGER（本进程内不再生效）\n");
            }
            BOOL allowReal = [m0 isEqualToString:@"appdl"] || [m0 isEqualToString:@"download"];
            if (!allowReal) {
                RSInstallIsolatedSharedManager();
                printf("RS-NOTE 已替换 +[DownloadManager sharedManager] 为本进程隔离替身\n");
            } else {
                printf("RS-NOTE 保留真实 +[DownloadManager sharedManager]（appdl 真实下载模式）\n");
            }
        }
        gRSStart = [NSDate date].timeIntervalSince1970;
        // 隔离夹具必须在任何入队/端点校验之前安装（校验发生在 enqueue 内部），
        // 且必须同时装到 manager 与后端——两者各自持有独立的 URLPolicy 实例。
        if ([[[NSProcessInfo processInfo] environment][@"RD_PROBE_ALLOW_LOOPBACK"] isEqualToString:@"1"]) {
            DownloadManager *mgr = [DownloadManager sharedManager];
            mgr.urlPolicy = [RDProbeLoopbackFixturePolicy new];
            printf("RS-NOTE 已启用隔离夹具策略（仅放行解析到 127.0.0.1 的目标；生产默认不生效）\n");
            RSInstallLoopbackFixtureOnBackend(mgr);
            RSInstallLocalTrustOnBackend(mgr);
            RSInstallLoopbackFixtureOnCapabilityProbe(mgr);
            RSInstrumentCapabilityProbe(mgr);
        }
        [NSApplication sharedApplication];
        if ([[[NSProcessInfo processInfo] environment][@"RD_PROBE_HEADLESS"] isEqualToString:@"1"]) {
            (void)[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *url = [NSString stringWithUTF8String:argv[2]];
        if ([mode isEqualToString:@"download"]) {
            if (argc < 5) { printf("usage: RealSiteProbe download <url> <referer> <title> [expectHeight] [destDir]\n"); return 2; }
            NSString *referer = [NSString stringWithUTF8String:argv[3]];
            NSString *title = [NSString stringWithUTF8String:argv[4]];
            double expect = argc > 5 ? atof(argv[5]) : 0;
            NSString *dest = argc > 6 ? [NSString stringWithUTF8String:argv[6]] : nil;
            // 注意：download 分支在此直接 return，合流组件注入必须放在 return 之前
            //（此前放在下方合并块里，download 路径永远走不到 —— 2026-09-19 现场 9 站复现）。
            NSString *muxerPathDL = [[NSProcessInfo processInfo] environment][@"RD_PROBE_MUXER_PATH"];
            if (muxerPathDL.length && [[NSFileManager defaultManager] isExecutableFileAtPath:muxerPathDL]) {
                [DownloadManager sharedManager].rd_streamMuxerURL = [NSURL fileURLWithPath:muxerPathDL];
                printf("RS-NOTE 注入真实合流组件（RD_PROBE_MUXER_PATH）：%s\n", muxerPathDL.UTF8String);
            }
            return RSRunDownload(url, referer, title, expect, dest);
        }
        if ([mode isEqualToString:@"selfcheck"]) return RSSelfCheck();
        if ([mode isEqualToString:@"app"]) return RSRunApp(url);
        if ([mode isEqualToString:@"variantcheck"]) return RSRunVariantCheck(url);
        if ([mode isEqualToString:@"variantrace"]) return RSRunVariantRace(url);
        if ([mode isEqualToString:@"downloadiso"]) return RSRunDownloadIsolated(url);
        if ([mode isEqualToString:@"appdl"] || [mode isEqualToString:@"download"]) {
            // 测试二进制没有主 bundle，生产代码按 mainBundle 找 MediaTools/ffmpeg 会找不到
            // （2026-09-19 现场：19 站 HLS 合流全部"离线视频合成组件缺失"）。
            // RD_PROBE_MUXER_PATH 显式注入仓库内真实 ffmpeg —— 走的是生产合流路径，非替身。
            NSString *muxerPath = [[NSProcessInfo processInfo] environment][@"RD_PROBE_MUXER_PATH"];
            if (muxerPath.length) {
                if ([[NSFileManager defaultManager] isExecutableFileAtPath:muxerPath]) {
                    [DownloadManager sharedManager].rd_streamMuxerURL = [NSURL fileURLWithPath:muxerPath];
                    printf("RS-NOTE 注入真实合流组件（RD_PROBE_MUXER_PATH）：%s\n", muxerPath.UTF8String);
                } else {
                    printf("RS-NOTE RD_PROBE_MUXER_PATH 指向的文件不可执行，忽略：%s\n", muxerPath.UTF8String);
                }
            }
        }
        if ([mode isEqualToString:@"appdl"]) {
            gRealDownload = YES;
            RSClearTerminalDownloadRecords();
            if (argc > 3) gDownloadDir = [NSString stringWithUTF8String:argv[3]];
            return RSRunApp(url);
        }
        if ([mode isEqualToString:@"dom"]) return RSRunDOMDump(url);
        return RSRunProbeChain(mode, url);
    }
}
