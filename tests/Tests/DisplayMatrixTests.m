// 模块三 R3：下载列表"行级行为矩阵"。
//
// 直接 #import 生产源码并调用生产方法（沿用本仓 RepairTests.m 的做法），
// 覆盖模块一/二/三修过的显示行为。**这是行为断言，不是字符串存在性检查**：
// 把生产代码改坏（进度不再绑定、已取消行加回取消按钮、/s 条件放宽、排序回退退化）
// 本测试必须变红。
#define main RDDisplayUnusedMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static int gFailures = 0;

static void Check(BOOL ok, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@: %@", ok ? @"PASS" : @"FAIL", msg);
    if (!ok) gFailures++;
}

static const char *StateName(DownloadJobState st) {
    switch (st) {
        case DownloadJobStateQueued:      return "Queued";
        case DownloadJobStateRunning:     return "Running";
        case DownloadJobStatePaused:      return "Paused";
        case DownloadJobStateCancelling:  return "Cancelling";
        case DownloadJobStateCancelled:   return "Cancelled";
        case DownloadJobStateFailed:      return "Failed";
        case DownloadJobStateCompleted:   return "Completed";
        case DownloadJobStateInterrupted: return "Interrupted";
    }
    return "?";
}

static DownloadJob *MakeJob(DownloadJobState st, double progress, int64_t expected, double bps, NSString *name) {
    DownloadJob *j = [DownloadJob new];
    j.identifier = [NSString stringWithFormat:@"matrix-%s-%@", StateName(st), name ?: @""];
    j.fileName = name ?: @"matrix.mp4";
    j.sourceURL = [NSURL URLWithString:@"https://example.com/a.mp4"];
    j.destinationURL = [NSURL URLWithString:@"file:///tmp/matrix-out.mp4"];
    j.expectedContentLength = expected;
    j.authoritativeExpectedLength = expected;
    j.transferredBytes = expected > 0 ? (int64_t)(expected * progress) : 0;
    j.progress = progress;
    j.bytesPerSecond = bps;
    j.state = st;
    return j;
}

// 按钮标题集合（排序后逗号连接，便于比对）
static NSString *ButtonTitles(NSArray<NSButton *> *buttons) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSButton *b in buttons) [titles addObject:b.title ?: @"(无标题)"];
    return [titles componentsJoinedByString:@","];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        ResourceDetectorAppDelegate *app = [[ResourceDetectorAppDelegate alloc] init];
        RDDownloadRowCellView *row = [[RDDownloadRowCellView alloc] initWithFrame:NSMakeRect(0, 0, 600, 72)];
        const int64_t known = 1048576;

        // ---------- A. 逐状态按钮集合（模块一 P4）----------
        NSLog(@"== A. 逐状态按钮集合 ==");
        struct { DownloadJobState st; const char *name; const char *expect; } buttonCases[] = {
            {DownloadJobStateQueued,      "Queued",      "取消"},
            {DownloadJobStateRunning,     "Running",     "暂停,取消"},
            {DownloadJobStatePaused,      "Paused",      "继续,取消"},
            {DownloadJobStateCancelling,  "Cancelling",  "取消"},
            {DownloadJobStateCancelled,   "Cancelled",   "显示文件"},
            {DownloadJobStateFailed,      "Failed",      "重试,取消,显示文件"},
            {DownloadJobStateCompleted,   "Completed",   "显示文件"},
            {DownloadJobStateInterrupted, "Interrupted", "继续,取消,显示文件"},
        };
        for (unsigned i = 0; i < sizeof(buttonCases) / sizeof(buttonCases[0]); i++) {
            DownloadJob *job = MakeJob(buttonCases[i].st, 0.5, known, 1000, @"row.mp4");
            NSArray<NSButton *> *buttons = [row visibleButtonsForJob:job app:app];
            NSString *titles = ButtonTitles(buttons);
            NSArray<NSString *> *actualSorted = [titles componentsSeparatedByString:@","];
            actualSorted = [actualSorted sortedArrayUsingSelector:@selector(compare:)];
            NSArray<NSString *> *expectSorted = [[[NSString stringWithUTF8String:buttonCases[i].expect]
                                                 componentsSeparatedByString:@","]
                                                sortedArrayUsingSelector:@selector(compare:)];
            Check([actualSorted isEqualToArray:expectSorted],
                  @"A %-12s 按钮集合 = [%@]（期望 [%@]）",
                  buttonCases[i].name, titles,
                  [NSString stringWithUTF8String:buttonCases[i].expect]);
        }

        // ---------- B. 行内指标文字是否渲染 /s（模块一 P3）----------
        NSLog(@"== B. 行内 /s 仅在 Running ==");
        for (int st = 0; st <= 7; st++) {
            DownloadJob *job = MakeJob((DownloadJobState)st, 0.5, known, 1234567, @"row.mp4");
            NSString *text = [app metricsStringForJob:job] ?: @"";
            BOOL hasRate = [text containsString:@"/s"];
            BOOL expect = (st == DownloadJobStateRunning);
            Check(hasRate == expect, @"B %-12s 行内%@ /s（期望%@）",
                  StateName((DownloadJobState)st), hasRate ? @"含" : @"无", expect ? @"含" : @"无");
        }

        // ---------- C. 进度条取值矩阵（模块一 P8 + 模块三 T4 无障碍）----------
        NSLog(@"== C. 进度条取值矩阵 ==");
        struct { const char *desc; DownloadJobState st; double prog; int64_t expected; double want; int wantIndeterminate; } progressCases[] = {
            {"Running 正常 0.5",         DownloadJobStateRunning,     0.5,  known, 0.5,  0},
            {"Running NaN",              DownloadJobStateRunning,     NAN,  known, 0.0,  0},
            {"Running 越界 1.5",         DownloadJobStateRunning,     1.5,  known, 1.0,  0},
            {"Running 负数 -0.1",        DownloadJobStateRunning,    -0.1,  known, 0.0,  0},
            {"Running 0",                DownloadJobStateRunning,     0.0,  known, 0.0,  0},
            {"Running 1",                DownloadJobStateRunning,     1.0,  known, 1.0,  0},
            {"Queued 却 progress=0.5",   DownloadJobStateQueued,      0.5,  known, 0.0,  0},
            {"Completed 却 progress=0.2",DownloadJobStateCompleted,   0.2,  known, 1.0,  0},
            {"Paused 保留 0.4",          DownloadJobStatePaused,      0.4,  known, 0.4,  0},
            {"Cancelled 保留 0.3",       DownloadJobStateCancelled,   0.3,  known, 0.3,  0},
            {"Failed 保留 0.25",         DownloadJobStateFailed,      0.25, known, 0.25, 0},
            {"Interrupted 保留 0.6",     DownloadJobStateInterrupted, 0.6,  known, 0.6,  0},
            {"Running 未知总大小",       DownloadJobStateRunning,     0.0,  0,     0.0,  1},
            {"Paused 未知总大小",        DownloadJobStatePaused,      0.4,  0,     0.4,  0},
            {"Queued 未知总大小",        DownloadJobStateQueued,      0.4,  0,     0.0,  0},
            {"Completed 未知总大小",     DownloadJobStateCompleted,   0.0,  0,     1.0,  0},
        };
        for (unsigned i = 0; i < sizeof(progressCases) / sizeof(progressCases[0]); i++) {
            DownloadJob *job = MakeJob(progressCases[i].st, progressCases[i].prog,
                                       progressCases[i].expected, 0, @"row.mp4");
            [row configureWithJob:job width:600 app:app];
            Check(fabs(row.progressView.progress - progressCases[i].want) < 1e-6,
                  @"C %-26@ progress=%.4f（期望 %.4f）",
                  [NSString stringWithUTF8String:progressCases[i].desc],
                  row.progressView.progress, progressCases[i].want);
            Check(row.progressView.indeterminate == (progressCases[i].wantIndeterminate != 0),
                  @"C %-26@ indeterminate=%s（期望 %s）",
                  [NSString stringWithUTF8String:progressCases[i].desc],
                  row.progressView.indeterminate ? "YES" : "no",
                  progressCases[i].wantIndeterminate ? "YES" : "no");
        }

        // ---------- D. 无障碍值（模块三 T4）----------
        NSLog(@"== D. 进度条无障碍值 ==");
        RDThinProgressView *bar = [[RDThinProgressView alloc] initWithFrame:NSMakeRect(0, 0, 100, 3)];
        bar.progress = 0.5;
        Check([bar.accessibilityValue doubleValue] == 0.5, @"D 确定态上报数值 0.5");
        bar.indeterminate = YES;
        Check(bar.accessibilityValue == nil, @"D 不确定态不得上报数字百分比");
        bar.indeterminate = NO;
        Check([bar.accessibilityValue doubleValue] == 0.5, @"D 回到确定态后恢复上报数值");

        // ---------- D2. 标题字素安全截断（模块二 P2）----------
        // 修复前按 UTF-16 下标硬切，emoji 被切成孤立代理项 → 畸形字符串。
        // 断言：截断结果必须能严格编码为 UTF-8，且头/尾按字素计数 24/12。
        NSLog(@"== D2. 标题字素安全截断 ==");
        NSString *emojiTitle = @"七个小矮人 Casinos😀😀😀😀😀😀😀😀😀😀😀😀😀😀世界末日";
        DetectedMedia *m = [DetectedMedia new];
        m.title = emojiTitle;
        NSString *summary = [m titleSummary] ?: @"";
        __block NSUInteger summaryGraphemes = 0;
        [summary enumerateSubstringsInRange:NSMakeRange(0, summary.length)
                                  options:NSStringEnumerationByComposedCharacterSequences
                               usingBlock:^(NSString *p2, NSRange r1, NSRange r2, BOOL *stop) { summaryGraphemes++; }];
        NSData *strict = [summary dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        NSLog(@"D2 诊断: strict=%@ summaryUTF8=%@ 字素=%lu 长度=%lu",
              strict ? @"非nil" : @"nil",
              summary.UTF8String ? @"非NULL" : @"NULL",
              (unsigned long)summaryGraphemes, (unsigned long)summary.length);
        Check(strict != nil && summary.UTF8String != NULL,
              @"D2 含 emoji 标题截断结果必须能严格编码为 UTF-8（不得出现孤立代理项）");
        __block NSUInteger graphemes = 0;
        [summary enumerateSubstringsInRange:NSMakeRange(0, summary.length)
                                  options:NSStringEnumerationByComposedCharacterSequences
                               usingBlock:^(NSString *p2, NSRange r1, NSRange r2, BOOL *stop) { graphemes++; }];
                const NSUInteger kHeadKeep = 24, kTailKeep = 12;   // DetectedMedia.m:7-8
        Check(summaryGraphemes <= kHeadKeep + kTailKeep + 1,
              @"D2 摘要字素数 %lu 不得超过 %lu（实际 %lu）",
              (unsigned long)summaryGraphemes,
              (unsigned long)(kHeadKeep + kTailKeep + 1), (unsigned long)summaryGraphemes);
        // 纯 ASCII 标题的截断行为不得改变
        m.title = @"abcdefghij";
        Check([[m titleSummary] isEqualToString:@"abcdefghij"], @"D2 短标题原样返回");

        // ---------- E. 排序回退键（模块一 P5）----------
        // identifier 的字典序与入队时间**故意相反**，否则测不出差别。
        NSLog(@"== E. 排序回退键 ==");
        NSString *tmpRoot = [NSString stringWithFormat:@"/tmp/rd-matrix-%d", getpid()];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSUserDefaults *isolated = [[NSUserDefaults alloc] initWithSuiteName:
                                    [NSString stringWithFormat:@"rd-matrix-%d", getpid()]];
        id backend = [[NSClassFromString(@"SessionDownloadBackend") alloc] init];
        DownloadManager *mgr = [[DownloadManager alloc] initWithBackend:backend
                                                               tempRoot:[NSURL fileURLWithPath:tmpRoot]
                                                                  store:[[DownloadStore alloc] initWithUserDefaults:isolated]];
        [app setValue:mgr forKey:@"downloadManager"];
        NSMutableDictionary *jobs = [mgr valueForKey:@"jobs"];
        struct { const char *ident; double when; } orderCases[] = {
            {"zzz-oldest", 10.0 * 3600},
            {"mmm-middle", 11.0 * 3600},
            {"aaa-newest", 12.0 * 3600},
        };
        NSMutableArray<NSString *> *expectOrder = [NSMutableArray array];
        for (unsigned i = 0; i < 3; i++) {
            DownloadJob *j = [DownloadJob new];
            j.identifier = [NSString stringWithUTF8String:orderCases[i].ident];
            j.fileName = [NSString stringWithFormat:@"%s.mp4", orderCases[i].ident];
            j.destinationURL = [NSURL URLWithString:@"file:///tmp/o.mp4"];
            j.state = DownloadJobStateFailed;                       // 终态、无速率样本
            j.enqueuedAt = [NSDate dateWithTimeIntervalSince1970:orderCases[i].when];
            jobs[j.identifier] = j;
            [expectOrder insertObject:j.identifier atIndex:0];      // 期望：最近入队在前
        }
        NSArray<DownloadJob *> *sorted = [app sortedDownloadJobsForFilter:RDDownloadFilterAll];
        NSMutableArray<NSString *> *actualOrder = [NSMutableArray array];
        for (DownloadJob *j in sorted) [actualOrder addObject:j.identifier];
        Check([actualOrder isEqualToArray:expectOrder],
              @"E 无速率样本时按 enqueuedAt 倒序排列（实际 [%@]，期望 [%@]）",
              [actualOrder componentsJoinedByString:@","],
              [expectOrder componentsJoinedByString:@","]);
        [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];

        NSLog(@"%@", gFailures == 0 ? @"PASS: display matrix production row behavior"
                                    : [NSString stringWithFormat:@"FAIL: %d 项断言未通过", gFailures]);
        fflush(stdout);
        return gFailures == 0 ? 0 : 1;
    }
}
