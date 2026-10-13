//
//  RDInAppBrowserWindow.m — 应用内浏览器窗口实现
//
//  自包含约束：本文件编入主 App（build.sh 按 Features 目录自动收集），
//  因此只依赖同目录 Features 层与系统框架，不得反向引用 App 层。
//

#import "RDInAppBrowserWindow.h"
#import <WebKit/WebKit.h>
#import "RDManualVerification.h"

static RDInAppBrowserWindow *_sharedInstance = nil;

NSString * const RDInAppBrowserWindowDidCloseNotification = @"RDInAppBrowserWindowDidClose";

@implementation RDInAppBrowserWindow {
    NSWindow *_window;
    WKWebView *_webView;
    NSTextField *_urlField;
}

+ (void)openWithAbsoluteURLString:(NSString *)urlString {
    if (!_sharedInstance) _sharedInstance = [[RDInAppBrowserWindow alloc] init];
    [_sharedInstance showWithURLString:urlString];
}

+ (nullable RDInAppBrowserWindow *)existingWindow {
    return _sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return self;
    NSRect frame = NSMakeRect(0, 0, 1040, 720);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskTitled
                                                        | NSWindowStyleMaskClosable
                                                        | NSWindowStyleMaskMiniaturizable
                                                        | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = @"应用内浏览器（与探测共用登录）";
    win.identifier = @"RDInAppBrowserWindow";
    win.releasedWhenClosed = NO;
    win.delegate = self;

    // 顶部工具条：后退 / 前进 / 刷新 + 地址栏 + 前往。AppKit contentView 坐标系
    // **底部原点**：工具条控件必须放 y = 高度顶部一带（首批版本误放 y≈8 被从
    // y=0 铺起的 webView 整个盖住，用户只看到空白页面没有地址栏）。窗口缩放时
    // 控件以 NSViewMinYMargin 钉在顶部，webView 底部锚定高度弹性。
    CGFloat toolbarH = 40;
    CGFloat margin = 10;
    CGFloat controlY = frame.size.height - 30;

    NSButton *back = [NSButton buttonWithTitle:@"←" target:self action:@selector(goBack:)];
    back.bordered = NO;
    back.identifier = @"RDInAppBrowserBack";
    back.frame = NSMakeRect(margin, controlY, 28, 24);
    back.autoresizingMask = NSViewMinYMargin;

    NSButton *forward = [NSButton buttonWithTitle:@"→" target:self action:@selector(goForward:)];
    forward.bordered = NO;
    forward.identifier = @"RDInAppBrowserForward";
    forward.frame = NSMakeRect(NSMaxX(back.frame) + 4, controlY, 28, 24);
    forward.autoresizingMask = NSViewMinYMargin;

    NSButton *reload = [NSButton buttonWithTitle:@"⟳" target:self action:@selector(reloadPage:)];
    reload.bordered = NO;
    reload.identifier = @"RDInAppBrowserReload";
    reload.frame = NSMakeRect(NSMaxX(forward.frame) + 4, controlY, 28, 24);
    reload.autoresizingMask = NSViewMinYMargin;

    NSTextField *urlField = [[NSTextField alloc] initWithFrame:
        NSMakeRect(NSMaxX(reload.frame) + 8, controlY,
                   frame.size.width - NSMaxX(reload.frame) - 3 * margin - 64, 24)];
    urlField.placeholderString = @"输入网址并回车（登录后 Cookie 与探测共享）";
    urlField.identifier = @"RDInAppBrowserURLField";
    urlField.target = self;
    urlField.action = @selector(navigateFromField:);
    urlField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    NSButton *go = [NSButton buttonWithTitle:@"前往" target:self action:@selector(navigateFromField:)];
    go.bordered = NO;
    go.font = [NSFont systemFontOfSize:12];
    go.identifier = @"RDInAppBrowserGo";
    go.frame = NSMakeRect(frame.size.width - margin - 52, controlY, 52, 24);
    go.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    // 与探测 WebView 同一持久存储：这里登录，探测即可携带 Cookie。
    cfg.websiteDataStore = [RDManualVerificationController sharedSessionDataStore];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:
        NSMakeRect(0, 0, frame.size.width, frame.size.height - toolbarH) configuration:cfg];
    webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    webView.navigationDelegate = self;

    NSView *content = win.contentView;
    [content addSubview:webView];                                            // 底层
    for (NSView *v in @[back, forward, reload, urlField, go]) [content addSubview:v];  // 工具条在上层

    _window = win;
    _webView = webView;
    _urlField = urlField;
    return self;
}

- (void)showWithURLString:(NSString *)urlString {
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (urlString.length) [self loadAbsoluteURLString:urlString];
}

- (void)loadAbsoluteURLString:(NSString *)raw {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length == 0) return;
    // 无协议输入按 https 处理；非法输入直接忽略，不弹错。
    NSURL *url = [NSURL URLWithString:s];
    if (!url.scheme.length) url = [NSURL URLWithString:[@"https://" stringByAppendingString:s]];
    if (!url || !url.host) return;
    _urlField.stringValue = url.absoluteString;
    [_webView loadRequest:[NSURLRequest requestWithURL:url]];
}

#pragma mark - 动作

- (void)navigateFromField:(id)sender {
    [self loadAbsoluteURLString:_urlField.stringValue];
    [_window makeFirstResponder:_webView];
}

- (void)goBack:(id)sender { if (_webView.canGoBack) [_webView goBack]; }
- (void)goForward:(id)sender { if (_webView.canGoForward) [_webView goForward]; }
- (void)reloadPage:(id)sender { [_webView reload]; }

#pragma mark - WKNavigationDelegate（地址栏跟随当前页）

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    NSURL *url = webView.URL;
    if (url && url.absoluteString.length) _urlField.stringValue = url.absoluteString;
}

#pragma mark - 窗口生命周期

// 关窗即释放窗口（Cookie/存储在 WKWebsiteDataStore 内持久，不受影响）。
- (void)windowWillClose:(NSNotification *)notification {
    if (_sharedInstance == self) _sharedInstance = nil;
    _window = nil;
    _webView = nil;
    _urlField = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:RDInAppBrowserWindowDidCloseNotification object:nil];
}

@end
