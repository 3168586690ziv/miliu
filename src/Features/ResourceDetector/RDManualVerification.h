//
//  RDManualVerification.h — hotfix-resource-manual-verification-resume-01
//
//  网页资源探测「用户手动完成人机验证后继续探测」的生产逻辑。
//
//  设计红线（强制）：
//  - 仅识别页面公开信号（文案/标题），绝不读取、打印、持久化或跨域发送 Cookie；
//  - 绝不替用户点击验证、绝不模拟任何验证过程、绝不借助第三方识别服务、绝不伪造身份；
//  - 验证窗口与隐藏的资源探测 WebView 共享同一个 WKWebsiteDataStore，仅允许同源会话自然延续；
//  - 每次用户操作最多恢复一次真实探测，不循环、不自动重试。
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 验证页面识别（纯函数，仅看公开文案信号）

@interface RDVerificationDetector : NSObject

// 仅依据页面 HTML/标题中的公开信号判断是否为人机验证/安全挑战页。
// statusCode 仅用于辅助区分（401 登录失效、普通 403/404/DRM 等若不含挑战短语一律不判定）。
+ (BOOL)pageRequiresHumanVerificationWithHTML:(NSString * _Nullable)html
                                        title:(NSString * _Nullable)title
                                httpStatusCode:(NSInteger)statusCode;

// 生成面向用户的「需要手动验证」原因说明（固定模板，不外泄任何内部信息）。
+ (NSString *)localizedReasonForVerificationPageWithHTML:(NSString * _Nullable)html
                                                   title:(NSString * _Nullable)title;

@end

#pragma mark - 手动验证流程控制器（无 GUI 依赖，可独立测试真实逻辑）

@interface RDManualVerificationController : NSObject

#pragma mark App 会话存储（探测 WebView 与验证窗口的唯一共享实例）

// App 容器内的**持久化**网站数据存储（= WKWebsiteDataStore.defaultDataStore）。
// 资源探测 WebView（WebProbe / ProductionDiscoveryHTMLProvider）与手动验证窗口
// 必须都从这里取同一个实例：会话（含用户手动完成人机验证后拿到的通行证）才能
// 跨探测延续，否则每次探测都是一位全新访客。
// 边界：只使用 App 自己容器内的存储，绝不共享或读取 Safari 的数据。
// 隐私：App 只让 WebKit 自己保管 Cookie —— 代码不读取、不打印、不导出任何 Cookie 内容。
+ (WKWebsiteDataStore *)sharedSessionDataStore;

// 清除 App 自己的全部网站数据（Cookie / 缓存 / 本地存储 / IndexedDB 等）。
// 只作用于 App 容器内的存储，不触碰 Safari 或系统其它 App 的数据；
// 不读取、不打印被清除的内容，只在完成后回调（主线程）。
+ (void)clearSharedSessionDataStoreWithCompletion:(void (^ _Nullable)(void))completion;

@property (nonatomic, copy, nullable) NSString *pendingURL;            // 待恢复探测的 URL
@property (nonatomic, strong, nullable) WKWebsiteDataStore *sharedDataStore; // 与资源探测 WebView 共享
@property (nonatomic, strong, nullable) NSWindow *verificationWindow;  // 可见验证窗口（GUI 创建后注入）
@property (nonatomic, strong, nullable) WKWebView *verificationWebView;// 可见验证 WebView（GUI 创建后注入）
@property (nonatomic, assign) BOOL isPresenting;        // 是否处于「等待用户手动验证」状态
@property (nonatomic, assign) BOOL verificationPresent;  // GUI 据可见页内容更新：挑战是否仍在
@property (nonatomic, assign, readonly) NSUInteger resumeCallCount;   // resumeAfterVerification 被调用次数
@property (nonatomic, assign, readonly) NSUInteger actualResumeCount;  // 实际成功恢复探测次数
// GUI 注入：用同一个 URL + 同一个会话恢复真实资源探测（每次最多触发一次）。
@property (nonatomic, copy, nullable) void (^resumeHandler)(NSString *url);

// 进入手动验证：记录 URL 与共享会话，标记等待状态（不创建任何窗口）。
- (void)prepareVerificationForURL:(NSString *)url dataStore:(WKWebsiteDataStore *)store;

// 生成可见验证 WebView 的配置：websiteDataStore 强制等于 sharedDataStore（同源共享）。
- (WKWebViewConfiguration *)verificationWebViewConfiguration;

// GUI 创建并展示可见窗口后注入引用（用于关闭/状态清理）。
- (void)attachVerificationWindow:(NSWindow *)window webView:(WKWebView *)webView;

// 挑战是否仍在（依据 verificationPresent；webView 仅作兼容参数）。
- (BOOL)verificationStillPresentInWebView:(WKWebView * _Nullable)webView;

// 用户点击「验证完成，继续探测」：挑战已消失→关闭窗口并恢复一次探测（返回 YES）；
// 挑战仍在→返回 NO（不关闭、不循环、不自动重试）。未处于等待态→直接 NO。
- (BOOL)resumeAfterVerification;

// 用户点击「取消」：关闭窗口、清理待恢复状态，绝不恢复探测。
- (void)cancelManualVerification;

// 新链接 / 切页 / 退出 App：关闭窗口、清理待恢复状态，绝不恢复探测。
- (void)cleanupManualVerification;

@end

NS_ASSUME_NONNULL_END
