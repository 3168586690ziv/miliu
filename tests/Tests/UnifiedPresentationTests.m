//
//  UnifiedPresentationTests.m — 统一呈现 + 画质变动刷新 生产链专项验收
//
//  只替换“元数据快照何时到达”（transport 层的结果投递）与表格托管对象（记录
//  reload/选择），App 的 finishScanWithResult / applyDiscoveryResult /
//  configureDetailForMedia / selectDeclaredVariant / downloadSelected /
//  visibleMedia / 进度展示全部走真实生产代码。
//
//  断言的是用户实际能看到的界面状态：进度条数值、状态文案、缩略图与占位文字、
//  大小/时长文本、以及真实入队参数——不是内部辅助函数。
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main

static NSMutableArray<NSString *> *gFailures;
static void Check(BOOL ok, NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!gFailures) gFailures = [NSMutableArray array];
    if (!ok) { [gFailures addObject:message]; NSLog(@"FAIL: %@", message); return; }
    NSLog(@"PASS: %@", message);
}
static void CheckSummary(void) {
    if (gFailures.count) {
        NSLog(@"FAILED %lu 项断言（首项：%@）", (unsigned long)gFailures.count, gFailures.firstObject);
        exit(1);
    }
    NSLog(@"PASS: ALL UNIFIED-PRESENTATION TESTS");
}
static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}

#pragma mark - 快照夹具

static RDMetadataField *UPField(RDMetadataState state, id value) {
    RDMetadataField *f = [RDMetadataField new];
    f.state = state; f.value = value; f.source = @"fixture";
    return f;
}
static RDMetadataField *UPFieldSource(RDMetadataState state, id value, NSString *source) {
    RDMetadataField *f = [RDMetadataField new];
    f.state = state; f.value = value; f.source = source;
    return f;
}
static RDMetadataField *UPLoading(void) { return UPField(RDMetadataLoading, nil); }
static RDMetadataField *UPUnknown(void) { return UPField(RDMetadataUnknown, nil); }
static RDMetadataSnapshot *UPSnapshot(RDMetadataField *duration, RDMetadataField *size,
                                      RDMetadataField *dimensions, RDMetadataField *preview) {
    RDMetadataSnapshot *s = [RDMetadataSnapshot new];
    s.duration = duration ?: UPUnknown();
    s.size = size ?: UPUnknown();
    s.dimensions = dimensions ?: UPUnknown();
    s.preview = preview ?: UPUnknown();
    s.variants = @[];
    return s;
}
// 首屏缩略图通道的终态快照：缩略图有结论，其余字段结构性未知（与生产服务的
// previewOnly work 收尾结果一致）。
static RDMetadataSnapshot *UPTerminalPreview(RDMetadataField *preview) {
    return UPSnapshot(UPUnknown(), UPUnknown(), UPUnknown(), preview);
}
// 完整详情通道的终态快照。
static RDMetadataSnapshot *UPTerminalFull(RDMetadataField *duration, RDMetadataField *size,
                                          RDMetadataField *dimensions, RDMetadataField *preview) {
    return UPSnapshot(duration, size, dimensions, preview);
}
static NSImage *UPImage(void) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(4, 4)];
    [image lockFocus]; [[NSColor redColor] setFill]; NSRectFill(NSMakeRect(0, 0, 4, 4)); [image unlockFocus];
    return image;
}

#pragma mark - 元数据服务替身（只控制“快照何时到达”）

@interface UPStubService : RDMetadataService
@property NSMutableDictionary<NSString *, RDMetadataSnapshot *> *fullSnapshots;
@property NSMutableDictionary<NSString *, RDMetadataSnapshot *> *previewSnapshots;
@property NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *subscribers;
@property NSUInteger fullSubscriptions, previewSubscriptions;
@end
@implementation UPStubService
- (instancetype)init {
    if ((self = [super init])) {
        _fullSnapshots = [NSMutableDictionary dictionary];
        _previewSnapshots = [NSMutableDictionary dictionary];
        _subscribers = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)recordToken:(RDMetadataToken *)token update:(void (^)(RDMetadataSnapshot *))update
                key:(NSString *)key full:(BOOL)full {
    NSMutableArray *entries = self.subscribers[key];
    if (!entries) { entries = [NSMutableArray array]; self.subscribers[key] = entries; }
    [entries addObject:@[token, [update copy], @(full)]];
}
- (RDMetadataToken *)subscribeMedia:(DetectedMedia *)media reload:(BOOL)reload
                             update:(void (^)(RDMetadataSnapshot *))update {
    RDMetadataToken *token = [RDMetadataToken new];
    self.fullSubscriptions++;
    [self recordToken:token update:update key:media.mediaURL ?: @"" full:YES];
    // 与生产服务一致：订阅时先投递一次当前已知快照（异步到主队列，避免重入）。
    RDMetadataSnapshot *snapshot = self.fullSnapshots[media.mediaURL ?: @""];
    if (snapshot) dispatch_async(dispatch_get_main_queue(), ^{
        if (!token.cancelled && self.fullSnapshots[media.mediaURL ?: @""] == snapshot) update(snapshot);
    });
    return token;
}
- (RDMetadataToken *)subscribePreviewOnlyForMedia:(DetectedMedia *)media
                                           update:(void (^)(RDMetadataSnapshot *))update {
    RDMetadataToken *token = [RDMetadataToken new];
    self.previewSubscriptions++;
    [self recordToken:token update:update key:media.mediaURL ?: @"" full:NO];
    RDMetadataSnapshot *snapshot = self.previewSnapshots[media.mediaURL ?: @""];
    if (snapshot) dispatch_async(dispatch_get_main_queue(), ^{
        if (!token.cancelled && self.previewSnapshots[media.mediaURL ?: @""] == snapshot) update(snapshot);
    });
    return token;
}
- (void)prioritizeMedia:(DetectedMedia *)media {}
// 同步投递（同一个主线程 turn），模拟生产服务在主队列回调订阅者。
- (NSUInteger)publishForMedia:(DetectedMedia *)media {
    return [self publishForKey:media.mediaURL ?: @""];
}
- (NSUInteger)publishForKey:(NSString *)key {
    NSUInteger delivered = 0;
    for (NSArray *entry in [self.subscribers[key] copy]) {
        RDMetadataToken *token = entry[0];
        void (^update)(RDMetadataSnapshot *) = entry[1];
        BOOL full = [entry[2] boolValue];
        RDMetadataSnapshot *snapshot = (full ? self.fullSnapshots : self.previewSnapshots)[key];
        if (!snapshot || token.cancelled) continue;
        update(snapshot);
        delivered++;
    }
    return delivered;
}
- (NSUInteger)activeSubscriberCountForKey:(NSString *)key {
    NSUInteger count = 0;
    for (NSArray *entry in self.subscribers[key]) if (!((RDMetadataToken *)entry[0]).cancelled) count++;
    return count;
}
@end

#pragma mark - 表格替身（记录真实 reload / 选择）

@interface UPTableRow : NSObject
@property (nonatomic, strong) DetectedMedia *media;
@property (nonatomic, copy) NSString *durationHint;
@property (nonatomic, copy) NSString *sizeHint;
@end
@implementation UPTableRow
- (BOOL)isKindOfClass:(Class)cls { return cls == ResourceResultRowView.class || [super isKindOfClass:cls]; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint {}
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint sizeHint:(NSString *)sizeHint {
    self.media = m; self.durationHint = hint; self.sizeHint = sizeHint;
}
@end
@interface UPTable : NSObject
@property NSUInteger reloads;
@property NSInteger selectedRow;
@property NSUInteger selectionRestores;
@property (nonatomic, strong) UPTableRow *lastRow;   // 最近一次被 App 真实配置的行视图
@end
@implementation UPTable
- (instancetype)init { if ((self = [super init])) _selectedRow = -1; return self; }
- (id)viewAtColumn:(NSInteger)c row:(NSInteger)r makeIfNecessary:(BOOL)make {
    UPTableRow *row = [UPTableRow new];
    self.lastRow = row;
    return row;
}
- (void)reloadData { self.reloads++; }
- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend {
    self.selectionRestores++;
    self.selectedRow = (NSInteger)indexes.firstIndex;
}
- (void)deselectAll:(id)sender { self.selectedRow = -1; }
@end

#pragma mark - 下载入队替身（只记录真实 downloadSelected: 传入的参数）

@interface RDEnqueueSpy : DownloadManager
@property NSString *lastURL;
@property NSNumber *lastExpectedLength;
@property NSUInteger count;
@end
@implementation RDEnqueueSpy
- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url folder:(NSURL *)folder
                            preferredName:(NSString *)name sourcePageURL:(NSString *)sourcePageURL
                             resourceKind:(DownloadResourceKind)kind expectedLength:(int64_t)length {
    self.lastURL = url.absoluteString ?: @"";
    self.lastExpectedLength = @(length);
    self.count++;
    DownloadJob *job = [DownloadJob new];
    job.sourceURL = url;
    job.fileName = name;
    job.resourceKind = kind;
    job.sourcePageURL = sourcePageURL;
    return job;
}
@end

#pragma mark - 团队夹具

// 无缩略图 ID 的普通视频（默认带海报，便于走缩略图通道）。
static DetectedMedia *UPVideo(NSString *url, NSString *poster) {
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = url;
    m.resourceKind = RDResourceKindVideo;
    m.format = @"mp4";
    m.title = @"统一呈现测试视频";
    m.poster = poster;
    return m;
}
static DetectedMedia *UPMaster(NSString *url) {
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = url;
    m.resourceKind = RDResourceKindManifest;
    m.isManifest = YES;
    m.format = @"hls";
    m.title = @"统一呈现测试影片";
    return m;
}
static NSArray *UPTiers(NSString *tier480, NSString *tier720) {
    return @[
        @{ @"url": tier480, @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": tier720, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ];
}

// App 的无窗口 UI：真实控件对象，断言真实界面状态。
static ResourceDetectorAppDelegate *MakeHeadlessApp(UPStubService **outService, UPTable **outTable) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    UPStubService *service = [UPStubService new];
    UPTable *table = [UPTable new];
    app.metadataService = service;
    app.results = [NSMutableArray array];
    app.durationCache = [NSMutableDictionary dictionary];
    app.table = (NSTableView *)table;
    app.variantPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 20) pullsDown:NO];
    app.linkField = [NSTextField labelWithString:@""];
    app.detailTitle = [NSTextField labelWithString:@""];
    app.durationValue = [NSTextField labelWithString:@""];
    app.formatValue = [NSTextField labelWithString:@""];
    app.sizeValue = [NSTextField labelWithString:@""];
    app.dimensionTitle = [NSTextField labelWithString:@""];
    app.dimensionValue = [NSTextField labelWithString:@""];
    app.sourceValue = [NSTextField labelWithString:@""];
    app.emptyHint = [NSTextField labelWithString:@""];
    app.thumbView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 340, 191)];
    app.thumbStatusLabel = [NSTextField labelWithString:@""];
    app.statusNote = [NSTextField labelWithString:@""];
    app.checkLabel = [NSTextField labelWithString:@""];
    app.modeButton = [NSButton buttonWithTitle:@"总/单" target:nil action:nil];
    app.downloadsPage = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 438)];
    app.downloadsTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 760, 300)];
    app.detailContent = @[app.thumbView, app.detailTitle, app.durationValue,
                          app.formatValue, app.sizeValue, app.dimensionTitle,
                          app.dimensionValue, app.sourceValue, app.linkField];
    if (outService) *outService = service;
    if (outTable) *outTable = table;
    return app;
}

// 统一呈现是否已提交（生产实现只在全部必需项到达终态后才写“探测完成”）。
static BOOL UPComplete(ResourceDetectorAppDelegate *app) {
    return [app.statusNote.stringValue containsString:@"探测完成"];
}

// 生产 resultHandler 的两步（applyDiscoveryResult + finishScanWithResult），
// 与 App 内注册的会话回调一致。探测进度不再有独立进度条，改由 statusNote 文字表达。
static void FinishProbe(ResourceDetectorAppDelegate *app, ZZResourceDiscoveryResult *result) {
    app.scanning = YES;
    [app applyDiscoveryResult:result final:YES];
    [app finishScanWithResult:result];
}
static ZZResourceDiscoveryResult *UPResult(NSArray<DetectedMedia *> *media) {
    ZZResourceDiscoveryResult *r = [ZZResourceDiscoveryResult new];
    r.allMedia = media ?: @[];
    r.pageResults = @[];
    r.candidateURLs = @[];
    return r;
}
// 等统一呈现提交（状态文字为探测完成）。
static void RunProgressToEnd(ResourceDetectorAppDelegate *app) {
    Wait(^BOOL { return [app.statusNote.stringValue containsString:@"探测完成"]; }, 3.0);
}

#pragma mark - 一、统一呈现

// U1：探测回调完成但首屏缩略图未完成 → 不得显示“探测完成”，也不得让进度到 100%。
static void U1_CompletionWaitsForListThumbnails(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    DetectedMedia *b = UPVideo(@"https://fixture.invalid/b.mp4", @"https://fixture.invalid/b.jpg");
    [app.results addObjectsFromArray:@[a, b]];
    service.previewSnapshots[a.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));
    service.previewSnapshots[b.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));

    FinishProbe(app, UPResult(@[a, b]));
    Check(!UPComplete(app), @"U1 缩略图未完成时不得宣布探测完成（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"正在准备呈现"] || [app.statusNote.stringValue containsString:@"正在"],
          @"U1 准备阶段状态文字仍在进行中（实际：%@）", app.statusNote.stringValue);
    Check(![app.statusNote.stringValue containsString:@"探测完成"], @"U1 准备阶段不得提前宣布完成");
    Check(service.previewSubscriptions + service.fullSubscriptions >= 2,
          @"U1 首屏缩略图通道已启动（preview=%lu full=%lu）",
          (unsigned long)service.previewSubscriptions, (unsigned long)service.fullSubscriptions);

    [service publishForMedia:a];
    Check(!UPComplete(app), @"U1 只完成部分缩略图时仍不得宣布完成");
    [service publishForMedia:b];
    Check(UPComplete(app), @"U1 全部缩略图有结论后才提交统一呈现");
    Check([app.statusNote.stringValue containsString:@"探测完成"], @"U1 提交后状态为探测完成（实际：%@）", app.statusNote.stringValue);
    Check(table.reloads >= 2, @"U1 统一提交时列表被刷新一次（实际 %lu 次 reload）", (unsigned long)table.reloads);
}

// U2：详细信息未完成时进度不得提前结束。
static void U2_CompletionWaitsForDetailMetadata(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    [app.results addObject:a];
    // 用户先选中该资源（详情订阅已建立），随后探测结束。
    [app configureDetailForMedia:a];
    table.selectedRow = 0;
    Check(app.metadataToken != nil, @"U2 详情订阅已建立");
    service.fullSnapshots[a.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @754.0),
                                                       UPField(RDMetadataKnown, @12345678),
                                                       UPField(RDMetadataKnown, [NSValue valueWithSize:NSMakeSize(1280, 720)]),
                                                       UPField(RDMetadataKnown, UPImage()));
    FinishProbe(app, UPResult(@[a]));
    Check(!UPComplete(app), @"U2 详情未就绪时不得宣布完成（实际：%@）", app.statusNote.stringValue);

    // 注意：详情订阅的回调同时更新界面；它到达终态时统一呈现才能提交。
    [service publishForMedia:a];
    Check(UPComplete(app), @"U2 详情到达终态后才提交（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"探测完成"], @"U2 提交后宣布完成");
    Check([app.sizeValue.stringValue containsString:@"MB"] || [app.sizeValue.stringValue containsString:@"KB"],
          @"U2 提交后详情大小与快照一致（实际：%@）", app.sizeValue.stringValue);
    Check([app.durationValue.stringValue isEqualToString:@"12:34"], @"U2 提交后时长与快照一致（实际：%@）", app.durationValue.stringValue);
    Check(app.thumbView.image != nil && app.thumbStatusLabel.hidden, @"U2 提交后缩略图已呈现");
    RunProgressToEnd(app);
}

// U3：缩略图失败必须稳定收尾，不得无限“读取中…”，且失败资源仍进入统一呈现。
static void U3_ThumbnailFailureSettles(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    [app.results addObject:a];
    [app configureDetailForMedia:a];
    table.selectedRow = 0;
    service.fullSnapshots[a.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @10.0),
                                                       UPField(RDMetadataKnown, @1024),
                                                       UPUnknown(),
                                                       UPField(RDMetadataFailed, nil));
    FinishProbe(app, UPResult(@[a]));
    [service publishForMedia:a];
    Check(UPComplete(app), @"U3 缩略图失败也能结束准备阶段（不无限等待）（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"探测完成"], @"U3 失败资源仍进入统一呈现");
    Check(app.thumbView.image == nil && !app.thumbStatusLabel.hidden, @"U3 失败时显示稳定占位而非空白或旧图");
    Check([app.thumbStatusLabel.stringValue isEqualToString:@"读取失败"], @"U3 占位文字为明确的失败状态（实际：%@）", app.thumbStatusLabel.stringValue);
    RunProgressToEnd(app);
    Check(![app.thumbStatusLabel.stringValue isEqualToString:@"读取中…"], @"U3 不再停留在读取中");
}

// U4：详细信息读取失败必须稳定收尾。
static void U4_DetailFailureSettles(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    [app.results addObject:a];
    [app configureDetailForMedia:a];
    table.selectedRow = 0;
    service.fullSnapshots[a.mediaURL] = UPTerminalFull(UPField(RDMetadataTimeout, nil),
                                                       UPField(RDMetadataFailed, nil),
                                                       UPField(RDMetadataFailed, nil),
                                                       UPField(RDMetadataFailed, nil));
    FinishProbe(app, UPResult(@[a]));
    [service publishForMedia:a];
    Check(UPComplete(app), @"U4 详情失败也能结束准备阶段（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"探测完成"], @"U4 完成状态不被单个失败请求拖住");
    Check(![app.durationValue.stringValue containsString:@"获取中"] && ![app.durationValue.stringValue containsString:@"读取中"],
          @"U4 时长显示终态占位而非读取中（实际：%@）", app.durationValue.stringValue);
    Check(![app.sizeValue.stringValue containsString:@"读取中"], @"U4 大小显示终态占位（实际：%@）", app.sizeValue.stringValue);
    Check([app.durationValue.stringValue isEqualToString:@"读取超时"] || [app.durationValue.stringValue isEqualToString:@"—"],
          @"U4 时长为明确的失败/占位文本（实际：%@）", app.durationValue.stringValue);
    RunProgressToEnd(app);
}

// U5：取消后旧回调不得写回；新一轮探测不得继承上一轮的加载状态。
static void U5_CancelAndRestartIsolateGenerations(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    [app.results addObject:a];
    [app configureDetailForMedia:a];
    table.selectedRow = 0;
    service.fullSnapshots[a.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @42.0),
                                                       UPField(RDMetadataKnown, @4096),
                                                       UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    FinishProbe(app, UPResult(@[a]));
    Check(!UPComplete(app), @"U5 准备阶段尚未完成");
    [app cancelScan:nil];
    Check([app.statusNote.stringValue containsString:@"已取消"], @"U5 取消状态明确（实际：%@）", app.statusNote.stringValue);
    // 迟到的缩略图/详情回调不得把结果、缩略图或详情写回界面
    NSImage *imageAtCancel = app.thumbView.image;
    NSString *sizeAtCancel = app.sizeValue.stringValue;
    NSString *linkAtCancel = app.linkField.stringValue;
    service.fullSnapshots[a.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @9999.0),
                                                       UPField(RDMetadataKnown, @88888888),
                                                       UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    [service publishForMedia:a];
    Check(![app.statusNote.stringValue containsString:@"探测完成"], @"U5 取消后迟到回调不得宣布完成");
    Check(app.thumbView.image == imageAtCancel, @"U5 取消后迟到缩略图不得改写界面");
    Check([app.sizeValue.stringValue isEqualToString:sizeAtCancel], @"U5 取消后迟到详情不得改写界面（%@ → %@）",
          sizeAtCancel, app.sizeValue.stringValue);
    Check([app.linkField.stringValue isEqualToString:linkAtCancel], @"U5 取消后迟到回调不得改变直链");
    // 新一轮探测：不得继承上一轮状态
    app.urlField = [NSTextField textFieldWithString:@"https://fixture.invalid/page"];
    app.session = nil;   // scan: 只负责重置状态；会话启动在此无关
    [app scan:nil];
    Check(app.scanning && !UPComplete(app), @"U5 新探测重置统一呈现状态");
    Check(![app.statusNote.stringValue containsString:@"探测完成"], @"U5 新探测不得继承上一轮完成文案（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"网址"] || [app.statusNote.stringValue containsString:@"正在"],
          @"U5 新探测状态文字已设置（实际：%@）", app.statusNote.stringValue);
    [service publishForMedia:a];
    Check(![app.statusNote.stringValue containsString:@"探测完成"], @"U5 旧一轮的迟到回调不影响新一轮");
}

// U6：统一呈现后列表、缩略图、详情与进度一致，且不再继续跳变。
static void U6_CommitIsConsistentAndStable(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    DetectedMedia *b = UPVideo(@"https://fixture.invalid/b.mp4", @"https://fixture.invalid/b.jpg");
    [app.results addObjectsFromArray:@[a, b]];
    [app configureDetailForMedia:a];
    table.selectedRow = 0;
    service.fullSnapshots[a.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @125.0),
                                                       UPField(RDMetadataKnown, @2048),
                                                       UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    service.previewSnapshots[b.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));
    FinishProbe(app, UPResult(@[a, b]));
    Check(!UPComplete(app), @"U6 准备阶段未提交");
    [service publishForMedia:b];   // 先完成非详情行
    Check(!UPComplete(app), @"U6 详情未完成时不提交");
    // 同一个主线程 turn 内完成详情 → 提交：界面各部件必须一次性一致
    [service publishForMedia:a];
    Check(UPComplete(app), @"U6 全部就绪后提交");
    BOOL consistent = [app.statusNote.stringValue containsString:@"探测完成"]
        && app.thumbView.image != nil && app.thumbStatusLabel.hidden
        && [app.sizeValue.stringValue containsString:@"KB"]
        && [app.durationValue.stringValue isEqualToString:@"02:05"];
    Check(consistent, @"U6 状态/列表/缩略图/详情在同一轮更新中一致（状态=%@ 大小=%@ 时长=%@ 缩略图=%@）",
          app.statusNote.stringValue, app.sizeValue.stringValue, app.durationValue.stringValue,
          app.thumbView.image ? @"有" : @"无");
    NSUInteger reloadsAfterCommit = table.reloads;
    NSUInteger thickness = app.thumbStatusLabel.hidden ? 1 : 0;
    Wait(^BOOL { return NO; }, 0.3);
    Check(table.reloads == reloadsAfterCommit && (app.thumbStatusLabel.hidden ? 1 : 0) == thickness,
          @"U6 提交后不再继续刷新列表或缩略图");
    RunProgressToEnd(app);
}

#pragma mark - 二、画质变动刷新

// V1：480p → 720p：直链、大小、下载对象全部对应 720p。
static void V1_TierSwitchRefreshesAllDependentFields(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *master = UPMaster(@"https://fixture.invalid/master.m3u8");
    [app.results addObject:master];
    RDMetadataSnapshot *masterSnapshot = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                        UPField(RDMetadataKnown, @0),
                                                        UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    masterSnapshot.variants = UPTiers(@"https://fixture.invalid/480.m3u8", @"https://fixture.invalid/720.m3u8");
    service.fullSnapshots[master.mediaURL] = masterSnapshot;
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 3),
          @"V1 档位选择器就绪（实际 %@）", app.variantPicker.itemTitles);
    // 480p 详情先到：大小/时长已知
    DetectedMedia *tier480 = app.detailMedia;
    Check([tier480.mediaURL isEqualToString:@"https://fixture.invalid/480.m3u8"], @"V1 初始详情为 480p（实际 %@）", tier480.mediaURL);
    service.fullSnapshots[tier480.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                             UPField(RDMetadataKnown, @72900000),
                                                             UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    [service publishForMedia:tier480];
    Check([app.sizeValue.stringValue containsString:@"MB"], @"V1 480p 大小已显示（实际 %@）", app.sizeValue.stringValue);

    // 用户切到 720p
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    Check([app.linkField.stringValue isEqualToString:@"https://fixture.invalid/720.m3u8"],
          @"V1 切换后直链为 720p（实际 %@）", app.linkField.stringValue);
    Check([app.currentDownloadMedia.mediaURL isEqualToString:@"https://fixture.invalid/720.m3u8"],
          @"V1 切换后下载对象为 720p（实际 %@）", app.currentDownloadMedia.mediaURL);
    Check(![app.sizeValue.stringValue containsString:@"69"] && ![app.sizeValue.stringValue containsString:@"72"],
          @"V1 切换后不得残留 480p 大小（实际 %@）", app.sizeValue.stringValue);
    Check(![app.durationValue.stringValue containsString:@"69"], @"V1 切换后不得残留旧档位数值（实际 %@）", app.durationValue.stringValue);
    // 720p 元数据到达
    service.fullSnapshots[app.currentDownloadMedia.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @601.0),
                                                                              UPField(RDMetadataKnown, @274000000),
                                                                              UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    [service publishForMedia:app.detailMedia];
    Check([app.sizeValue.stringValue containsString:@"261"] || [app.sizeValue.stringValue containsString:@"274"],
          @"V1 切换后大小更新为 720p（实际 %@）", app.sizeValue.stringValue);
    // 下载对象必须与界面当前显示一致
    RDEnqueueSpy *spy = [RDEnqueueSpy new];
    table.selectedRow = 0;   // 真实应用里下载动作来自选中的行
    app.downloadManager = spy;
    app.downloadSettings = [[ResourceDownloadSettings alloc]
        initWithPreferencesStore:[PreferencesStore shared]
                    downloadsURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]
                      desktopURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
    app.table = (NSTableView *)table;   // 保持托管对象
    [app downloadSelected:nil];
    Check([spy.lastURL isEqualToString:@"https://fixture.invalid/720.m3u8"],
          @"V1 下载动作使用 720p 直链（实际 %@）", spy.lastURL);
    Check([spy.lastExpectedLength longLongValue] == 274000000,
          @"V1 入队大小与 720p 一致（实际 %@）", spy.lastExpectedLength);
}

// V2：切换画质时旧档位的迟到回调不得覆盖新档位数据。
static void V2_StaleTierCallbackCannotOverwrite(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *master = UPMaster(@"https://fixture.invalid/master.m3u8");
    [app.results addObject:master];
    RDMetadataSnapshot *masterSnapshot = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                        UPUnknown(), UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    masterSnapshot.variants = UPTiers(@"https://fixture.invalid/480.m3u8", @"https://fixture.invalid/720.m3u8");
    service.fullSnapshots[master.mediaURL] = masterSnapshot;
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 3), @"V2 档位就绪");
    DetectedMedia *tier480 = app.detailMedia;
    service.fullSnapshots[tier480.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                             UPField(RDMetadataKnown, @72900000),
                                                             UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    NSString *urlAfterSwitch = app.linkField.stringValue;
    service.fullSnapshots[app.currentDownloadMedia.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @601.0),
                                                                             UPField(RDMetadataKnown, @274000000),
                                                                             UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    // 旧档位（480p）的订阅此刻才返回：不得覆盖 720p
    [service publishForMedia:tier480];
    Check([app.linkField.stringValue isEqualToString:urlAfterSwitch],
          @"V2 旧档位迟到回调不得改写直链（实际 %@）", app.linkField.stringValue);
    Check([app.detailMedia.mediaURL isEqualToString:@"https://fixture.invalid/720.m3u8"],
          @"V2 旧档位迟到回调不得改写详情对象（实际 %@）", app.detailMedia.mediaURL);
    Check(![app.sizeValue.stringValue containsString:@"69"], @"V2 旧档位迟到回调不得写回大小（实际 %@）", app.sizeValue.stringValue);
    Check([service activeSubscriberCountForKey:tier480.mediaURL] == 0 || ![app.linkField.stringValue containsString:@"480"],
          @"V2 旧档位订阅不再影响当前界面");
}

// V3：新画质缺少大小或缩略图时，不得残留旧画质数值或图片。
static void V3_NewTierWithoutDataShowsStablePlaceholders(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *master = UPMaster(@"https://fixture.invalid/master.m3u8");
    [app.results addObject:master];
    RDMetadataSnapshot *masterSnapshot = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                        UPUnknown(), UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    masterSnapshot.variants = UPTiers(@"https://fixture.invalid/480.m3u8", @"https://fixture.invalid/720.m3u8");
    service.fullSnapshots[master.mediaURL] = masterSnapshot;
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 3), @"V3 档位就绪");
    DetectedMedia *tier480 = app.detailMedia;
    // 480p 的缩略图来自视频首帧（依赖画质 URL），大小已知
    service.fullSnapshots[tier480.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                             UPField(RDMetadataKnown, @72900000),
                                                             UPUnknown(),
                                                             UPFieldSource(RDMetadataKnown, UPImage(), @"local first frame"));
    [service publishForMedia:tier480];
    Check(app.thumbView.image != nil, @"V3 480p 首帧缩略图已显示");
    // 切到 720p：还没有任何数据
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    DetectedMedia *tier720 = app.detailMedia;
    Check([tier720.mediaURL isEqualToString:@"https://fixture.invalid/720.m3u8"], @"V3 已切到 720p");
    Check(app.thumbView.image == nil, @"V3 720p 尚未就绪时不得继续显示 480p 的首帧缩略图");
    Check(!app.thumbStatusLabel.hidden && [app.thumbStatusLabel.stringValue containsString:@"读取中"],
          @"V3 显示稳定的读取中占位（实际：%@/hidden=%d）", app.thumbStatusLabel.stringValue, app.thumbStatusLabel.hidden);
    Check(![app.sizeValue.stringValue containsString:@"69"], @"V3 不得残留 480p 大小（实际 %@）", app.sizeValue.stringValue);
    Check([app.sizeValue.stringValue isEqualToString:@"—"], @"V3 大小显示明确占位（实际 %@）", app.sizeValue.stringValue);
    Check(![app.durationValue.stringValue containsString:@"10:00"], @"V3 不得残留 480p 时长（实际 %@）", app.durationValue.stringValue);
    // 720p 到达后正常呈现
    service.fullSnapshots[tier720.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @120.0),
                                                             UPField(RDMetadataKnown, @2048),
                                                             UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    [service publishForMedia:tier720];
    Check([app.sizeValue.stringValue containsString:@"KB"], @"V3 720p 数据到达后显示自己的大小（实际 %@）", app.sizeValue.stringValue);
    Check(app.thumbView.image != nil && app.thumbStatusLabel.hidden, @"V3 720p 缩略图到达后替换占位");
}

// V3b：同一海报 URL、但预览来自视频首帧（依赖画质）时，切换档位不得继续显示旧档位首帧。
static void V3b_QualityDependentFrameIsNotCarriedAcrossTiers(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *master = UPMaster(@"https://fixture.invalid/master.m3u8");
    master.poster = @"https://fixture.invalid/cover.jpg";   // 两档共享同一张海报 URL
    [app.results addObject:master];
    RDMetadataSnapshot *masterSnapshot = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                        UPUnknown(), UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    masterSnapshot.variants = UPTiers(@"https://fixture.invalid/480.m3u8", @"https://fixture.invalid/720.m3u8");
    service.fullSnapshots[master.mediaURL] = masterSnapshot;
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 3), @"V3b 档位就绪");
    DetectedMedia *tier480 = app.detailMedia;
    Check([tier480.mediaURL isEqualToString:@"https://fixture.invalid/480.m3u8"], @"V3b 初始为 480p");
    // 480p 的海报取失败，回退为“视频首帧”（该预览内容随资源 URL 变化）
    service.fullSnapshots[tier480.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                             UPField(RDMetadataKnown, @72900000),
                                                             UPUnknown(),
                                                             UPFieldSource(RDMetadataKnown, UPImage(), @"local first frame"));
    [service publishForMedia:tier480];
    Check(app.thumbView.image != nil, @"V3b 480p 首帧缩略图已显示");
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    Check([app.detailMedia.mediaURL isEqualToString:@"https://fixture.invalid/720.m3u8"], @"V3b 已切到 720p");
    Check(app.thumbView.image == nil,
          @"V3b 切换档位后不得继续显示上一档位的视频首帧（该预览依赖画质 URL）");
    Check(!app.thumbStatusLabel.hidden && [app.thumbStatusLabel.stringValue containsString:@"读取中"],
          @"V3b 切换后显示稳定的读取中占位（实际：%@）", app.thumbStatusLabel.stringValue);
}

// V4：切换画质后下载动作与界面数据一致（含大小与资源对象）。
static void V4_DownloadMatchesCurrentTier(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    RDEnqueueSpy *spy = [RDEnqueueSpy new];
    table.selectedRow = 0;   // 真实应用里下载动作来自选中的行
    app.downloadManager = spy;
    app.downloadSettings = [[ResourceDownloadSettings alloc]
        initWithPreferencesStore:[PreferencesStore shared]
                    downloadsURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]
                      desktopURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
    DetectedMedia *master = UPMaster(@"https://fixture.invalid/master.m3u8");
    [app.results addObject:master];
    RDMetadataSnapshot *masterSnapshot = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                        UPUnknown(), UPUnknown(), UPField(RDMetadataKnown, UPImage()));
    masterSnapshot.variants = UPTiers(@"https://fixture.invalid/480.m3u8", @"https://fixture.invalid/720.m3u8");
    service.fullSnapshots[master.mediaURL] = masterSnapshot;
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 3), @"V4 档位就绪");
    [app.variantPicker selectItemWithTitle:@"480p"];
    [app selectDeclaredVariant:nil];
    [app downloadSelected:nil];
    Check([spy.lastURL isEqualToString:@"https://fixture.invalid/480.m3u8"], @"V4 480p 下载目标正确（实际 %@）", spy.lastURL);
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    [app downloadSelected:nil];
    Check([spy.lastURL isEqualToString:@"https://fixture.invalid/720.m3u8"], @"V4 切到 720p 后下载目标为 720p（实际 %@）", spy.lastURL);
    Check([spy.lastURL isEqualToString:app.currentDownloadMedia.mediaURL], @"V4 入队对象与详情对象一致");
    Check([spy.lastURL isEqualToString:app.linkField.stringValue], @"V4 入队对象与直链一致");
}


#pragma mark - 生产服务口径：仅缩略图预热的行必须能收尾（真实 RDMetadataService + 替身传输）

// 生产 RDMetadataService 对 previewOnly（首屏缩略图预热）订阅**故意不跑媒体腿**：
// 时长/大小/分辨率按产品约定留到用户真正选中该资源时读取。因此这类快照的
// size 会长期停留在 Loading。统一呈现门若仍按“四项全终态”判定，这类行永远
// 不就绪，只能干等 60s 安全兜底（真实网址实测：hanime1.life 单资源页 67–73s）。
// 本用例用真实服务 + 替身传输忠实复现，要求“缩略图落地即提交”。
@interface UPImageTransport : NSObject <RDMetadataTransporting>
@end
@implementation UPImageTransport
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout
                  completion:(void (^)(RDMetadataResponse *))completion {
    RDMetadataToken *token = [RDMetadataToken new];
    RDMetadataResponse *r = [RDMetadataResponse new];
    NSURL *url = request.URL;
    if ([url.pathExtension.lowercaseString isEqualToString:@"jpg"]) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:4
                                                                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                                                                      isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                                                                     bytesPerRow:0 bitsPerPixel:0];
        r.data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        r.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
                                               headerFields:@{ @"Content-Type": @"image/jpeg" }];
    } else {
        r.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) completion(r); });
    return token;
}
@end

static void U7_PreviewOnlyRowsMustNotStallPresentation(void) {
    UPStubService *unused; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&unused, &table);
    app.metadataService = [[RDMetadataService alloc] initWithTransport:[UPImageTransport new]];
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    [app.results addObject:a];

    double t0 = [NSDate date].timeIntervalSince1970;
    FinishProbe(app, UPResult(@[a]));
    Check(!UPComplete(app), @"U7 缩略图尚未落地时不得先宣布完成（实际：%@）", app.statusNote.stringValue);
    BOOL committed = Wait(^BOOL { return UPComplete(app); }, 8.0);
    double elapsed = [NSDate date].timeIntervalSince1970 - t0;
    Check(committed, @"U7 首屏缩略图落地后应立即提交统一呈现（实际 %.1fs 仍未提交，状态：%@）",
          elapsed, app.statusNote.stringValue);
    Check(elapsed < 8.0, @"U7 提交耗时必须远小于 60s 安全兜底（实际 %.1fs）", elapsed);
    Check([app.statusNote.stringValue containsString:@"探测完成"], @"U7 提交后状态文字为探测完成（实际：%@）", app.statusNote.stringValue);
}


// V5：用户为某行选定画质档位后，左侧列表行摘要必须跟随该档位——不得再显示
// 发现时那个档位的大小（真实网址验收发现：详情 100.6 MB、列表仍写 30.4 MB，
// 与实际下载到 100.6 MB 互相矛盾）。断言走 App 真实传参路径（行视图拿到的
// sizeHint）并用真实行视图渲染出用户可见文本。
static void V5_RowSummaryFollowsSelectedTier(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *row = UPVideo(@"https://fixture.invalid/480.mp4", @"https://fixture.invalid/p.jpg");
    row.sizeBytes = 72900000;                    // 发现时（480p）算出来的大小
    // 生产里 declaredVariants 一律由 RDQualityTier 生成、必带 label；这里照此构造。
    NSArray *tiers = @[ @{ @"url": @"https://fixture.invalid/480.mp4", @"label": @"480p",
                           @"level": @480, @"pixelWidth": @854, @"pixelHeight": @480 },
                        @{ @"url": @"https://fixture.invalid/720.mp4", @"label": @"720p",
                           @"level": @720, @"pixelWidth": @1280, @"pixelHeight": @720 } ];
    row.declaredVariants = tiers;
    [app.results addObject:row];
    table.selectedRow = 0;

    RDMetadataSnapshot *rowSnapshot = UPTerminalFull(UPField(RDMetadataKnown, @600.0),
                                                     UPField(RDMetadataKnown, @72900000),
                                                     UPField(RDMetadataKnown, [NSValue valueWithSize:NSMakeSize(854, 480)]),
                                                     UPField(RDMetadataKnown, UPImage()));
    rowSnapshot.variants = tiers;
    service.fullSnapshots[row.mediaURL] = rowSnapshot;
    [app configureDetailForMedia:row];
    [service publishForMedia:row];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 3), @"V5 档位就绪");
    Check(table.lastRow.sizeHint == nil,
          @"V5 未选档位时不给行视图加大小提示（按发现时大小展示，实际 %@）", table.lastRow.sizeHint);

    // 用户切到 720p：详情与列表行都必须变成 720p 的大小。
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    DetectedMedia *tier = app.detailMedia;
    service.fullSnapshots[tier.mediaURL] = UPTerminalFull(UPField(RDMetadataKnown, @601.0),
                                                          UPField(RDMetadataKnown, @274000000),
                                                          UPField(RDMetadataKnown, [NSValue valueWithSize:NSMakeSize(1280, 720)]),
                                                          UPField(RDMetadataKnown, UPImage()));
    [service publishForMedia:tier];
    Check(Wait(^BOOL { return [app.sizeValue.stringValue containsString:@"274"]; }, 3),
          @"V5 详情大小已更新为 720p（实际 %@）", app.sizeValue.stringValue);

    Check([table.lastRow.sizeHint containsString:@"274"],
          @"V5 App 把当前档位大小传给行视图（实际 %@）", table.lastRow.sizeHint);
    ResourceResultRowView *rendered = [[ResourceResultRowView alloc] initWithFrame:NSMakeRect(0, 0, 420, 44)];
    [rendered configureWithMedia:row durationHint:table.lastRow.durationHint sizeHint:table.lastRow.sizeHint];
    NSString *rowText = [[rendered valueForKey:@"detailField"] stringValue];
    Check(![rowText containsString:@"72"],
          @"V5 列表行摘要不得再显示 480p 的大小（实际 %@）", rowText);
    Check([rowText containsString:@"274"],
          @"V5 列表行摘要跟随当前档位大小（实际 %@）", rowText);
}


#pragma mark - 生产服务口径：提交前必须等齐「每一条可见行」的缩略图

// 统一呈现的契约是：宣布「探测完成」时，列表里用户第一眼看到的那些行缩略图
// 必须都已有结论（有图 / 明确失败），不得先宣布完成再让缩略图逐张跳出。
// 本用例用真实 RDMetadataService + 会「扣住」某张海报的替身传输验证该契约。
@interface UPHoldingTransport : NSObject <RDMetadataTransporting>
@property (nonatomic, strong) NSMutableArray *held;   // 被扣住的 completion 块
@property (nonatomic, copy) NSString *holdName;       // 文件名含该串则暂不放行
@end
@implementation UPHoldingTransport
- (instancetype)init { if ((self = [super init])) _held = [NSMutableArray array]; return self; }
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout
                  completion:(void (^)(RDMetadataResponse *))completion {
    RDMetadataToken *token = [RDMetadataToken new];
    RDMetadataResponse *r = [RDMetadataResponse new];
    NSURL *url = request.URL;
    if ([url.pathExtension.lowercaseString isEqualToString:@"jpg"]) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:4
                                                                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                                                                      isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                                                                     bytesPerRow:0 bitsPerPixel:0];
        r.data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        r.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
                                               headerFields:@{ @"Content-Type": @"image/jpeg" }];
    } else {
        r.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil];
    }
    if (self.holdName.length && [url.lastPathComponent containsString:self.holdName]) {
        [self.held addObject:^{ if (!token.cancelled) completion(r); }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) completion(r); });
    }
    return token;
}
- (void)releaseHeld {
    NSArray *blocks = [self.held copy];
    [self.held removeAllObjects];
    for (void (^fire)(void) in blocks) fire();
}
@end

static void U8_MustNotCommitWhileAnyVisibleThumbnailIsLoading(void) {
    UPStubService *unused; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&unused, &table);
    UPHoldingTransport *transport = [UPHoldingTransport new];
    transport.holdName = @"b.jpg";      // b 的海报被扣住，a 正常返回
    app.metadataService = [[RDMetadataService alloc] initWithTransport:transport];
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    DetectedMedia *b = UPVideo(@"https://fixture.invalid/b.mp4", @"https://fixture.invalid/b.jpg");
    [app.results addObjectsFromArray:@[a, b]];
    FinishProbe(app, UPResult(@[a, b]));

    // 给 a 的缩略图足够时间落地；b 仍被扣住 → 不得宣布完成。
    Wait(^BOOL { return NO; }, 1.5);
    Check(!UPComplete(app), @"U8 任一可见行缩略图未落地时不得宣布完成（实际：%@）", app.statusNote.stringValue);

    [transport releaseHeld];
    Check(Wait(^BOOL { return UPComplete(app); }, 5.0),
          @"U8 末个缩略图落地后必须提交统一呈现（实际：%@）", app.statusNote.stringValue);
}

// V6：档位字典缺 label 时不得把 nil 交给 NSMenuItem（会抛 NSInvalidArgumentException
// 直接崩溃），也绝不因此丢掉这个档位（用户会白白少一个可下载档位）。
static void V6_VariantWithoutLabelMustNotCrash(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *row = UPVideo(@"https://fixture.invalid/x-480.mp4", @"https://fixture.invalid/p.jpg");
    row.declaredVariants = @[ @{ @"url": @"https://fixture.invalid/x-480.mp4", @"level": @480,
                                 @"pixelWidth": @854, @"pixelHeight": @480 },
                              @{ @"url": @"https://fixture.invalid/x-720.mp4", @"level": @720,
                                 @"pixelWidth": @1280, @"pixelHeight": @720 } ];
    [app.results addObject:row];
    NSException *thrown = nil;
    @try { [app configureDetailForMedia:row]; }
    @catch (NSException *e) { thrown = e; }
    Check(thrown == nil, @"V6 档位缺 label 时不得抛异常（实际 %@：%@）", thrown.name, thrown.reason);
    Check(app.variantPicker.numberOfItems == 2,
          @"V6 缺 label 的档位仍须保留在下拉里（实际 %lu 项）", (unsigned long)app.variantPicker.numberOfItems);
}


// U9：准备阶段必须由“已就绪必需项”驱动状态文字——未就绪时停在进行中文案，
// 全部就绪后才提交为“探测完成”（探测进度条已删除，改由 statusNote 表达）。
static void U9_PrepProgressIsDrivenByRequirements(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    DetectedMedia *b = UPVideo(@"https://fixture.invalid/b.mp4", @"https://fixture.invalid/b.jpg");
    [app.results addObjectsFromArray:@[a, b]];
    service.previewSnapshots[a.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));
    service.previewSnapshots[b.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));

    FinishProbe(app, UPResult(@[a, b]));
    Check(!UPComplete(app), @"U9 必需项未就绪不得宣布完成（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"正在准备呈现"] || [app.statusNote.stringValue containsString:@"正在整理"],
          @"U9 必需项未就绪时显示进行中状态文字（实际：%@）", app.statusNote.stringValue);

    [service publishForMedia:a];
    Check(!UPComplete(app), @"U9 仅部分必需项就绪时仍不得宣布完成（实际：%@）", app.statusNote.stringValue);

    [service publishForMedia:b];
    Check(UPComplete(app), @"U9 全部就绪后提交（实际：%@）", app.statusNote.stringValue);
    Check([app.statusNote.stringValue containsString:@"探测完成"], @"U9 提交后状态文字为探测完成（实际：%@）", app.statusNote.stringValue);
}

// U10：有画质档位声明的视频行，必须把**每一档**的完整元数据（时长/大小/分辨率）
// 都探索清楚，统一呈现才允许提交——产品要求“3 档画质之间的数据全部探索清楚，
// 探索进度条才能完成”。
static void U10_AllDeclaredTiersMustBeExploredBeforeCompletion(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    app.explorationResultsSuppressed = YES;   // 模拟 scan: 进入新一轮时的状态
    DetectedMedia *row = UPVideo(@"https://fixture.invalid/480.mp4", @"https://fixture.invalid/p.jpg");
    row.declaredVariants = @[ @{ @"url": @"https://fixture.invalid/480.mp4", @"label": @"480p",
                                 @"level": @480, @"pixelWidth": @854, @"pixelHeight": @480 },
                              @{ @"url": @"https://fixture.invalid/720.mp4", @"label": @"720p",
                                 @"level": @720, @"pixelWidth": @1280, @"pixelHeight": @720 } ];
    [app.results addObject:row];
    NSTableView *tableProbe = [NSTableView new];

    FinishProbe(app, UPResult(@[row]));
    Check(service.fullSubscriptions == 2,
          @"U10 两个声明档位都必须走完整元数据通道（full=%lu preview=%lu）",
          (unsigned long)service.fullSubscriptions, (unsigned long)service.previewSubscriptions);
    Check(!UPComplete(app), @"U10 档位未全部探索清楚时不得宣布完成（实际：%@）", app.statusNote.stringValue);
    Check([app numberOfRowsInTableView:tableProbe] == 0, @"U10 探索期间列表不得呈现行");

    service.fullSnapshots[@"https://fixture.invalid/480.mp4"] =
        UPTerminalFull(UPField(RDMetadataKnown, @600.0), UPField(RDMetadataKnown, @30400462),
                       UPField(RDMetadataKnown, [NSValue valueWithSize:NSMakeSize(854, 480)]),
                       UPField(RDMetadataKnown, UPImage()));
    [service publishForKey:@"https://fixture.invalid/480.mp4"];
    Check(!UPComplete(app), @"U10 只探索清楚 480p 时不得宣布完成（实际：%@）", app.statusNote.stringValue);

    service.fullSnapshots[@"https://fixture.invalid/720.mp4"] =
        UPTerminalFull(UPField(RDMetadataKnown, @601.0), UPField(RDMetadataKnown, @51156307),
                       UPField(RDMetadataKnown, [NSValue valueWithSize:NSMakeSize(1280, 720)]),
                       UPField(RDMetadataKnown, UPImage()));
    [service publishForKey:@"https://fixture.invalid/720.mp4"];
    Check(UPComplete(app), @"U10 全部档位探索清楚后提交（实际：%@）", app.statusNote.stringValue);
}

// V7：严格统一呈现——探索未完成前列表不得呈现任何行；探索完成时与状态/进度
// 一次性出现（修复「进度条还没加载完，内容就直接冒出来」）。
static void V7_ResultsHiddenUntilExplorationCompletes(void) {
    UPStubService *service; UPTable *table;
    ResourceDetectorAppDelegate *app = MakeHeadlessApp(&service, &table);
    app.explorationResultsSuppressed = YES;   // 模拟 scan: 进入新一轮时的状态
    DetectedMedia *a = UPVideo(@"https://fixture.invalid/a.mp4", @"https://fixture.invalid/a.jpg");
    DetectedMedia *b = UPVideo(@"https://fixture.invalid/b.mp4", @"https://fixture.invalid/b.jpg");
    [app.results addObjectsFromArray:@[a, b]];
    NSTableView *tableProbe = [NSTableView new];
    service.previewSnapshots[a.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));
    service.previewSnapshots[b.mediaURL] = UPTerminalPreview(UPField(RDMetadataKnown, UPImage()));

    FinishProbe(app, UPResult(@[a, b]));
    Check(app.explorationResultsSuppressed, @"V7 探索期间内容必须被抑制");
    Check([app numberOfRowsInTableView:tableProbe] == 0,
          @"V7 探索期间列表不得呈现任何行（实际 %ld）", (long)[app numberOfRowsInTableView:tableProbe]);

    [service publishForMedia:a];
    Check([app numberOfRowsInTableView:tableProbe] == 0, @"V7 部分就绪时仍不得呈现");

    [service publishForMedia:b];
    Check(UPComplete(app), @"V7 全部就绪后提交（实际：%@）", app.statusNote.stringValue);
    Check(!app.explorationResultsSuppressed, @"V7 提交后解除抑制");
    Check([app numberOfRowsInTableView:tableProbe] == 2,
          @"V7 提交时列表一次性呈现全部行（实际 %ld / 应 2）", (long)[app numberOfRowsInTableView:tableProbe]);
}

int main(void) { @autoreleasepool {
    U1_CompletionWaitsForListThumbnails();
    U2_CompletionWaitsForDetailMetadata();
    U3_ThumbnailFailureSettles();
    U4_DetailFailureSettles();
    U5_CancelAndRestartIsolateGenerations();
    U6_CommitIsConsistentAndStable();
    V1_TierSwitchRefreshesAllDependentFields();
    V2_StaleTierCallbackCannotOverwrite();
    V3_NewTierWithoutDataShowsStablePlaceholders();
    V3b_QualityDependentFrameIsNotCarriedAcrossTiers();
    V4_DownloadMatchesCurrentTier();
    U7_PreviewOnlyRowsMustNotStallPresentation();
    V5_RowSummaryFollowsSelectedTier();
    U8_MustNotCommitWhileAnyVisibleThumbnailIsLoading();
    V6_VariantWithoutLabelMustNotCrash();
    U9_PrepProgressIsDrivenByRequirements();
    U10_AllDeclaredTiersMustBeExploredBeforeCompletion();
    V7_ResultsHiddenUntilExplorationCompletes();
    CheckSummary();
} return 0; }
