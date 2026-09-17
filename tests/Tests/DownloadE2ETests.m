// 模块三 R4：受控本地下载的**行级**时间轴 E2E。
//
// 目的：证明真实字节流下，用户实际看到的那一行（进度条 + 指标文字 + 状态）
// 会连续更新，且暂停/恢复的显示语义正确。这是模块一遗留的验收缺口。
//
// 隔离保证（硬要求）：
//   · 独立 tempRoot（/tmp/rd-e2e-<pid>），绝不触碰 App 真实临时目录
//   · 独立 UserDefaults suite（rd-e2e-<pid>），绝不触碰用户真实下载记录
//   · 只访问 127.0.0.1，不依赖外网
//
// 用法：RD_E2E_BASE=http://127.0.0.1:<port> ./DownloadE2ETests
#define main RDUnusedE2EMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static int gFailures = 0;

static void Check(BOOL ok, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (ok) {
        NSLog(@"PASS: %@", msg);
    } else {
        gFailures++;
        NSLog(@"FAIL: %@", msg);
    }
}

#pragma mark - 放行策略（只为访问本地回环测试服务；沿用项目 RepairPolicy 的做法）

@interface E2EAllowPolicy : URLPolicy @end
@implementation E2EAllowPolicy
- (URLPolicyDecision *)evaluateTextURL:(NSString *)urlString { return [URLPolicyDecision allow]; }
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips { return [URLPolicyDecision allow]; }
- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current { return [URLPolicyDecision allow]; }
@end

#pragma mark - 回调计数（证明 didUpdateJob 持续触发）

static NSUInteger gUpdateCallbacks = 0;
@class E2ERecorder;
static E2ERecorder *gRecorder = nil;   // delegate 是 weak，必须自己持有

@interface E2ERecorder : NSObject <DownloadManagerDelegate>
@end
@implementation E2ERecorder
- (void)downloadManager:(id)manager didUpdateJob:(DownloadJob *)job { gUpdateCallbacks++; }
- (void)downloadManagerDidChange:(id)manager {}
@end

#pragma mark - 状态机

static DownloadManager *gManager = nil;
static DownloadJob *gJob = nil;
static ResourceDetectorAppDelegate *gApp = nil;
static RDDownloadRowCellView *gRow = nil;
static NSTimeInterval gStart = 0;
static int gTick = 0;
static int gCycles = 0;
static int gSamples = 0;
static int gRunningSamples = 0;
static int gPausedSamples = 0;
static double gLastProgress = -1;
static int gProgressAdvances = 0;
static BOOL gPausedSawRate = NO;
static BOOL gRunningSawRate = NO;
static BOOL gRunningMissingRateWhileBytes = NO;

static double Elapsed(void) { return [NSDate date].timeIntervalSince1970 - gStart; }

// 采样：复现"用户实际看到的那一行"
static void Sample(const char *tag) {
    [gRow configureWithJob:gJob width:600 app:gApp];
    NSString *text = gRow.metricsLabel.stringValue ?: @"";
    double progress = gRow.progressView.progress;
    BOOL hasRate = [text containsString:@"/s"];

    gSamples++;
    if (gJob.state == DownloadJobStateRunning) {
        gRunningSamples++;
        if (hasRate) gRunningSawRate = YES;
        if (gJob.bytesPerSecond > 0 && !hasRate) gRunningMissingRateWhileBytes = YES;
    }
    if (gJob.state == DownloadJobStatePaused || gJob.state == DownloadJobStateInterrupted) {
        gPausedSamples++;
        if (hasRate) gPausedSawRate = YES;
    }
    if (gLastProgress >= 0 && progress > gLastProgress + 0.001) gProgressAdvances++;
    gLastProgress = progress;

    NSLog(@"t=%5.1fs %-14s 状态=%-9s 已下载=%9lld 速率=%9.0f 进度=%.3f %@ | 行内=%@",
          Elapsed(), tag,
          [gApp stateLabelForJob:gJob].UTF8String,
          (long long)gJob.transferredBytes, gJob.bytesPerSecond, progress,
          gRow.progressView.indeterminate ? @"(不确定条纹)" : @"          ",
          text);
}

static void Finish(void) {
    NSLog(@"---- 断言 ----");
    Check(gSamples >= 8, @"采样点 ≥ 8（实际 %d）", gSamples);
    Check(gRunningSamples >= 4, @"下载中采样 ≥ 4（实际 %d）", gRunningSamples);
    Check(gProgressAdvances >= 2, @"进度条在传输中真实前进 ≥ 2 次（实际 %d）", gProgressAdvances);
    Check(gRunningSawRate, @"下载中行内出现过速率 /s");
    Check(!gRunningMissingRateWhileBytes, @"有速率时行内必须渲染 /s（不得漏渲染）");
    Check(!gPausedSawRate, @"暂停中行内不得出现 /s（实际出现=%d 次）", gPausedSawRate ? 1 : 0);
    Check(gPausedSamples >= 3, @"暂停态采样 ≥ 3（实际 %d）", gPausedSamples);
    Check(gCycles >= 3, @"完成暂停↔恢复往返 ≥ 3 轮（实际 %d）", gCycles);
    Check(gUpdateCallbacks >= 10, @"didUpdateJob 回调 ≥ 10 次（实际 %lu）", (unsigned long)gUpdateCallbacks);
    Check(gJob.state == DownloadJobStateCompleted, @"终态为已完成（实际 %@）", [gApp stateLabelForJob:gJob]);
    Check(gRow.progressView.progress == 1.0, @"终态进度条满格（实际 %.3f）", gRow.progressView.progress);

    // 刷新合并（防刷新风暴）：连调 3 次必须复用同一个定时器
    gApp.downloadsRefreshTimer = nil;
    [gApp scheduleDownloadsRefresh];
    NSTimer *first = gApp.downloadsRefreshTimer;
    [gApp scheduleDownloadsRefresh];
    [gApp scheduleDownloadsRefresh];
    Check(first != nil && gApp.downloadsRefreshTimer == first,
          @"scheduleDownloadsRefresh 连调 3 次复用同一 0.2s 定时器（合并生效）");

    NSLog(@"---- 结果 ----");
    NSLog(@"%@", gFailures == 0 ? @"PASS: download E2E row-level timeline" : [NSString stringWithFormat:@"FAIL: %d 项断言未通过", gFailures]);
    fflush(stdout);
    exit(gFailures == 0 ? 0 : 1);
}

static void Tick(void) {
    gTick++;
    switch (gTick) {
        case 1: Sample("下载中"); break;
        case 2: Sample("下载中"); break;
        case 3: if (gJob.state == DownloadJobStateRunning) { [gManager pauseJob:gJob.identifier]; } break;
        case 4: Sample("暂停后①"); break;
        case 5: if (gJob.state == DownloadJobStatePaused) { [gManager resumeJob:gJob.identifier]; gCycles++; } break;
        case 6: Sample("恢复后①"); break;
        case 7: if (gJob.state == DownloadJobStateRunning) { [gManager pauseJob:gJob.identifier]; } break;
        case 8: Sample("暂停后②"); break;
        case 9: if (gJob.state == DownloadJobStatePaused) { [gManager resumeJob:gJob.identifier]; gCycles++; } break;
        case 10: Sample("恢复后②"); break;
        case 11: if (gJob.state == DownloadJobStateRunning) { [gManager pauseJob:gJob.identifier]; } break;
        case 12: Sample("暂停后③"); break;
        case 13: if (gJob.state == DownloadJobStatePaused) { [gManager resumeJob:gJob.identifier]; gCycles++; } break;
        case 14: Sample("恢复后③"); break;
        default: Sample("下载中"); break;
    }

    if (gJob.state == DownloadJobStateCompleted || gJob.state == DownloadJobStateFailed ||
        gJob.state == DownloadJobStateCancelled) {
        Sample("终态");
        Finish();
    }
    if (Elapsed() > 75) {
        NSLog(@"FAIL: 超时未达终态（状态=%@）", [gApp stateLabelForJob:gJob]);
        gFailures++;
        Finish();
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        const char *base = getenv("RD_E2E_BASE");
        if (!base || !strlen(base)) {
            NSLog(@"FAIL: 缺少 RD_E2E_BASE（应为 http://127.0.0.1:<port>）");
            return 1;
        }
        NSString *urlString = [NSString stringWithFormat:@"%s/video.mp4", base];
        int64_t expect = 20 * 1024 * 1024;

        // ---- 隔离 ----
        NSString *tempRoot = [NSString stringWithFormat:@"/tmp/rd-e2e-%d", getpid()];
        NSString *destDir = [tempRoot stringByAppendingPathComponent:@"dst"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSUserDefaults *isolated = [[NSUserDefaults alloc] initWithSuiteName:
                                    [NSString stringWithFormat:@"rd-e2e-%d", getpid()]];
        DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:isolated];

        // SessionDownloadBackend 是 DownloadManager.m 内部私有类：运行时取类并自行持有
        id backend = [[NSClassFromString(@"SessionDownloadBackend") alloc] init];
        [backend setValue:[E2EAllowPolicy new] forKey:@"urlPolicy"];   // 策略层 2
        gManager = [[DownloadManager alloc] initWithBackend:backend
                                                   tempRoot:[NSURL fileURLWithPath:tempRoot]
                                                      store:store];
        [gManager setValue:[E2EAllowPolicy new] forKey:@"urlPolicy"];  // 策略层 1
        id probe = [gManager valueForKey:@"capabilityProbe"];
        [probe setValue:[E2EAllowPolicy new] forKey:@"urlPolicy"];     // 策略层 3
        gRecorder = [E2ERecorder new];
        gManager.delegate = gRecorder;

        gApp = [[ResourceDetectorAppDelegate alloc] init];
        [gApp buildDownloadsPage];              // scheduleDownloadsRefresh 依赖 downloadsTable
        gApp.downloadsPage.hidden = NO;
        gRow = [[RDDownloadRowCellView alloc] initWithFrame:NSMakeRect(0, 0, 600, 72)];

        NSLog(@"受控下载源: %@", urlString);
        NSLog(@"隔离: tempRoot=%@  defaults suite=rd-e2e-%d", tempRoot, getpid());

        gStart = [NSDate date].timeIntervalSince1970;
        gJob = [gManager enqueueItemWithSourceURL:[NSURL URLWithString:urlString]
                                           folder:[NSURL fileURLWithPath:destDir]
                                    preferredName:@"e2e.mp4"
                                    sourcePageURL:nil
                                     resourceKind:DownloadResourceVideo
                                   expectedLength:expect];
        Check(gJob != nil, @"任务成功入队");

        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { Tick(); }];
        [NSApp run];
    }
    return gFailures == 0 ? 0 : 1;
}
