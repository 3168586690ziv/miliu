//
//  UIExperienceTests.m — 本轮 UI 体验专项验收
//
//  覆盖四组真实行为断言（直接驱动生产代码，不依赖字符串存在性）：
//   1. 三档分栏比例：0.30 / 0.20 / 0.25，非法偏好值安全回退 3:7；
//      每档按真实 layoutWorkspace 计算左右 pane 宽度，误差 ≤1pt；
//   2. 探测状态文案：底层长串（含 host、页数）绝不直接展示；
//   3. 详情标题：完整显示、不出现尾部省略号，且与下方字段不重叠、不越界；
//   4. 设置页：三档比例控件存在；固定页头/版本号在页内，表单内容在滚动文档视图内
//      （第 12 轮起表单区可滚动，越界断言按「页面控件」与「文档视图内容」分别执行）。
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static int gFailures = 0;
static void Check(BOOL ok, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@: %@", ok ? @"PASS" : @"FAIL", msg);
    if (!ok) gFailures++;
}

static BOOL RectsOverlap(NSRect a, NSRect b) {
    return NSIntersectsRect(a, b) && !NSIsEmptyRect(NSIntersectionRect(a, b));
}

// 用真实窗口/主页/布局流程构建 App。
static ResourceDetectorAppDelegate *MakeLaunchedApp(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:@"UIExperienceLaunch" object:nil]];
    return app;
}

static void SetContentSize(ResourceDetectorAppDelegate *app, CGFloat w, CGFloat h) {
    app.window.contentView.frame = NSMakeRect(0, 0, w, h);
    [app layoutWorkspace];
}

// 详情字段集合（标题之外的键值行）
static NSArray<NSView *> *DetailFieldViews(ResourceDetectorAppDelegate *app) {
    NSMutableArray<NSView *> *v = [NSMutableArray array];
    for (NSView *x in @[app.durationTitle, app.durationValue, app.formatTitle, app.formatValue,
                        app.sizeTitle, app.sizeValue, app.sourceTitle, app.sourceValue,
                        app.variantPicker, app.linkTitleLabel, app.linkField, app.linkCopyButton,
                        app.detailDownloadButton]) {
        if (x) [v addObject:x];
    }
    return v;
}

static void TestPaneRatio(void) {
    ResourceDetectorAppDelegate *app = MakeLaunchedApp();
    PreferencesStore *store = [PreferencesStore shared];
    NSInteger original = [store integerForKey:SevenZZKeyMainPaneRatio defaultValue:0];
    NSArray<NSNumber *> *expected = @[@0.30, @0.20, @0.25];
    NSArray<NSNumber *> *widths = @[@760, @980];

    for (NSUInteger i = 0; i < expected.count; i++) {
        [store setInteger:(NSInteger)i forKey:SevenZZKeyMainPaneRatio];
        Check(fabs([app leftPaneRatio] - expected[i].doubleValue) < 0.0001,
              @"UIR-1 档位 %lu 返回比例 %.2f（实际 %.3f）", (unsigned long)i, expected[i].doubleValue, [app leftPaneRatio]);
        for (NSNumber *w in widths) {
            SetContentSize(app, w.doubleValue, 438);
            CGFloat innerW = w.doubleValue - 2 * 24.0;
            CGFloat wantLeft = expected[i].doubleValue * innerW;
            CGFloat gotLeft = NSWidth(app.leftPane.frame);
            Check(fabs(gotLeft - wantLeft) <= 1.0,
                  @"UIR-2 窗口 %.0f 档位 %lu 左栏宽 %.1f 与期望 %.1f 误差 ≤1pt", w.doubleValue, (unsigned long)i, gotLeft, wantLeft);
            CGFloat wantRight = w.doubleValue - 24.0 - (24.0 + wantLeft + 1);
            Check(fabs(NSWidth(app.detailPane.frame) - wantRight) <= 1.0,
                  @"UIR-2 窗口 %.0f 档位 %lu 详情栏宽 %.1f 与期望 %.1f 误差 ≤1pt", w.doubleValue, (unsigned long)i, NSWidth(app.detailPane.frame), wantRight);
            Check(NSMaxX(app.leftPane.frame) <= NSMinX(app.detailPane.frame),
                  @"UIR-3 窗口 %.0f 档位 %lu 左栏与详情栏不重叠", w.doubleValue, (unsigned long)i);
        }
    }

    // 非法偏好值回退 3:7
    [store setInteger:99 forKey:SevenZZKeyMainPaneRatio];
    Check(fabs([app leftPaneRatio] - 0.30) < 0.0001, @"UIR-4 非法偏好值 99 回退 3:7（实际 %.3f）", [app leftPaneRatio]);
    [store setInteger:-7 forKey:SevenZZKeyMainPaneRatio];
    Check(fabs([app leftPaneRatio] - 0.30) < 0.0001, @"UIR-4 非法偏好值 -7 回退 3:7（实际 %.3f）", [app leftPaneRatio]);

    // 持久化 + 重启恢复：写入 2 后新建 App 读回 2
    [store setInteger:2 forKey:SevenZZKeyMainPaneRatio];
    ResourceDetectorAppDelegate *restarted = MakeLaunchedApp();
    Check(fabs([restarted leftPaneRatio] - 0.25) < 0.0001, @"UIR-5 重新启动后恢复所选比例 2.5:7.5（实际 %.3f）", [restarted leftPaneRatio]);

    [store setInteger:original forKey:SevenZZKeyMainPaneRatio];
}

static void TestStatusText(void) {
    ResourceDetectorAppDelegate *app = MakeLaunchedApp();

    NSArray<NSString *> *longStrings = @[@"正在探测第 1/1 个页面：example.com",
                                         @"正在扫描列表页 1/3 的视频…",
                                         @"列表页 2/3：视频页加载失败，正在重试…"];
    for (NSString *raw in longStrings) {
        NSString *shown = [app displayStatusForDiscoveryStatus:raw];
        Check(shown.length > 0, @"UIS-1 底层状态有短文案映射（原始：%@）", raw);
        Check(![shown containsString:@"第"] && ![shown containsString:@"/"] && ![shown containsString:@"example.com"],
              @"UIS-2 不显示 host/页数/进度细节（原始 %@ → 实际 %@）", raw, shown);
        Check([shown containsString:@"探测"] || [shown containsString:@"读取"],
              @"UIS-3 短文案仍表达进行中（实际：%@）", shown);
    }

    // 真正跑一次 scan：状态文字必须是短文本
    app.urlField.stringValue = @"https://example.com/page";
    [app scan:nil];
    NSString *status = app.statusNote.stringValue ?: @"";
    Check(![status containsString:@"第 1/1"] && ![status containsString:@"example.com/page"],
          @"UIS-4 真实探测状态不出现长串（实际：%@）", status);
}

static void TestDetailTitleFullAndStable(void) {
    ResourceDetectorAppDelegate *app = MakeLaunchedApp();
    NSString *longTitle = @"这是一个非常非常长的视频标题用于验证详情区域标题不会被省略号截断并且下方字段整体下移不会重叠";
    app.detailTitle.stringValue = longTitle;

    for (NSNumber *w in @[@760, @980]) {
        SetContentSize(app, w.doubleValue, 438);
        // 标题完整（未在数据层被 titleSummary 截断）
        Check([app.detailTitle.stringValue isEqualToString:longTitle],
              @"UID-1 窗口 %.0f 标题完整显示未被截断", w.doubleValue);
        Check(![app.detailTitle.stringValue containsString:@"…"],
              @"UID-2 窗口 %.0f 标题不含省略号", w.doubleValue);
        Check(app.detailTitle.lineBreakMode == NSLineBreakByWordWrapping,
              @"UID-3 窗口 %.0f 标题采用换行而非尾部截断", w.doubleValue);

        NSRect pane = app.detailPane.bounds;
        Check(NSContainsRect(pane, app.detailTitle.frame), @"UID-4 窗口 %.0f 标题在面板内", w.doubleValue);
        for (NSView *v in DetailFieldViews(app)) {
            if (v.hidden) continue;
            Check(NSContainsRect(pane, v.frame), @"UID-5 窗口 %.0f %@ 在面板内", w.doubleValue, NSStringFromClass(v.class));
            Check(!RectsOverlap(app.detailTitle.frame, v.frame),
                  @"UID-6 窗口 %.0f 标题与 %@ 不重叠", w.doubleValue, NSStringFromClass(v.class));
        }
        // 字段之间也不重叠
        NSArray<NSView *> *fields = DetailFieldViews(app);
        for (NSUInteger i = 0; i < fields.count; i++) {
            for (NSUInteger j = i + 1; j < fields.count; j++) {
                if (fields[i].hidden || fields[j].hidden) continue;
                Check(!RectsOverlap(fields[i].frame, fields[j].frame),
                      @"UID-7 窗口 %.0f 详情字段 %lu/%lu 不重叠", w.doubleValue, (unsigned long)i, (unsigned long)j);
            }
        }
        Check(NSMaxY(app.detailTitle.frame) > NSMaxY(app.durationValue.frame),
              @"UID-8 窗口 %.0f 标题位于首行字段上方", w.doubleValue);
    }
}

// 第 12 轮起行标题/说明位于滚动容器的文档视图内（不再是 settingsPage 的直接子视图），
// 因此必须递归查找；否则这些断言会退化成「找不到控件 → 直接失败」或「静默跳过」。
static NSTextField *RatioLabelIn(NSView *page, NSString *title) {
    for (NSView *v in page.subviews) {
        if ([v isKindOfClass:[NSTextField class]] && [[(NSTextField *)v stringValue] isEqualToString:title]) return (NSTextField *)v;
        NSTextField *nested = RatioLabelIn(v, title);
        if (nested) return nested;
    }
    return nil;
}

static void TestSettingsPageStable(void) {
    ResourceDetectorAppDelegate *app = MakeLaunchedApp();
    NSView *page = app.settingsPage;
    page.frame = NSMakeRect(0, 0, 760, 438);
    [app layoutSettingsControls];

    // 三档比例控件存在、稳定 identifier、恰好三段
    // （第 12 轮把「要展开的下拉菜单」换成「三档平铺分段控件」，identifier 保持不变）
    Check(app.settingsPaneRatioControl != nil, @"UIX-1 设置页存在比例控件");
    Check([app.settingsPaneRatioControl.identifier isEqualToString:@"RDPaneRatioPopup"], @"UIX-2 比例控件 identifier 稳定");
    Check(app.settingsPaneRatioControl.segmentCount == 3, @"UIX-3 比例控件恰好三档（实际 %ld）", (long)app.settingsPaneRatioControl.segmentCount);

    // 页面固定控件（页头 + 滚动容器 + 版本号）在最小窗口 bounds 内
    for (NSView *v in page.subviews) {
        Check(NSContainsRect(page.bounds, v.frame), @"UIX-4a 最小窗口下页面固定控件 %@ 在设置页内", NSStringFromClass(v.class));
    }
    // 表单内容在滚动文档视图 bounds 内（一条都不能被裁掉）
    NSView *doc = app.settingsDocumentView;
    Check(doc != nil, @"UIX-4b 设置页存在滚动文档视图");
    if (doc) {
        for (NSView *v in doc.subviews) {
            Check(NSContainsRect(doc.bounds, v.frame),
                  @"UIX-4b 最小窗口下表单内容 %@ 在滚动文档视图内", NSStringFromClass(v.class));
        }
    }

    // 比例行与下载位置行不重叠
    NSTextField *ratioLabel = RatioLabelIn(page, @"左右栏比例");
    NSTextField *ratioHint = RatioLabelIn(page, @"调整资源列表与详情区域的宽度比例");
    NSTextField *locLabel = RatioLabelIn(page, @"下载位置");
    NSTextField *locHint = RatioLabelIn(page, @"选择资源下载后保存的文件夹");
    Check(ratioLabel && locLabel && ratioHint && locHint, @"UIX-5 比例行与下载位置行控件齐备");
    if (ratioLabel && locLabel && ratioHint && locHint) {
        Check(!RectsOverlap(ratioLabel.frame, locLabel.frame), @"UIX-6 比例标题与下载位置标题不重叠");
        Check(!RectsOverlap(ratioHint.frame, locHint.frame), @"UIX-7 比例说明与下载位置说明不重叠");
        Check(!RectsOverlap(app.settingsPaneRatioControl.frame, locLabel.frame), @"UIX-8 比例控件不与下载位置标题重叠");
        Check(!RectsOverlap(app.settingsPaneRatioControl.frame, locHint.frame), @"UIX-9 比例控件不与下载位置说明重叠");
        // 「比例行在下载位置行上方」的判定必须按容器坐标朝向读：行现在位于 flipped 的
        // 文档视图内，y 向下增长，上方 = y 更小。断言强度不变，只是换了正确的比较方向。
        BOOL flipped = ratioLabel.superview.isFlipped;
        BOOL ratioIsAbove = flipped ? (NSMinY(ratioLabel.frame) < NSMinY(locLabel.frame))
                                    : (NSMaxY(ratioLabel.frame) > NSMaxY(locLabel.frame));
        Check(ratioIsAbove, @"UIX-10 比例行位于下载位置行上方（容器 flipped=%d）", (int)flipped);
    }
}

int main(int argc, const char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSLog(@"== UI 体验专项测试 ==");
        TestPaneRatio();
        TestStatusText();
        TestDetailTitleFullAndStable();
        TestSettingsPageStable();
        if (gFailures) {
            NSLog(@"FAILED: %d 项断言未通过", gFailures);
            return 1;
        }
        NSLog(@"PASS: ALL UI EXPERIENCE TESTS");
    }
    return 0;
}