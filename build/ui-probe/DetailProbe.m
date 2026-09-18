// build/ui-probe/DetailProbe.m — 详情面板几何取证（非测试套件）
// 走真实启动路径（applicationDidFinishLaunching）+ 真实填充入口（configureDetailForMedia:），
// 用一个「长标题 + 可见画质下拉」的真实资源，打印详情面板每个控件的真实 frame 与两两重叠。
#define main RDUnusedDetailProbeMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static NSString *F(NSRect r) {
    return [NSString stringWithFormat:@"x=%7.2f y=%7.2f w=%7.2f h=%6.2f maxY=%7.2f maxX=%7.2f",
            r.origin.x, r.origin.y, r.size.width, r.size.height, NSMaxY(r), NSMaxX(r)];
}

static NSArray<NSArray *> *Items(ResourceDetectorAppDelegate *app) {
    NSMutableArray *items = [NSMutableArray array];
    void (^add)(NSString *, NSView *) = ^(NSString *name, NSView *v) {
        if (v) [items addObject:@[name, v]];
    };
    add(@"标题", app.detailTitle);
    add(@"时长标题", app.durationTitle);   add(@"时长值", app.durationValue);
    add(@"格式标题", app.formatTitle);     add(@"格式值", app.formatValue);
    add(@"大小标题", app.sizeTitle);       add(@"大小值", app.sizeValue);
    add(@"来源标题", app.sourceTitle);     add(@"来源值", app.sourceValue);
    add(@"画质下拉", app.variantPicker);
    add(@"直链标题", app.linkTitleLabel);  add(@"直链字段", app.linkField);
    add(@"复制按钮", app.linkCopyButton);  add(@"下载按钮", app.detailDownloadButton);
    add(@"缩略图", app.thumbView);
    return items;
}

static int DumpAndCheck(ResourceDetectorAppDelegate *app, NSString *tag) {
    NSView *pane = app.detailPane;
    NSRect bounds = pane.bounds;
    printf("\n=== %s（detailPane %.0f x %.0f）===\n", tag.UTF8String, NSWidth(bounds), NSHeight(bounds));
    int bad = 0, ov = 0;
    NSArray<NSArray *> *items = Items(app);
    for (NSArray *pair in items) {
        NSView *v = pair[1];
        NSRect f = v.frame;
        BOOL inside = NSContainsRect(bounds, f);
        if (!inside) bad++;
        printf("  %-4s %-9s %s  hidden=%d\n", inside ? "OK" : "OUT", [pair[0] UTF8String],
               F(f).UTF8String, (int)v.hidden);
    }
    for (NSUInteger i = 0; i < items.count; i++) {
        for (NSUInteger j = i + 1; j < items.count; j++) {
            NSView *a = items[i][1], *b = items[j][1];
            if (a.hidden || b.hidden) continue;
            NSRect inter = NSIntersectionRect(a.frame, b.frame);
            if (!NSIntersectsRect(a.frame, b.frame) || NSIsEmptyRect(inter)) continue;
            ov++;
            printf("  !! 重叠 %s × %s  重合 y=%.2f..%.2f x=%.2f..%.2f 面积=%.0f\n",
                   [items[i][0] UTF8String], [items[j][0] UTF8String],
                   NSMinY(inter), NSMaxY(inter), NSMinX(inter), NSMaxX(inter),
                   NSWidth(inter) * NSHeight(inter));
        }
    }
    printf("  小结：越界 %d / 重叠 %d%s\n", bad, ov, (bad == 0 && ov == 0) ? "  → 通过" : "  → 不通过");
    return bad + ov;
}

int main(void) {
    @autoreleasepool {
        ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
        [app applicationDidFinishLaunching:[NSNotification notificationWithName:@"DetailProbeLaunch" object:nil]];

        NSString *titles[] = {
            @"这是一个非常非常长的视频标题用于验证详情区域标题不会被省略号截断并且下方字段整体下移不会重叠",
            @"超长标题压力用例：这是一个明显更长的中文视频标题它会在详情面板里折成三行用来验证键值行与画质下拉在极限情况下依然保持各自槽位互不重叠也不会被顶出面板下边界之外"
        };
        CGFloat sizes[][2] = { {980, 700}, {980, 438}, {760, 438}, {760, 428}, {860, 520} };
        int bad = 0;
        for (int t = 0; t < 2; t++) {
            DetectedMedia *m = [DetectedMedia new];
            m.title = titles[t];
            m.mediaURL = @"https://cdn.example.com/b01KKUv00d96MgJ1inKYWu4b5enEJIVMnszJqBkHh00/tracks/v1/variant.m3u8";
            m.sourcePageURL = @"https://example.com/";
            m.format = @"hls";
            m.resourceKind = RDResourceKindManifest;
            m.declaredVariants = @[ @{@"label": @"720p", @"level": @720, @"url": @"https://cdn.example.com/a/variant-720.m3u8"},
                                    @{@"label": @"1080p", @"level": @1080, @"url": @"https://cdn.example.com/a/variant-1080.m3u8"} ];
            [app configureDetailForMedia:m];
            for (int i = 0; i < 5; i++) {
                app.window.contentView.frame = NSMakeRect(0, 0, sizes[i][0], sizes[i][1]);
                [app layoutWorkspace];
                NSString *tag = [NSString stringWithFormat:@"标题%lu字 + 画质下拉可见 @ 内容区 %.0fx%.0f", (unsigned long)titles[t].length, sizes[i][0], sizes[i][1]];
                bad += DumpAndCheck(app, tag);
            }
        }
        printf("\n总计问题数：%d\n", bad);
        return bad == 0 ? 0 : 1;
    }
}
