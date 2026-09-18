#import "StaticHTMLDiscoveryPageProbe.h"
#import "RDLog.h"
#import "RDManualVerification.h"   // 共享会话存储（探测 WebView 与验证窗口同一实例）
#import "ResourceURLGate.h"
#import "WebProbe.h"
#import "RDStaticScriptAnalyzer.h"
#import <WebKit/WebKit.h>
#import <math.h>   // isfinite：Retry-After 解析必须挡住 NaN/Infinity

NSString *const ZZStaticHTMLPageProbeErrorDomain = @"ZZStaticHTMLPageProbeErrorDomain";

// ── 浏览器请求头（第 13 轮补齐；值集中在这一处，便于以后维护）──
// 原先这里只带一个截断的 UA 与 Accept：`Mozilla/5.0 (Macintosh; Intel Mac OS X)
// AppleWebKit/605.1.15 Safari/605.1.15` 既缺 `Version/17.x`，也缺浏览器都会带的
// 语言 / 来源 / Sec-Fetch / 升级提示等头。缺这些头时部分站点会直接拒绝或返回降级
// 页面，静态腿因此整页探不到资源。
// 纪律：**只用这一个固定值** —— 不做版本轮换、不做指纹伪装、不模拟任何验证过程；
// 目的只是让一个正常请求看起来像正常请求，不改变请求的身份与来源。
static NSString * const SHPBrowserUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";
static NSString * const SHPBrowserAccept = @"text/html,application/xhtml+xml;q=0.9,*/*;q=0.8";
static NSString * const SHPBrowserAcceptLanguage = @"zh-CN,zh;q=0.9,en;q=0.8";

// 统一安装上面这套请求头（描述的是浏览器发起顶层文档导航时的形态）。
// referer 是来源页地址：**只有有来源页时才设 Referer**，没有来源页
//（用户直接粘贴地址的顶层页面请求）就不设这个头。
static void SHPApplyBrowserHeaders(NSMutableURLRequest *request, NSURL *referer) {
    if (!request) return;
    [request setValue:SHPBrowserUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:SHPBrowserAccept forHTTPHeaderField:@"Accept"];
    [request setValue:SHPBrowserAcceptLanguage forHTTPHeaderField:@"Accept-Language"];
    [request setValue:@"document" forHTTPHeaderField:@"Sec-Fetch-Dest"];
    [request setValue:@"navigate" forHTTPHeaderField:@"Sec-Fetch-Mode"];
    [request setValue:@"none" forHTTPHeaderField:@"Sec-Fetch-Site"];
    [request setValue:@"1" forHTTPHeaderField:@"Upgrade-Insecure-Requests"];
    if (referer.absoluteString.length) [request setValue:referer.absoluteString forHTTPHeaderField:@"Referer"];
}

// ── 瞬时类失败的重试策略（第 13 轮）──
// 实测 pixabay.com/videos 连测三次是 26 / 403 / 26 个资源：属于限流，重试即可救回。
// 只重试**瞬时类**结果：HTTP 403 / 429 / 5xx、连接超时（含连不上、连接中断）。
// 401、404 及其它 4xx（除 429）不重试 —— 那是确定性答复，重试只会白等。
static const NSUInteger kSHPTransientMaxRetries = 2;
static const NSTimeInterval kSHPTransientRetryDelays[2] = {1.0, 3.0};
// 服务端 Retry-After 是「此刻之前不得再次请求」的硬约束。等待值不再截断到 5s ——
// 截断到 5s 会在服务端要求的时间之前就重试，等于无视服务端限流。
// 常量 24.0 是一个**有限哨兵**：超预算的值会被 MIN 压到 24（确属截断），
// 但压到预算后调用方的剩余预算判定必然 <=0，结论是「不可等待、不重试」，
// 因此这次截断只会导致“放弃”，绝不会导致早于服务端时间的请求；
// 同时它是有限值，保证 dispatch_time 的 (int64_t)(delay * NSEC_PER_SEC) 不溢出。
// 因此它必须等于 kSHPTransientRetryTotalBudget。
static const NSTimeInterval kSHPTransientRetryAfterCap = 24.0;
// 整个请求（含全部重试与内核回退等待）的总时长预算：取单次请求超时的 2 倍。
// 重试 / 回退必须计入且受它约束 —— 绝不允许把探测总时长翻倍。
static const NSTimeInterval kSHPTransientRetryTotalBudget = 24.0;

static BOOL SHPIsTransientStatus(NSInteger statusCode) {
    if (statusCode == 403 || statusCode == 429) return YES;
    return statusCode >= 500 && statusCode <= 599;
}

static BOOL SHPIsTransientNetworkError(NSError *error) {
    if (!error || ![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorNotConnectedToInternet:
            return YES;
        default:
            return NO;   // 含 NSURLErrorCancelled：取消绝不重试
    }
}

// 合法 delta-seconds 只允许 1*DIGIT（RFC 7231）。NaN / Infinity / 科学计数 /
// 负数 / 小数 / 混合文本一律判为非法：它们要么语义不明，要么是伪装的巨大值。
static BOOL SHPIsLegalDeltaSeconds(NSString *raw) {
    if (raw.length == 0) return NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

// 响应带 Retry-After 时返回等待秒数：合法 delta-seconds 或 HTTP-date 两种形式。
// · 非法文本（含 "inf"/"nan"/"1e999"/"1.5"）→ 按「无此头」处理，返回 0；
// · 合法但巨大的数字（如 10^12）→ doubleValue 仍有限 → 压到预算 → 判定为不可等待、不重试；
// · 数字长到 doubleValue 溢出成 Infinity → 同样按「至少等满预算」处理，绝不提前重试。
// 返回值保证有限且非负；调用方再据预算决定是否等待，dispatch_time 不会溢出。
static NSTimeInterval SHPRetryAfterDelay(NSHTTPURLResponse *http) {
    id raw = http.allHeaderFields[@"Retry-After"];
    if (![raw isKindOfClass:NSString.class] || [raw length] == 0) return 0;
    NSTimeInterval value = 0;
    if (SHPIsLegalDeltaSeconds(raw)) {
        value = [raw doubleValue];
        if (!isfinite(value)) value = kSHPTransientRetryAfterCap;   // 巨值溢出：不提前重试
    } else {
        static NSDateFormatter *formatter;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
        });
        NSDate *date = [formatter dateFromString:raw];
        if (date) value = date.timeIntervalSinceNow;
    }
    if (!isfinite(value) || value <= 0) return 0;
    return MIN(value, kSHPTransientRetryAfterCap);
}

// 按 HTTP Content-Type / <meta charset> 声明解码；无声明或声明解码失败时
// 维持原 UTF-8 → Latin-1 兜底。中文资源站的 GB2312/GBK 页面若无此嗅探，
// 会被 Latin-1 兜底解码成整体乱码并被静默采纳入库。
static NSString *SHPEncodingNameFromContentType(NSString *contentType) {
    if (contentType.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"charset\\s*=\\s*\"?([A-Za-z0-9_\\-]+)\"?" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:contentType options:0 range:NSMakeRange(0, contentType.length)];
    return m ? [contentType substringWithRange:[m rangeAtIndex:1]] : nil;
}

// 媒体 / 流清单的扩展名集合：MIME 不明确时的回退判据，
// 由「静态腿 MIME 分流」与「直链媒体浏览器内核回退」共用同一份定义。
static NSSet<NSString *> *SHPVideoExtensions(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"mp4",@"m4v",@"mov",@"webm",@"mkv",@"avi",
                                    @"ts",@"m2ts",@"flv",@"ogv"]];
    });
    return set;
}

static NSSet<NSString *> *SHPManifestExtensions(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"m3u8", @"mpd"]]; });
    return set;
}

// 地址是否**看起来是直链媒体 / 流清单**：只看扩展名 —— 请求失败时没有 MIME 可用。
// 只用于「静态腿失败后改用浏览器内核再取一次响应头」这一条窄路，不参与分流判定。
static BOOL SHPURLLooksLikeDirectMedia(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString ?: @"";
    if (!ext.length) return NO;
    return [SHPVideoExtensions() containsObject:ext] || [SHPManifestExtensions() containsObject:ext];
}

// ── 直链媒体 / 流清单分流（2026-09-18 新增）──
// 背景：用户可能把「媒体文件」或「流清单」的地址直接粘进输入框。此前这类请求也
// 一律当 HTML 解析，实测两个后果：① 超过 2MB 的视频文件被「页面内容超过 2 MB
// 安全上限」挡掉，一个资源都探不到；② 白白把整个媒体文件下载完再当 HTML 丢弃。
// 判定顺序：先看 HTTP MIME；只有 MIME 不明确（空 / octet-stream）时才回退看扩展名。
// 只要 MIME 明确是 text/html，无论扩展名像不像媒体，都走原 HTML 解析路径 ——
// 「伪装成 .mp4 的 HTML 页」不会被误判成媒体。
static DetectedMedia *SHPDetectedMediaForDirectResponse(NSHTTPURLResponse *http, NSURL *url) {
    if (!http || !url) return nil;
    NSString *mime = [http.MIMEType lowercaseString] ?: @"";
    NSString *ext = url.pathExtension.lowercaseString ?: @"";
    BOOL mimeGeneric = (mime.length == 0
                        || [mime isEqualToString:@"application/octet-stream"]
                        || [mime isEqualToString:@"binary/octet-stream"]);
    BOOL manifest = [mime containsString:@"mpegurl"]
                 || [mime isEqualToString:@"application/dash+xml"]
                 || (mimeGeneric && [SHPManifestExtensions() containsObject:ext]);
    BOOL video = [mime hasPrefix:@"video/"] || (mimeGeneric && [SHPVideoExtensions() containsObject:ext]);
    if (!manifest && !video) return nil;

    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = url.absoluteString;
    if (mime.length) m.mimeType = mime;
    m.resourceKind = manifest ? RDResourceKindManifest : RDResourceKindVideo;
    m.isManifest = manifest;
    m.discoverySource = @"direct-url";
    m.sourcePageURL = url.absoluteString;   // 直链本身就是来源页
    NSString *name = url.lastPathComponent.stringByRemovingPercentEncoding ?: url.lastPathComponent;
    m.title = name.length ? name : url.absoluteString;
    if (manifest) {
        BOOL dash = [ext isEqualToString:@"mpd"] || [mime isEqualToString:@"application/dash+xml"];
        m.format = dash ? @"dash" : @"hls";
        m.thumbnailStatus = RDThumbnailNone;
    } else {
        m.format = ext.length ? ext : @"mp4";
        m.thumbnailStatus = RDThumbnailPending;
    }
    // 响应是 200 且 MIME 明确为媒体，可用性有据可依；该字段只参与排序，不控制显隐。
    m.availabilityState = @"downloadable";
    m.discoveredAt = [NSDate date].timeIntervalSince1970;
    if (http.expectedContentLength > 0) m.sizeBytes = http.expectedContentLength;
    return m;
}

static NSString *SHPDecodeHTML(NSData *data, NSURLResponse *response, NSString *metaSnippet) {
    NSMutableArray<NSString *> *declared = [NSMutableArray array];
    NSString *fromHeader = SHPEncodingNameFromContentType(
        ((NSHTTPURLResponse *)response).allHeaderFields[@"Content-Type"] ?: @"");
    if (fromHeader.length) [declared addObject:fromHeader];
    if (metaSnippet.length) {
        NSString *fromMeta = SHPEncodingNameFromContentType(metaSnippet);
        if (fromMeta.length) [declared addObject:fromMeta];
    }
    for (NSString *name in declared) {
        CFStringEncoding cfEnc = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)name);
        if (cfEnc == kCFStringEncodingInvalidId) continue;
        NSStringEncoding nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc);
        if (nsEnc == NSProprietaryStringEncoding) continue;
        NSString *html = [[NSString alloc] initWithData:data encoding:nsEnc];
        if (html) return html;
    }
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return html;
}

#pragma mark - 直链媒体的浏览器内核响应探针（第 13 轮）

// 有些直链媒体 / 流清单地址对**普通 HTTP 请求**返回 403（CDN 只认真实浏览器内核），
// 静态腿因此拿不到响应，条目也就生成不了。这里用离屏 WKWebView 导航一次，只从
// WKNavigationResponse 读取真实的状态码 / MIME / expectedContentLength，
// **拿到响应头立刻取消导航：不读取响应体、不下载媒体、不渲染页面**。
// 会话存储与探测 WebView 共用同一个实例（Cookie 由 WebKit 自己保管，
// 本类不读取、不打印、不导出）。
// 内核回退探针的最小契约：生产实现是 SHPMediaResponseProbe（真实 WKWebView），
// 测试可注入替身，从而在**没有任何真实 WebKit 导航**的前提下驱动回退分支。
// 仅用于可测试性，不改变生产行为，也不暴露到任何公共头文件。
@protocol SHPMediaResponseProbing <NSObject>
- (void)startWithURL:(NSURL *)url referer:(NSURL *)referer timeout:(NSTimeInterval)timeout;
- (void)cancel;
@end

@interface SHPMediaResponseProbe : NSObject <WKNavigationDelegate, SHPMediaResponseProbing>
@property (nonatomic, copy, nullable) void (^completion)(NSHTTPURLResponse * _Nullable response, NSError * _Nullable error);
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic, strong) ResourceURLGate *gate;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong, nullable) dispatch_source_t timeoutTimer;
@end

@implementation SHPMediaResponseProbe

- (void)dealloc {
    if (_timeoutTimer) dispatch_source_cancel(_timeoutTimer);
}

// 仅在主线程调用：创建 WebView 并发起一次导航。
- (void)startWithURL:(NSURL *)url referer:(NSURL *)referer timeout:(NSTimeInterval)timeout {
    NSAssert([NSThread isMainThread], @"SHPMediaResponseProbe 的 WebKit 操作只允许在主线程");
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = [RDManualVerificationController sharedSessionDataStore];
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180) configuration:cfg];
    self.webView.navigationDelegate = self;
    [self armTimeout:timeout];
    // 与静态腿同一套请求头（含「只有有来源页时才设 Referer」）。
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:MAX(1.0, timeout)];
    SHPApplyBrowserHeaders(request, referer);
    [self.webView loadRequest:request];
}

- (void)armTimeout:(NSTimeInterval)timeout {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    self.timeoutTimer = t;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(1.0, timeout) * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    __weak typeof(self) w = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(w) s = w;
        if (!s) return;
        [s finishWithResponse:nil
                        error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
                                               userInfo:@{NSLocalizedDescriptionKey : @"浏览器内核取响应超时"}]];
    });
    dispatch_resume(t);
}

- (void)finishWithResponse:(NSHTTPURLResponse *)response error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    if (self.timeoutTimer) { dispatch_source_cancel(self.timeoutTimer); self.timeoutTimer = nil; }
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    void (^cb)(NSHTTPURLResponse *, NSError *) = self.completion;
    self.completion = nil;
    if (cb) cb(response, error);
}

- (void)cancel {
    [self finishWithResponse:nil error:nil];
}

#pragma mark WKNavigationDelegate

// 与探测 WebView 同一安全边界：每一跳（含重定向）都要过 URLPolicy。
- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *target = navigationAction.request.URL;
    if ([target.scheme.lowercaseString isEqualToString:@"about"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (!self.gate.rd_checksEnabled) { decisionHandler(WKNavigationActionPolicyAllow); return; }
    URLPolicyDecision *text = [self.gate.policy evaluateRedirect:target fromURL:webView.URL];
    if (!text.allowed) { decisionHandler(WKNavigationActionPolicyCancel); return; }
    __weak typeof(self) w = self;
    [self.gate verifyURLAsync:target completion:^(URLPolicyDecision *decision) {
        __strong typeof(w) s = w;
        if (!s) { decisionHandler(WKNavigationActionPolicyCancel); return; }
        decisionHandler(decision.allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    }];
}

// 关键一步：响应头到手就结束 —— 立刻取消加载，不读正文。
- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
        decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSHTTPURLResponse *http = [navigationResponse.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)navigationResponse.response : nil;
    decisionHandler(WKNavigationResponsePolicyCancel);
    [self finishWithResponse:http error:nil];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithResponse:nil error:error];   // 含取消自身带来的 NSURLErrorCancelled：finished 已挡住
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithResponse:nil error:error];
}

@end

@interface ZZStaticHTMLProbeContext : NSObject
@property (nonatomic, strong) NSURL *originalURL;
@property (nonatomic, strong, nullable) NSURL *refererURL;   // 来源页（有才设 Referer 头）
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, copy, nullable) void (^mediaCompletion)(NSArray<DetectedMedia *> *, NSError *);
@property (nonatomic, copy, nullable) ZZDiscoveryHTMLCompletion htmlCompletion;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL bodyLimitExceeded;
@property (nonatomic) NSUInteger byteLimit;
@property (nonatomic) NSUInteger receivedBytes;
@property (nonatomic) NSUInteger redirectCount;
@property (nonatomic, strong) ZZStaticHTMLProbeContext *scriptToken;
@property (nonatomic, copy) NSArray<NSURL *> *scriptURLs;
@property (nonatomic, strong) NSMutableArray<DetectedMedia *> *collectedMedia;
@property (nonatomic, strong, nullable) NSURL *documentBaseURL;
@property (nonatomic) NSUInteger scriptIndex;
@property (nonatomic) NSUInteger scriptBytes;
@property (nonatomic) BOOL scriptsDone;
@property (nonatomic, strong, nullable) NSError *redirectError;
@property (nonatomic, strong, nullable) NSError *pageError;
// ── 瞬时类失败退避重试 / 直链媒体内核回退（第 13 轮）──
@property (nonatomic) NSTimeInterval startedAt;              // 本次请求起始时刻
@property (nonatomic) NSUInteger transientRetryCount;        // 已发生的重试次数
@property (nonatomic, assign) BOOL awaitingRetry;            // 正在退避等待
// 当前任务的结论已由 didReceiveResponse 分支定下（非 2xx / 已生成直链条目）：
// 该任务随后必然收到一次 NSURLErrorCancelled（我们自己取消了它），
// 那是本次取消的回声，不能当成失败覆盖掉正在进行的回退/重试。
@property (nonatomic, assign) BOOL pendingOutcomeHandled;
@property (nonatomic, assign) BOOL mediaFallbackAttempted;   // 直链媒体已走过一次内核回退
@property (nonatomic, strong, nullable) id<SHPMediaResponseProbing> mediaResponseProbe;
@end
@implementation ZZStaticHTMLProbeContext
@end

@interface StaticHTMLDiscoveryPageProbe () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong) URLPolicy *policy;
@property (nonatomic, strong) ResourceURLGate *gate;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ZZStaticHTMLProbeContext *> *contexts;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
// 测试专用注入点（KVC 可设，非公共 API）：nil 时使用真实 WKWebView 探针。
// 测试传入替身工厂即可在无真实 WebKit 导航、无真实网络的前提下驱动内核回退分支。
@property (nonatomic, copy, nullable) id<SHPMediaResponseProbing> (^rd_mediaResponseProbeFactory)(NSURL *url, NSURL *referer, NSTimeInterval timeout, void (^completion)(NSHTTPURLResponse * _Nullable, NSError * _Nullable));
@end

@implementation StaticHTMLDiscoveryPageProbe

- (instancetype)initWithPolicy:(URLPolicy *)policy {
    return [self initWithPolicy:policy sessionConfiguration:nil];
}

- (instancetype)initWithPolicy:(URLPolicy *)policy
           sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self=[super init];
    if(self){
        _policy=policy ?: [URLPolicy new];
        _gate=[ResourceURLGate new];
        _gate.policy=_policy;
        // 上限对齐（2026-09-18）：原先这里写死 2 MB，而同一项目的另外两条网页读取路径
        // 都是 8 MB（WebProbe.m 的 _maxHTMLBytes、ProductionDiscoveryHTMLProvider 的
        // kHTMLMaxBytes）。三处做同一件事却两套上限属实现不一致，且实测有真实站点因此
        // 被整页拒绝（coverr.co：HTML 约 9.7 MB，报「页面内容超过 2 MB 安全上限」、
        // 一个资源都探不到）。这里对齐为 8 MB；超过 8 MB 的页面仍按原策略拒绝。
        _maxHTMLBytes=8*1024*1024;
        _requestTimeout=12.0;
        _contexts=[NSMutableDictionary dictionary];
        _stateQueue=dispatch_queue_create("zz.static-html-probe.state",DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg=configuration ? [configuration copy]
                                                     : NSURLSessionConfiguration.ephemeralSessionConfiguration;
        // The session is shared by all detail probes.  Keep it aligned with
        // the controller's bounded probe concurrency so one origin is not
        // flooded when a listing has many entries.
        cfg.HTTPMaximumConnectionsPerHost=8;
        cfg.timeoutIntervalForRequest=_requestTimeout;
        cfg.timeoutIntervalForResource=_requestTimeout;
        cfg.URLCache=nil;
        cfg.HTTPCookieStorage=nil; cfg.URLCredentialStorage=nil; cfg.HTTPShouldSetCookies=NO;
        _session=[NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    return self;
}

- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(void (^)(NSArray<DetectedMedia *> *, NSError *))completion {
    return [self startURL:pageURL mediaCompletion:completion htmlCompletion:nil];
}

- (nullable id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    return [self startURL:url mediaCompletion:nil htmlCompletion:completion];
}

- (nullable id)startURL:(NSURL *)pageURL
        mediaCompletion:(void (^)(NSArray<DetectedMedia *> *, NSError *))mediaCompletion
         htmlCompletion:(ZZDiscoveryHTMLCompletion)htmlCompletion {
    return [self startURL:pageURL mediaCompletion:mediaCompletion htmlCompletion:htmlCompletion byteLimit:self.maxHTMLBytes];
}

- (id)startURL:(NSURL *)pageURL mediaCompletion:(void (^)(NSArray<DetectedMedia *> *, NSError *))mediaCompletion
 htmlCompletion:(ZZDiscoveryHTMLCompletion)htmlCompletion byteLimit:(NSUInteger)byteLimit {
    return [self startURL:pageURL referer:nil mediaCompletion:mediaCompletion
           htmlCompletion:htmlCompletion byteLimit:byteLimit];
}

// referer：来源页地址（只有页面内子请求才有；顶层请求传 nil，此时不设 Referer 头）。
- (id)startURL:(NSURL *)pageURL
       referer:(NSURL *)referer
mediaCompletion:(void (^)(NSArray<DetectedMedia *> *, NSError *))mediaCompletion
htmlCompletion:(ZZDiscoveryHTMLCompletion)htmlCompletion
     byteLimit:(NSUInteger)byteLimit {
    ZZStaticHTMLProbeContext *ctx=[ZZStaticHTMLProbeContext new];
    ctx.originalURL=pageURL;
    ctx.refererURL=referer;
    ctx.byteLimit=byteLimit;
    ctx.data=[NSMutableData data];
    ctx.startedAt=[NSDate date].timeIntervalSince1970;
    ctx.mediaCompletion=[mediaCompletion copy];
    ctx.htmlCompletion=[htmlCompletion copy];
    if(!pageURL||![self.gate isTextAllowed:pageURL]){
        NSError *error=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                           code:ZZResourceDiscoveryErrorInvalidURL
                                       userInfo:@{NSLocalizedDescriptionKey:@"页面地址未通过安全校验"}];
        dispatch_async(dispatch_get_main_queue(),^{
            if(ctx.cancelled)return;
            if(mediaCompletion)mediaCompletion(@[],error);
            if(htmlCompletion)htmlCompletion(nil,nil,error);
        });
        return ctx;
    }
    __weak typeof(self) w=self;
    [self.gate verifyURLAsync:pageURL completion:^(URLPolicyDecision *decision) {
        __strong typeof(w) s=w;
        if(!s||ctx.cancelled)return;
        if(!decision.allowed){
            [s finishContext:ctx media:@[]
                       error:[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                                code:ZZResourceDiscoveryErrorPermissionDenied
                                            userInfo:@{NSLocalizedDescriptionKey:decision.userMessage ?: @"页面地址被安全策略拒绝"}]];
            return;
        }
        NSMutableURLRequest *request=[s requestForURL:pageURL referer:referer timeout:s.requestTimeout];
        // HTML 必须完整读取；固定 Range 会让服务器只返回前 128KB，
        // 从而漏掉详情页后部的 source/清晰度。
        NSURLSessionDataTask *task=[s.session dataTaskWithRequest:request];
        ctx.task=task;
        dispatch_sync(s.stateQueue,^{ s.contexts[@(task.taskIdentifier)]=ctx; });
        [task resume];
    }];
    return ctx;
}

- (void)cancelProbe:(id)probeToken {
    ZZStaticHTMLProbeContext *ctx=[probeToken isKindOfClass:ZZStaticHTMLProbeContext.class]?probeToken:nil;
    if(!ctx)return;
    ctx.cancelled=YES;
    [self cancelProbe:ctx.scriptToken];
    ctx.scriptToken=nil;
    ctx.mediaCompletion=nil;
    ctx.htmlCompletion=nil;
    // 在途的「直链媒体内核回退」随之作废（WebView 只在主线程回收）。
    id<SHPMediaResponseProbing> mediaProbe=ctx.mediaResponseProbe;
    ctx.mediaResponseProbe=nil;
    if(mediaProbe){
        if(NSThread.isMainThread)[mediaProbe cancel];
        else dispatch_async(dispatch_get_main_queue(),^{ [mediaProbe cancel]; });
    }
    [ctx.task cancel];
    if(ctx.task)dispatch_async(self.stateQueue,^{ [self.contexts removeObjectForKey:@(ctx.task.taskIdentifier)]; });
}

- (void)cancelHTMLRequest:(id)requestToken {
    [self cancelProbe:requestToken];
}

// 统一的请求构造：浏览器请求头集中在这一处（见文件顶部常量）。
- (NSMutableURLRequest *)requestForURL:(NSURL *)url referer:(NSURL *)referer timeout:(NSTimeInterval)timeout {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:MAX(1.0, timeout)];
    SHPApplyBrowserHeaders(request, referer);
    return request;
}

#pragma mark - 失败处理：瞬时重试 / 直链媒体内核回退（第 13 轮）

// 一次请求失败（非 2xx 或网络错误）的统一入口：
// ① 地址看起来是直链媒体 / 流清单 → 改用浏览器内核再取一次响应头；
// ② 瞬时类（403/429/5xx、连接超时）→ 退避重试；
// ③ 其余（401/404 等确定性答复）→ 直接按原错误收尾。
- (void)handleFailureForContext:(ZZStaticHTMLProbeContext *)ctx
                         status:(NSInteger)statusCode
                     retryAfter:(NSTimeInterval)retryAfter
                          error:(NSError *)error {
    if (ctx.cancelled || ctx.finished) return;
    if (!ctx.mediaFallbackAttempted && SHPURLLooksLikeDirectMedia(ctx.originalURL)) {
        // 内核回退同样是一次新的网络请求：服务端给了 Retry-After 时不得立即导航，
        // 必须先满足等待窗口（含预算判定）—— 否则即便随后重试“等到”，那一次回退
        // 本身仍是早于服务端的请求。
        [self scheduleMediaFallbackForContext:ctx
                                       status:statusCode
                                   retryAfter:retryAfter
                                        error:error];
        return;
    }
    if (SHPIsTransientStatus(statusCode) || SHPIsTransientNetworkError(error)) {
        [self scheduleTransientRetryForContext:ctx status:statusCode retryAfter:retryAfter error:error];
        return;
    }
    [self finishContext:ctx media:@[] error:error];
}

// 瞬时类失败的退避重试：最多 2 次，间隔 1s / 3s；响应带 Retry-After 时按服务端要求等待，
// 但绝不提前请求，且要求等待超过剩余预算时按原错误收尾（不重试）。
// 重试计入同一探测预算（kSHPTransientRetryTotalBudget），预算不足就按原错误收尾 ——
// 重试绝不允许把探测总时长翻倍。
- (void)scheduleTransientRetryForContext:(ZZStaticHTMLProbeContext *)ctx
                                  status:(NSInteger)statusCode
                              retryAfter:(NSTimeInterval)retryAfter
                                   error:(NSError *)error {
    if (ctx.cancelled || ctx.finished) return;
    if (ctx.transientRetryCount >= kSHPTransientMaxRetries) {
        [self finishContext:ctx media:@[] error:error];
        return;
    }
    NSTimeInterval elapsed = [NSDate date].timeIntervalSince1970 - ctx.startedAt;
    NSTimeInterval delay = retryAfter > 0 ? retryAfter : kSHPTransientRetryDelays[ctx.transientRetryCount];
    NSTimeInterval remaining = kSHPTransientRetryTotalBudget - elapsed - delay;
    // 剩余预算不足 1s 就不再重试：既避免超预算，也避免 requestForURL 的 MAX(1, timeout)
    // 把超时抬高到剩余预算之外。
    if (remaining < 1.0) {
        [self finishContext:ctx media:@[] error:error];
        return;
    }
    ctx.transientRetryCount += 1;
    ctx.awaitingRetry = YES;
    RDLogWrite(@"probe", @"瞬时类失败第 %lu/%lu 次重试：status=%ld wait=%.1fs url=%@",
               (unsigned long)ctx.transientRetryCount, (unsigned long)kSHPTransientMaxRetries,
               (long)statusCode, delay, ctx.originalURL.absoluteString ?: @"(nil)");
    NSURLSessionDataTask *oldTask = ctx.task;
    if (oldTask) dispatch_async(self.stateQueue, ^{ [self.contexts removeObjectForKey:@(oldTask.taskIdentifier)]; });
    [oldTask cancel];
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(w) s = w;
        if (!s) return;
        if (ctx.cancelled || ctx.finished || !ctx.awaitingRetry) return;
        ctx.awaitingRetry = NO;
        // 到期时**重算**预算：等待期间主线程若迟到，调度时捕获的 remaining 已作废，
        // 不得再用它给新请求放行或算超时。
        NSTimeInterval live = kSHPTransientRetryTotalBudget - ([NSDate date].timeIntervalSince1970 - ctx.startedAt);
        if (live < 1.0) {   // 预算已在等待期间耗尽：不再发起新请求，按原错误收尾
            [s finishContext:ctx media:@[] error:error];
            return;
        }
        ctx.pendingOutcomeHandled = NO;   // 新任务：结论重新开放
        // 上一次尝试的残缺响应不得带入这一次。
        ctx.data = [NSMutableData data];
        ctx.receivedBytes = 0;
        ctx.bodyLimitExceeded = NO;
        NSMutableURLRequest *request = [s requestForURL:ctx.originalURL
                                                referer:ctx.refererURL
                                                timeout:MIN(s.requestTimeout, live)];
        NSURLSessionDataTask *task = [s.session dataTaskWithRequest:request];
        ctx.task = task;
        dispatch_sync(s.stateQueue, ^{ s.contexts[@(task.taskIdentifier)] = ctx; });
        [task resume];
    });
}

// 内核回退的等待门：服务端 Retry-After > 0 时，先按与重试相同的预算规则校验 ——
// 要求等待超过剩余预算（含 24s 总预算）就按原错误收尾，既不提前导航也不重试；
// 预算允许才在等待窗口之后发起那一次内核回退。retryAfter <= 0 时维持立即回退，
// 但立即回退同样先过预算，耗尽则零新请求。
- (void)scheduleMediaFallbackForContext:(ZZStaticHTMLProbeContext *)ctx
                                 status:(NSInteger)statusCode
                             retryAfter:(NSTimeInterval)retryAfter
                                  error:(NSError *)error {
    if (ctx.cancelled || ctx.finished) return;
    if (retryAfter <= 0) {
        NSTimeInterval live = kSHPTransientRetryTotalBudget - ([NSDate date].timeIntervalSince1970 - ctx.startedAt);
        if (live < 1.0) { [self finishContext:ctx media:@[] error:error]; return; }
        [self attemptMediaResponseFallbackForContext:ctx status:statusCode error:error];
        return;
    }
    NSTimeInterval elapsed = [NSDate date].timeIntervalSince1970 - ctx.startedAt;
    NSTimeInterval remaining = kSHPTransientRetryTotalBudget - elapsed - retryAfter;
    if (remaining < 1.0) {   // 服务端要求的等待超出剩余预算：不导航、不重试，如实收尾
        [self finishContext:ctx media:@[] error:error];
        return;
    }
    ctx.awaitingRetry = YES;
    RDLogWrite(@"probe", @"直链媒体回退等待服务端 Retry-After：wait=%.1fs url=%@",
               retryAfter, ctx.originalURL.absoluteString ?: @"(nil)");
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(w) s = w;
        if (!s) return;
        if (ctx.cancelled || ctx.finished || !ctx.awaitingRetry) return;
        ctx.awaitingRetry = NO;
        // 到期时重算：等待期间主线程迟到不得沿用调度时的旧预算。
        NSTimeInterval live = kSHPTransientRetryTotalBudget - ([NSDate date].timeIntervalSince1970 - ctx.startedAt);
        if (live < 1.0) { [s finishContext:ctx media:@[] error:error]; return; }
        [s attemptMediaResponseFallbackForContext:ctx status:statusCode error:error];
    });
}

// 直链媒体 / 流清单：静态腿拿到非 2xx 或连接失败时，改用浏览器内核导航一次，
// 只读 WKNavigationResponse 里的真实状态码 / MIME / expectedContentLength。
// 为 2xx 且 MIME 属于媒体 / 清单时，**复用同一套 MIME 分流规则**
//（SHPDetectedMediaForDirectResponse）生成条目：字段规则与静态腿那条分支完全一致。
- (void)attemptMediaResponseFallbackForContext:(ZZStaticHTMLProbeContext *)ctx
                                        status:(NSInteger)statusCode
                                         error:(NSError *)error {
    if (ctx.cancelled || ctx.finished) return;
    ctx.mediaFallbackAttempted = YES;
    NSURL *url = ctx.originalURL;
    __weak typeof(self) w = self;
    void (^finish)(NSHTTPURLResponse *, NSError *) = ^(NSHTTPURLResponse *http, NSError *probeError) {
        __strong typeof(w) s = w;
        if (!s) return;
        if (ctx.cancelled || ctx.finished) return;
        ctx.mediaResponseProbe = nil;
        DetectedMedia *direct = nil;
        if (http.statusCode >= 200 && http.statusCode < 300) {
            direct = SHPDetectedMediaForDirectResponse(http, http.URL ?: url);
        }
        RDLogWrite(@"probe", @"浏览器内核回退结果 status=%ld mime=%@ 条目=%d",
                   (long)http.statusCode, http.MIMEType ?: @"(无响应)", direct ? 1 : 0);
        if (direct) {
            [s finishContext:ctx media:@[direct] error:nil];
            return;
        }
        // 浏览器内核也没拿到可用响应：按**已经拿到的答复**决定去路与最终文案 ——
        // · 内核给了 HTTP 响应 → 按该状态码判（401/404 等确定性答复直接收尾，不重试）；
        // · 内核没给响应、但静态腿本来就有状态码 → 静态腿的答复仍然成立
        //（静态腿说 404，就不该因为内核这次超时而去重试一个确定性的 404，
        //  也不该把「内核超时」当成用户看到的失败原因）；
        // · 两边都没有状态码（纯连接失败）→ 按网络错误判，交给瞬时重试。
        NSInteger finalStatus = http ? http.statusCode : statusCode;
        NSError *finalError = nil;
        if (http) {
            finalError = [NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                             code:finalStatus
                                         userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HTTP %ld", (long)finalStatus]}];
        } else if (statusCode > 0) {
            finalError = error;
        } else {
            finalError = probeError ?: error;
        }
        BOOL transient = (http || statusCode > 0) ? SHPIsTransientStatus(finalStatus)
                                                  : SHPIsTransientNetworkError(probeError);
        if (transient) {
            // 静态腿给出的等待已在回退前由 scheduleMediaFallback 的等待门履行完毕，
            // 这里以「内核这次的新答复」为准：内核没给 Retry-After 就用默认退避。
            // 不对同一个静态答复重复等待 —— 那只是无谓地把探测时间拖长，协议并不要求。
            NSTimeInterval probeRetryAfter = http ? SHPRetryAfterDelay(http) : 0;
            [s scheduleTransientRetryForContext:ctx status:finalStatus
                                     retryAfter:probeRetryAfter
                                          error:finalError];
        } else {
            [s finishContext:ctx media:@[] error:finalError];
        }
    };
    void (^start)(void) = ^{
        __strong typeof(w) s = w;
        if (!s || ctx.cancelled || ctx.finished) return;
        // 导航超时必须受剩余预算约束（>=1s）：否则「等待 23s + 内核 12s」会突破 24s 预算。
        // 用 >=1s 的最低可用预算，使 MIN 结果不会被 SHPMediaResponseProbe 的 MAX(1, timeout) 抬高。
        NSTimeInterval live = kSHPTransientRetryTotalBudget - ([NSDate date].timeIntervalSince1970 - ctx.startedAt);
        if (live < 1.0) { [s finishContext:ctx media:@[] error:error]; return; }
        NSTimeInterval probeTimeout = MIN(s.requestTimeout, live);
        RDLogWrite(@"probe", @"直链媒体静态腿失败，改用浏览器内核再取一次响应头：%@（静态腿状态 %ld，超时预算 %.1fs）",
                   url.absoluteString ?: @"(nil)", (long)statusCode, probeTimeout);
        id<SHPMediaResponseProbing> probe = nil;
        if (s.rd_mediaResponseProbeFactory) {
            probe = s.rd_mediaResponseProbeFactory(url, ctx.refererURL, probeTimeout, finish);
        } else {
            SHPMediaResponseProbe *real = [SHPMediaResponseProbe new];
            real.gate = s.gate;
            real.completion = finish;
            [real startWithURL:url referer:ctx.refererURL timeout:probeTimeout];
            probe = real;
        }
        ctx.mediaResponseProbe = probe;
    };
    if (NSThread.isMainThread) start();
    else dispatch_async(dispatch_get_main_queue(), start);
}

- (ZZStaticHTMLProbeContext *)contextForTask:(NSURLSessionTask *)task {
    __block ZZStaticHTMLProbeContext *ctx=nil;
    dispatch_sync(self.stateQueue,^{ ctx=self.contexts[@(task.taskIdentifier)]; });
    return ctx;
}

- (void)finishContext:(ZZStaticHTMLProbeContext *)ctx
                 media:(NSArray<DetectedMedia *> *)media
                  error:(NSError *)error {
    @synchronized(ctx){
        if(ctx.finished||ctx.cancelled)return;
        ctx.finished=YES;
    }
    if(ctx.task)dispatch_async(self.stateQueue,^{ [self.contexts removeObjectForKey:@(ctx.task.taskIdentifier)]; });
    // 在途的「直链媒体内核回退」一并回收（只保留一次导航，不留下悬空 WebView）。
    id<SHPMediaResponseProbing> mediaProbe=ctx.mediaResponseProbe;
    ctx.mediaResponseProbe=nil;
    if(mediaProbe){
        if(NSThread.isMainThread)[mediaProbe cancel];
        else dispatch_async(dispatch_get_main_queue(),^{ [mediaProbe cancel]; });
    }
    void (^mediaCompletion)(NSArray<DetectedMedia *> *,NSError *)=ctx.mediaCompletion;
    ZZDiscoveryHTMLCompletion htmlCompletion=ctx.htmlCompletion;
    ctx.mediaCompletion=nil;
    ctx.htmlCompletion=nil;
    NSError *finalError = error ?: (media.count ? nil : ctx.pageError);
    if(mediaCompletion)dispatch_async(dispatch_get_main_queue(),^{ if(!ctx.cancelled)mediaCompletion(media ?: @[],finalError); });
    if(htmlCompletion)dispatch_async(dispatch_get_main_queue(),^{ if(!ctx.cancelled)htmlCompletion(nil,nil,error); });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:task];
    NSURL *target=request.URL;
    if(!ctx||ctx.cancelled||ctx.finished||!target){ completionHandler(nil); return; }
    if(++ctx.redirectCount>5){completionHandler(nil);[task cancel];return;}
    URLPolicyDecision *text=[self.policy evaluateRedirect:target fromURL:response.URL ?: task.currentRequest.URL];
    if(!text.allowed){
        ctx.redirectError=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                              code:ZZResourceDiscoveryErrorPermissionDenied
                                          userInfo:@{NSLocalizedDescriptionKey:text.userMessage ?: @"重定向被安全策略拒绝"}];
        completionHandler(nil);
        [task cancel];
        return;
    }
    [self.gate verifyURLAsync:target completion:^(URLPolicyDecision *decision) {
        if(ctx.cancelled){ completionHandler(nil); return; }
        if(!decision.allowed){
            ctx.redirectError=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                                  code:ZZResourceDiscoveryErrorPermissionDenied
                                              userInfo:@{NSLocalizedDescriptionKey:decision.userMessage ?: @"重定向地址被安全策略拒绝"}];
            completionHandler(nil);
            [task cancel];
            return;
        }
        completionHandler(request);
    }];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:dataTask];
    if(!ctx||ctx.cancelled){ completionHandler(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)response:nil;
    if(http.statusCode<200||http.statusCode>=300){
        ctx.pendingOutcomeHandled=YES;   // 结论已定：这一次取消的回声不得当成失败
        completionHandler(NSURLSessionResponseCancel);
        // 非 2xx 不再直接判死：直链媒体改用浏览器内核再取一次，瞬时类失败退避重试
        //（第 13 轮）。最终失败时仍用同一个「HTTP <code>」错误文案收尾。
        NSError *httpError=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                               code:http.statusCode
                                           userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HTTP %ld",(long)http.statusCode]}];
        [self handleFailureForContext:ctx status:http.statusCode retryAfter:SHPRetryAfterDelay(http) error:httpError];
        return;
    }
    // 直链媒体/流清单：不下载正文，直接由 URL 生成一条媒体条目（见上方分流函数注释）。
    // 用重定向之后的有效地址：直链媒体常跳转到 CDN，那个才是真正可下载的地址。
    DetectedMedia *directMedia = SHPDetectedMediaForDirectResponse(http, http.URL ?: ctx.originalURL);
    if (directMedia) {
        ctx.pendingOutcomeHandled=YES;   // 已由本条响应生成条目，同上
        completionHandler(NSURLSessionResponseCancel);
        [dataTask cancel];
        [self finishContext:ctx media:@[directMedia] error:nil];
        return;
    }
    if(response.expectedContentLength>(long long)ctx.byteLimit){
        ctx.bodyLimitExceeded=YES;
        completionHandler(NSURLSessionResponseCancel);
        [dataTask cancel];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:dataTask];
    if(!ctx||ctx.cancelled)return;
    // Charge even rejected chunks, so oversized/failed scripts cannot reset
    // the page-wide budget. NSURLSession may deliver one in-flight excess chunk.
    ctx.receivedBytes=MIN(ctx.receivedBytes,NSUIntegerMax-data.length)+data.length;
    if(data.length>ctx.byteLimit-ctx.data.length){
        ctx.bodyLimitExceeded=YES;
        [dataTask cancel];
        return;
    }
    [ctx.data appendData:data];
    // 媒体标签可能位于页面尾部；等待完整响应后统一解析，确保所有清晰度/格式都进入结果。
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:task];
    if(!ctx||ctx.cancelled)return;
    // 结论已定的任务：这里的回调是「我们自己取消了它」的回声，直接丢弃。
    if(ctx.pendingOutcomeHandled)return;
    if(ctx.redirectError){ [self finishContext:ctx media:@[] error:ctx.redirectError]; return; }
    if(ctx.bodyLimitExceeded){
        [self finishContext:ctx media:@[]
                     error:[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                              code:NSURLErrorDataLengthExceedsMaximum
                                          userInfo:@{NSLocalizedDescriptionKey:@"页面内容超过 8 MB 安全上限"}]];
        return;
    }
    if(error){
        // 取消（用户取消 / 我们自己取消了旧任务）绝不重试；其余按瞬时类失败处理：
        // 连接超时等瞬时故障退避重试，直链媒体则先走一次浏览器内核回退。
        BOOL cancelled=[error.domain isEqualToString:NSURLErrorDomain]&&error.code==NSURLErrorCancelled;
        if(cancelled){ [self finishContext:ctx media:@[] error:error]; return; }
        [self handleFailureForContext:ctx status:0 retryAfter:0 error:error];
        return;
    }
    // 编码嗅探：Latin-1 兜底对任意字节恒成功，必须在兜底之前先按声明解码。
    NSString *metaSnippet = [[NSString alloc] initWithData:[ctx.data subdataWithRange:NSMakeRange(0, MIN(ctx.data.length, (NSUInteger)2048))] encoding:NSISOLatin1StringEncoding] ?: @"";
    NSString *html = SHPDecodeHTML(ctx.data, task.response, metaSnippet);
    if(ctx.htmlCompletion){
        ZZDiscoveryHTMLCompletion completion=ctx.htmlCompletion;
        ctx.htmlCompletion=nil;
        ctx.finished=YES;
        dispatch_async(self.stateQueue,^{ [self.contexts removeObjectForKey:@(task.taskIdentifier)]; });
        dispatch_async(dispatch_get_main_queue(),^{ if(!ctx.cancelled)completion(html,task.currentRequest.URL ?: ctx.originalURL,nil); });
        return;
    }
    RDProbeResult *result=[RDProbeAnalyzer analyzeHTML:html baseURL:task.currentRequest.URL ?: ctx.originalURL];
    if(result.isBadPage)ctx.pageError=[NSError errorWithDomain:ZZResourceDiscoveryErrorDomain code:ZZResourceDiscoveryErrorUnrecognizedPage
        userInfo:@{NSLocalizedDescriptionKey:@"页面无法识别，请检查页面内容或稍后重试"}];
    dispatch_async(dispatch_get_main_queue(), ^{
        if(ctx.cancelled||ctx.finished)return;
        NSURL *finalPageURL=task.currentRequest.URL ?: ctx.originalURL;
        ctx.documentBaseURL=[RDStaticScriptAnalyzer documentBaseURLInHTML:html baseURL:finalPageURL];
        ctx.collectedMedia=[(result.media ?: @[]) mutableCopy];
        ctx.scriptURLs=[RDStaticScriptAnalyzer scriptURLsInHTML:html ?: @"" baseURL:task.currentRequest.URL ?: ctx.originalURL limit:6];
        // Sequential, one-level enrichment: <=6 files, 256 KiB/file, 1 MiB
        // combined bodies, four seconds total. HTML results survive every failure.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            [self finishScripts:ctx];
        });
        [self nextScript:ctx];
    });
}

- (void)finishScripts:(ZZStaticHTMLProbeContext *)ctx {
    if(ctx.cancelled||ctx.finished||ctx.scriptsDone)return;
    ctx.scriptsDone=YES;
    [self cancelProbe:ctx.scriptToken];ctx.scriptToken=nil;
    NSMutableArray *unique=[NSMutableArray array];NSMutableSet *keys=[NSMutableSet set];
    for(DetectedMedia *media in ctx.collectedMedia){
        NSString *key=[DetectedMedia dedupKeyForURL:media.mediaURL];
        if(!key.length||[keys containsObject:key])continue;
        [keys addObject:key];media.sourcePageURL=ctx.originalURL.absoluteString;[unique addObject:media];
    }
    [self verifyMediaCandidates:unique context:ctx];
}

- (void)nextScript:(ZZStaticHTMLProbeContext *)ctx {
    if(ctx.cancelled||ctx.finished||ctx.scriptsDone)return;
    if(ctx.scriptIndex>=ctx.scriptURLs.count||ctx.scriptBytes>=1024*1024||ctx.collectedMedia.count>=500){[self finishScripts:ctx];return;}
    NSURL *scriptURL=ctx.scriptURLs[ctx.scriptIndex++];
    __block ZZStaticHTMLProbeContext *child;
    // 子请求带来源页（页面地址）→ 只有这时才设 Referer 头。
    child=[self startURL:scriptURL referer:ctx.originalURL mediaCompletion:nil htmlCompletion:^(NSString *text,NSURL *finalURL,NSError *error){
        if(ctx.cancelled||ctx.finished||ctx.scriptsDone)return;
        ctx.scriptBytes=MIN(ctx.scriptBytes,NSUIntegerMax-child.receivedBytes)+child.receivedBytes;
        if(!error&&text.length){
            NSArray *found=[RDStaticScriptAnalyzer mediaInScript:text
                                                       scriptURL:finalURL ?: scriptURL
                                                     sourcePage:ctx.originalURL
                                               documentBaseURL:ctx.documentBaseURL ?: (ctx.originalURL ?: scriptURL)];
            [ctx.collectedMedia addObjectsFromArray:[found subarrayWithRange:NSMakeRange(0,MIN(found.count,500-ctx.collectedMedia.count))]];
        }
        ctx.scriptToken=nil;
        [self nextScript:ctx];
    } byteLimit:MIN((NSUInteger)256*1024,(NSUInteger)1024*1024-ctx.scriptBytes)];
    ctx.scriptToken=child;
}

// 页面发现的媒体候选与页面地址执行同一安全标准（URLPolicy）：
// 文本阶段同步校验（scheme/localhost/IP 字面量/私网字样），通过者再逐一
// 异步 DNS 解析并逐 IP 预校验（不是实际 peer-IP 绑定）；拒绝即剔除该候选，
// 全部拒绝时以空结果完成（不透传被策略拒绝的 URL）。
- (void)verifyMediaCandidates:(NSArray<DetectedMedia *> *)media
                      context:(ZZStaticHTMLProbeContext *)ctx {
    if (!media.count) {
        [self finishContext:ctx media:@[] error:nil];
        return;
    }
    NSMutableArray<DetectedMedia *> *pending = [NSMutableArray array];
    for (DetectedMedia *m in media) {
        NSURL *u = [NSURL URLWithString:m.mediaURL ?: @""];
        if (u && [self.gate textDecisionForURL:u].allowed && u.host.length) {
            [pending addObject:m];
        }
    }
    if (!pending.count) {
        [self finishContext:ctx media:@[] error:nil];
        return;
    }
    NSMutableArray<DetectedMedia *> *approved = [NSMutableArray array];
    __block NSUInteger remaining = pending.count;
    __weak typeof(self) w = self;
    for (DetectedMedia *m in pending) {
        [self.gate verifyURLAsync:[NSURL URLWithString:m.mediaURL]
                       completion:^(URLPolicyDecision *decision) {
            __strong typeof(w) s = w;
            if (!s) return;
            if (ctx.cancelled) return;   // 校验期间被取消：finishContext 已作废
            if (decision.allowed) [approved addObject:m];
            remaining -= 1;
            if (remaining == 0 && !ctx.finished) {
                [s finishContext:ctx media:[approved copy] error:nil];
            }
        }];
    }
}

@end
