//
//  RDInAppBrowserWindow.h — 应用内浏览器窗口（用户主动登录用）
//
//  背景（2026-10-05 第 21 轮）：部分站点的视频地址只出现在**需要登录**的接口响应里
//  （例：X/Twitter 的 GraphQL 响应体），而探测 WebView 是离屏的、用户无法登录。
//  本窗口与探测 WebView 共用同一持久会话存储（WKWebsiteDataStore.defaultDataStore）：
//  用户在此手动登录任意站点，Cookie 留在 App 容器内，下次探测自动携带。
//  边界：不读取、不打印、不导出会话内容；「清除网站会话」仍然只清 App 容器内存储。
//

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 应用内浏览器窗口关闭通知（object=nil）。设置页借此刷新「已存 Cookie 登录态站点」显示。
extern NSString * const RDInAppBrowserWindowDidCloseNotification;

@interface RDInAppBrowserWindow : NSObject <NSWindowDelegate, WKNavigationDelegate>

/// 主线程调用：打开（或前置已存在的）共享会话浏览器窗口；urlString 为空时
/// 显示空白起始页，由用户在地址栏自行输入。
+ (void)openWithAbsoluteURLString:(nullable NSString *)urlString;

/// 仅供测试：当前存在的窗口实例（无则 nil）。
+ (nullable RDInAppBrowserWindow *)existingWindow;

@property (nonatomic, readonly, strong) NSWindow *window;

@end

NS_ASSUME_NONNULL_END
