#!/bin/bash
set -euo pipefail
# 追更页离屏生产类断言（WATCH-V1-CONTRACT §3.4/§3.5）—— 运行：bash tests/Tests/watch-ui.sh
# 模式照 build/settings-probe/probe.sh：探针 .m 内容内嵌于本脚本（tests/Tests/ 不新增 .m 文件），
# 运行时用 heredoc 生成到 build/watch-ui-probe/WatchUIProbe.m，把生产 App 源（#define main 改名
# 引入 ResourceDetectorApp.m）+ RDWatchlistPage.m + RDWatchlistStore.m 编译为可执行探针，
# 离屏构建 RDWatchlistPageController 并断言控件标识与追更存储语义。
# 断言清单（U1–U7）：
#   U1 契约页面类 RDWatchlistPageController 存在
#   U2 页面类能构建实例且视图可离屏加载（initWithFrame:delegate: + prepareForShow，真实 API）
#   U3 页内四个控件标识齐全（RDWatchAddCurrentPageButton/RDWatchReloadAllButton/
#      RDWatchTableView/RDWatchSettingsCard；RDWatchNavButton 在 App.m 主页，不在本页，不在此查）
#   U4 行级标识模式抽查：RDWatchRowSwitch.<id> 必现 + RDWatchRow{Delete,ViewButton,Interval}.<id> 至少其一
#   U5 添加当前页入库：upsertEntryForURL 后 store.entries 计数 +1（同页归一不重复）
#   U6 间隔改动持久化：改 intervalMinutes → updateEntry → 新 store 实例读回
#   U7 已读清未读：recordProbeResult 造未读 → markPendingRead → totalPendingNewCount 归零
# U2–U4 的页面直读 RDWatchlistStore.sharedStore（页面无 store 注入口，集成裁决）：
#   向 sharedStore 临时播种 1 条探针条目供行级抽查，断言后按 identifier 删除，
#   并断言条目数恢复播种前基线；U5–U7 一律使用 NSTemporaryDirectory 下的独立实例。
#   除上述「播种→删除」往返外绝不改动真实 watchlist.json 的既有内容。
# 注意：施工期间不得运行本脚本（契约 §4.1：共享生成头 + A/B 半成品源码必挂）；
# 集成阶段由主智能体串行执行。
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/watch-ui-probe"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
# 日志隔离：本探针驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
printf 'Watchlist page offscreen production-class probe: %s\n' "$(date -u)"

# 构建期版本头（幂等：只重算代码行数，不改变修复轮数；与 settings-probe 同一做法）
bash "$REPO/scripts/generate-version.sh" >/dev/null

cat > "$OUT/WatchUIProbe.m" <<'OBJC'
// build/watch-ui-probe/WatchUIProbe.m —— 由 tests/Tests/watch-ui.sh 运行时生成（勿手工编辑）
// 追更页离屏生产类断言探针：复用 settings-probe 的编译模式（#define main 改名引入生产 App 源），
// 直接驱动 RDWatchlistPageController 离屏构建与 RDWatchlistStore 数据语义（U1–U7）。
#define main RDUnusedProbeOriginalMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "RDWatchlistStore.h"
#import <Cocoa/Cocoa.h>

static int gFail = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) printf("PASS: %s\n", msg.UTF8String);
    else { printf("FAIL: %s\n", msg.UTF8String); gFail++; }
}

static NSURL *ProbeStoreURL(NSString *name) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"watch-ui-probe-%@-%ld", name, (long)getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"watchlist.json"]];
}

static void CollectIdentifiers(NSView *view, NSMutableSet<NSString *> *out) {
    if (view.identifier.length) [out addObject:view.identifier];
    for (NSView *sub in view.subviews) CollectIdentifiers(sub, out);
}

static NSTableView *FindTableView(NSView *root, NSString *ident) {
    if ([root isKindOfClass:[NSTableView class]]) {
        NSTableView *tv = (NSTableView *)root;
        if (!ident || [tv.identifier isEqualToString:ident]) return tv;
    }
    for (NSView *sub in root.subviews) {
        NSTableView *found = FindTableView(sub, ident);
        if (found) return found;
    }
    return nil;
}

int main(void) { @autoreleasepool {
    // ── U1 契约页面类存在 ──
    Class pageClass = NSClassFromString(@"RDWatchlistPageController");
    Check(pageClass != nil, @"U1 追更页面类 RDWatchlistPageController 存在（契约 §3.4，App 侧已编入）");
    if (pageClass == nil) {
        printf("WATCH-UI PROBE FAILED (页面类缺失，无法继续离屏构建)\n");
        return 1;
    }

    // ── U2 能构建实例（真实 API：initWithFrame:delegate: + prepareForShow；集成裁决） ──
    printf("==== U2/U3/U4 离屏构建 RDWatchlistPageController ====\n");
    // 页面直读 sharedStore：先记基线，播种 1 条探针条目供行级抽查，结束后删除并核对恢复
    RDWatchlistStore *shared = RDWatchlistStore.sharedStore;
    NSInteger baselineCount = (NSInteger)shared.entries.count;
    RDWatchlistEntry *seed = [shared upsertEntryForURL:@"https://probe-watch-ui.example.com/series"
                                                 title:@"离屏探针页（watch-ui.sh 播种，随后删除）"];
    Check(seed != nil && (NSInteger)shared.entries.count == baselineCount + 1,
          [NSString stringWithFormat:@"U2 前置：sharedStore 播种探针条目成功（基线 %ld → %ld）",
           (long)baselineCount, (long)baselineCount + 1]);

    RDWatchlistPageController *page = nil;
    @try {
        page = [[RDWatchlistPageController alloc] initWithFrame:NSMakeRect(0, 0, 980, 732) delegate:nil];
    } @catch (NSException *e) {
        Check(NO, [NSString stringWithFormat:@"U2 构建页面实例抛异常：%@（%@）", e.name, e.reason]);
    }
    Check(page != nil, @"U2 RDWatchlistPageController 可构建实例（initWithFrame:delegate:）");

    NSView *rootView = nil;
    if (page) {
        @try {
            [page prepareForShow];   // 公开入口：refreshData（sharedStore）+ 设置卡同步
            rootView = page.pageView;
        } @catch (NSException *e) {
            Check(NO, [NSString stringWithFormat:@"U2 离屏加载页面视图抛异常：%@（%@）", e.name, e.reason]);
        }
    }
    Check(rootView != nil, @"U2 页面视图离屏加载成功（pageView 非空）");

    if (rootView) {
        // ── U3 页内四个控件标识齐全（契约 §3.4；RDWatchNavButton 在 App.m 主页，不在本页） ──
        NSMutableSet<NSString *> *ids = [NSMutableSet set];
        CollectIdentifiers(rootView, ids);
        for (NSString *ident in @[@"RDWatchAddCurrentPageButton", @"RDWatchReloadAllButton",
                                  @"RDWatchTableView", @"RDWatchSettingsCard"]) {
            Check([ids containsObject:ident],
                  [NSString stringWithFormat:@"U3 追更页内控件标识存在：%@（契约 §3.4）", ident]);
        }

        // ── U4 行级标识模式抽查（离屏直接向数据源/委托索取行视图） ──
        printf("==== U4 行级标识抽查 ====\n");
        NSTableView *tv = FindTableView(rootView, @"RDWatchTableView");
        if (!tv) tv = FindTableView(rootView, nil);
        if (!tv) {
            Check(NO, @"U4 行级标识抽查失败：离屏页面内找不到 NSTableView");
        } else {
            id ds = tv.dataSource;
            NSInteger rows = -1;
            if ([ds respondsToSelector:@selector(numberOfRowsInTableView:)])
                rows = [(id<NSTableViewDataSource>)ds numberOfRowsInTableView:tv];
            if (rows <= 0) {
                Check(NO, [NSString stringWithFormat:
                    @"U4 行级标识抽查失败：表格数据源 %ld 行（prepareForShow 后 sharedStore 应有 %ld 条——"
                    "若仍为 0 属页面读库时序问题，集成裁决项）",
                    (long)rows, (long)baselineCount + 1]);
            } else {
                id del = tv.delegate;
                NSTableColumn *col = tv.tableColumns.firstObject;
                NSMutableSet<NSString *> *rowIds = [NSMutableSet set];
                NSInteger cap = rows < 5 ? rows : 5;
                for (NSInteger r = 0; r < cap; r++) {
                    if (![del respondsToSelector:@selector(tableView:viewForTableColumn:row:)]) break;
                    @try {
                        NSView *rowView = [del tableView:tv viewForTableColumn:col row:r];
                        if (rowView) CollectIdentifiers(rowView, rowIds);
                    } @catch (NSException *e) {
                        printf("  行 %ld 视图构建异常：%s\n", (long)r, e.reason.UTF8String);
                    }
                }
                BOOL hasSwitch = NO, hasOther = NO;
                for (NSString *s in rowIds) {
                    if ([s hasPrefix:@"RDWatchRowSwitch."]) hasSwitch = YES;
                    if ([s hasPrefix:@"RDWatchRowDelete."] || [s hasPrefix:@"RDWatchRowViewButton."]
                        || [s hasPrefix:@"RDWatchRowInterval."]) hasOther = YES;
                }
                Check(hasSwitch, @"U4 行级标识抽查：RDWatchRowSwitch.<条目id> 出现（契约 §3.4）");
                Check(hasOther, @"U4 行级标识抽查：RDWatchRowDelete. / RDWatchRowViewButton. / RDWatchRowInterval. 至少其一（契约 §3.4）");
            }
        }
    } else {
        Check(NO, @"U3 页面视图未能离屏加载，控件标识断言无法执行");
        Check(NO, @"U4 页面视图未能离屏加载，行级标识抽查无法执行");
    }

    // ── U5/U6/U7 追更存储语义（独立临时实例，与页面实例无关） ──
    printf("==== U5/U6/U7 RDWatchlistStore 语义（独立临时实例） ====\n");
    NSURL *addStoreURL = ProbeStoreURL(@"add");
    RDWatchlistStore *s = [[RDWatchlistStore alloc] initWithStoreURL:addStoreURL];
    Check(s.entries.count == 0, @"U5 前置：空库 0 条");
    [s upsertEntryForURL:@"https://example-wui.com/watch/" title:@"探针页"];
    Check(s.entries.count == 1, @"U5 upsertEntryForURL 后 store.entries 计数 +1（添加当前页入库，契约 §3.5）");
    [s upsertEntryForURL:@"HTTPS://Example-WUI.COM/watch#frag" title:nil];
    Check(s.entries.count == 1, @"U5 同一页面（大小写/尾斜杠/fragment 归一）再次添加不重复入库");

    RDWatchlistEntry *e = [s entryForURL:@"https://example-wui.com/watch"];
    e.intervalMinutes = 120;
    [s updateEntry:e];
    RDWatchlistStore *sReopen = [[RDWatchlistStore alloc] initWithStoreURL:addStoreURL];
    RDWatchlistEntry *eReopen = [sReopen entryForURL:@"https://example-wui.com/watch"];
    Check(eReopen != nil && eReopen.intervalMinutes == 120,
          @"U6 intervalMinutes=120 → updateEntry → 新 store 实例读回（间隔改动持久化）");

    e = [s entryForURL:@"https://example-wui.com/watch"];
    [s recordProbeResult:e fetchedKeys:@[@"wk1", @"wk2"] error:nil];
    Check([s totalPendingNewCount] == 2, @"U7 recordProbeResult 造出 2 条未读（totalPendingNewCount=2）");
    e = [s entryForURL:@"https://example-wui.com/watch"];
    [s markPendingRead:e.identifier];
    Check([s totalPendingNewCount] == 0, @"U7 markPendingRead 后 totalPendingNewCount 归零（已读清未读）");

    // ── 播种清理：删除探针条目，断言 sharedStore 恢复播种前基线（真实存储零残留） ──
    if (seed) [shared removeEntryWithIdentifier:seed.identifier];
    Check((NSInteger)shared.entries.count == baselineCount,
          [NSString stringWithFormat:@"U2 收尾：探针条目已删除，sharedStore 恢复基线 %ld 条（真实存储零残留）",
           (long)baselineCount]);

    // 清理临时目录（绝不遗留）
    [[NSFileManager defaultManager] removeItemAtPath:addStoreURL.path.stringByDeletingLastPathComponent error:nil];
    printf(gFail ? "WATCH-UI PROBE FAILED (%d)\n" : "PASS: ALL WATCH-UI PROBE CHECKS\n", gFail);
    return gFail ? 1 : 0;
}}
OBJC

# 编译：照 watchlist.sh / settings-probe 模式（ASan + Cocoa；App 源 + RDWatchlistPage + 全部
# Features 探测引擎 + Shared 基础件；探针内已用 #define main 改名引入 ResourceDetectorApp.m）
SRC=("$OUT/WatchUIProbe.m" "$ROOT/App/ResourceResultRowView.m" "$ROOT/App/RDWatchlistPage.m")
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in AppError DNSResolver HTTPPrivacyPolicy IPAddressPolicy HTTPRequest HTTPResult HTTPClient PreferencesStore RDLog; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m" "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
      "$ROOT/Shared/UI/DesignSystem/ColorTokens.m" "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m"
      "$ROOT/Shared/UI/StateView.m" "$ROOT/Shared/UI/UIThemeSupport.m")
INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" "$ROOT/Shared" \
           "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" "$ROOT/Shared/Infrastructure/Performance" \
           "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" "$BUILD/generated"; do INCLUDES+=("-I$dir"); done
SRC+=("$ROOT/App/RDMetadataRecoveryCoordinator.m")   # 第 38 轮：本套件 import 生产 App.m，需一并编译其接线源
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  -lsqlite3 \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/WatchUIProbe" >"$OUT/compile.log" 2>&1 \
  || { cat "$OUT/compile.log"; echo "FAIL: 探针编译失败"; exit 1; }
ASAN_OPTIONS=detect_leaks=0 "$OUT/WatchUIProbe"
printf 'PROBE DONE\n'
