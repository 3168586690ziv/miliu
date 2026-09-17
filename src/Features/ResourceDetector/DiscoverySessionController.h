//
//  DiscoverySessionController.h — 第 5 阶段｜资源发现会话控制器
//
//  组装 ResourceDiscoveryCoordinator 的生产依赖（ProductionDiscoveryPageProbe
//  包装 WebProbe + ProductionDiscoveryHTMLProvider 专用 WKWebView），
//  向 UI（资源探测页）提供最小接口：
//    startWithURL:mode: → 中文进度状态（statusHandler）
//                          → 最终结果（resultHandler，ZZResourceDiscoveryResult）
//    cancel
//
//  进度状态：内部用计数包装器观测页面探测的开始/完成/重试，
//  输出"正在读取页面链接…/正在探测第 N 个页面：…/页面加载失败，正在重试…"。
//  （协调器结果模型不提供运行中总页数，故显示已完成序号与当前页面，
//  最终汇总由 resultHandler 提供完整统计。）
//
//  线程：statusHandler/resultHandler 均在主线程回调。
//  依赖可注入（测试用 mock；生产用 initWithDefaultDependencies）。
//  无 UI 依赖、无全局可变状态。
//

#import <Foundation/Foundation.h>
#import "ResourceDiscoveryCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface DiscoverySessionController : NSObject

/// 中文进度状态（主线程；nil 表示无更新）。
@property (nonatomic, copy, nullable) void (^statusHandler)(NSString *status);

/// 0...1 的会话进度（主线程）：读取链接为 0，页面探测逐页推进，最终结果为 1。
@property (nonatomic, copy, nullable) void (^progressHandler)(double progress);

/// 任务最终结果（主线程，每任务恰好一次）。
@property (nonatomic, copy, nullable) void (^resultHandler)(ZZResourceDiscoveryResult *result);

/// 探测过程中的临时（非终态）结果（主线程，一次任务可能回调多次）：页面探测器的
/// 静态取页腿先回来时先把列表透出，用户不必等动态 WebKit 腿。临时结果是最终结果
/// 的子集，任务随后仍会通过 resultHandler 给出最终结果。批量（站点）任务不触发。
@property (nonatomic, copy, nullable) void (^interimResultHandler)(ZZResourceDiscoveryResult *result);

/// 站点批次收敛后，按列表页顺序逐个回调（主线程）。缩略图准备在完整
/// 批次结束后才开始，避免与后续列表页争抢同站连接。
@property (nonatomic, copy, nullable) void (^listingPageResultHandler)(ZZResourceDiscoveryResult *result,
                                                                         NSUInteger completedPageCount,
                                                                         NSUInteger totalPageCount);

/// 非批量探测中，列表 HTML 刚解析出网站封面时回调（主线程），不等待详情页探测完成。
/// posterByPageURL 的键是详情页 URL，值是该视频在网站列表中的封面 URL。
@property (nonatomic, copy, nullable) void (^listingPagePreviewHandler)(NSURL *listingPageURL,
                                                                          NSDictionary<NSString *, NSString *> *posterByPageURL);

/// Detail-page scheduling policy. Production defaults to 8 concurrent probes
/// with a 15-second batch deadline; injected dependencies remain serial unless
/// the caller explicitly opts into concurrency.
@property (nonatomic, assign) NSUInteger maxConcurrentPageProbes;
@property (nonatomic, assign) NSTimeInterval pageBatchDeadline;

/// 生产依赖：ProductionDiscoveryPageProbe（包装 WebProbe）+ ProductionDiscoveryHTMLProvider。
- (instancetype)initWithDefaultDependencies;

/// 测试/注入：自定义页面探测器、HTML 来源与延迟调度器。
- (instancetype)initWithPageProbe:(id<ZZDiscoveryPageProbing>)pageProbe
                     htmlProvider:(id<ZZDiscoveryHTMLProviding>)htmlProvider
                   delayScheduler:(nullable ZZDiscoveryDelayScheduler)delayScheduler;

/// 按模式开始一次发现任务（新任务自动取消并顶替旧任务）。
- (void)startWithURL:(NSURL *)url mode:(ZZResourceDiscoveryMode)mode;

/// 按用户指定的页面上限开始发现；有候选子页时最多探测 maxSubpageCount 个，
/// 没有子页时回退探测当前页。
- (void)startWithURL:(NSURL *)url
                mode:(ZZResourceDiscoveryMode)mode
     maxSubpageCount:(NSUInteger)maxSubpageCount;

/// 按网站列表页执行一次完整批次。count=2 表示依次读取 seed 的第 1、2 个列表页，
/// 每个列表页内部探测其详情链接；全部列表页结束后 resultHandler 只回调一次。
- (void)startSiteBatchWithURL:(NSURL *)url listingPageCount:(NSUInteger)count;

/// 取消当前任务（重复调用无害）。
- (void)cancel;

#pragma mark - 站点模式翻页（纯 URL 工具）

/// 解析 URL 的 page 页码；无 page 参数或值非法（非正整数）返回 1。
+ (NSInteger)sitePageNumberFromURL:(NSURL *)url;

/// 构造种子 URL 指定页码的地址：设置/替换 page 查询参数并保留其余查询参数
/// （如 genre 等筛选条件）；page<=1 时移除 page 参数（还原为首页形态）。
/// 翻页探测本身就是一次普通 Site 任务（种子带 page 参数），协调器无需改动。
+ (nullable NSURL *)sitePageURLForSeed:(NSURL *)seedURL page:(NSInteger)page;

/// 站点模式翻页上限（防无限爬取）。
@property (class, readonly) NSInteger siteMaxPages;

@end

NS_ASSUME_NONNULL_END
