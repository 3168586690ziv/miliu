//
//  RealWebSocketScanTests.m — 注入脚本「WebSocket 帧媒体地址扫描」真实 WebKit 端到端测试
//
//  场景（第 44 轮）：媒体地址只出现在 WebSocket 文本帧里，页面 HTML 从不包含、
//  也从不请求它们 —— 因此 media 列表里出现这些地址只可能来自新增的 WS 帧解析。
//  服务器夹具：fixtures/websocket_scan_server.py（路由见文件头）。
//
//  本套件同时验证：
//   · JSON 内嵌地址（source=websocket_body）与裸 URL 文本帧（source=websocket）；
//   · >2MB 填充帧被长度闸挡住，不产生垃圾条目、不崩溃；
//   · 幂等：生产脚本重复注入不重复上报；
//   · WS 钩子失败（window.WebSocket 取值即抛）时脚本其余钩子仍工作；
//   · 原生桥接零拒收。
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import "WebProbe.h"
#import "URLPolicy.h"
#import "DNSResolver.h"
#import "DetectedMedia.h"

// 与 RealSiteProbe.m / RealBodyScanTests.m 的夹具策略同构：仅放行解析到 127.0.0.1 的目标
// （SSRF 防线原样保留）。类名独立，避免与其它套件的夹具符号冲突。
@interface WSLoopbackFixturePolicy : URLPolicy
@end
@implementation WSLoopbackFixturePolicy
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
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips
                          resolutionStatus:(DNSResolutionStatus)status {
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow] : [super evaluateResolvedURL:url resolvedIPs:ips resolutionStatus:status];
}
- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current {
    return [self rd_isLoopbackFixtureURL:target] ? [URLPolicyDecision allow] : [super evaluateRedirect:target fromURL:current];
}
@end

static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }

static BOOL mediaListHasURL(NSArray<DetectedMedia *> *media, NSString *needle, NSString **foundSource) {
    for (DetectedMedia *m in media) {
        if ([m.mediaURL containsString:needle]) {
            if (foundSource) *foundSource = m.discoverySource;
            return YES;
        }
    }
    return NO;
}

#pragma mark - 裸 WKWebView 场景（幂等 / WS 钩子失败）

@interface WSEventSink : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@end

@implementation WSEventSink
- (instancetype)init {
    self = [super init];
    if (self) _events = [NSMutableArray array];
    return self;
}
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.body isKindOfClass:[NSDictionary class]]) [self.events addObject:(NSDictionary *)message.body];
}
@end

// scripts 按数组顺序在 document start 注入（生产注入点相同）。返回收集到的事件。
static NSArray<NSDictionary *> *WSRunScenario(NSString *urlString, NSArray<NSString *> *scripts,
                                              NSTimeInterval timeout) {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WSEventSink *sink = [WSEventSink new];
    [cfg.userContentController addScriptMessageHandler:sink name:@"rdBridge"];
    for (NSString *src in scripts) {
        [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:src
                                                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                    forMainFrameOnly:NO]];
    }
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 2, 2) configuration:cfg];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        usleep(20000);
    }
    // 让最后几个 postMessage 落地（WKScriptMessage 投递走主线程队列）。
    for (int i = 0; i < 10; i++) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        usleep(20000);
    }
    [webView stopLoading];
    return [sink.events copy];
}

// 在已注入钩子的页面里求值一个 JS 表达式，返回字符串结果（用于验证 WebSocket
// 构造器语义：instanceof 与静态常量不得被包装破坏）。
static NSString *WSEvaluateInPage(NSString *urlString, NSString *script, NSString *expression) {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WSEventSink *sink = [WSEventSink new];
    [cfg.userContentController addScriptMessageHandler:sink name:@"rdBridge"];
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script
                                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                forMainFrameOnly:NO]];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 2, 2) configuration:cfg];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        usleep(20000);
    }
    __block NSString *out = nil;
    __block BOOL done = NO;
    [webView evaluateJavaScript:expression completionHandler:^(id result, NSError *error) {
        out = error ? [@"ERR:" stringByAppendingString:error.localizedDescription ?: @""] : [result description];
        done = YES;
    }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        usleep(20000);
    }
    [webView stopLoading];
    return out ?: @"(nil)";
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *base = NSProcessInfo.processInfo.environment[@"RD_WEBSOCKET_SCAN_HTTP"];
    if (!base.length) { printf("FAIL missing RD_WEBSOCKET_SCAN_HTTP\n"); return 1; }
    NSURL *pageURL = [NSURL URLWithString:[base stringByAppendingString:@"/"]];

    // ---------- 主场景：真实探测链路（动态腿 + 请求腿，与生产同构） ----------
    RDWebViewProbeLoader *loader = [RDWebViewProbeLoader new];
    WebProbe *probe = [[WebProbe alloc] initWithPolicy:[WSLoopbackFixturePolicy new]];
    probe.loader = loader;
    probe.hardTimeout = 90.0;
    __block RDProbeResult *result = nil;
    __block AppError *probeError = nil;
    [probe probeURL:pageURL.absoluteString
         completion:^(RDProbeResult *r, AppError *error, NSUInteger gen) {
             (void)gen; result = r; probeError = error;
         }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:90];
    while (!result && !probeError && deadline.timeIntervalSinceNow > 0) {
        usleep(100000);
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
    if (!result) {
        printf("FAIL probe did not deliver (error=%s)\n",
               probeError ? probeError.message.UTF8String : "timeout");
        return 1;
    }
    NSArray<DetectedMedia *> *media = result.media ?: @[];
    printf("WS-MEDIA %lu 条\n", (unsigned long)media.count);
    for (DetectedMedia *m in media) {
        printf("WS-ITEM %s | source=%s\n", m.mediaURL.UTF8String, (m.discoverySource ?: @"").UTF8String);
    }

    NSString *source = nil;
    check(mediaListHasURL(media, @"ws_only.mp4", &source), "mp4 URL inside WS JSON text frame discovered");
    check(source && [source containsString:@"websocket"], "mp4 discovery source carries websocket marker");
    source = nil;
    check(mediaListHasURL(media, @"ws_plain.webm", &source), "bare URL in WS text frame discovered");
    check(source && [source containsString:@"websocket"], "webm discovery source carries websocket marker");
    check(!mediaListHasURL(media, @"filler.mp4", NULL), "over-2MB WS frame is NOT scanned (length gate)");
    source = nil;
    check(mediaListHasURL(media, @"ws_binary.m4v", &source), "media URL inside a binary (ArrayBuffer) WS frame discovered");
    check(source && [source containsString:@"websocket"], "binary frame discovery source carries websocket marker");
    check(!mediaListHasURL(media, @"ws_far_binary.m4v", NULL),
          "binary frame payload beyond the first 65536 bytes is NOT scanned (offset gate)");
    check(media.count == 3, "WS frame scan yields exactly the 3 expected entries (no garbage)");

    // 原生桥接零拒收（读生产 loader 里当前会话的 bridge 计数）。
    id session = [loader valueForKey:@"session"];
    RDScriptBridgeHandler *bridge = session ? [session valueForKey:@"bridge"] : nil;
    NSInteger accepted = bridge ? bridge.acceptedCount : -1;
    NSInteger rejected = bridge ? bridge.rejectedCount : -1;
    printf("WS-BRIDGE accepted=%ld rejected=%ld\n", (long)accepted, (long)rejected);
    check(bridge && accepted > 0 && rejected == 0, "native bridge accepted every WS report (rejectedCount==0)");

    // ---------- 幂等：同一生产脚本重复注入不重复上报 ----------
    NSString *requestScript = [RDWebViewProbeLoader requestCaptureScriptForTesting];
    NSArray<NSDictionary *> *events = WSRunScenario(pageURL.absoluteString,
                                                    @[requestScript, requestScript], 12.0);
    NSUInteger wsOnly = 0;
    for (NSDictionary *e in events) {
        if ([[e[@"url"] description] containsString:@"ws_only.mp4"]) wsOnly++;
    }
    printf("WS-IDEMPOTENT events=%lu ws_only_hits=%lu\n", (unsigned long)events.count, (unsigned long)wsOnly);
    check(wsOnly == 1, "duplicate script injection does not duplicate WS reports (seen/idempotent guard)");

    // ---------- WS 钩子失败：脚本其余钩子仍必须工作 ----------
    NSString *breakWS = @"try{Object.defineProperty(window,'WebSocket',{configurable:true,"
                        @"get:function(){throw new Error('ws-hook-boom');}});}catch(e){}";
    NSArray<NSDictionary *> *failEvents = WSRunScenario([base stringByAppendingString:@"/wsfail"],
                                                        @[breakWS, requestScript], 12.0);
    NSMutableString *failHTML = [NSMutableString string];
    for (NSDictionary *e in failEvents) {
        NSString *html = [RDBridgeEventSynthesizer syntheticHTMLForEvent:e];
        if (html.length) [failHTML appendString:html];
    }
    RDProbeResult *failResult = [RDProbeAnalyzer analyzeHTML:failHTML baseURL:[NSURL URLWithString:base]];
    NSArray<DetectedMedia *> *failMedia = failResult.media ?: @[];
    printf("WS-FAILHOOK events=%lu media=%lu\n", (unsigned long)failEvents.count, (unsigned long)failMedia.count);
    check(mediaListHasURL(failMedia, @"control.png", NULL), "WS hook failure: <img> path still reports media");
    check(mediaListHasURL(failMedia, @"control2.mp4", NULL), "WS hook failure: fetch body path still reports media");
    // 反向：钩子确实被弄坏了 —— 否则上面两条「其余钩子仍工作」不足以证明故障隔离，
    // 可能只是该场景里 WS 帧恰好没被解析。
    check(!mediaListHasURL(failMedia, @"ws_only.mp4", NULL), "WS hook failure: WS frames really are not parsed (hook disabled)");


    // ---------- WebSocket 构造器语义未被包装破坏（instanceof / 静态常量） ----------
    NSString *semantics = WSEvaluateInPage(pageURL.absoluteString, requestScript,
        @"(function(){try{var w=new WebSocket('ws://127.0.0.1:1/none');"
         "var r=(w instanceof WebSocket)+'|'+WebSocket.OPEN+'|'+WebSocket.CONNECTING+'|'"
         "+WebSocket.CLOSING+'|'+WebSocket.CLOSED+'|'+(typeof w.addEventListener);"
         "try{w.close();}catch(e){}return r;}catch(e){return 'THREW:'+e.message;}})()");
    printf("WS-SEMANTICS %s\n", semantics.UTF8String);
    check([semantics isEqualToString:@"true|1|0|2|3|function"],
          "WebSocket wrapper keeps instanceof and OPEN/CONNECTING/CLOSING/CLOSED constants");

    printf("%s\n", failures == 0 ? "ALL PASS" : "HAS FAILURES");
    return failures == 0 ? 0 : 1;
}}
