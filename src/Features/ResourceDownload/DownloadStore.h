//
//  DownloadStore.h
//  7zz
//
//  下载状态持久化抽象：仅验证通过后才记录 CompletedResourceURLs；
//  退出时记录 interrupted 任务，重开用于展示“可重新开始”原因（不承诺系统级续传）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DownloadStore : NSObject

- (instancetype)initWithUserDefaults:(NSUserDefaults *)ud;

/// 该 URL 是否已下载完成（用于去重跳过）。
- (BOOL)isCompletedURL:(NSURL *)url;

/// 仅在输出验证通过后调用。
- (void)recordCompletedURL:(NSURL *)url;

/// 退出时记录被中断的任务（identifier -> 展示原因）。
- (void)setInterruptedRecords:(NSDictionary<NSString *, NSDictionary *> *)records;
/// 重开时读取中断记录（identifier -> 原因），用于 UI 展示。
- (NSDictionary<NSString *, NSDictionary *> *)interruptedRecords;

/// 清空中断记录（重新开始 / 全部结束后）。
- (void)clearInterruptedRecords;

/// 任务到达终态（完成/失败/取消）后移除其单条中断记录，
/// 避免下一次启动把已完成任务恢复成幽灵中断任务。
- (void)removeInterruptedRecord:(NSString *)identifier;

/// 终态任务追溯记录（identifier -> {destinationURL, fileName, state, errorText,
/// finishedAt, sourceURL, expectedLength}）。重启后下载列表据此仍能显示
/// 历史任务的最终路径与状态；仅作展示，不参与续传。
- (void)recordFinishedJob:(NSDictionary<NSString *, id> *)record;
- (NSArray<NSDictionary<NSString *, id> *> *)finishedJobRecords;

/// 最近一次加入队列的任务 identifier，跨重启保存。
- (void)setLatestEnqueuedJobIdentifier:(NSString *)identifier;
- (nullable NSString *)latestEnqueuedJobIdentifier;
- (void)clearAllDownloadRecords;


@end

NS_ASSUME_NONNULL_END
