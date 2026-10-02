//
//  WatchlistTests.m — RDWatchlistStore 行为契约验收（小肥鱼地基，2026-10-03）
//  运行：bash tests/Tests/watchlist.sh
//  T1/T2 用 storeA（a、b 两页）；T3–T9 用独立 storeB（c、d 两页）避免计数串扰；
//  T10 损坏容错复用 storeB 的文件。
//
#import <Foundation/Foundation.h>
#import "RDWatchlistStore.h"

static int gFail = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { printf("PASS: %s\n", msg.UTF8String); }
    else { printf("FAIL: %s\n", msg.UTF8String); gFail++; }
}

static NSURL *FreshStore(NSString *name) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"watchlist-%@-%ld", name, (long)getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"watchlist.json"]];
}

int main(void) { @autoreleasepool {
    NSURL *urlA = FreshStore(@"a"), *urlB = FreshStore(@"b");
    RDWatchlistStore *store = [[RDWatchlistStore alloc] initWithStoreURL:urlA];

    // ── T1 upsert 身份（scheme/host 大小写、尾斜杠、fragment 归一；路径区分大小写故两段保持一致）──
    RDWatchlistEntry *a1 = [store upsertEntryForURL:@"HTTPS://Example-A.COM/list/#frag" title:@"A 站"];
    RDWatchlistEntry *a2 = [store upsertEntryForURL:@"https://example-a.com/list/" title:@"A 站改"];
    Check(store.entries.count == 1, @"T1 同地址（大小写/尾斜杠/fragment 归一）只留一条");
    Check([a1.identifier isEqualToString:a2.identifier], @"T1 identifier 稳定");
    Check([a2.title isEqualToString:@"A 站改"], @"T1 title 就地更新");
    Check([a2.pageURL isEqualToString:@"https://example-a.com/list"], @"T1 规范化地址落库");

    // ── T2 到期判定 ──
    [store upsertEntryForURL:@"https://example-b.com/watch" title:nil];
    NSDate *now = [NSDate date];
    Check([store dueEntriesBeforeDate:now].count == 2, @"T2 从未探测即到期（a、b）");
    RDWatchlistEntry *b = [store entryForURL:@"https://example-b.com/watch"];
    [store recordProbeResult:b fetchedKeys:@[@"k1"] error:nil];
    Check([store dueEntriesBeforeDate:now].count == 1, @"T2 间隔未到→只剩 a 到期");
    [store recordProbeResult:[store entryForURL:@"https://example-a.com/list"] fetchedKeys:@[] error:nil];
    NSDate *later = [now dateByAddingTimeInterval:31 * 60];
    Check([store dueEntriesBeforeDate:later].count == 2, @"T2 过 30 分钟后双双再到期");
    b = [store entryForURL:@"https://example-b.com/watch"];
    b.enabled = NO;
    [store updateEntry:b];
    Check([store dueEntriesBeforeDate:later].count == 1, @"T2 停用后不再到期");

    // ── T3–T6 记账语义（独立 storeB，仅 c 页）──
    RDWatchlistStore *s2 = [[RDWatchlistStore alloc] initWithStoreURL:urlB];
    RDWatchlistEntry *c = [s2 upsertEntryForURL:@"https://example-c.com/series" title:nil];
    [s2 recordProbeResult:c fetchedKeys:@[@"v1", @"v2"] error:nil];
    c = [s2 entryForURL:@"https://example-c.com/series"];
    Check(c.pendingNewKeys.count == 2 && c.knownKeys.count == 2, @"T3 首轮 2 新且入 known");
    [s2 recordProbeResult:c fetchedKeys:@[@"v1", @"v2", @"v3"] error:nil];
    c = [s2 entryForURL:@"https://example-c.com/series"];
    Check(c.pendingNewKeys.count == 3 && c.knownKeys.count == 3, @"T3 二轮只多 v3");
    Check([s2 totalPendingNewCount] == 3, @"T3 角标总数 = c 未读 3");

    // T4 单调性：v1 消失后回归不重复提醒
    [s2 recordProbeResult:c fetchedKeys:@[@"v9"] error:nil];
    [s2 recordProbeResult:c fetchedKeys:@[@"v1", @"v9"] error:nil];
    c = [s2 entryForURL:@"https://example-c.com/series"];
    Check(c.pendingNewKeys.count == 4 && c.knownKeys.count == 4, @"T4 回归键不重复提醒（known 单调=4）");

    // T5 失败路径
    [s2 recordProbeResult:c fetchedKeys:@[] error:@"DNS 解析超时"];
    c = [s2 entryForURL:@"https://example-c.com/series"];
    Check(c.pendingNewKeys.count == 4 && c.knownKeys.count == 4
          && [c.lastError isEqualToString:@"DNS 解析超时"], @"T5 失败只记错误，不冲数据");
    [s2 recordProbeResult:c fetchedKeys:@[@"v1", @"v2", @"v3", @"v9"] error:nil];
    c = [s2 entryForURL:@"https://example-c.com/series"];
    Check(c.lastError == nil, @"T5 成功后错误清空");

    // T6 已读
    [s2 markPendingRead:c.identifier];
    c = [s2 entryForURL:@"https://example-c.com/series"];
    Check(c.pendingNewKeys.count == 0 && c.knownKeys.count == 4, @"T6 已读清未读、留 known(4)");
    Check([s2 totalPendingNewCount] == 0, @"T6 角标归零");

    // T7 持久化往返（第三个实例）
    RDWatchlistStore *s3 = [[RDWatchlistStore alloc] initWithStoreURL:urlB];
    Check(s3.entries.count == 1, @"T7 文件往返条目数一致");
    RDWatchlistEntry *c3 = [s3 entryForURL:@"https://example-c.com/series"];
    Check(c3 && c3.knownKeys.count == 4 && c3.intervalMinutes == 30, @"T7 字段往返完整");

    // T8 非法间隔收敛
    RDWatchlistEntry *d = [s3 upsertEntryForURL:@"https://example-d.com/x" title:nil];
    d.intervalMinutes = 45;
    [s3 updateEntry:d];
    d = [s3 entryForURL:@"https://example-d.com/x"];
    Check(d.intervalMinutes == 30, @"T8 非法间隔收敛为 30");

    // T9 删除
    Check([s3 removeEntryWithIdentifier:d.identifier] && s3.entries.count == 1, @"T9 删除后条目数减一");
    Check(![s3 removeEntryWithIdentifier:d.identifier], @"T9 重复删除返回 NO");

    // T10 损坏容错
    [@"{ not valid json !!!" writeToFile:urlB.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    RDWatchlistStore *s4 = [[RDWatchlistStore alloc] initWithStoreURL:urlB];
    Check(s4.entries.count == 0, @"T10 损坏文件回退空库不崩溃");
    RDWatchlistEntry *z = [s4 upsertEntryForURL:@"https://z.com/" title:nil];
    Check(z != nil && s4.entries.count == 1, @"T10 空库上可继续写入");

    [[NSFileManager defaultManager] removeItemAtPath:urlA.path.stringByDeletingLastPathComponent error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:urlB.path.stringByDeletingLastPathComponent error:nil];
    printf(gFail ? "WATCHLIST TESTS FAILED (%d)\n" : "PASS: ALL WATCHLIST TESTS\n", gFail);
    return gFail ? 1 : 0;
}}
