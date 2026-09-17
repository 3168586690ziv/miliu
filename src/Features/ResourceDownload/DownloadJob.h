//
//  DownloadJob.h
//  7zz
//
//  单个下载任务的状态机与元数据。固定状态机：
//  queued / running / paused / cancelling / cancelled / failed / completed / interrupted
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DownloadJobState) {
    DownloadJobStateQueued     = 0,
    DownloadJobStateRunning,
    DownloadJobStatePaused,
    DownloadJobStateCancelling,
    DownloadJobStateCancelled,
    DownloadJobStateFailed,
    DownloadJobStateCompleted,
    DownloadJobStateInterrupted,
};
typedef NS_ENUM(NSInteger, DownloadResourceKind) { DownloadResourceVideo, DownloadResourceImage, DownloadResourceManifest };

@interface DownloadJob : NSObject

@property (nonatomic, copy) NSString *identifier;        // UUID
@property (nonatomic, copy) NSURL *sourceURL;
@property (nonatomic, assign) DownloadResourceKind resourceKind;
@property (nonatomic, copy, nullable) NSString *referer;
@property (nonatomic, copy) NSURL *destinationURL;       // 用户目标（已预留唯一名）
@property (nonatomic, copy) NSURL *tempRootURL;          // 本任务 App 专用临时目录
@property (nonatomic, assign) int64_t expectedContentLength;
/// 任务侧可信预期长度：只来自元数据、能力探测、链接刷新或中断恢复，
/// 绝不被传输过程中的响应头覆写。短文件校验以它为准——否则一个声明
/// 143 字节的截断响应会把“预期几十 MB”抹掉，完整性校验随之失效。
@property (nonatomic, assign) int64_t authoritativeExpectedLength;
@property (nonatomic, copy) NSString *etag;
@property (nonatomic, copy) NSString *lastModified;
@property (nonatomic, assign) BOOL acceptRanges;
@property (nonatomic, copy) NSString *fileName;          // 预留后的最终文件名
@property (nonatomic, assign) DownloadJobState state;
@property (nonatomic, assign) double progress;           // 0..1 整体进度
@property (nonatomic, copy, nullable) NSString *errorText;
@property (nonatomic, assign) NSInteger generation;      // 失效代次（取消/暂停后递增）
@property (nonatomic, assign) BOOL segmented;
@property (nonatomic, assign) NSInteger segmentCount;
@property (nonatomic, assign) NSInteger finishedSegments;
@property (nonatomic, assign) BOOL fallbackUsed;
@property (nonatomic, assign) BOOL cancelledIntentionally;
/// 传输层最近一次上报的总字节数、平滑速率和剩余秒数；仅用于实时展示。
@property (nonatomic, assign) int64_t transferredBytes;
@property (nonatomic, assign) double bytesPerSecond;
/// 能力探测记录的首字节延迟；用于区分服务器慢与 APP 降级。
@property (nonatomic, assign) NSTimeInterval firstByteLatency;
@property (nonatomic, assign) NSTimeInterval estimatedRemainingSeconds;
/// 最近一次得到有效速率的时刻。批次切换时仅作很短的速率展示衔接，不能用于续传。
@property (nonatomic, strong, nullable) NSDate *lastRateSampleDate;
/// 用户加入下载队列的真实时间，跨重启保存，用于列表显示弱化规则。
@property (nonatomic, strong, nullable) NSDate *enqueuedAt;

/// —— 单资源链接刷新（自动恢复）专用元数据 ——
/// 自动刷新是否已用过：每个任务自动重探测+重启最多一次；手动“重新获取”
/// 每次点击恰好一次。防止失败-刷新循环。
@property (nonatomic, assign) BOOL linkRefreshAttempted;
/// 原画质提示（如 1080p）：刷新后优先匹配原画质，不可用时选最低可用画质。
@property (nonatomic, copy, nullable) NSString *qualityHint;
/// 资源标题：重探测后用于确认新 URL 仍对应原资源。
@property (nonatomic, copy, nullable) NSString *resourceTitle;
/// 来源详情页 URL（重探测入口；仅内存会话级，不持久化）。
@property (nonatomic, copy, nullable) NSString *sourcePageURL;
/// 下载计划上下文：sourceURL 是界面选中的具体 HLS 档位（子清单）时，
/// 保留其来源主清单 URL。流任务从 master 入口解析分离音轨并固定选中
/// 该档位；为空表示下载目标本身就是清单入口。
@property (nonatomic, copy, nullable) NSString *streamMasterURL;

/// 状态机合法性：返回 next 是否为合法跳转。
- (BOOL)canTransitionTo:(DownloadJobState)next;
/// 执行跳转（非法跳转会被忽略并记录）。
- (void)transitionTo:(DownloadJobState)next;

/// 仅用于启动时恢复持久化的终态历史/中断记录：跳过状态机直接置终态
/// （Completed/Failed/Cancelled/Interrupted 之外一律忽略）。
/// 绝不在正常传输流程中使用。
- (void)restoreTerminalState:(DownloadJobState)state;

/// 分段第 i 个临时片段路径（在 tempRootURL 内）。
- (NSURL *)partFileURLForIndex:(NSInteger)i;
/// 合并用的临时文件。
- (NSURL *)mergedTempURL;

/// 校验文件头是否像视频（ISO/MP4、Matroska/EBML、AVI、MPEG）。
+ (BOOL)isLikelyVideoFileAtURL:(NSURL *)url;
+ (BOOL)isLikelyImageFileAtURL:(NSURL *)url;

/// 校验文件内容是否是 HTML 错误页（首个非空白字节为 '<'）。
/// 用于识别“HTTP 200 但返回 HTML 而非媒体”的伪媒体响应。
+ (BOOL)isLikelyHTMLErrorFileAtURL:(NSURL *)url;

/// 原子化预留唯一文件名：检查内存 reserved 集合与磁盘，避免覆盖已有文件。
/// 命中则追加 -2, -3 ... 直到不冲突，并加入 reserved。
+ (NSString *)reserveUniqueNameForPreferred:(NSString *)preferred
                                   inFolder:(NSString *)folder
                            againstReserved:(NSMutableSet<NSString *> *)reserved;

/// 文件名清洗（2026-09-08 事故回归）：网页标题直接当文件名时，其中未解码的
/// HTML 实体（&nbsp; 等）和路径分隔符 `/` 会让最终 move 把目标拆成不存在的
/// 嵌套目录，已下载完成的文件因此全部丢弃。本方法：解码常见 HTML 实体
/// （含数字/十六进制实体）、U+00A0 转普通空格、`/` 与 `:` 替换为 `-`、
/// 删除控制字符、去除首尾空白。清洗后为空返回 nil。
+ (nullable NSString *)sanitizedFileNameFromPreferred:(NSString *)preferred;

/// 保证文件名带可用的媒体扩展名：扩展名缺失，或是网页标题常见的域名尾巴
/// （如 hanime2.org 被误判为 .org 扩展）时，追加 fallbackExtension。
+ (NSString *)fileNameByEnsuringMediaExtension:(NSString *)name
                              fallbackExtension:(NSString *)ext;

@end

NS_ASSUME_NONNULL_END
