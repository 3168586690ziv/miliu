//
//  MultiPageResourceProbe.h — 第 3 阶段｜总站探测·多页面串行编排器
//
//  依赖注入的单页面探测器协议 + 串行编排：
//    候选子页面 URL 列表
//    → 过滤 nil / URL 去重（保留首次出现顺序）
//    → 逐页串行调用 id<ZZSinglePageProbing>（最大并发数固定为 1）
//    → 收集页面级结果（成功/空/失败/取消）
//    → 跨页资源去重合并
//    → completion 回调一次总结果（主线程）
//
//  线程与回调约定：
//  · 单页面探测器的 completion 可在任意线程回调（编排器统一转发到内部串行
//    状态队列处理，天然互斥、不新增并发队列）；
//  · 编排器 completion 固定在主线程回调，且每个任务恰好一次；
//  · 防迟到回调：generation 计数，取消/新任务后所有在途页面回调作废；
//  · 防重复回调推进：页面序号 + currentPageCompletionAccepted 标志，
//    每页只接受第一次「最终」完成回调，页面 A 的重复回调不会推进页面 B；
//    增量发布型探测器（可选 probePageURL:incrementalCompletion:）的
//    isFinal=NO 临时回调只刷新该页结果、不推进也不结束任务（见协议注释）。
//
//  边界：
//  · 不递归访问页面中的新 URL、不自动下载、不改输入 URL；
//  · 一个页面失败或无资源不影响后续页面；
//  · 取消后已完成页面结果保留，未开始页面保持 NotStarted；
//  · 本类不感知 UI 与生产 WebView——生产单页面探测器尚未接入
//    （App/SevenZZToolbox.m 的私有流程无法在不修改该文件的情况下注入），
//    接入留给第 5 阶段；当前用协议 mock 验证编排行为。
//

#import <Foundation/Foundation.h>
#import "DetectedMedia.h"
#import "MultiPageProbeResult.h"

NS_ASSUME_NONNULL_BEGIN

/// 单页面探测器完成回调：media 为该页资源（无资源时为 nil 或空数组），
/// error 非 nil 表示该页探测失败。
typedef void (^ZZSinglePageProbeCompletion)(
    NSArray<DetectedMedia *> * _Nullable media,
    NSError * _Nullable error
);

/// 增量发布完成回调：同一页面可能回调多次，isFinal=NO 是「已经能填列表」的
/// 临时结果（不得当作终态），isFinal=YES 才是该页最终结果。
typedef void (^ZZIncrementalPageProbeCompletion)(
    NSArray<DetectedMedia *> * _Nullable media,
    NSError * _Nullable error,
    BOOL isFinal
);

/// 单页面探测器协议（依赖注入）：由第 5 阶段的生产实现或测试 mock 实现。
@protocol ZZSinglePageProbing <NSObject>

/// 探测单个页面；返回值作为取消凭据传给 cancelProbe:（可为 nil）。
/// 每个任务恰好回调一次（增量能力由下面的可选方法提供）。
- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(ZZSinglePageProbeCompletion)completion;

/// 取消一次探测；取消后迟到的 completion 会被编排器作废，调用方无需处理。
- (void)cancelProbe:(nullable id)probeToken;

@optional

/// 增量发布（可选能力）。实现该方法的探测器优先走增量通道：编排器在
/// isFinal=NO 的临时回调到达时只刷新该页结果（并可选地透出一次临时汇总），
/// 不推进页面循环、也不结束任务；只有 isFinal=YES 之后才把该页作为最终结果
/// 采纳。这样「静态取页腿先发布一次、动态腿回来再发布合并结果」这类多次发布
/// 不会被当成最终结果，动态腿独有的资源不会被丢弃。
- (nullable id)probePageURL:(NSURL *)pageURL
     incrementalCompletion:(ZZIncrementalPageProbeCompletion)completion;

@end

/// 多页面串行编排器（同一实例同时只运行一个任务）。
@interface MultiPageResourceProbe : NSObject

/// 注入的单页面探测器（测试注入 mock；生产实现待第 5 阶段接入）。
@property (nonatomic, strong, readonly) id<ZZSinglePageProbing> pageProbe;
/// 最大同时探测页数。默认 1 保持原串行行为；生产静态 HTML 探测可提高到 12。
@property (nonatomic, assign) NSUInteger maxConcurrentProbes;

/// 临时（非终态）汇总回调，可空。当注入的探测器是增量发布型（实现了可选的
/// probePageURL:incrementalCompletion:）时，临时结果到达即回调一次，供上层先
/// 把列表显示出来；任务并未结束，completion 仍会按约定回调恰好一次。回调在
/// 主线程；同一次任务可能回调多次。
@property (nonatomic, copy, nullable) void (^interimSummaryHandler)(MultiPageProbeSummary *summary);

- (instancetype)initWithPageProbe:(id<ZZSinglePageProbing>)pageProbe;
- (instancetype)initWithPageProbe:(id<ZZSinglePageProbing>)pageProbe
              maxConcurrentProbes:(NSUInteger)maxConcurrentProbes;

/// 串行探测多个候选页面。
/// @param pageURLs 页面 URL 列表；nil 元素被过滤，重复 URL（规范化 key 相同）
///        只处理首次出现的一个，顺序保持输入顺序；输入数组与元素不被修改
/// @param completion 任务总结果回调，固定在主线程、恰好一次
- (void)probePageURLs:(NSArray<NSURL *> *)pageURLs
           completion:(void (^)(MultiPageProbeSummary *summary))completion;

/// 取消当前任务：取消当前页面探测、不启动后续页面、已完成结果保留、
/// 未开始页面保持 NotStarted、completion（若尚未回调）以 cancelled 汇总回调一次。
/// 任务已结束后重复调用无害。
- (void)cancelAll;

/// 当前是否有任务在运行（串行队列上同步读取，仅供观测）。
- (BOOL)isRunning;

/// 页面结果快照（同步读取内部串行队列）：取消（cancelAll）之后调用时，
/// 已完成页保留真实状态、在途页为 Cancelled、未开始页为 NotStarted。
/// 供上层编排器在取消路径采纳已完成页结果，避免其被 generation 检查丢弃。
- (NSArray<MultiPageProbePageResult *> *)pageResultsSnapshotSync;

@end

NS_ASSUME_NONNULL_END
