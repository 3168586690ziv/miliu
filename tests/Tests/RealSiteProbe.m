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
#import "DownloadCapabilityProbe.h"
#import <objc/runtime.h>

static NSMutableArray<NSString *> *gFailures;
static double gRSStart;

// 隔离夹具策略（仅测试）：只放行**解析到 127.0.0.1** 的目标，其余一律交回生产策略判定。
// 之所以按“解析结果”而不是按主机名放行：本地模型服务器需要一个像公网主机名的
// 名字（如 127-0-0-1.nip.io）才能同时通过探针与后端两处独立的 URLPolicy 实例，
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
@property (nonatomic, strong) NSMutableArray<DownloadJob *> *jobs;
@end
@implementation RSEnqueueSpy
- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url folder:(NSURL *)folder preferredName:(NSString *)name
                            sourcePageURL:(NSString *)sourcePageURL resourceKind:(DownloadResourceKind)kind
                           expectedLength:(int64_t)length {
    DownloadJob *job = [DownloadJob new];
    job.sourceURL = url; job.fileName = name; job.resourceKind = kind; job.sourcePageURL = sourcePageURL;
    if (!self.jobs) self.jobs = [NSMutableArray array];
    [self.jobs addObject:job];
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
    RSCheck(filmRows == 1, @"同一部影片只有一个视频选项（带画质声明的视频行 %lu，视频行合计 %lu）",
            (unsigned long)filmRows, (unsigned long)videoRows.count);

    RSCheck(finished, @"真实网址探测在 120s 内完成（%.1fs）", probeSeconds);
    RSCheck(media.count > 0, @"真实网址探测到媒体资源（%lu）", (unsigned long)media.count);
    if (rows.count == 0) { RSSummary(); return 0; }

    // 选中第一行：走生产 tableViewSelectionDidChange → configureDetailForMedia
    [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    NSUInteger pickerItems = delegate.variantPicker.numberOfItems;
    BOOL pickerVisible = !delegate.variantPicker.hidden;
    NSMutableArray<NSString *> *pickerTitles = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)pickerItems; i++) [pickerTitles addObject:[delegate.variantPicker itemAtIndex:i].title];
    printf("RS-DETAIL pickerHidden=%s items=%lu titles=[%s] link=%s\n",
           (pickerVisible ? @"no" : @"yes").UTF8String, (unsigned long)pickerItems,
           [pickerTitles componentsJoinedByString:@","].UTF8String,
           RSRedactedURL(delegate.linkField.stringValue).UTF8String);
    printf("RS-DIM hidden=%s text=%s frame=%.0f,%.0f\n",
           (delegate.dimensionValue.hidden ? @"yes" : @"no").UTF8String,
           (delegate.dimensionValue.stringValue ?: @"").UTF8String,
           delegate.dimensionValue.frame.origin.x, delegate.dimensionValue.frame.origin.y);

    // 详情读取耗时（首行）：直到四个字段全部终态
    double tSelect = RSTicks();
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

    // 画质切换：每个档位都必须让链接与下载对象同步
    if (pickerVisible && pickerItems >= 2) {
        for (NSInteger i = 0; i < (NSInteger)pickerItems; i++) {
            [delegate.variantPicker selectItemAtIndex:i];
            [delegate selectDeclaredVariant:nil];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSString *label = [delegate.variantPicker itemAtIndex:i].title;
            NSString *link = delegate.linkField.stringValue;
            DetectedMedia *current = delegate.currentDownloadMedia;
            printf("RS-VARIANT label=%s link=%s current=%s\n", label.UTF8String,
                   RSRedactedURL(link).UTF8String, RSRedactedURL(current.mediaURL).UTF8String);
            RSCheck(link.length > 0 && current.mediaURL.length > 0
                    && [[DetectedMedia dedupKeyForURL:link] isEqual:[DetectedMedia dedupKeyForURL:current.mediaURL]],
                    @"画质 %@：详情直链与下载对象一致", label);
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
        // 回到 720p（若存在）后入队，检查入队对象
        NSInteger target = -1;
        for (NSInteger i = 0; i < (NSInteger)pickerItems; i++)
            if ([[delegate.variantPicker itemAtIndex:i].title isEqualToString:@"720p"]) target = i;
        if (target >= 0) {
            [delegate.variantPicker selectItemAtIndex:target];
            [delegate selectDeclaredVariant:nil];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            [delegate downloadSelected:nil];
            DownloadJob *job = gRealDownload ? realManager.allJobs.lastObject : spy.jobs.lastObject;
            printf("RS-DOWNLOAD enqueued=%lu url=%s name=%s qualityHint=%s master=%s\n",
                   (unsigned long)spy.jobs.count, RSRedactedURL(job.sourceURL.absoluteString).UTF8String,
                   (job.fileName ?: @"").UTF8String, (job.qualityHint ?: @"-").UTF8String,
                   RSRedactedURL(job.streamMasterURL).UTF8String);
            RSCheck(job != nil, @"下载入队成功（%@）", gRealDownload ? @"真实下载" : @"入队记录");
            if (job) {
                RSCheck([[DetectedMedia dedupKeyForURL:job.sourceURL.absoluteString]
                         isEqual:[DetectedMedia dedupKeyForURL:delegate.linkField.stringValue]],
                        @"入队对象与界面显示直链一致（%@）", RSRedactedURL(job.sourceURL.absoluteString));
                RSCheck([job.sourceURL.path containsString:@"720p"], @"入队对象确实是 720p（%@）",
                        RSRedactedURL(job.sourceURL.absoluteString));
            }
        }
    }

    // 缓存命中：切到第二行再切回第一行，必须同步恢复且不新增网络请求
    if (rows.count >= 2) {
        DetectedMedia *first = rows[0];
        [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        RSWait(^BOOL { return delegate.metadataSnapshot != nil; }, 30);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        NSUInteger before = transport.requests.count;
        double tBack = RSTicks();
        [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        BOOL synchronous = delegate.thumbView.image != nil
            && ![delegate.durationValue.stringValue isEqualToString:@"获取中…"];
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
    DownloadJob *job = [manager enqueueItemWithSourceURL:[NSURL URLWithString:urlString] folder:folder
                                           preferredName:title sourcePageURL:referer resourceKind:DownloadResourceVideo
                                          expectedLength:0];
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
    if (videoRow == NSNotFound) { printf("RS-RESULT FAIL 无视频行\n"); return 1; }
    [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:videoRow] byExtendingSelection:NO];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    RSLogVariantState(delegate, "row-selected");

    NSInteger target = -1;
    for (NSInteger i = 0; i < (NSInteger)delegate.variantPicker.numberOfItems; i++)
        if ([[delegate.variantPicker itemAtIndex:i].title isEqualToString:@"1080p"]) target = i;
    if (target < 0) { printf("RS-RESULT FAIL 选择器无 1080p 档位\n"); return 1; }
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
    DownloadJob *job = spy.jobs.lastObject;
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
    DownloadJob *job = spy.jobs.lastObject;
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
            return 2;
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
            return RSRunDownload(url, referer, title, expect, dest);
        }
        if ([mode isEqualToString:@"app"]) return RSRunApp(url);
        if ([mode isEqualToString:@"variantcheck"]) return RSRunVariantCheck(url);
        if ([mode isEqualToString:@"variantrace"]) return RSRunVariantRace(url);
        if ([mode isEqualToString:@"downloadiso"]) return RSRunDownloadIsolated(url);
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
