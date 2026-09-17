//
//  WebProbe.h — 模块 17｜网页探测核心
//
//  包含：
//  - RDProbeResult      探测结果（纯模型）
//  - RDProbeAnalyzer    纯函数：HTML → 结构化结果（视频/DRM/坏页）
//  - RDProbeProvider    给 ViewModel 的探测入口协议（含 generation）
//  - RDProbeLoader      实际取页协议（GUI 用 WebView；测试注入 mock）
//  - RDScriptBridgeHandler  WebView script bridge，仅收固定字典、限长/限条目/限总量
//  - WebProbe            generation + 取消 + 硬超时；旧代次回调失效
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "DetectedMedia.h"
#import "URLPolicy.h"
#import "AppError.h"
#import "HTTPResult.h"
#import "HTTPClient.h"
#import "RDResourceDisplayMetadata.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 探测结果

@interface RDProbeResult : NSObject
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, copy) NSString *ogTitle;                 // <meta property="og:title">
@property (nonatomic, copy) NSString *ogImageURL;            // <meta property="og:image">（绝对 URL）
@property (nonatomic, copy) NSArray<DetectedMedia *> *media;  // 已去重
@property (nonatomic, assign) BOOL hasVideo;
@property (nonatomic, assign) RDDrmType drmType;
@property (nonatomic, assign) BOOL isBadPage;                  // 坏页面/无内容/解析失败
/// 页面使用 MediaSource/Blob 播放但无法还原原始 URL 时的可解释线索数。
@property (nonatomic, assign) NSUInteger unresolvedMediaClueCount;
@property (nonatomic, copy) NSArray<NSDictionary *> *mediaClues;

/// 从解析结果中挑选最佳的展示元数据（标题 + 预览图）。
- (RDResourceDisplayMetadata *)bestDisplayMetadataForSourcePageURL:(NSURL *)sourcePageURL;
@end

#pragma mark - 纯分析器（无 GUI、可 headless 测试）

@interface RDProbeAnalyzer : NSObject
// 纯函数：分析 HTML 与 baseURL，返回结构化结果。html 为空/解析失败 → isBadPage=YES。
+ (RDProbeResult *)analyzeHTML:(NSString * _Nullable)html baseURL:(NSURL * _Nullable)baseURL;
@end

#pragma mark - 取页协议

@protocol RDProbeLoader <NSObject>
// 取回页面 HTML；policy 用于重定向/DNS 阶段再校验（返回非 nil error 表示被策略拒绝或失败）。
// 回调线程由实现方决定；生产实现 RDWebViewProbeLoader 固定在主线程回调，
// 每次任务的 completion 恰好投递一次，且旧任务回调绝不影响新任务。
- (nullable HTTPTask *)loadPageAtURL:(NSURL *)url
                              policy:(URLPolicy *)policy
                          completion:(void (^)(NSString * _Nullable html, AppError * _Nullable error))completion;
@optional
// 带本次任务 HTML 上限的扩展取页：上限绑定在任务上下文内（逐任务生效），
// 实现方不得依赖任何跨线程可变属性。支持该方法的实现会被 WebProbe 优先调用。
- (nullable HTTPTask *)loadPageAtURL:(NSURL *)url
                              policy:(URLPolicy *)policy
                         maxHTMLBytes:(NSUInteger)maxHTMLBytes
                          completion:(void (^)(NSString * _Nullable html, AppError * _Nullable error))completion;
// 任意线程可调：异步失效当前在途任务（不触发其 completion），主线程停止加载。
- (void)cancelActiveLoad;
@end

#pragma mark - 给 ViewModel 的探测入口（含 generation）

@protocol RDProbeProvider <NSObject>
// 返回本次探测的 generation；旧 generation 的结果不应被上层采用。
- (NSUInteger)probeURL:(NSString *)urlString
            completion:(void (^)(RDProbeResult * _Nullable result, AppError * _Nullable error, NSUInteger generation))completion;
- (void)cancelAll;
@end

#pragma mark - Script bridge（仅收固定字典，限长/限条目/限总量）

// 动态事件 → 可解析 HTML 的转换单元（生产 bridge 与测试共用同一实现）：
// 仅接受 action=resource、http/https URL 与 image/video/manifest 类型的
// 事件，输出可被 RDProbeAnalyzer 解析的标签；非法事件返回空串。
@interface RDBridgeEventSynthesizer : NSObject
+ (NSString *)syntheticHTMLForEvent:(NSDictionary *)event;
@end

@interface RDScriptBridgeHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, copy, nullable) void (^eventHandler)(NSDictionary *event);
@property (nonatomic, assign) NSUInteger maxStringLength;  // 单字符串最大长度，默认 2048
@property (nonatomic, assign) NSUInteger maxItems;         // 字典最大条目数，默认 64
@property (nonatomic, assign) NSUInteger maxTotalBytes;    // 负载最大字节，默认 64KB
@property (nonatomic, assign) NSInteger acceptedCount;     // 通过的消息数（测试观测）
@property (nonatomic, assign) NSInteger rejectedCount;     // 拒绝的消息数（测试观测）
// 纯校验：body 必须是字典、键固定、各字符串不超长、条目不超、总字节不超。
- (BOOL)validateBridgePayload:(id)body reason:(NSString * _Nullable * _Nullable)reason;
// 允许的消息键（固定集合）
- (NSSet<NSString *> *)allowedKeys;
@end

#pragma mark - WebView 探测 loader（主线程会话模型，可注入工厂）

// 会话内对 WebView 的最小操作面：生产用真实 WKWebView（由默认工厂创建），
// 测试可注入 mock 以验证线程归属与回调隔离。
@protocol RDProbeWebView <NSObject>
@property (nonatomic, nullable, weak) id<WKNavigationDelegate> navigationDelegate;
// 真实 WKWebView 的 loadRequest: 返回 WKNavigation*；协议忽略返回值
// （非 init/new/copy 族方法按 +0 约定，调用点不持有该返回对象）。
- (void)loadRequest:(NSURLRequest *)request;
- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(void (^ _Nullable)(id _Nullable result, NSError * _Nullable error))completionHandler;
- (void)stopLoading;
@end

// WebView 工厂：必须且只会在主线程被调用。
@protocol RDProbeWebViewFactory <NSObject>
- (id<RDProbeWebView>)makeWebViewWithConfiguration:(WKWebViewConfiguration *)configuration;
@end

// 默认工厂：主线程创建离屏 WKWebView（NSZeroRect）。
@interface RDDefaultWebViewFactory : NSObject <RDProbeWebViewFactory>
@end

// GUI 取页器。线程模型：
// · WKWebView / WKWebViewConfiguration / WKUserContentController /
//   navigationDelegate / loadRequest / evaluateJavaScript / stopLoading /
//   removeScriptMessageHandlerForName 全部只在主线程创建与调用；
// · 每次 loadPageAtURL 生成独立任务会话（绑定 URL/policy/completion/
//   取消状态/任务 token/HTML 上限），旧任务在途回调一律作废；
// · completion 固定主线程回调、每任务恰好一次；
// · detach 仅拆除当前 WebKit 会话，loader 之后仍可复用（新任务自动重建）。
@interface RDWebViewProbeLoader : NSObject <RDProbeLoader>
// 默认 HTML 上限（仅作为未显式传上限的兼容路径的缺省值）
@property (nonatomic, assign) NSUInteger maxHTMLBytes;
- (instancetype)init;
- (instancetype)initWithWebViewFactory:(id<RDProbeWebViewFactory>)factory;
// 带本次任务 HTML 上限的取页（任意线程可调；内部异步到主线程开会话）
- (nullable HTTPTask *)loadPageAtURL:(NSURL *)url
                              policy:(URLPolicy *)policy
                         maxHTMLBytes:(NSUInteger)maxHTMLBytes
                          completion:(void (^)(NSString * _Nullable html, AppError * _Nullable error))completion;
// 任意线程可调：失效并停止当前在途任务（不触发其 completion）
- (void)cancelActiveLoad;
// 页面离开时清理：主线程停止加载、移除 script handler、释放 WebKit 对象；
// 不使 loader 永久不可复用——后续新探测任务会重建会话。
- (void)detach;
/// 供 headless 回归检查实际生产注入脚本的能力清单；返回值只读，不改变运行时状态。
+ (NSString *)dynamicCaptureScriptForTesting;
+ (NSString *)requestCaptureScriptForTesting;
@end

#pragma mark - WebProbe

@interface WebProbe : NSObject <RDProbeProvider>
@property (nonatomic, strong) URLPolicy *policy;
@property (nonatomic, strong, nullable) id<RDProbeLoader> loader;  // 默认 RDWebViewProbeLoader（GUI）
@property (nonatomic, assign) NSTimeInterval hardTimeout;          // 默认 30s
// 资源耗尽防护：outerHTML 最大字节数（默认 8MB），超出视为解析失败
@property (nonatomic, assign) NSUInteger maxHTMLBytes;
- (instancetype)initWithPolicy:(URLPolicy *)policy;
// 页面离开时调用：停止隐藏 WebView 的非必要监听并移除 script handler。
- (void)detachWebView;
@end

NS_ASSUME_NONNULL_END
