//
//  RDWatchlistPage.h — 追更页（主窗口内切页，与下载列表同级）
//
//  「追更 v1」App 侧页面主体（WATCH-V1-CONTRACT §3.4/§3.5，基准＝已定稿预览稿）：
//  · 工具栏：＋添加当前页 / ↻全部重探 / 摘要（N 个页面 · M 个未读 · 助手运行态）
//  · 观察列表：行高 58，间隔分段 15·30·60·120 改动即持久化，状态胶囊
//    （＋N 新资源 / 无更新 / 已暂停 / 失败：<lastError 摘要>），查看 / 重探 / 开关 / 删除
//  · 设置卡四行：开机自启 / 新资源通知 / 静音时段（00:00–08:00 / 关闭）/ 判定范围（v1 固定仅视频，置灰注明 v2）
//
//  数据一律经 RDWatchlistStore（App 与助手唯一共享存储，禁另建第二套）；
//  跨进程通知名与助手 bundle id 在下方以常量定死（契约 §3.1/§3.2/§3.5），勿改字面值。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// ── 跨进程契约常量（字面值定死于契约，勿改）──
/// 助手 → App：唤醒Miliu并自动探测目标页（userInfo {pageURL: 地址}）。App 侧在
/// applicationDidFinishLaunching 注册观察者（接收端在 ResourceDetectorApp.m）。
extern NSString *const RDWatchNotificationOpenAndScan;
/// App → 助手：立即全部重探（工具栏「全部重探」与行内「立即重探」都发它，助手监听同名通知）。
extern NSString *const RDWatchNotificationWatchNow;
/// App → 助手：开机自启注册/注销 SMAppService（userInfo {enabled: BOOL}）。
extern NSString *const RDWatchNotificationWatchService;
/// 助手 bundle id（运行态检测：NSWorkspace.runningApplications 查它）。
extern NSString *const RDWatchAgentBundleIdentifier;

@class RDWatchlistEntry;
@class RDWatchlistPageController;

/// App 侧回调：页面只管本页 UI 与观察库数据；切页 / 填址 / 探测由 ResourceDetectorAppDelegate 执行。
@protocol RDWatchlistPageDelegate <NSObject>
/// 用户点了返回（页面不自己切页）。
- (void)watchlistPageDidRequestBack;
/// 行「查看」或行点按：markPendingRead 已由页面完成，App 负责 回主页 + 填址 + scan:。
- (void)watchlistPageDidRequestOpenPageURL:(NSString *)pageURL;
/// 「＋添加当前页」取主页地址栏当前内容（可能为空或非法，页面自行校验）。
- (nullable NSString *)watchlistPageCurrentAddressForWatchlist;
@end

@interface RDWatchlistPageController : NSObject

/// 页面根视图（App 作为同窗口第四个页面容器加入 contentView，靠 hidden 切换）。
@property (nonatomic, strong, readonly) NSView *pageView;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 构建整页 UI（工具栏 / 列表 / 设置卡）；delegate 弱持有。
- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(id<RDWatchlistPageDelegate>)delegate NS_DESIGNATED_INITIALIZER;

/// 页面即将显示：重读观察库、刷新助手运行态 / 摘要 / 相对时间 / 设置卡控件状态。
- (void)prepareForShow;

@end

NS_ASSUME_NONNULL_END
