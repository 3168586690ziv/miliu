//
//  ResourceDiscoveryCoordinator.h — 第 4 阶段｜总站探测·策略协调器
//
//  在第 2 阶段（SubpageLinkExtractor）与第 3 阶段（MultiPageResourceProbe）
//  之上增加"当前页面 / 总站 / 智能"三种模式的策略层。
//
//  模式行为：
//  · 当前页面模式：只探测 seedURL；不读 HTML、不提取子页面、不访问其他 URL。
//  · 总站模式：读 seedURL HTML → 提取候选子页面（同源过滤/去重/数量限制）→
//    串行探测子页面；无候选子页面时回退探测 seedURL（usedCurrentPageFallback=YES）。
//  · 智能模式：先探测 seedURL；发现资源直接返回（不读 HTML、不扩展）；
//    无资源时读 HTML 提取子页面并串行探测；无子页面时返回当前页面结果
//    （seed 已探测，不重复探测，usedCurrentPageFallback=NO）。
//
//  依赖注入（无 UI、无真实网络、无下载）：
//  · ZZDiscoveryPageProbing  页面探测器（生产实现待第 5 阶段；测试注入 mock）
//  · ZZDiscoveryHTMLProviding 页面 HTML 来源（同上）
//  · ZZDiscoveryDelayScheduler 可注入延迟调度器（默认 dispatch_after 主队列；
//    测试注入同步/记录型实现，不真实等待）
//
//  范围限制：最大深度固定语义 0/1（>1 收敛为 1，maxDepth=0 不探测子页面）；
//  最大子页面数默认 50（maxSubpageCount==0 不探测子页面）；最大并发数 1；
//  默认重试 1 次（仅对可重试的页面探测失败，同一页面、不改顺序、不加数量）；
//  请求间隔默认 0.5s（子页面之间与重试之前生效）；始终同源（跨域一律过滤，
//  与第 2 阶段提取器一致）；不递归、不分页遍历、不访问媒体 URL。
//
//  取消：取消当前 HTML 请求或页面探测；不启动新页面；不再重试；已完成页面
//  保留；当前页标记 Cancelled；未开始页保持 NotStarted；completion 恰好一次；
//  generation 使迟到回调全部作废；重复 cancel 无害；取消后不触发智能回退。
//
//  错误模型（ZZResourceDiscoveryErrorDomain）：InvalidURL / PermissionDenied /
//  DRMProtected / HTMLFetchFailed。前三种与 NSURLErrorBadURL 等视为不可重试。
//

#import <Foundation/Foundation.h>
#import "DetectedMedia.h"
#import "MultiPageProbeResult.h"

NS_ASSUME_NONNULL_BEGIN

/// 策略层错误域。
FOUNDATION_EXPORT NSString *const ZZResourceDiscoveryErrorDomain;

/// 策略层错误码。InvalidURL / PermissionDenied / DRMProtected 不可重试；
/// HTMLFetchFailed 表示种子页面 HTML 获取失败（独立状态，不触发页面重试）。
typedef NS_ENUM(NSInteger, ZZResourceDiscoveryErrorCode) {
    ZZResourceDiscoveryErrorInvalidURL = 1,
    ZZResourceDiscoveryErrorPermissionDenied = 2,
    ZZResourceDiscoveryErrorDRMProtected = 3,
    ZZResourceDiscoveryErrorHTMLFetchFailed = 4,
    ZZResourceDiscoveryErrorUnrecognizedPage = 5, // 读取到内容，但无法识别页面；不是正常空结果
};

/// 探测模式。
typedef NS_ENUM(NSInteger, ZZResourceDiscoveryMode) {
    ZZResourceDiscoveryModeCurrentPage = 0,
    ZZResourceDiscoveryModeSite,
    ZZResourceDiscoveryModeSmart,
    /// 第 5 阶段生产接入增补：智能模式的"扩展阶段"。调用方已用现有生产探测器
    /// 完成当前页面首屏探测且无资源，本模式直接读取 HTML 提取子页面并探测；
    /// 无候选子页面时直接返回（usedCurrentPageFallback=NO，不重复探测 seed）。
    ZZResourceDiscoveryModeSmartExpansion,
};

#pragma mark - 依赖协议

/// 单页面探测器（依赖注入；生产实现待第 5 阶段接入）。
@protocol ZZDiscoveryPageProbing <NSObject>

/// 探测单个页面；返回值作为取消凭据传给 cancelProbe:（可为 nil）。
- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(void (^)(NSArray<DetectedMedia *> * _Nullable media,
                                      NSError * _Nullable error))completion;

/// 取消一次探测；取消后迟到的 completion 由协调器作废。
- (void)cancelProbe:(nullable id)probeToken;

@optional

/// 增量发布（可选能力）：同一页面可能回调多次，isFinal=NO 是「已经能填列表」的
/// 临时结果（不得当作终态），isFinal=YES 才是该页最终结果。实现它的探测器会
/// 被上层编排器优先按增量通道调用（见 MultiPageResourceProbe.h）。
- (nullable id)probePageURL:(NSURL *)pageURL
     incrementalCompletion:(void (^)(NSArray<DetectedMedia *> * _Nullable media,
                                     NSError * _Nullable error,
                                     BOOL isFinal))completion;

@end

/// 页面 HTML 来源（依赖注入）。
typedef void (^ZZDiscoveryHTMLCompletion)(
    NSString * _Nullable html,
    NSURL * _Nullable finalURL,   // 重定向后的最终页面 URL（提取子页面时作为 base）
    NSError * _Nullable error
);

@protocol ZZDiscoveryHTMLProviding <NSObject>

/// 加载页面 HTML；返回值作为取消凭据传给 cancelHTMLRequest:（可为 nil）。
- (nullable id)loadHTMLForURL:(NSURL *)url
                   completion:(ZZDiscoveryHTMLCompletion)completion;

/// 取消一次 HTML 请求；取消后迟到的 completion 由协调器作废。
- (void)cancelHTMLRequest:(nullable id)requestToken;

@end

/// 可测试的延迟调度器：在 delay 秒后执行 block（block 内部自行转发回状态队列）。
typedef void (^ZZDiscoveryDelayScheduler)(NSTimeInterval delay, dispatch_block_t block);

#pragma mark - 选项

@interface ZZResourceDiscoveryOptions : NSObject

@property (nonatomic, assign) ZZResourceDiscoveryMode mode;       // 默认 Smart
@property (nonatomic, assign) NSUInteger maxSubpageCount;         // 默认 50；0 = 不探测子页面
@property (nonatomic, assign) NSUInteger maxDepth;                // 默认 1；>1 收敛为 1；0 = 不探测子页面
@property (nonatomic, assign) NSUInteger maxRetries;              // 默认 1；0 = 不重试
@property (nonatomic, assign) NSTimeInterval requestInterval;     // 默认 0.5s；页面之间与重试之前生效
@property (nonatomic, assign) BOOL sameOriginOnly;                // 默认 YES；当前固定同源（与提取器一致，跨域一律过滤）
@property (nonatomic, assign) NSUInteger maxConcurrentPageProbes; // 默认 1；生产总站模式使用 12
@property (nonatomic, assign) NSTimeInterval pageBatchDeadline;   // 默认 0 不截止；生产每列表页 15 秒

+ (instancetype)defaultOptions;

@end

#pragma mark - 结果

@interface ZZResourceDiscoveryResult : NSObject

@property (nonatomic, copy) NSURL *seedURL;
@property (nonatomic, assign) ZZResourceDiscoveryMode mode;
/// 实际使用的候选子页面（当前页面模式恒为空；智能模式首屏有资源时为空）。
@property (nonatomic, copy) NSArray<NSURL *> *candidateURLs;
/// 全部页面级结果（按探测顺序；取消时当前页 Cancelled、未开始页 NotStarted）。
@property (nonatomic, copy) NSArray<MultiPageProbePageResult *> *pageResults;
/// 跨页去重后的全部资源（首次发现顺序）。
@property (nonatomic, copy) NSArray<DetectedMedia *> *allMedia;
/// 候选详情页 URL -> 列表页可见标题。用于优先保留网站列表中已经本地化的标题。
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *preferredTitleByPageURL;
/// 候选详情页 URL -> 网站列表卡片封面 URL。同一详情页仅对应一个视频时，
/// 该封面优先于详情页播放器 poster，保持作品封面来源一致。
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *preferredPosterByPageURL;
/// 列表页批次结果；普通单列表页任务为空。批次内每个元素对应一个网站分页。
@property (nonatomic, copy) NSArray<ZZResourceDiscoveryResult *> *listingPageResults;
@property (nonatomic, assign) NSUInteger requestedListingPageCount;
@property (nonatomic, assign) NSUInteger completedListingPageCount;
/// 仅总站模式无候选子页面时回退探测 seedURL 置 YES。
@property (nonatomic, assign) BOOL usedCurrentPageFallback;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong, nullable) NSError *error;

@end

#pragma mark - 协调器

/// 三模式策略协调器（同一实例同时只运行一个任务；新任务会取消并顶替旧任务）。
@interface ResourceDiscoveryCoordinator : NSObject

/// 列表页 HTML 解析出“详情页 -> 网站封面”后立即回调。此时详情页探测仍在
/// 进行，调用方可并行预取这些无需等待媒体地址的封面。回调在协调器状态队列。
@property (nonatomic, copy, nullable) void (^listingPagePreviewHandler)(NSURL *listingPageURL,
                                                                          NSDictionary<NSString *, NSString *> *preferredPosterByPageURL);

/// 临时（非终态）发现结果，可空。仅「当前页/智能首屏」这种单页阶段会触发：
/// 页面探测器的静态取页腿先回来时先把列表透出，让用户不必等动态 WebKit 腿。
/// 任务随后仍会走 completion 回调最终结果（恰好一次）；两者 allMedia 口径一致，
/// 临时结果是最终结果的子集。回调在主线程。
@property (nonatomic, copy, nullable) void (^interimResultHandler)(ZZResourceDiscoveryResult *result);

- (instancetype)initWithPageProbe:(id<ZZDiscoveryPageProbing>)pageProbe
                     htmlProvider:(id<ZZDiscoveryHTMLProviding>)htmlProvider;

/// 注入可测试延迟调度器（nil = 默认 dispatch_after 主队列）。
- (instancetype)initWithPageProbe:(id<ZZDiscoveryPageProbing>)pageProbe
                     htmlProvider:(id<ZZDiscoveryHTMLProviding>)htmlProvider
                   delayScheduler:(nullable ZZDiscoveryDelayScheduler)delayScheduler;

/// 按模式探测 seedURL；completion 固定主线程、恰好一次。
- (void)discoverFromURL:(NSURL *)seedURL
                options:(ZZResourceDiscoveryOptions *)options
             completion:(void (^)(ZZResourceDiscoveryResult *result))completion;

/// 取消当前任务（重复调用无害）。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
