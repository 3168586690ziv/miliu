// build/settings-probe/SettingsProbe.m
// 几何取证探针（不属于测试套件，不修改任何测试文件）：
// 复用 tests/Tests/repair.sh 的编译配置，直接驱动生产代码 buildSettingsPage /
// layoutSettingsControls，打印每个子控件在若干内容区尺寸下的真实 frame，
// 并统计「越界」与「重叠」两件事。用于给 RD-11 与「两个尺寸都不重叠」提供数字证据。
#define main RDUnusedProbeOriginalMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static int gBad = 0;
static int gOverlap = 0;

static NSString *ProbeName(NSView *v) {
    NSMutableString *s = [NSMutableString string];
    if ([v isKindOfClass:[NSPopUpButton class]]) [s appendString:@"PopUp"];
    else if ([v isKindOfClass:[NSSwitch class]]) [s appendString:@"Switch"];
    else if ([v isKindOfClass:[NSButton class]]) [s appendString:@"Button"];
    else if ([v isKindOfClass:[NSTextField class]]) [s appendString:@"Text"];
    else [s appendString:NSStringFromClass([v class])];
    if (v.identifier.length) [s appendFormat:@"[%@]", v.identifier];
    NSString *t = nil;
    if ([v isKindOfClass:[NSTextField class]]) t = [(NSTextField *)v stringValue];
    else if ([v isKindOfClass:[NSButton class]]) t = [(NSButton *)v title];
    if (t.length > 24) t = [[t substringToIndex:24] stringByAppendingString:@"…"];
    if (t.length) [s appendFormat:@" “%@”", t];
    return s;
}

// 第 12 轮起设置页采用「分组卡片」：卡片是有意覆盖其内容的容器背景，
// 因此「背景 × 内容」的包含关系不算重叠。只豁免这一种；越界检查与
// 「内容彼此之间」的重叠检查保持不变（不放宽真实约束）。
static BOOL IsContainerBackground(NSView *v) {
    return [v.identifier isEqualToString:@"RDSettingsCardBackground"];
}

static void ProbeAudit(NSView *page, NSSize size, NSString *tag) {
    NSRect bounds = NSMakeRect(0, 0, size.width, size.height);
    NSArray<NSView *> *subs = page.subviews;
    printf("\n=== %s @ %.0f x %.0f（子控件 %lu 个）===\n", tag.UTF8String, size.width, size.height,
           (unsigned long)subs.count);
    int bad = 0;
    for (NSView *v in subs) {
        NSRect f = v.frame;
        BOOL inside = NSContainsRect(bounds, f);
        if (!inside) bad++;
        printf("  %-4s y=%7.2f h=%6.2f x=%7.2f w=%7.2f maxY=%7.2f maxX=%7.2f  %s\n",
               inside ? "OK" : "OUT", f.origin.y, f.size.height, f.origin.x, f.size.width,
               NSMaxY(f), NSMaxX(f), ProbeName(v).UTF8String);
    }
    int ov = 0, exempt = 0;
    for (NSUInteger i = 0; i < subs.count; i++) {
        for (NSUInteger j = i + 1; j < subs.count; j++) {
            NSRect a = subs[i].frame, b = subs[j].frame;
            NSRect inter = NSIntersectionRect(a, b);
            if (NSIsEmptyRect(inter)) continue;
            if (IsContainerBackground(subs[i]) || IsContainerBackground(subs[j])) { exempt++; continue; }
            ov++;
            printf("  !! OVERLAP  %s  ×  %s  → 重合 y=%.1f..%.1f x=%.1f..%.1f 面积=%.0f\n",
                   ProbeName(subs[i]).UTF8String, ProbeName(subs[j]).UTF8String,
                   NSMinY(inter), NSMaxY(inter), NSMinX(inter), NSMaxX(inter),
                   NSWidth(inter) * NSHeight(inter));
        }
    }
    printf("  说明: %d 组为「卡片背景 × 其内容」的包含关系，属设计，不计为重叠\n", exempt);
    printf("  小结: 越界 %d 个 / 重叠 %d 组%s\n", bad, ov, (bad == 0 && ov == 0) ? "  → 通过" : "  → 不通过");
    gBad += bad;
    gOverlap += ov;
}

static ResourceDetectorAppDelegate *ProbeApp(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.settingsPage = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 980, 700)];
    [app buildSettingsPage];
    return app;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL realPath = (argc > 1 && strcmp(argv[1], "--real-path") == 0);
        printf("探针模式：%s\n", realPath ? "真实路径（resize 后显式调用 layoutSettingsControls）"
                                          : "RD-11 路径（resize 后由 NSViewFrameDidChangeNotification 触发重排）");

        if (!realPath) {
            ResourceDetectorAppDelegate *a = ProbeApp();
            ProbeAudit(a.settingsPage, NSMakeSize(980, 700), @"A1 设计尺寸 980x700（build 后原状）");
            a.settingsPage.frame = NSMakeRect(0, 0, 760, 438);
            ProbeAudit(a.settingsPage, NSMakeSize(760, 438), @"A2 RD-11 最小内容区 760x438（仅 autoresizing）");
            a.settingsPage.frame = NSMakeRect(0, 0, 860, 520);
            ProbeAudit(a.settingsPage, NSMakeSize(860, 520), @"A3 860x520（仅 autoresizing，含上一步叠加）");
        } else {
            NSSize sizes[] = { {980, 700}, {900, 600}, {800, 500}, {760, 438}, {860, 520}, {1000, 720} };
            for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
                ResourceDetectorAppDelegate *a = ProbeApp();
                a.settingsPage.frame = NSMakeRect(0, 0, sizes[i].width, sizes[i].height);
                [a layoutSettingsControls];
                NSString *tag = [NSString stringWithFormat:@"B%u 真实路径 %gx%g", i + 1, sizes[i].width, sizes[i].height];
                ProbeAudit(a.settingsPage, sizes[i], tag);
            }
        }
        printf("\n总计：越界 %d 个，重叠 %d 组\n", gBad, gOverlap);
        return (gBad == 0 && gOverlap == 0) ? 0 : 1;
    }
}
