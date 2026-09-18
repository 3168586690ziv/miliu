//
//  ProductionDiscoveryHTMLProvider.m — 第 5 阶段｜生产页面 HTML 来源实现
//

#import "ProductionDiscoveryHTMLProvider.h"
#import "RDManualVerification.h"   // 共享会话存储（探测 WebView 与验证窗口同一实例）
#import "URLPolicy.h"
#import "ResourceURLGate.h"

static const NSTimeInterval kHTMLLoadTimeout = 20.0;
static const NSUInteger kHTMLMaxBytes = 8 * 1024 * 1024;

// 默认工厂：主线程创建离屏真实 WKWebView（App 容器内的持久化会话存储由
// 调用方在 configuration 上配置，与手动验证窗口共用同一实例）。
@interface ZZDiscoveryDefaultWebViewFactory : NSObject <ZZDiscoveryWebViewFactory>
@end

@implementation ZZDiscoveryDefaultWebViewFactory

- (WKWebView *)makeWebViewWithConfiguration:(WKWebViewConfiguration *)configuration {
    return [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 960, 540) configuration:configuration];
}

@end

@interface ProductionDiscoveryHTMLProvider ()
@property (nonatomic, strong, nullable) WKWebView *webView;   // 仅主线程读写
@property (nonatomic, strong) id<ZZDiscoveryWebViewFactory> webViewFactory;
@property (nonatomic, strong) ResourceURLGate *gate;
@property (nonatomic, assign) NSInteger generation;
@property (nonatomic, copy, nullable) ZZDiscoveryHTMLCompletion pendingCompletion;
@property (nonatomic, strong, nullable) dispatch_source_t timeoutTimer;
@property (nonatomic, strong, nullable) WKNavigation *pendingNavigation;
@property (nonatomic, assign) NSInteger pendingNavigationGeneration;
@end

@implementation ProductionDiscoveryHTMLProvider

- (instancetype)init {
    return [self initWithWebViewFactory:nil];
}

- (instancetype)initWithWebViewFactory:(nullable id<ZZDiscoveryWebViewFactory>)factory {
    self = [super init];
    if (self) {
        _gate = [ResourceURLGate new];  // 生产模式：文本 + DNS 全链路校验
        _webViewFactory = factory ?: [ZZDiscoveryDefaultWebViewFactory new];
    }
    return self;
}

- (void)dealloc {
    if (_timeoutTimer) dispatch_source_cancel(_timeoutTimer);
}

- (nullable id)loadHTMLForURL:(NSURL *)url
                   completion:(ZZDiscoveryHTMLCompletion)completion {
    if (!completion) return nil;
    if (url == nil || url.absoluteString.length == 0) {
        completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil]);
        return nil;
    }
    __block NSInteger gen = 0;
    void (^start)(void) = ^{
        // 新请求顶替旧请求：状态、导航和定时器统一由主线程拥有。
        self.generation += 1;
        gen = self.generation;
        if (self.timeoutTimer) { dispatch_source_cancel(self.timeoutTimer); self.timeoutTimer = nil; }
        self.pendingCompletion = [completion copy];
        self.pendingNavigation = nil;
        self.pendingNavigationGeneration = gen;
        [self loadRequestOnMainThreadForURL:url generation:gen];
        [self armTimeoutTimerForGeneration:gen];
    };
    if ([NSThread isMainThread]) start();
    else dispatch_sync(dispatch_get_main_queue(), start);
    return @(gen);
}

// WebKit 会话启动（仅主线程）：懒创建 WebView 并发起加载。
- (void)loadRequestOnMainThreadForURL:(NSURL *)url generation:(NSInteger)gen {
    NSAssert([NSThread isMainThread], @"ProductionDiscoveryHTMLProvider 的 WebKit 操作只允许在主线程");
    if (!self.webView) {
        WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
        // 会话延续（第 13 轮）：这里原来出于安全加固用了 nonPersistentDataStore，
        // 结果是每次探测都是一位全新访客 —— Cookie、会话、以及用户手动完成人机验证
        // 后拿到的通行证，探测一结束全部丢弃。现改为 App 容器内的**持久化**存储，
        // 并与手动验证窗口共用同一个实例（RDSharedSessionDataStore），会话才能跨探测延续。
        // 边界不变：只用 App 自己的存储，不共享/不读取 Safari 数据；
        // Cookie 只由 WebKit 自己保管，本代码不读取、不打印、不导出。
        cfg.websiteDataStore = [RDManualVerificationController sharedSessionDataStore];
        self.webView = [self.webViewFactory makeWebViewWithConfiguration:cfg];
        self.webView.navigationDelegate = self;
    }
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:15.0];
    if (gen != self.generation) return;
    self.pendingNavigation = [self.webView loadRequest:req];
    self.pendingNavigationGeneration = gen;
}

- (void)cancelHTMLRequest:(nullable id)requestToken {
    void (^cancel)(void) = ^{
        if (requestToken && [requestToken respondsToSelector:@selector(integerValue)] &&
            [requestToken integerValue] != self.generation) return;
        self.generation += 1;               // 迟到回调作废
        self.pendingCompletion = nil;
        self.pendingNavigation = nil;
        if (self.timeoutTimer) { dispatch_source_cancel(self.timeoutTimer); self.timeoutTimer = nil; }
        [self stopLoadingOnMainThread];
    };
    if ([NSThread isMainThread]) cancel();
    else dispatch_async(dispatch_get_main_queue(), cancel);
}

// 停止当前加载（仅主线程）；webView 属性读取同样收敛在主线程。
- (void)stopLoadingOnMainThread {
    NSAssert([NSThread isMainThread], @"ProductionDiscoveryHTMLProvider 的 WebKit 操作只允许在主线程");
    [self.webView stopLoading];
}

#pragma mark - 完成回调（generation 校验后主线程触发）

- (void)finishWithGeneration:(NSInteger)gen
                       html:(NSString * _Nullable)html
                   finalURL:(NSURL * _Nullable)finalURL
                      error:(NSError * _Nullable)error {
    if (gen != self.generation) return;  // 已取消/被顶替
    ZZDiscoveryHTMLCompletion cb = self.pendingCompletion;
    self.pendingCompletion = nil;
    if (self.timeoutTimer) { dispatch_source_cancel(self.timeoutTimer); self.timeoutTimer = nil; }
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        cb(html, finalURL, error);
    });
}

- (void)armTimeoutTimerForGeneration:(NSInteger)gen {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    self.timeoutTimer = t;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHTMLLoadTimeout * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    __weak typeof(self) w = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(w) s = w;
        if (!s) return;
        [s stopLoadingOnMainThread];   // 定时器固定主队列：主线程 stopLoading
        [s finishWithGeneration:gen html:nil finalURL:nil
                          error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
                                                 userInfo:@{NSLocalizedDescriptionKey : @"页面加载超时"}]];
    });
    dispatch_resume(t);
}

#pragma mark - WKNavigationDelegate（安全边界与生产资源探测 WebView 对齐）

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // 子框架也必须经过同一地址策略，避免恶意页面借广告 iframe 探测
    // 本机/私网；被拒绝时只取消该 iframe，不让主页面探测失败。
    BOOL isMainFrame = navigationAction.targetFrame.isMainFrame;
    NSURL *target = navigationAction.request.URL;
    // WebKit 内部空白文档 about:blank：不访问网络，允许（对齐生产实现）
    if ([target.scheme.lowercaseString isEqualToString:@"about"] &&
        [target.absoluteString.lowercaseString isEqualToString:@"about:blank"] &&
        navigationAction.navigationType == WKNavigationTypeOther) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (!self.gate.rd_checksEnabled) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // 文本校验（含重定向目标）→ DNS 解析后全 IP 校验（decisionHandler 允许异步）
    URLPolicyDecision *d = [self.gate.policy evaluateRedirect:target fromURL:webView.URL];
    if (!d.allowed) {
        if (isMainFrame) {
            [self finishWithGeneration:self.generation html:nil finalURL:nil
                                 error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL
                                                        userInfo:@{NSLocalizedDescriptionKey : d.userMessage}]];
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    __weak typeof(self) w = self;
    NSInteger gen = self.generation;
    [self.gate verifyURLAsync:target completion:^(URLPolicyDecision *vd) {
        __strong typeof(w) s = w;
        if (!s) { decisionHandler(WKNavigationActionPolicyCancel); return; }
        if (gen != s.generation) { decisionHandler(WKNavigationActionPolicyCancel); return; }
        if (!vd.allowed) {
            if (isMainFrame) {
                [s finishWithGeneration:gen html:nil finalURL:nil
                                 error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL
                                                        userInfo:@{NSLocalizedDescriptionKey : vd.userMessage}]];
            }
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
        decisionHandler(WKNavigationActionPolicyAllow);
    }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (navigation != self.pendingNavigation || self.pendingNavigationGeneration != self.generation) return;
    NSInteger gen = self.generation;
    __weak typeof(self) w = self;
    [webView evaluateJavaScript:@"document.documentElement.outerHTML"
               completionHandler:^(id _Nullable html, NSError * _Nullable err) {
        __strong typeof(w) s = w;
        if (!s) return;
        if (gen != s.generation || navigation != s.pendingNavigation) return;
        if (err != nil || ![html isKindOfClass:[NSString class]]) {
            [s finishWithGeneration:gen html:nil finalURL:webView.URL
                              error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotParseResponse
                                                     userInfo:@{NSLocalizedDescriptionKey : @"页面内容读取失败",
                                                                NSUnderlyingErrorKey : (err ?: [NSError new])}]];
            return;
        }
        NSString *s_html = (NSString *)html;
        if ([s_html lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kHTMLMaxBytes) {
            [s finishWithGeneration:gen html:nil finalURL:webView.URL
                               error:[NSError errorWithDomain:NSURLErrorDomain
                                                          code:NSURLErrorDataLengthExceedsMaximum
                                                      userInfo:@{NSLocalizedDescriptionKey : @"页面内容超过 8 MB 安全上限"}]];
            return;
        }
        [s finishWithGeneration:gen html:s_html finalURL:webView.URL error:nil];
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (navigation != self.pendingNavigation || self.pendingNavigationGeneration != self.generation) return;
    [self finishWithGeneration:self.generation html:nil finalURL:nil error:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (navigation != self.pendingNavigation || self.pendingNavigationGeneration != self.generation) return;
    [self finishWithGeneration:self.generation html:nil finalURL:nil error:error];
}

@end
