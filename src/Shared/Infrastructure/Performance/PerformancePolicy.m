//
//  PerformancePolicy.m
//  7zz
//

#import "PerformancePolicy.h"

// 与既有设置面板注册默认值保持一致：0 省电 / 1 性能 / 2 高效
static NSInteger gOverrideMode = -1; // -1 表示使用 userDefaults

@implementation PerformancePolicy

+ (NSInteger)currentMode {
    if (gOverrideMode >= 0) return gOverrideMode;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud objectForKey:@"PerformanceMode"]) return 1;
    NSInteger m = [ud integerForKey:@"PerformanceMode"];
    if (m < 0 || m > 2) return 1;
    return m;
}

+ (void)setMode:(NSInteger)mode {
    gOverrideMode = (mode < 0 || mode > 2) ? -1 : mode;
}

+ (NSInteger)efficientDownloadConnections {
    // 20 条连接用于 5 个视频的公平并行：每个视频最多 4 段，
    // 避免前两个视频抢满连接、后续视频长期排队。
    return 20;
}

+ (NSInteger)maximumSegmentsPerDownloadJob {
    // 单个大文件允许最多 8 段；fairSegmentCap 会按同时下载的视频数
    // 与全局 20 条连接预算自动收敛（5 个视频时仍为每个 4 段）。
    // 对单视频下载可利用更多独立连接，避免一条被 CDN 晾住的长段拖慢整体。
    return 8;
}

+ (NSInteger)downloadConnections {
    switch ([self currentMode]) {
        case 0: return 2;
        case 2: return [self efficientDownloadConnections];
        default: return [self efficientDownloadConnections];
    }
}

+ (NSInteger)concurrentDownloadJobs {
    // 非省电模式最多同时运行 5 个视频；配合 20 条总连接即 4 段/视频。
    return [self currentMode] == 0 ? 2 : 5;
}

+ (BOOL)allowsSegmentedDownload {
    // 省电模式(0)维持单连接；标准(1)是正式版默认常用模式，高效(2)同为其
    // 常用模式，两者都允许在安全预算内对单个大文件做多段并行提速，
    // 不能只有隐藏的特殊模式才能获得提速。
    return [self currentMode] != 0;
}

+ (int64_t)downloadMaxSingleFileBytes {
    // 资源耗尽防护：单文件上限 10GB（expectedContentLength 提示值与完成后实际大小双校验）
    return 10LL * 1024 * 1024 * 1024;
}

+ (int64_t)downloadMaxTotalBytes {
    // 资源耗尽防护：全部在途任务总上限 50GB
    return 50LL * 1024 * 1024 * 1024;
}

+ (int64_t)minimumFreeDiskSpace {
    // 资源耗尽防护：目标卷剩余空间低于 1GB 拒绝新下载，避免写满磁盘
    return 1LL * 1024 * 1024 * 1024;
}

@end
