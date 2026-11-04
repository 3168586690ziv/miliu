//
//  RDQueueWAL.h
//  Miliu
//
//  下载队列的追加式日志（write-ahead log）。
//
//  背景：原先队列状态只靠 NSUserDefaults 里的「中断记录 + 终态记录」两张表，
//  每次变化整表重写。进程崩溃/强制退出时，排在后面的任务顺序、画质选择、
//  Referer、已经下了多少，全部丢失，重启后只能从头再来。
//
//  这里每一个状态迁移写成**一行 JSON 追加到文件末尾**，恢复时从头重放。
//  关键性质：最后一行可能在写入中途被截断（进程被杀），它被丢弃，**其余全部有效**——
//  这是整文件重写做不到的。设计来源：OmniGet 的 queue_wal.rs（仅借鉴思路，
//  本项目为 MIT，对方为 GPL-3.0，代码为零复制）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 进度只在跨过 5% 时落一行。200 个任务 × 每个几百次回调若全落盘，
/// WAL 会变成 I/O 生成器；5% 的代价是崩溃最多回退 5% 的进度显示，
/// 而已经写入磁盘的分片不受影响。
extern const double RDQueueWALProgressStepPercent;

/// 一行记录的编码（纯函数，测试直接调用）。
/// 返回 nil 表示该记录不可序列化（调用方跳过，不写半行）。
NSString * _Nullable RDQueueWALEncodeLine(NSDictionary *record);

/// 解码整个日志。返回值按文件顺序；discarded 回传被丢弃的坏行数
/// （正常最多 1 行：末尾被截断的那行）。
NSArray<NSDictionary *> *RDQueueWALDecodeLines(NSString *text, NSUInteger *discarded);

/// 重放：把一串迁移折叠成「当前还活着的任务」。
/// 按 position 升序返回（用户排的队是一个顺序，顺序本身就是被恢复的东西）。
NSArray<NSDictionary *> *RDQueueWALReplay(NSArray<NSDictionary *> *records);

/// 这次进度值不值得落盘。
BOOL RDQueueWALShouldLogProgress(double lastLogged, double current);

/// 是否需要压缩：日志行数超过阈值，或终态记录远多于存活任务。
BOOL RDQueueWALCompactionNeeded(NSUInteger lineCount, NSUInteger liveCount);

@interface RDQueueWAL : NSObject

/// 生产位置：~/Library/Application Support/Miliu/queue.wal
+ (instancetype)shared;

/// 测试注入：任意文件路径（不存在则创建）。
- (instancetype)initWithFileURL:(NSURL *)fileURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *fileURL;

/// 入队。position 是队列里的位置（0 起）。
- (void)appendEnqueuedRecord:(NSDictionary *)record position:(NSUInteger)position;

/// 开始传输（用于区分「上次是正在下」和「上次只是排队」）。
- (void)appendStarted:(NSString *)identifier;

/// 进度（内部按 5% 节流；同一 identifier 的节流状态由本对象持有）。
- (void)appendProgress:(NSString *)identifier percent:(double)percent;

/// 终态：completed / failed / cancelled / interrupted / removed。
- (void)appendTerminal:(NSString *)identifier state:(NSInteger)state;

/// 重放当前日志。
- (NSArray<NSDictionary *> *)recoveredItems;

/// 压缩：只保留存活任务的最新状态与进度，行数从此不再增长。
- (void)compactIfNeeded;

/// 清空（用户点「清除下载记录」时调用）。
- (void)truncate;

@end

NS_ASSUME_NONNULL_END
