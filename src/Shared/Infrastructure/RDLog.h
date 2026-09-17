#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 统一日志：所有组件（下载/探测/元数据/应用/崩溃/诊断）写入同一个文件，
/// 每行带组件前缀，便于 AI 拿到单个文件就能定位"哪一步、什么原因"。
///
/// 行格式：yyyy-MM-dd HH:mm:ss.SSS [component] message
///   · component 实际取值：dl（下载）/ probe（探测）/ meta（元数据）/ app（应用）
///     / crash（崩溃）/ diag（诊断导出）/ log（日志系统自身）
///   · error / warn 级在组件后追加 [error] / [warn] 标记；info 级与历史格式一致
/// 文件：~/Library/Logs/ResourceDetector.log（超过 8MB 自动轮转为 .1，只保留一代）
///   轮转不只在启动时发生：写入路径上按累计字节数自动触发，长期不重启也不会无界增长。
///
/// 线程模型：异步写与轮转都在同一个串行队列上串行化，并发组件（下载队列 / 探测状态队列 /
///   主队列）的行不会互相穿插截断；崩溃/致命路径用 RDLogWriteSync 在当前线程同步落盘 ——
///   进程随即结束时，队列里排队的行会全部丢失，而崩溃现场恰恰是最需要留下的那几行。
///
/// 隐私：URL 在本层统一脱敏，只保留 scheme 与 host（host 是定位"哪条链路/哪个站点"的关键字段），
///   路径 / 查询 / 密钥一律替换为 [redacted]；覆盖 http/https/rtsp/rtsps/ws/wss 等带 scheme 形态
///   与无 scheme 的 host/path?query 形态，且不会吞掉 URL 之后的正文。
///   同时整段脱敏 Authorization / Proxy-Authorization（含 Bearer、Basic 等方案前缀以及
///   无 header 名的裸方案前缀形态）与 Cookie / Set-Cookie 头（含会话标识 cookie），
///   覆盖 HTTPPrivacyPolicy 明确列为敏感的请求头。这些规则在普通键值规则之前执行，
///   不会只抹掉方案词而把后面的真实凭据留在日志里。
///   调用方应先自行用 RDRedactedURL() 脱敏；已脱敏的 host 在本层仍会保留。
///
/// 测试隔离：环境变量 RD_LOG_PATH 覆盖日志文件路径，RD_LOG_MAX_BYTES 覆盖轮转阈值
///   （默认 8MB）。两者仅在显式设置时生效，生产默认行为不变。
typedef NS_ENUM(NSInteger, RDLogLevel) {
    RDLogLevelError = 0,   ///< 失败 / 崩溃，必然需要人看
    RDLogLevelWarn  = 1,   ///< 可疑但不致命
    RDLogLevelInfo  = 2,   ///< 常规追踪（默认）
};

/// 写一行日志（info 级）。component 为短组件名（dl / probe / meta / app / crash / diag / log）。
void RDLogWrite(NSString *component, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// 带级别写一行日志（异步，经串行队列）。
void RDLogWriteLevel(RDLogLevel level, NSString *component, NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

/// 同步写一行日志（error 级）：在当前线程完成格式化、脱敏、落盘与 fflush/fsync，返回即已写入。
/// 专供崩溃 / 致命路径使用（未捕获异常、致命信号），不经串行队列。
void RDLogWriteSync(NSString *component, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// 排空日志串行队列：返回时此前所有异步写入都已落盘。
/// 可从任意线程调用；若已在日志队列上则直接返回（避免自等待死锁）。
void RDLogFlush(void);

/// 安装硬崩溃兜底（SIGSEGV / SIGABRT / SIGBUS / SIGILL / SIGFPE）。
/// 处理器内只用异步信号安全接口（open/write/close + 栈上整数格式化，不分配内存、不调用 ObjC），
/// 记录信号号后恢复默认动作并重发，因此崩溃转储与退出码语义不变。可重复调用（仅首次生效）。
void RDLogInstallCrashHandlers(void);

/// 当前日志文件完整路径（受 RD_LOG_PATH 覆盖）。
NSString *RDLogFilePath(void);

/// 启动时调用：超过阈值（默认 8MB）则轮转（ResourceDetector.log → ResourceDetector.log.1）。
void RDLogRotateIfNeeded(void);

/// 把日志与关键状态打包到桌面「资源探测诊断-时间戳/」目录，返回目录路径；失败返回 nil。
/// 导出前会先排空日志队列，保证最近的日志一定在包里。
/// appVersion 由调用方传入（构建期生成的显示版本）。
NSString * _Nullable RDLogExportDiagnostics(NSString *appVersion, NSError * _Nullable *error);

/// 在访达中显示日志文件所在文件夹（并选中日志文件）。
/// 仅当文件不存在时才创建；已存在的日志内容绝不被截断。
void RDLogRevealInFinder(void);

NS_ASSUME_NONNULL_END
