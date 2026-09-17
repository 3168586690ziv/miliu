//
//  MultiPageProbeResult.h — 第 3 阶段｜总站探测·多页面结果模型
//
//  纯模型（仅 Foundation，无 UI/无网络/无全局状态）：
//  · MultiPageProbePageResult：页面级结果（页面 URL、状态、该页资源、错误）。
//    DetectedMedia 没有来源页面字段且本阶段禁止修改它，页面来源由本模型承载。
//  · MultiPageProbeSummary：总结果（全部页面结果 + 跨页去重后的全部资源 +
//    是否被取消）。
//
//  页面状态机：
//    NotStarted → Probing → Succeeded / Empty / Failed
//    Probing → Cancelled（用户取消）
//    NotStarted（取消时未开始的页面保持 NotStarted，明确表示未执行）
//

#import <Foundation/Foundation.h>
#import "DetectedMedia.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MultiPageProbePageStatus) {
    MultiPageProbePageStatusNotStarted = 0,  // 未开始（含取消时未执行到的页面）
    MultiPageProbePageStatusProbing,         // 探测中
    MultiPageProbePageStatusSucceeded,       // 成功且发现资源
    MultiPageProbePageStatusEmpty,           // 成功但无资源
    MultiPageProbePageStatusFailed,          // 探测失败（保留错误）
    MultiPageProbePageStatusCancelled,       // 探测中被取消
};

/// 单个候选子页面的探测结果。
@interface MultiPageProbePageResult : NSObject

@property (nonatomic, copy) NSURL *pageURL;                 // 页面来源 URL
@property (nonatomic, assign) MultiPageProbePageStatus status;
@property (nonatomic, copy) NSArray<DetectedMedia *> *media; // 该页探测到的资源（原样保留）
@property (nonatomic, copy, nullable) NSError *error;       // 失败原因（仅 Failed 状态非 nil）

+ (instancetype)resultWithPageURL:(NSURL *)pageURL;

@end

/// 一次多页面探测任务的总结果。
@interface MultiPageProbeSummary : NSObject

@property (nonatomic, copy) NSArray<MultiPageProbePageResult *> *pageResults; // 与输入顺序一致
@property (nonatomic, copy) NSArray<DetectedMedia *> *allMedia;  // 跨页去重后按首次发现顺序
@property (nonatomic, assign) BOOL cancelled;                    // 任务是否被取消

@end

NS_ASSUME_NONNULL_END
