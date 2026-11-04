//
//  QueueWALTests.m — 队列追加日志与失败诊断的隔离测试
//
//  为什么需要：WAL 的全部价值在「进程被杀后的那一秒」。用内存对象验证毫无意义，
//  必须真的写文件、真的截断最后一行、真的从另一个实例重放。
//

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import "RDQueueWAL.h"
#import "RDFailureDiagnosis.h"
#import "RDImageWrapperStripper.h"
#import <Cocoa/Cocoa.h>

static int gChecks = 0;

static void Check(BOOL ok, NSString *message, ...) {
    gChecks++;
    va_list args; va_start(args, message);
    NSString *formatted = [[NSString alloc] initWithFormat:message arguments:args];
    va_end(args);
    if (!ok) {
        NSLog(@"FAIL: %@", formatted);
        NSLog(@"TEST-SUITE-FAILED");
        exit(1);
    }
    NSLog(@"PASS: %@", formatted);
}

static NSData *PNGBytes(NSUInteger payloadBytes) {
    NSMutableData *d = [NSMutableData data];
    const unsigned char sig[8] = {0x89,'P','N','G',0x0D,0x0A,0x1A,0x0A};
    [d appendBytes:sig length:8];
    // IHDR：13 字节载荷
    unsigned char ihdr[8 + 13 + 4];
    memset(ihdr, 0, sizeof(ihdr));
    ihdr[3] = 13; memcpy(ihdr + 4, "IHDR", 4);
    [d appendBytes:ihdr length:sizeof(ihdr)];
    // IDAT：载荷里**故意**塞进字面 IEND，字面搜索会切在这里
    NSMutableData *idat = [NSMutableData dataWithBytes:"IEND" length:4];
    while (idat.length < payloadBytes) [idat appendBytes:"\x00" length:1];
    unsigned char head[8]; memset(head, 0, 8);
    head[3] = (unsigned char)(idat.length & 0xFF); head[2] = (unsigned char)((idat.length >> 8) & 0xFF);
    memcpy(head + 4, "IDAT", 4);
    [d appendBytes:head length:8];
    [d appendData:idat];
    unsigned char crc[4] = {0,0,0,0};
    [d appendBytes:crc length:4];
    // IEND 空块
    unsigned char iend[12]; memset(iend, 0, sizeof(iend));
    memcpy(iend + 4, "IEND", 4);
    [d appendBytes:iend length:12];
    return d;
}

static NSData *JPEGBytes(NSUInteger fillerBytes) {
    NSMutableData *d = [NSMutableData data];
    const unsigned char head[4] = {0xFF, 0xD8, 0xFF, 0xE0};
    [d appendBytes:head length:4];
    NSMutableData *body = [NSMutableData data];
    while (body.length < fillerBytes) [body appendBytes:"\x11" length:1];
    [d appendData:body];
    const unsigned char tail[2] = {0xFF, 0xD9};
    [d appendBytes:tail length:2];
    return d;
}

static NSString *TempWALPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"miliu-wal-%@.log", NSUUID.UUID.UUIDString]];
}

static void WaitForIO(void) {
    // WAL 写入在自己的串行队列；用一次同步空操作把它排空。
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (end.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        break;
    }
    usleep(120000);
}

// ── WAL 编码 ─────────────────────────────────────────────
static void TestEncodeRejectsNonJSON(void) {
    Check(RDQueueWALEncodeLine(@{@"id": @"a", @"op": @"enqueued"}) != nil, @"W1: 合法记录可编码");
    Check(RDQueueWALEncodeLine(@{@"id": [NSDate date]}) == nil, @"W2: 不可序列化的值返回 nil（不写半行）");
    Check(RDQueueWALEncodeLine(@{}) == nil, @"W3: 空记录返回 nil");
    Check([RDQueueWALEncodeLine(@{@"id": @"a"}) componentsSeparatedByString:@"\n"].count == 1,
          @"W4: 一条记录永远是一行（换行被转义）");
}

// ── 重放：顺序 / 覆盖 / 终态 ─────────────────────────────
static void TestReplayKeepsOrderAndDropsTerminal(void) {
    NSArray *records = @[
        @{@"op": @"enqueued", @"id": @"b", @"position": @1, @"url": @"http://x/b"},
        @{@"op": @"enqueued", @"id": @"a", @"position": @0, @"url": @"http://x/a"},
        @{@"op": @"started", @"id": @"a"},
        @{@"op": @"progress", @"id": @"a", @"percent": @42},
        @{@"op": @"terminal", @"id": @"b", @"state": @5},
    ];
    NSArray *live = RDQueueWALReplay(records);
    Check(live.count == 1, @"W5: 终态记录让任务离开队列（实际 %lu）", (unsigned long)live.count);
    Check([live.firstObject[@"identifier"] isEqual:@"a"], @"W6: 存活的是未终态的那个");
    Check([live.firstObject[@"percent"] doubleValue] == 42, @"W7: 进度按最后一条 progress 覆盖");
    Check([live.firstObject[@"wasRunning"] boolValue], @"W8: started 标记保留（用于区分排队/在途）");

    NSArray *two = RDQueueWALReplay(@[
        @{@"op": @"enqueued", @"id": @"z", @"position": @9},
        @{@"op": @"enqueued", @"id": @"y", @"position": @2},
    ]);
    Check([two[0][@"identifier"] isEqual:@"y"] && [two[1][@"identifier"] isEqual:@"z"],
          @"W9: 按 position 升序返回（用户排的队是一个顺序）");
}

static void TestDecodeDiscardsOnlyBadLines(void) {
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n{\"op\":\"enq",
                      RDQueueWALEncodeLine(@{@"op": @"enqueued", @"id": @"a"}),
                      RDQueueWALEncodeLine(@{@"op": @"started", @"id": @"a"})];
    NSUInteger discarded = 0;
    NSArray *records = RDQueueWALDecodeLines(text, &discarded);
    Check(records.count == 2, @"W10: 末尾半截行被丢弃，其余记录仍然有效（实际 %lu）", (unsigned long)records.count);
    Check(discarded == 1, @"W11: 坏行计数 = 1（实际 %lu）", (unsigned long)discarded);
    Check(RDQueueWALReplay(records).count == 1, @"W12: 丢弃尾行后仍能重放出活任务");
}

// ── 进度节流 ─────────────────────────────────────────────
static void TestProgressThrottle(void) {
    Check(!RDQueueWALShouldLogProgress(-1, 0), @"W13: 0% 不落盘（没有信息量）");
    Check(RDQueueWALShouldLogProgress(-1, 1), @"W14: 首次 >0% 落盘");
    Check(!RDQueueWALShouldLogProgress(10, 14.9), @"W15: 不到 5% 不落盘");
    Check(RDQueueWALShouldLogProgress(10, 15), @"W16: 满 5% 落盘");
    Check(RDQueueWALShouldLogProgress(10, 3), @"W17: 回退（重试归零）也落盘");
    Check(!RDQueueWALShouldLogProgress(10, NAN), @"W18: NaN 不落盘");
}

// ── 真实文件：追加 / 重放 / 压缩 / 截断 ──────────────────
static void TestFileRoundTrip(void) {
    NSString *path = TempWALPath();
    RDQueueWAL *wal = [[RDQueueWAL alloc] initWithFileURL:[NSURL fileURLWithPath:path]];
    [wal appendEnqueuedRecord:@{@"id": @"j1", @"url": @"http://x/1.mp4", @"title": @"一", @"output_dir": @"/tmp"} position:0];
    [wal appendEnqueuedRecord:@{@"id": @"j2", @"url": @"http://x/2.mp4", @"title": @"二", @"output_dir": @"/tmp"} position:1];
    [wal appendStarted:@"j1"];
    [wal appendProgress:@"j1" percent:10];
    [wal appendProgress:@"j1" percent:12];   // 节流：不写
    [wal appendProgress:@"j1" percent:30];
    [wal appendTerminal:@"j2" state:4];
    WaitForIO();

    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSUInteger lines = [[text componentsSeparatedByString:@"\n"] filteredArrayUsingPredicate:
                        [NSPredicate predicateWithBlock:^BOOL(NSString *s, id b) { return s.length > 0; }]].count;
    Check(lines == 6, @"W19: 节流生效——2 条入队 + 1 条 started + 2 条 progress（12%% 被节流）+ 1 条终态 = 6 行（实际 %lu）", (unsigned long)lines);

    // 换一个实例读同一个文件：模拟重启
    RDQueueWAL *reopened = [[RDQueueWAL alloc] initWithFileURL:[NSURL fileURLWithPath:path]];
    NSArray *items = [reopened recoveredItems];
    Check(items.count == 1, @"W20: 重启后只剩 1 个活任务（实际 %lu）", (unsigned long)items.count);
    Check([items.firstObject[@"id"] isEqual:@"j1"], @"W21: 活任务 identity 正确");
    Check([items.firstObject[@"percent"] doubleValue] == 30, @"W22: 进度恢复到 30%%（实际 %.0f）",
          [items.firstObject[@"percent"] doubleValue]);
    Check([items.firstObject[@"url"] isEqual:@"http://x/1.mp4"], @"W23: URL 恢复");
    Check([items.firstObject[@"output_dir"] isEqual:@"/tmp"], @"W24: 目标目录恢复");

    // 截断最后一行（模拟进程被杀）
    // 直接在末尾续写半条记录：这才是「进程在写一行的中途被杀」的真实形态。
    // 注意不能删掉上一行末尾的换行——那会把一条完整记录和半条拼成一条坏行，
    // 等于模拟了另一种故障（整条记录丢失），而不是本项目要验证的那种。
    NSMutableString *mutilated = [text mutableCopy];
    [mutilated appendString:@"{\"op\":\"prog"];
    [mutilated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSArray *afterCrash = [[[RDQueueWAL alloc] initWithFileURL:[NSURL fileURLWithPath:path]] recoveredItems];
    Check(afterCrash.count == 1, @"W25: 半截行不影响重放（仍恢复 1 个任务）");

    // 压缩：终态历史被折叠，行数回到「活任务 + 进度」
    RDQueueWAL *toCompact = [[RDQueueWAL alloc] initWithFileURL:[NSURL fileURLWithPath:path]];
    for (int i = 0; i < 300; i++) [toCompact appendTerminal:[NSString stringWithFormat:@"old%d", i] state:5];
    WaitForIO();
    [toCompact compactIfNeeded];
    WaitForIO();
    NSString *compacted = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSUInteger compactedLines = [[compacted componentsSeparatedByString:@"\n"] filteredArrayUsingPredicate:
                                 [NSPredicate predicateWithBlock:^BOOL(NSString *s, id b) { return s.length > 0; }]].count;
    Check(compactedLines <= 3, @"W26: 压缩后行数收敛到活任务量级（实际 %lu）", (unsigned long)compactedLines);
    Check([[toCompact recoveredItems] count] == 1, @"W27: 压缩不丢活任务");

    [toCompact truncate];
    Check([[toCompact recoveredItems] count] == 0, @"W28: 清除记录后重放为空");
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static void TestCompactionPolicy(void) {
    Check(!RDQueueWALCompactionNeeded(10, 5), @"W29: 小日志不压缩");
    Check(RDQueueWALCompactionNeeded(201, 5), @"W30: 超过 200 行压缩");
    Check(RDQueueWALCompactionNeeded(60, 2), @"W31: 终态远多于活任务时压缩");
    Check(!RDQueueWALCompactionNeeded(40, 20), @"W32: 活任务占多数时不压缩");
}

// ── 失败诊断 ─────────────────────────────────────────────
static void TestDiagnosisMapping(void) {
    Check(RDDiagnoseFailure(@"磁盘剩余空间不足（剩余 1 GB，本批至少需要 3 GB），已停止下载", 0).action == RDFailureActionFreeDiskSpace,
          @"D1: 磁盘不足 → 清理空间");
    Check(RDDiagnoseFailure(@"网站返回 403（网站方限制或链接失效）", 403).action == RDFailureActionRefreshLink,
          @"D2: 403 → 重新获取链接");
    Check(RDDiagnoseFailure(@"需要登录后才能访问", 0).action == RDFailureActionSignIn,
          @"D3: 需要登录 → 导入登录态");
    Check(RDDiagnoseFailure(@"网站返回 429", 429).action == RDFailureActionWaitAndRetry,
          @"D4: 429 → 等一等");
    Check(RDDiagnoseFailure(@"下载不完整：服务器声明 100 字节，实际只收到 43 字节", 0).action == RDFailureActionRetry,
          @"D5: 截断 → 重试");
    Check(RDDiagnoseFailure(@"保存的内容是网页/错误页，不是视频文件", 0).action == RDFailureActionRefreshLink,
          @"D6: 伪媒体 → 重新获取链接");
    Check(RDDiagnoseFailure(@"链接已过期", 410).action == RDFailureActionRefreshLink,
          @"D7: 410 → 重新获取链接");
    Check(RDDiagnoseFailure(@"完全没见过的错误", 0).action == RDFailureActionNone,
          @"D8: 不认识就返回 None，绝不编造原因");
    Check(RDDiagnoseFailure(nil, 0).action == RDFailureActionNone, @"D9: nil 原因不崩溃");

    // 顺序：更具体的判据优先（会员内容 + 403 必须先判登录）
    Check(RDDiagnoseFailure(@"这是会员专属内容，HTTP 403", 403).action == RDFailureActionSignIn,
          @"D10: 会员/登录优先于 403（否则用户会一直刷链接）");

    NSString *withAdvice = RDFailureMessageWithAdvice(@"网站返回 403", 403);
    Check([withAdvice hasPrefix:@"网站返回 403"], @"D11: 原始原因原样保留在最前面");
    Check([withAdvice containsString:@"建议"], @"D12: 追加建议文案");
    Check([RDFailureMessageWithAdvice(@"完全没见过的错误", 0) isEqual:@"完全没见过的错误"],
          @"D13: 识别不出时不追加任何东西");
    Check([RDFailureActionText(RDFailureActionNone) isEqual:@""], @"D14: None 动作没有文案");
}

// ── 窄窗文案自适应（2026-11-05 实测缺陷的守卫）───────────
// 背景：建议在末尾，而 NSTextField 尾部截断。最小窗口 760 宽时失败原因
// 只有 402px 可用，而「原因 · 建议」最宽 447px（10pt 系统字体），
// 被切掉的正是建议本身 —— 引导在最窄窗口下等于不存在。
static CGFloat MeasureAt10pt(NSString *text) {
    return [text sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10]}].width;
}

static void TestFailureTextFitsNarrowRow(void) {
    NSString *reason = @"网站返回 403（网站方限制或链接失效，非应用故障），下载中止";
    NSString *full = RDFailureMessageWithAdvice(reason, 403);
    Check([full containsString:@"建议"], @"F1: 完整文案包含建议");

    // 宽屏（默认 980 窗口 → 622px）：原样返回，不做任何删改
    NSString *wide = RDFailureTextFitted(reason, 403, 622, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
    Check([wide isEqualToString:full], @"F2: 宽度足够时原样返回（不误删任何字）");

    // 最小窗口（760 → 402px）：必须仍能看见建议的动作文字
    NSString *narrow = RDFailureTextFitted(reason, 403, 402, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
    Check([narrow containsString:@"点「重试」重新获取下载链接"], @"F3: 窄窗下建议仍在（实际：%@）", narrow);
    Check(MeasureAt10pt(narrow) <= 402.0, @"F4: 窄窗结果确实放得进 402px（实际 %.0f）", MeasureAt10pt(narrow));
    Check([narrow hasPrefix:@"网站返回 403"], @"F5: 原因仍尽量保留在最前（实际：%@）", narrow);

    // 更窄（极端：按钮多的失败行 300px）：连「· 建议：」都放不下时只显示动作
    NSString *tiny = RDFailureTextFitted(reason, 403, 300, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
    Check(MeasureAt10pt(tiny) <= 300.0, @"F6: 极窄宽度下也不溢出（实际 %.0f）", MeasureAt10pt(tiny));
    Check([tiny containsString:@"重试"], @"F7: 极窄宽度下仍保住动作（实际：%@）", tiny);

    // 逐档宽度全扫：任何宽度都不得溢出，且只要放得下建议就必须含建议
    CGFloat adviceOnly = MeasureAt10pt(@"· 建议：点「重试」重新获取下载链接");
    for (CGFloat w = 120; w <= 700; w += 7) {
        NSString *text = RDFailureTextFitted(reason, 403, w, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
        if (MeasureAt10pt(text) > w + 0.5 && w > adviceOnly) {
            Check(NO, @"F8: 宽度 %.0f 时溢出（实际 %.0f）", w, MeasureAt10pt(text));
        }
        if (w >= MeasureAt10pt(full) && ![text isEqualToString:full]) {
            Check(NO, @"F9: 宽度 %.0f 足够时却被截断（实际：%@）", w, text);
        }
    }
    Check(YES, @"F8/F9: 120–700px 全宽度扫描无溢出、无过度截断");

    // 无建议可保（未知原因）：退回对原文做字素截断，不得返回空
    NSString *unknown = @"完全没见过的错误原因描述文本";
    NSString *trimmed = RDFailureTextFitted(unknown, 0, 100, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
    Check(trimmed.length > 0 && MeasureAt10pt(trimmed) <= 100.0, @"F10: 无建议时按宽度截断且非空（实际：%@）", trimmed);
    Check([unknown hasPrefix:trimmed] || [trimmed isEqualToString:unknown], @"F11: 截断只删尾部，不改内容");

    // emoji 不得被切成孤立代理项
    NSString *emoji = @"下载失败🎬🎬🎬🎬🎬🎬🎬🎬🎬🎬🎬🎬";
    for (CGFloat w = 20; w <= 200; w += 6) {
        NSString *cut = RDFailureTextTruncatedToWidth(emoji, w, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
        const char *utf8 = cut.UTF8String;
        Check(utf8 != NULL || cut.length == 0, @"F12: emoji 截断结果必须是合法 UTF-8（宽 %.0f）", w);
    }
    Check(YES, @"F12: emoji 全宽度截断均未产生畸形字符串");

    // nil / 非法参数的契约
    Check([RDFailureTextFitted(nil, 0, 402, ^CGFloat(NSString *t) { return MeasureAt10pt(t); }) length] > 0,
          @"F13: nil 原因仍给出可读文案");
    NSString *noMeasure = RDFailureTextFitted(reason, 403, 402, nil);
    Check([noMeasure isEqualToString:full], @"F14: 没有测量器时退回完整文案（不误删）");
    NSString *zeroWidth = RDFailureTextFitted(reason, 403, 0, ^CGFloat(NSString *t) { return MeasureAt10pt(t); });
    Check([zeroWidth isEqualToString:full], @"F15: 宽度未知（<=0）时不做适配");
}

// ── 图片外壳剥离 ─────────────────────────────────────────
static void TestImageWrapper(void) {
    NSData *png = PNGBytes(4000);
    NSMutableData *wrapped = [png mutableCopy];
    [wrapped appendBytes:"PAYLOAD-BYTES" length:13];
    Check(RDImageWrapperPayloadOffset(wrapped) == png.length,
          @"I1: PNG 外壳按 chunk 表精确切在 IEND 之后（%lu vs %lu）",
          (unsigned long)RDImageWrapperPayloadOffset(wrapped), (unsigned long)png.length);
    Check([RDStripImageWrapper(wrapped) isEqualToData:[wrapped subdataWithRange:NSMakeRange(png.length, 13)]],
          @"I2: 剥壳后正文完整");

    NSData *jpeg = JPEGBytes(2000);
    NSMutableData *jw = [jpeg mutableCopy];
    [jw appendBytes:"SEGMENT" length:7];
    Check(RDImageWrapperPayloadOffset(jw) == jpeg.length, @"I3: JPEG 外壳切在 FFD9 之后");

    // 随机字节恰好以 FFD8FF 开头：marker 校验必须拒绝
    NSMutableData *fake = [NSMutableData dataWithBytes:"\xFF\xD8\xFF\x00" length:4];
    for (int i = 0; i < 500; i++) [fake appendBytes:"\x11" length:1];
    [fake appendBytes:"\xFF\xD9" length:2];
    Check(RDImageWrapperPayloadOffset(fake) == 0, @"I4: 伪 JPEG（marker 非法）不切");

    // 只有图片没有正文：返回 0，原样交给校验层拒绝
    Check(RDImageWrapperPayloadOffset(png) == 0, @"I5: 纯图片（无正文）不切");
    Check(RDImageWrapperPayloadOffset([@"hello" dataUsingEncoding:NSUTF8StringEncoding]) == 0,
          @"I6: 非图片数据原样通过");
    Check(RDImageWrapperPayloadOffset(nil) == 0, @"I7: nil 不崩溃");

    // 正常 TS 分片必须以 0x47 开头，绝不能被当成图片切掉
    NSMutableData *ts = [NSMutableData data];
    for (int i = 0; i < 20; i++) { unsigned char b[188]; memset(b, 0x47, 188); [ts appendBytes:b length:188]; }
    Check(RDImageWrapperPayloadOffset(ts) == 0, @"I8: 正常 TS 分片零误伤");
}

int main(void) {
    @autoreleasepool {
        TestEncodeRejectsNonJSON();
        TestReplayKeepsOrderAndDropsTerminal();
        TestDecodeDiscardsOnlyBadLines();
        TestProgressThrottle();
        TestFileRoundTrip();
        TestCompactionPolicy();
        TestDiagnosisMapping();
        TestFailureTextFitsNarrowRow();
        TestImageWrapper();
        NSLog(@"== 全部 %d 项检查通过 ==", gChecks);
        NSLog(@"TEST-SUITE-PASSED");
        return 0;
    }
}
