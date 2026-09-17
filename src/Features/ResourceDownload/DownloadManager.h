//
//  DownloadManager.h
//  7zz
//
//  单一下载入口（合并旧两套实现）。负责：队列/进度/暂停/取消/分段回退/
// 重名原子预留/临时目录验证后移动/完成验证后才记录/退出记 interrupted。
// 连接数只从 PerformancePolicy 获取。
//

#import <Foundation/Foundation.h>
#import "DownloadJob.h"
#import "DownloadStore.h"
#import "URLPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// 单个传输任务（由后端实现，可取消/挂起/恢复）。
@protocol RDDownloadTask <NSObject>
- (void)rd_cancel;
@optional
- (void)rd_suspend;
- (void)rd_resume;
@end

/// 传输后端抽象：把请求下载结果写入 manager 指定的临时文件 writeToURL。
/// 真实实现基于 NSURLSession；测试用可控 Mock 实现。
@protocol RDDownloadBackend <NSObject>
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL * _Nullable writtenURL,
                                                 NSHTTPURLResponse * _Nullable response,
                                                 NSError * _Nullable error))completion;
@optional
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(nullable void (^)(int64_t bytesWritten,
                                                         int64_t totalBytesWritten,
                                                         int64_t totalBytesExpected))progress
                           completion:(void (^)(NSURL * _Nullable writtenURL,
                                                NSHTTPURLResponse * _Nullable response,
                                                NSError * _Nullable error))completion;
/// 停滞重发专用：必须在一条**全新连接**上重发同一请求（新会话 ⇒ 新 TCP 连接），
/// 不能复用可能已被服务器晾住的那条连接。未实现的后端由 DownloadManager 回退到
/// rd_startRequest:（测试替身与旧后端保持原语义）。
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request
                             writeToURL:(NSURL *)writeToURL
                               progress:(nullable void (^)(int64_t bytesWritten,
                                                           int64_t totalBytesWritten,
                                                           int64_t totalBytesExpected))progress
                             completion:(void (^)(NSURL * _Nullable writtenURL,
                                                  NSHTTPURLResponse * _Nullable response,
                                                  NSError * _Nullable error))completion;
@end

@protocol DownloadManagerDelegate <NSObject>
@optional
- (void)downloadManager:(id)manager didUpdateJob:(DownloadJob *)job;
- (void)downloadManagerDidChange:(id)manager;
@end

@interface DownloadManager : NSObject

- (instancetype)initWithBackend:(id<RDDownloadBackend>)backend
                       tempRoot:(NSURL *)tempRoot
                          store:(DownloadStore *)store;

+ (instancetype)sharedManager; // 真实 NSURLSession 后端

@property (nonatomic, weak, nullable) id<DownloadManagerDelegate> delegate;
@property (nonatomic, copy, nullable) NSString *defaultReferer;
@property (nonatomic, strong, nullable) NSURL *rd_streamMuxerURL;
/// Optional muxer override for isolated tests; production uses its bundled offline executable.
@property (nonatomic, copy, nullable, readonly) NSString *latestEnqueuedJobIdentifier;

/// 链接失效类失败（401/403/404/410、伪媒体 HTML 响应）回调：任务进入
/// Failed 终态后触发，由上层（DownloadLinkRefresher）做单资源重探测。
/// 用户取消或本地错误（磁盘/权限）不会触发本回调。
@property (nonatomic, copy, nullable) void (^linkRefreshHandler)(DownloadJob *job, NSString *reason);

/// 持久化存储（测试可读取中断记录等）。
@property (nonatomic, readonly) DownloadStore *store;

/// SSRF 防护：URL 安全策略（默认新建实例）。入队与完成阶段均以
/// 同一策略做文本 + DNS 解析后全 IP 校验（网络层与下载层双重防线）。
@property (nonatomic, strong, nullable) URLPolicy *urlPolicy;

/// 主机解析器（默认 DNSResolver.getaddrinfo）。测试可注入固定公网 IP 避免触网。
@property (nonatomic, copy, nullable) NSArray<NSString *> *(^rd_resolver)(NSString *host);

/// 是否启用入队异步 DNS 校验（默认开启；仅隔离 Mock 测试允许关闭，真实传输始终复查）。
@property (nonatomic, assign) BOOL rd_enableEndpointResolution;

/// 用于入队去重的稳定资源身份：保留内容参数，规范化顺序并忽略常见的
/// CDN 签名/过期参数。空或无效 URL 返回空字符串。
+ (NSString *)sourceIdentityForURL:(NSURL *)url;

/// 入队一个下载任务（内部原子预留唯一名 + 建临时目录 + 决定分段/单连接）。
- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url
                                   folder:(NSURL *)destinationFolder
                            preferredName:(NSString *)name
                                     etag:(nullable NSString *)etag
                              lastModified:(nullable NSString *)lastModified
                              acceptRanges:(BOOL)acceptRanges
                           expectedLength:(int64_t)length;
- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url folder:(NSURL *)folder preferredName:(NSString *)name sourcePageURL:(nullable NSString *)sourcePageURL resourceKind:(DownloadResourceKind)kind expectedLength:(int64_t)length;

- (void)pauseJob:(NSString *)identifier;
- (void)resumeJob:(NSString *)identifier;
- (void)cancelJob:(NSString *)identifier;
- (void)cancelAll;

/// HTTP 状态码是否属于“链接失效类”（401/403/404/410）。
/// 这类失败可触发单资源重新探测；本地磁盘/权限/校验类错误不得触发。
+ (BOOL)isLinkExpiryStatus:(NSInteger)statusCode;

/// 下载链接刷新成功后的“原地重启”：保留 identifier、文件名、目标路径与
/// 用户选择（画质），只替换失效的 sourceURL，绝不创建第二个任务或文件。
/// 仅当任务处于 Failed 终态时生效；重启沿用现有排队/连接预算（单视频
/// 4 连接、全局 12 连接不变），不额外占用瞬时连接。
- (BOOL)restartFailedJobWithIdentifier:(NSString *)identifier
                             sourceURL:(NSURL *)newSourceURL
                         expectedLength:(int64_t)length
                                   etag:(nullable NSString *)etag
                            lastModified:(nullable NSString *)lastModified
                           acceptRanges:(BOOL)acceptRanges;

/// 批量入队作用域：begin 之后入队的任务不会逐条启动队列，end 时统一按
/// 整批任务数规划每个任务的分段连接数，避免“逐条入队导致首批任务先占用
/// 过多连接、后续任务被不合理阻塞”。支持嵌套计数；调用方在异常路径也必须
/// 调用 end（建议 @try/@finally 包裹入队循环）。
- (void)beginBatchEnqueue;
- (void)endBatchEnqueue;

/// 退出时调用：运行中的任务记为 interrupted 并持久化原因（不承诺系统级续传）。
- (void)markInterruptedOnTerminate;

/// 当前所有任务（只读快照）。
- (NSArray<DownloadJob *> *)allJobs;

/// 参与进度条/聚合指标的任务：仅未到终态（排队/运行/已暂停/取消中）。
/// 终态历史任务（完成/失败/取消/中断）只用于列表追溯，绝不计入当前
/// 下载的百分比与总大小——否则恢复一条 236MB 历史会让新下载从 50%
/// 起步、总量翻倍（2026-09-08 用户报告的“400 多 MB/半途起步”事故）。
+ (NSArray<DownloadJob *> *)activeJobsForJobs:(NSArray<DownloadJob *> *)jobs;

/// 按预期文件大小加权聚合一批任务的整体进度。未知大小的任务使用已知任务的平均大小估算。
+ (double)overallProgressForJobs:(NSArray<DownloadJob *> *)jobs;

/// 聚合一批任务的传输指标。返回 expectedBytes、transferredBytes、remainingBytes、bytesPerSecond、
/// estimatedRemainingSeconds 和 hasKnownExpected，未知大小任务在有已知大小时按平均值估算。
+ (NSDictionary<NSString *, NSNumber *> *)aggregateMetricsForJobs:(NSArray<DownloadJob *> *)jobs;

/// 安全网：清理临时根目录下不属于任何在途任务的孤儿片段。
/// 清除终态下载记录，不中断在途任务，也不删除磁盘文件。
- (void)clearAllDownloadRecords;

- (void)cleanupOrphanTempDirs;

@end

NS_ASSUME_NONNULL_END
