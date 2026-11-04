//
//  PerformancePolicy.h
//  7zz
//
//  下载连接数的唯一权威来源。模块 18 要求连接数只从 PerformancePolicy 获取。
//  模式：0 = 省电，1 = 标准性能，2 = 高效。
//  ⚠ 键的唯一来源是 PreferencesStore 的 SevenZZKeyPerformanceMode。本类**不** import
//    PreferencesStore（多个测试套件只链接本文件、不链接 PreferencesStore.m，加了依赖
//    会 Undefined symbols），故这里保留字面量——但两侧的值必须一致：verify.sh 的死键
//    断言会核对 @"PerformanceMode" 与 SevenZZKeyPerformanceMode 的取值是否分叉。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PerformancePolicy : NSObject

/// 当前性能模式（读取 @"PerformanceMode" 键，默认 1 = 标准）。
+ (NSInteger)currentMode;

/// 下载并发连接数，唯一由本类决定。
/// 省电(0) → 2；标准(1) 与 高效(2) → efficientDownloadConnections（当前 20）。
/// 注：1 与 2 的取值**目前相同**——两者的差异只在语义（高效是给将来更激进调度预留的
/// 档位），UI 也只暴露「省电/标准」两档。此处如实写明，避免再看代码时误以为有隐藏档位。
+ (NSInteger)downloadConnections;

/// 同时处于运行/暂停态的视频任务上限。分段下载仍另受连接槽位约束。
+ (NSInteger)concurrentDownloadJobs;

/// 高效模式下的连接数（与其它后台任务共享时的保守上限）。
+ (NSInteger)efficientDownloadConnections;

/// 单个下载任务允许的最大分段传输连接数（初始硬上限，当前为 4；
/// 自适应调度器可在服务器能力允许时逐步调整）。
/// 实际分段数由 DownloadManager 按“总连接 ÷ 预期同时活动视频数”均摊后与此上限取小；
/// 还需服务器允许 Range、文件大小达到门槛且全局有空闲槽位。
+ (NSInteger)maximumSegmentsPerDownloadJob;

/// 标准(1)/高效(2)等常用正式下载模式允许分段提速；省电(0)保持单连接。
+ (BOOL)allowsSegmentedDownload;

/// 单文件下载大小上限（字节）。expectedContentLength 与完成后实际大小均受此约束。
+ (int64_t)downloadMaxSingleFileBytes;

/// 全部在途任务总下载大小上限（字节，按 expectedContentLength 提示值累计）。
+ (int64_t)downloadMaxTotalBytes;

/// 目标目录所在卷最小剩余磁盘空间（字节），低于此值拒绝新下载。
+ (int64_t)minimumFreeDiskSpace;

/// 用于注入模式（测试 / 设置面板）。
+ (void)setMode:(NSInteger)mode;

@end

NS_ASSUME_NONNULL_END
