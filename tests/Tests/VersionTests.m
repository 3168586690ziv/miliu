//
//  VersionTests.m — 设置页版本号专项验收
//
//  覆盖：控件存在、严格格式 ^v[0-9]+\.[0-9]+$、与构建日志 CODE_LINES /
//  FIX_ROUND / DISPLAY_VERSION 一致、重复打开设置页不改变、最小设置页尺寸下
//  仍在 bounds 内、不遮挡现有控件、低调样式、不写死版本串。
//  构建产物级一致性（Info.plist / 二进制 / 图标 / 重复构建不递增轮数）
//  由 tests/Tests/version.sh 在同一脚本内校验。
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static NSMutableArray<NSString *> *gFailures;
static void Check(BOOL ok, NSString *message) {
    if (!gFailures) gFailures = [NSMutableArray array];
    if (!ok) { [gFailures addObject:message]; NSLog(@"FAIL: %@", message); return; }
    NSLog(@"PASS: %@", message);
}
static void CheckSummary(void) {
    if (gFailures.count) {
        NSLog(@"FAILED %lu 项断言（首项：%@）", (unsigned long)gFailures.count, gFailures.firstObject);
        exit(1);
    }
    NSLog(@"PASS: ALL VERSION TESTS");
}

static NSString *Env(NSString *key) {
    return [[NSProcessInfo processInfo].environment objectForKey:key];
}

// 设置页上的版本号控件（构建实现用 identifier 标记，测试不依赖私有属性）
static NSView *VersionLabelIn(NSView *page) {
    for (NSView *v in page.subviews) {
        if ([v.identifier isEqualToString:@"RDVersionLabel"]) return v;
    }
    return nil;
}

static ResourceDetectorAppDelegate *MakeSettingsApp(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    NSRect frame = NSMakeRect(0, 0, 980, 700);
    app.homePage = [[NSView alloc] initWithFrame:frame];
    app.settingsPage = [[NSView alloc] initWithFrame:frame];
    [app buildSettingsPage];
    return app;
}

int main(int argc, const char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    NSLog(@"== 设置页版本号专项测试 ==");
    ResourceDetectorAppDelegate *app = MakeSettingsApp();
    NSView *page = app.settingsPage;
    NSView *label = VersionLabelIn(page);

    // 1. 控件存在且是文本控件
    Check(label != nil, @"V1 设置页存在版本号控件（identifier=RDVersionLabel）");
    Check([label isKindOfClass:[NSTextField class]], @"V1 版本号控件是 NSTextField");
    if (!label) { CheckSummary(); return 0; }
    NSTextField *field = (NSTextField *)label;
    NSString *text = field.stringValue ?: @"";

    // 2. 主文本严格匹配 ^v[0-9]+\.[0-9]+$（无多余文字、无大写 V、无空格/横杠）
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^v[0-9]+\\.[0-9]+$" options:0 error:NULL];
    BOOL strict = [re numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] == 1;
    Check(strict, [NSString stringWithFormat:@"V2 主文本严格匹配 ^v[0-9]+\\.[0-9]+$（实际：%@）", text]);

    // 3/4/5. 与构建日志三行一致
    NSString *expectLines = Env(@"ZZ_EXPECT_CODE_LINES");
    NSString *expectRound = Env(@"ZZ_EXPECT_FIX_ROUND");
    NSString *expectDisplay = Env(@"ZZ_EXPECT_DISPLAY_VERSION");
    NSArray *parts = [text componentsSeparatedByString:@"."];
    NSString *linesPart = ([text hasPrefix:@"v"] && parts.count == 2) ? [parts[0] substringFromIndex:1] : nil;
    Check(expectDisplay.length > 0 && [text isEqualToString:expectDisplay],
          [NSString stringWithFormat:@"V5 显示串与构建日志 DISPLAY_VERSION 一致（期望 %@，实际 %@）", expectDisplay, text]);
    Check(expectLines.length > 0 && [linesPart isEqualToString:expectLines],
          [NSString stringWithFormat:@"V3 代码行数与构建日志 CODE_LINES 一致（期望 %@，实际 %@）", expectLines, linesPart]);
    Check(expectRound.length > 0 && [parts.lastObject isEqualToString:expectRound],
          [NSString stringWithFormat:@"V4 修复轮数与构建日志 FIX_ROUND 一致（期望 %@，实际 %@）", expectRound, parts.lastObject]);

    // 10. 显示值来自构建期生成头文件，而不是页面里写死的字符串
#ifdef RD_GENERATED_VERSION_STRING
    Check([text isEqualToString:RD_GENERATED_VERSION_STRING], @"V10 显示串来自构建生成头 RD_GENERATED_VERSION_STRING");
    Check([linesPart isEqualToString:[NSString stringWithFormat:@"%d", RD_GENERATED_CODE_LINES]],
          @"V10 行数来自构建生成头 RD_GENERATED_CODE_LINES");
    Check([parts.lastObject isEqualToString:[NSString stringWithFormat:@"%d", RD_GENERATED_FIX_ROUND]],
          @"V10 轮数来自构建生成头 RD_GENERATED_FIX_ROUND");
#else
    Check(NO, @"V10 构建生成头未接入（RD_GENERATED_VERSION_STRING 未定义）");
#endif

    // 6. 重复打开设置页：同一控件、同一文本、数量不变
    for (int i = 0; i < 5; i++) { [app showSettingsPage:nil]; [app switchBackToHome:nil]; }
    NSView *again = VersionLabelIn(page);
    Check(again == label, @"V6 重复打开设置页后仍是同一个版本号控件");
    Check([((NSTextField *)again).stringValue isEqualToString:text], @"V6 重复打开设置页后版本号文本不变");
    NSUInteger labelCount = 0;
    for (NSView *v in page.subviews) if ([v.identifier isEqualToString:@"RDVersionLabel"]) labelCount++;
    Check(labelCount == 1, [NSString stringWithFormat:@"V6 设置页始终只有一个版本号控件（实际 %lu 个）", (unsigned long)labelCount]);

    // 8. 低调样式：小字号、低对比、底部右侧
    Check(field.font.pointSize > 0 && field.font.pointSize <= 11.0,
          [NSString stringWithFormat:@"V8 使用小字号（实际 %.1fpt）", field.font.pointSize]);
    Check(![field.textColor isEqual:[NSColor labelColor]], @"V8 使用低对比度颜色而非正文色");
    Check(NSMinY(label.frame) < 60 && NSMaxX(label.frame) > NSWidth(page.bounds) * 0.5,
          [NSString stringWithFormat:@"V8 位于设置页底部右侧（frame=%@）", NSStringFromRect(label.frame)]);

    // 9. 不在探测主页 / 不遮挡现有设置控件
    Check(![app.homePage.subviews containsObject:label], @"V9 版本号不在探测主页（结果列表区域）");
    BOOL overlaps = NO;
    for (NSView *v in page.subviews) {
        if (v == label) continue;
        if (NSIntersectsRect(v.frame, label.frame)) { overlaps = YES; break; }
    }
    Check(!overlaps, @"V9 版本号不遮挡任何现有设置控件");

    // 7. 最小设置页尺寸（窗口 760x460 对应内容区 760x438；再收紧到 432）仍在 bounds 内
    [page setFrameSize:NSMakeSize(760, 438)];
    Check(NSContainsRect(page.bounds, label.frame), @"V7 最小设置页尺寸 760x438 下版本号仍在 bounds 内");
    [page setFrameSize:NSMakeSize(760, 432)];
    Check(NSContainsRect(page.bounds, label.frame), @"V7 收紧尺寸 760x432 下版本号仍在 bounds 内");
    [page setFrameSize:NSMakeSize(980, 700)];
    Check(NSContainsRect(page.bounds, label.frame), @"V7 原始尺寸 980x700 下版本号仍在 bounds 内");

    CheckSummary();
    return 0;
} }
