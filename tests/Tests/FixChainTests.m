//
//  FixChainTests.m — FIX-A / FIX-B 生产调用链专项验收
//
//  只替换外部网络（元数据 transport 层的快照投递）与下载后端（入队记录），
//  App 的详情配置、元数据订阅回调、变体选择、visibleMedia、downloadSelected:
//  全部走真实生产代码。断言的是真实 enqueue 参数与行数，不是辅助函数。
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "WebProbe.h"
#import "RDManifestParser.h"

// 收集全部失败后统一汇总退出：断言不因前序失败被跳过，修复前基线可以一次
// 跑完全部场景，完整列出失败清单与真实对照输出。
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
    NSLog(@"PASS: ALL FIX-CHAIN TESTS");
}
static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}

#pragma mark - 受控替身（只替换网络投递与下载后端）

// 元数据服务替身：按 mediaURL 投递预置快照。真实 RDMetadataService/transport
// 负责网络；这里只控制“哪个快照、何时到达”，App 回调逻辑保持生产原样。
// 取消语义与生产一致：token 已取消时投递被丢弃。
@interface RDChainMetadataService : RDMetadataService
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDMetadataSnapshot *> *snapshots;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDMetadataToken *> *tokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(RDMetadataSnapshot *)> *updates;
@property (nonatomic, assign) NSUInteger publishCount;
@end
@implementation RDChainMetadataService
- (instancetype)init {
    if ((self = [super init])) {
        _snapshots = [NSMutableDictionary dictionary];
        _tokens = [NSMutableDictionary dictionary];
        _updates = [NSMutableDictionary dictionary];
    }
    return self;
}
- (RDMetadataToken *)subscribeMedia:(DetectedMedia *)media reload:(BOOL)reload update:(void (^)(RDMetadataSnapshot *))update {
    RDMetadataToken *token = [RDMetadataToken new];
    NSString *key = media.mediaURL ?: @"";
    self.tokens[key] = token;
    self.updates[key] = update;
    RDMetadataSnapshot *snapshot = self.snapshots[key];
    if (snapshot) dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) update(snapshot); });
    return token;
}
- (void)prioritizeMedia:(DetectedMedia *)media {}
- (void)publishSnapshotForMedia:(DetectedMedia *)media {
    NSString *key = media.mediaURL ?: @"";
    void (^update)(RDMetadataSnapshot *) = self.updates[key];
    RDMetadataToken *token = self.tokens[key];
    RDMetadataSnapshot *snapshot = self.snapshots[key];
    if (!update || !snapshot || token.cancelled) return;
    self.publishCount++;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) update(snapshot); });
}
@end

// 下载管理器替身：只记录真实 downloadSelected: 传进来的 enqueue 参数与返回任务。
@interface RDEnqueueSpyManager : DownloadManager
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *enqueued;
@end
@implementation RDEnqueueSpyManager
- (DownloadJob *)enqueueItemWithSourceURL:(NSURL *)url folder:(NSURL *)folder preferredName:(NSString *)name sourcePageURL:(NSString *)sourcePageURL resourceKind:(DownloadResourceKind)kind expectedLength:(int64_t)length {
    if (!self.enqueued) self.enqueued = [NSMutableArray array];
    DownloadJob *job = [DownloadJob new];
    job.sourceURL = url;
    job.fileName = name;
    job.resourceKind = kind;
    job.sourcePageURL = sourcePageURL;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"url"] = url.absoluteString ?: @"";
    record[@"kind"] = @(kind);
    record[@"expectedLength"] = @(length);
    record[@"job"] = job;
    [self.enqueued addObject:record];
    return job;
}
@end

@interface RDChainRow : NSObject
@property NSUInteger updates;
@end
@implementation RDChainRow
- (BOOL)isKindOfClass:(Class)cls { return cls == ResourceResultRowView.class || [super isKindOfClass:cls]; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint { self.updates++; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint sizeHint:(NSString *)sizeHint { self.updates++; }
@end
@interface RDChainTable : NSObject
@property RDChainRow *row;
@property NSUInteger reloads;
@property NSInteger selectedRow;
@property NSInteger restoredSelections;
@end
@implementation RDChainTable
- (id)viewAtColumn:(NSInteger)c row:(NSInteger)r makeIfNecessary:(BOOL)make { return self.row; }
- (void)reloadData { self.reloads++; }
- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend {
    self.restoredSelections++;
    self.selectedRow = (NSInteger)indexes.firstIndex;
}
@end

#pragma mark - 夹具

static RDMetadataField *UnknownField(void) {
    RDMetadataField *f = [RDMetadataField new];
    f.state = RDMetadataUnknown; f.source = @"";
    return f;
}
static RDMetadataSnapshot *VariantSnapshot(NSArray *variants) {
    RDMetadataSnapshot *s = [RDMetadataSnapshot new];
    s.variants = variants;
    s.duration = UnknownField(); s.dimensions = UnknownField();
    s.size = UnknownField(); s.preview = UnknownField();
    return s;
}
static RDMetadataSnapshot *KnownSizeSnapshot(long long bytes) {
    RDMetadataSnapshot *s = [RDMetadataSnapshot new];
    RDMetadataField *size = [RDMetadataField new];
    size.state = RDMetadataKnown; size.value = @(bytes); size.source = @"moov";
    s.variants = @[];
    s.duration = UnknownField(); s.dimensions = UnknownField();
    s.size = size; s.preview = UnknownField();
    return s;
}
static DetectedMedia *MasterMedia(NSString *url) {
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = url;
    m.resourceKind = RDResourceKindManifest;
    m.isManifest = YES;
    m.format = @"hls";
    m.title = @"示例视频";
    return m;
}

static ResourceDetectorAppDelegate *MakeChainApp(RDChainMetadataService **outService,
                                                 RDEnqueueSpyManager **outSpy,
                                                 RDChainTable **outTable) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDChainMetadataService *service = [RDChainMetadataService new];
    RDEnqueueSpyManager *spy = [RDEnqueueSpyManager new];
    RDChainTable *table = [RDChainTable new];
    table.row = [RDChainRow new];
    table.selectedRow = 0;
    app.metadataService = service;
    app.downloadManager = spy;
    app.downloadSettings = [[ResourceDownloadSettings alloc]
        initWithPreferencesStore:[PreferencesStore shared]
                    downloadsURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]
                      desktopURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
    app.durationCache = [NSMutableDictionary dictionary];
    app.results = [NSMutableArray array];
    app.table = (NSTableView *)table;
    app.downloadsPage = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 438)];
    app.downloadsPage.hidden = NO;
    app.downloadsTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 760, 360)];
    app.downloadsTable.dataSource = (id)app;
    app.downloadsTable.delegate = (id)app;
    app.downloadsTable.rowHeight = 72;
    NSTableColumn *downloadColumn = [[NSTableColumn alloc] initWithIdentifier:@"download"];
    [app.downloadsTable addTableColumn:downloadColumn];
    app.downloadsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 760, 360)];
    app.downloadsScrollView.documentView = app.downloadsTable;
    app.downloadsEmptyLabel = [NSTextField labelWithString:@""];
    app.variantPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 20) pullsDown:NO];
    app.linkField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    if (outService) *outService = service;
    if (outSpy) *outSpy = spy;
    if (outTable) *outTable = table;
    return app;
}

static NSArray *MasterTiers(NSString *tier480, NSString *tier720) {
    return @[
        @{ @"url": tier480, @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": tier720, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ];
}

#pragma mark - FIX-A

// A1：初次 HLS master 到达。结果列表只有 master；快照返回 480p/720p 两个
// 真实子清单；不手动切换，直接 downloadSelected:。显示的具体档位与实际
// 入队目标必须一致（修复前：显示 480p、入队 master.m3u8）。
static void FixA1_InitialMasterMustDownloadSelectedTier(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *master = MasterMedia(@"https://example.invalid/master.m3u8");
    [app.results addObject:master];
    service.snapshots[master.mediaURL] = VariantSnapshot(MasterTiers(@"https://example.invalid/480.m3u8",
                                                                     @"https://example.invalid/720.m3u8"));
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL {
        return [app.variantPicker.itemTitles containsObject:@"480p"] && app.detailMedia != master;
    }, 5), @"A1 快照到达后详情自动同步为具体档位（未手动切换）");
    NSString *label = app.variantPicker.selectedItem.title;
    NSString *pickerURL = app.variantPicker.selectedItem.representedObject[@"url"];
    NSString *detailURL = app.detailMedia.mediaURL;
    NSString *linkURL = app.linkField.stringValue;
    Check([label isEqualToString:@"480p"], @"A1 界面显示 480p");
    Check([pickerURL isEqualToString:@"https://example.invalid/480.m3u8"], @"A1 选择器当前项对应 480.m3u8");
    Check([detailURL isEqualToString:@"https://example.invalid/480.m3u8"], @"A1 详情当前媒体为 480.m3u8");
    Check([linkURL isEqualToString:@"https://example.invalid/480.m3u8"], @"A1 复制链接目标为 480.m3u8");
    [app downloadSelected:nil];
    Check(spy.enqueued.count == 1, @"A1 恰好入队一个下载任务");
    NSString *downloadURL = spy.enqueued.lastObject[@"url"];
    DownloadJob *job = spy.enqueued.lastObject[@"job"];
    DownloadResourceKind kind = (DownloadResourceKind)[spy.enqueued.lastObject[@"kind"] integerValue];
    NSLog(@"FIX-A A1: SELECTED_LABEL=%@ PICKER_URL=%@ DETAIL_URL=%@ LINK_URL=%@ DOWNLOAD_URL=%@ KIND=%ld",
          label, pickerURL, detailURL, linkURL, downloadURL, (long)kind);
    Check([downloadURL isEqualToString:@"https://example.invalid/480.m3u8"],
          @"A1 实际入队目标与显示档位一致（不得是 master.m3u8）");
    Check(kind == DownloadResourceManifest, @"A1 HLS 变体按清单类型入队");
    Check([job.streamMasterURL isEqualToString:master.mediaURL], @"A1 下载计划保留来源主清单（分离音轨上下文）");
}

// A2：用户主动切换到 720p 后下载，目标必须是 720p。
static void FixA2_UserSwitchDownloadsChosenTier(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *master = MasterMedia(@"https://example.invalid/master.m3u8");
    [app.results addObject:master];
    service.snapshots[master.mediaURL] = VariantSnapshot(MasterTiers(@"https://example.invalid/480.m3u8",
                                                                     @"https://example.invalid/720.m3u8"));
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 5),
          @"A2 两个档位选项就绪");
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    Check([app.detailMedia.mediaURL isEqualToString:@"https://example.invalid/720.m3u8"], @"A2 切换后详情为 720.m3u8");
    Check([[app.variantPicker.selectedItem.representedObject objectForKey:@"url"] isEqualToString:@"https://example.invalid/720.m3u8"],
          @"A2 选择器当前项为 720.m3u8");
    [app downloadSelected:nil];
    NSString *downloadURL = spy.enqueued.lastObject[@"url"];
    NSLog(@"FIX-A A2: LABEL=%@ DOWNLOAD_URL=%@", app.variantPicker.selectedItem.title, downloadURL);
    Check([downloadURL isEqualToString:@"https://example.invalid/720.m3u8"], @"A2 入队目标为 720.m3u8");
}

// A3：用户已选 720p 后，后台快照追加 1080p。选择与下载对象不得被切回默认档。
static void FixA3_BackgroundUpdateKeepsUserSelection(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *master = MasterMedia(@"https://example.invalid/master.m3u8");
    [app.results addObject:master];
    service.snapshots[master.mediaURL] = VariantSnapshot(MasterTiers(@"https://example.invalid/480.m3u8",
                                                                     @"https://example.invalid/720.m3u8"));
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 5),
          @"A3 初始同步完成");
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    DetectedMedia *selected = app.detailMedia;
    Check([selected.mediaURL isEqualToString:@"https://example.invalid/720.m3u8"], @"A3 用户选中 720p");
    // 后台快照：新增 1080p，720p 仍存在
    DetectedMedia *detailNow = app.detailMedia;
    service.snapshots[detailNow.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://example.invalid/480.m3u8", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": @"https://example.invalid/720.m3u8", @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
        @{ @"url": @"https://example.invalid/1080.m3u8", @"bandwidth": @8000000, @"width": @1920, @"height": @1080 },
    ]);
    NSUInteger before = spy.enqueued.count;
    [service publishSnapshotForMedia:detailNow];
    Check(Wait(^BOOL { return app.variantPicker.itemTitles.count == 3; }, 5), @"A3 新档位进入选择器");
    Check(app.detailMedia == selected, @"A3 详情对象未因后台更新切换");
    Check([[app.variantPicker.selectedItem.representedObject objectForKey:@"url"] isEqualToString:@"https://example.invalid/720.m3u8"],
          @"A3 选择保持 720p");
    [app downloadSelected:nil];
    NSString *downloadURL = spy.enqueued.count > before ? spy.enqueued.lastObject[@"url"] : @"";
    NSLog(@"FIX-A A3: LABEL=%@ DOWNLOAD_URL=%@", app.variantPicker.selectedItem.title, downloadURL);
    Check([downloadURL isEqualToString:@"https://example.invalid/720.m3u8"], @"A3 后台更新后下载对象仍是 720.m3u8");
}

// A4：当前档位被同档更高带宽的新 URL 择优替换（RDQualityTier 生产规则）。
// 选择必须跟随同档新 URL，详情、链接与入队目标一致，旧 URL 无残留。
static void FixA4_SameTierReplacementStaysInTier(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *master = MasterMedia(@"https://example.invalid/master.m3u8");
    [app.results addObject:master];
    service.snapshots[master.mediaURL] = VariantSnapshot(MasterTiers(@"https://example.invalid/480.m3u8",
                                                                     @"https://example.invalid/720.m3u8"));
    [app configureDetailForMedia:master];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 5), @"A4 初始档位就绪");
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    DetectedMedia *detailNow = app.detailMedia;
    Check([detailNow.mediaURL isEqualToString:@"https://example.invalid/720.m3u8"], @"A4 选中 720p");
    // 后台快照：720p 被更高带宽的同档新 URL 替换（带宽更高者优先胜出）
    service.snapshots[detailNow.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://example.invalid/480.m3u8", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": @"https://example.invalid/720-new.m3u8", @"bandwidth": @6000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:detailNow];
    Check(Wait(^BOOL {
        return [app.detailMedia.mediaURL isEqualToString:@"https://example.invalid/720-new.m3u8"];
    }, 5), @"A4 同档替换后详情同步到新 URL");
    NSString *pickerURL = app.variantPicker.selectedItem.representedObject[@"url"];
    NSString *linkURL = app.linkField.stringValue;
    NSLog(@"FIX-A A4: LABEL=%@ PICKER_URL=%@ DETAIL_URL=%@ LINK_URL=%@",
          app.variantPicker.selectedItem.title, pickerURL, app.detailMedia.mediaURL, linkURL);
    Check([app.variantPicker.selectedItem.title isEqualToString:@"720p"], @"A4 标签保持同档 720p");
    Check([pickerURL isEqualToString:@"https://example.invalid/720-new.m3u8"], @"A4 选择器对应新 URL");
    Check([linkURL isEqualToString:@"https://example.invalid/720-new.m3u8"], @"A4 链接对应新 URL");
    [app downloadSelected:nil];
    NSString *downloadURL = spy.enqueued.lastObject[@"url"];
    Check([downloadURL isEqualToString:@"https://example.invalid/720-new.m3u8"], @"A4 入队目标为新 URL");
    Check(![downloadURL isEqualToString:@"https://example.invalid/720.m3u8"], @"A4 旧链接无残留");
}

// A5：媒体类型与上下文。MP4 候选不得被改成 HLS；DASH Representation 保持
// DASH 下载上下文；HLS 具体档位保留来源主清单（分离音轨）关联。
static void FixA5_MediaTypesAndContexts(void) {
    // 5a. MP4：同档更高带宽替换后合成的具体档位仍是视频文件
    {
        RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
        ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
        DetectedMedia *low = [DetectedMedia new];
        low.mediaURL = @"https://offline.invalid/q-480.mp4"; low.format = @"mp4";
        low.resourceKind = RDResourceKindVideo; low.title = @"同标题";
        DetectedMedia *high = [DetectedMedia new];
        high.mediaURL = @"https://offline.invalid/q-720.mp4"; high.format = @"mp4";
        high.resourceKind = RDResourceKindVideo; high.title = @"同标题";
        NSString *family = [NSUUID UUID].UUIDString;
        low.videoFamilyID = family; high.videoFamilyID = family;
        NSArray *declared = @[
            @{ @"url": low.mediaURL, @"label": @"480p", @"level": @480 },
            @{ @"url": high.mediaURL, @"label": @"720p", @"level": @720 },
        ];
        low.declaredVariants = declared; high.declaredVariants = declared;
        [app.results addObjectsFromArray:@[low, high]];
        [app configureDetailForMedia:low];
        // 快照把 480p 替换为新的更高带宽 mp4 候选（不在 results 中 → 合成对象）
        service.snapshots[low.mediaURL] = VariantSnapshot(@[
            @{ @"url": @"https://offline.invalid/q-480-new.mp4", @"bandwidth": @1200000, @"width": @854, @"height": @480 },
            @{ @"url": high.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
        ]);
        [service publishSnapshotForMedia:low];
        Check(Wait(^BOOL { return [app.detailMedia.mediaURL isEqualToString:@"https://offline.invalid/q-480-new.mp4"]; }, 5),
              @"A5-MP4 同档替换后详情指向新 mp4 候选");
        DetectedMedia *synthetic = app.detailMedia;
        Check(synthetic.resourceKind == RDResourceKindVideo, @"A5-MP4 合成候选保持视频类型");
        Check(!synthetic.isManifest, @"A5-MP4 合成候选不是清单");
        Check([synthetic.format isEqualToString:@"mp4"], @"A5-MP4 格式保持 mp4（不得伪装 hls）");
        [app downloadSelected:nil];
        DownloadJob *job = spy.enqueued.lastObject[@"job"];
        DownloadResourceKind kind = (DownloadResourceKind)[spy.enqueued.lastObject[@"kind"] integerValue];
        NSLog(@"FIX-A A5-MP4: DOWNLOAD_URL=%@ KIND=%ld", spy.enqueued.lastObject[@"url"], (long)kind);
        Check(kind == DownloadResourceVideo, @"A5-MP4 按视频文件入队");
        Check(job.streamMasterURL == nil, @"A5-MP4 不携带主清单关联");
    }
    // 5b. DASH Representation：保持 DASH 上下文，不按 HLS 处理
    {
        RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
        ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
        DetectedMedia *mpd = [DetectedMedia new];
        mpd.mediaURL = @"https://example.invalid/manifest.mpd";
        mpd.resourceKind = RDResourceKindManifest; mpd.isManifest = YES; mpd.format = @"dash";
        [app.results addObject:mpd];
        service.snapshots[mpd.mediaURL] = VariantSnapshot(@[
            @{ @"url": @"https://example.invalid/manifest-480.mpd", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        ]);
        [app configureDetailForMedia:mpd];
        Check(Wait(^BOOL { return [app.detailMedia.mediaURL isEqualToString:@"https://example.invalid/manifest-480.mpd"]; }, 5),
              @"A5-DASH 详情同步到具体 Representation");
        DetectedMedia *synthetic = app.detailMedia;
        Check(synthetic.resourceKind == RDResourceKindManifest, @"A5-DASH 保持清单类型");
        Check([synthetic.format isEqualToString:@"dash"], @"A5-DASH 保持 dash 格式（不得按 hls 处理）");
        [app downloadSelected:nil];
        DownloadResourceKind kind = (DownloadResourceKind)[spy.enqueued.lastObject[@"kind"] integerValue];
        NSLog(@"FIX-A A5-DASH: DOWNLOAD_URL=%@ KIND=%ld", spy.enqueued.lastObject[@"url"], (long)kind);
        Check(kind == DownloadResourceManifest, @"A5-DASH 按清单类型入队");
    }
    // 5c. HLS 分离音频：具体档位入队时必须保留来源主清单关联
    {
        RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
        ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
        DetectedMedia *master = MasterMedia(@"https://example.invalid/master.m3u8");
        [app.results addObject:master];
        service.snapshots[master.mediaURL] = VariantSnapshot(MasterTiers(@"https://example.invalid/480.m3u8",
                                                                         @"https://example.invalid/720.m3u8"));
        [app configureDetailForMedia:master];
        Check(Wait(^BOOL { return [app.detailMedia.mediaURL isEqualToString:@"https://example.invalid/480.m3u8"]; }, 5),
              @"A5-HLS 同步到具体档位");
        [app downloadSelected:nil];
        DetectedMedia *synthetic = app.detailMedia;
        Check([synthetic.parentMediaURL isEqualToString:@"https://example.invalid/master.m3u8"],
              @"A5-HLS 合成档位保留主清单关联（分离音轨上下文）");
        DownloadJob *job = spy.enqueued.lastObject[@"job"];
        NSLog(@"FIX-A A5-HLS: DOWNLOAD_URL=%@ MASTER_CONTEXT=%@", spy.enqueued.lastObject[@"url"], job.streamMasterURL);
        Check([job.streamMasterURL isEqualToString:@"https://example.invalid/master.m3u8"],
              @"A5-HLS 下载计划携带主清单（流任务解析分离音轨的入口）");
    }
}

// 生产流任务数据基础：主清单解析出变体与分离音轨；pinned 档位可被定位。
static void FixA6_StreamPlanContext(void) {
    NSString *master = @"#EXTM3U\n"
        @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",DEFAULT=YES,URI=\"audio.m3u8\"\n"
        @"#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO=\"aud\"\n480.m3u8\n"
        @"#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1280x720,AUDIO=\"aud\"\n720.m3u8\n";
    NSDictionary *parsed = [RDManifestParser parseManifest:master
                                                   baseURL:[NSURL URLWithString:@"https://example.invalid/master.m3u8"]];
    Check([parsed[@"isMaster"] boolValue], @"A6 主清单识别");
    NSArray *variants = parsed[@"variants"];
    Check(variants.count == 2, @"A6 两个变体");
    // RDManifestParser 按文档顺序返回变体；带宽择优发生在 RDStreamDownloadTask
    // 内部。这里按生产同款规则（带宽最高者胜）验证数据基础。
    NSDictionary *best = nil;
    for (NSDictionary *v in variants)
        if (!best || [v[@"bandwidth"] longLongValue] > [best[@"bandwidth"] longLongValue]) best = v;
    Check([best[@"url"] hasSuffix:@"720.m3u8"], @"A6 默认带宽择优为 720（修复前的下载行为）");
    BOOL pinnedFound = NO;
    for (NSDictionary *v in variants) if ([v[@"url"] hasSuffix:@"480.m3u8"]) pinnedFound = YES;
    Check(pinnedFound, @"A6 界面档位 480.m3u8 可在主清单中定位");
    Check([parsed[@"audioTracks"] count] >= 1, @"A6 分离音轨声明存在（只有 master 入口能解析）");
    NSLog(@"FIX-A A6: 默认择优=%@ pinned=480.m3u8 audioTracks=%lu", best[@"url"], (unsigned long)[parsed[@"audioTracks"] count]);
}

#pragma mark - FIX-B

// B1：本轮精确复现。生产解析器解析三个同档 source → 初始 1 行；
// 详情订阅回调给当前媒体新增一个档位后，visibleMedia 必须仍是 1 行。
static void FixB1_MetadataUpdateDoesNotSplitGroup(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video>"
        @"<source src='https://offline.invalid/b.mp4' size='720'>"
        @"<source src='https://offline.invalid/c.mp4' size='720'>"
        @"<source src='https://offline.invalid/a.mp4' size='720'>"
        @"</video></body></html>"
        baseURL:[NSURL URLWithString:@"https://offline.invalid/watch"]];
    [app.results addObjectsFromArray:r.media];
    Check(r.media.count == 3, @"B1 生产解析得到 3 个同族成员");
    Check(app.visibleMedia.count == 1, @"B1 初始 visibleMedia 为 1 行");
    NSString *familyID = r.media.firstObject.videoFamilyID;
    Check(familyID.length > 0, @"B1 生产解析器写入稳定视频分组身份");
    for (DetectedMedia *m in r.media)
        Check([m.videoFamilyID isEqualToString:familyID], @"B1 三个成员同一分组身份");
    // 详情走真实 configureDetail → 订阅；给当前媒体返回含新档位的清单
    [app configureDetailForMedia:r.media.firstObject];
    DetectedMedia *detail = app.detailMedia;
    Check(detail != nil, @"B1 详情已配置");
    service.snapshots[detail.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/a-480.mp4", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": @"https://offline.invalid/a.mp4", @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:detail];
    Check(Wait(^BOOL { return detail.declaredVariants.count == 2; }, 5), @"B1 新档位合并进当前媒体");
    NSUInteger rows = app.visibleMedia.count;
    NSLog(@"FIX-B B1: STATIC_GROUP rows=1 → GROUP_AFTER_METADATA rows=%lu", (unsigned long)rows);
    Check(rows == 1, @"B1 元数据更新后 visibleMedia 仍为 1 行（修复前为 2）");
    for (DetectedMedia *m in r.media)
        Check(m.declaredVariants.count == 2, @"B1 同族成员候选统一更新");
}

// B2：同组多个对象先后获得不同快照（先 1080p，后补充更高带宽的 480p），
// 不产生两个组，合并后可选档位与组身份一致。
static void FixB2_FamilyMembersDifferentSnapshotOrder(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *x = [DetectedMedia new];
    x.mediaURL = @"https://offline.invalid/x-720.mp4"; x.title = @"同一标题";
    DetectedMedia *z = [DetectedMedia new];
    z.mediaURL = @"https://offline.invalid/x-480.mp4"; z.title = @"同一标题";
    NSString *family = [NSUUID UUID].UUIDString;
    x.videoFamilyID = family; z.videoFamilyID = family;
    NSArray *base = @[
        @{ @"url": z.mediaURL, @"label": @"480p", @"level": @480 },
        @{ @"url": x.mediaURL, @"label": @"720p", @"level": @720 },
    ];
    x.declaredVariants = base; z.declaredVariants = base;
    [app.results addObjectsFromArray:@[x, z]];
    Check(app.visibleMedia.count == 1, @"B2 初始折叠为一行");
    // x 先收到 1080p
    [app configureDetailForMedia:x];
    Check([app.detailMedia.mediaURL isEqualToString:x.mediaURL], @"B2 x 保持详情（自身是 720 择优）");
    service.snapshots[x.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/x-1080.mp4", @"bandwidth": @8000000, @"width": @1920, @"height": @1080 },
        @{ @"url": z.mediaURL, @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": x.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:x];
    Check(Wait(^BOOL { return x.declaredVariants.count == 3; }, 5), @"B2 x 合并 1080p");
    Check(app.visibleMedia.count == 1, @"B2 x 更新后仍一行");
    // z 随后收到补充的更高带宽 480p（同档择优替换）
    [app configureDetailForMedia:z];
    Check([app.detailMedia.mediaURL isEqualToString:z.mediaURL], @"B2 z 保持详情（自身是 480 择优）");
    service.snapshots[z.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/x-480b.mp4", @"bandwidth": @1200000, @"width": @854, @"height": @480 },
        @{ @"url": @"https://offline.invalid/x-1080.mp4", @"bandwidth": @8000000, @"width": @1920, @"height": @1080 },
        @{ @"url": x.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:z];
    Check(Wait(^BOOL {
        return z.declaredVariants.count == 3 && x.declaredVariants.count == 3
            && [x.declaredVariants isEqualToArray:z.declaredVariants];
    }, 5), @"B2 合并后的可选档位在两个成员上一致");
    NSLog(@"FIX-B B2: rows=%lu variants=%lu familySame=%d",
          (unsigned long)app.visibleMedia.count, (unsigned long)z.declaredVariants.count,
          [x.videoFamilyID isEqualToString:z.videoFamilyID]);
    Check(app.visibleMedia.count == 1, @"B2 逆序补充后仍一行");
    Check([x.videoFamilyID isEqualToString:z.videoFamilyID], @"B2 组身份不变");
}

// B3：相同快照重复发布、新旧快照逆序返回：不新增重复行，不回滚有效档位。
static void FixB3_DuplicateAndReversedSnapshots(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = @"https://offline.invalid/only-720.mp4"; m.title = @"标题";
    m.declaredVariants = @[ @{ @"url": m.mediaURL, @"label": @"720p", @"level": @720 } ];
    [app.results addObject:m];
    [app configureDetailForMedia:m];
    service.snapshots[m.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/only-480.mp4", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": m.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:m];
    Check(Wait(^BOOL { return m.declaredVariants.count == 2; }, 5), @"B3 首次快照合并两档");
    NSUInteger rowsBefore = app.visibleMedia.count;
    NSUInteger reloadsBefore = table.reloads;
    // 相同快照重复发布：合并结果不变，不得触发整体 reload
    [service publishSnapshotForMedia:m];
    Check(Wait(^BOOL { return service.publishCount >= 2; }, 5), @"B3 重复快照已投递");
    Check(app.visibleMedia.count == rowsBefore, @"B3 重复快照不新增行");
    Check(table.reloads == reloadsBefore, @"B3 重复快照不触发整体 reload");
    // 逆序：旧快照（单档）后到——合并保持并集，不回滚 480p 选项
    service.snapshots[m.mediaURL] = VariantSnapshot(@[
        @{ @"url": m.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:m];
    Check(Wait(^BOOL { return service.publishCount >= 3; }, 5), @"B3 逆序快照已投递");
    NSLog(@"FIX-B B3: rows=%lu variants=%lu reloads=%lu", (unsigned long)app.visibleMedia.count,
          (unsigned long)m.declaredVariants.count, (unsigned long)table.reloads);
    Check(m.declaredVariants.count == 2, @"B3 逆序旧快照不回滚有效档位");
    Check(app.visibleMedia.count == 1, @"B3 逆序旧快照不改变分组");
}

// B4：两个不同视频（标题相同、同为 720p）各自接收清单更新，不得误合并。
static void FixB4_TwoDistinctVideosNeverMerge(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body>"
        @"<video><source src='https://offline.invalid/v1-a.mp4' size='720'>"
        @"<source src='https://offline.invalid/v1-b.mp4' size='720'></video>"
        @"<video><source src='https://offline.invalid/v2-a.mp4' size='720'>"
        @"<source src='https://offline.invalid/v2-b.mp4' size='720'></video>"
        @"</body></html>"
        baseURL:[NSURL URLWithString:@"https://offline.invalid/watch"]];
    [app.results addObjectsFromArray:r.media];
    NSString *f1 = r.media.firstObject.videoFamilyID;
    NSString *f2 = r.media.lastObject.videoFamilyID;
    Check(f1.length > 0 && f2.length > 0 && ![f1 isEqualToString:f2],
          @"B4 两个 video 块获得不同分组身份");
    for (DetectedMedia *m in r.media) m.title = @"完全相同的标题";
    Check(app.visibleMedia.count == 2, @"B4 初始两行（同标题不合并）");
    // 只给第一个视频发清单更新
    DetectedMedia *first = app.visibleMedia.firstObject;
    [app configureDetailForMedia:first];
    service.snapshots[first.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/v1-480.mp4", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": first.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:first];
    Check(Wait(^BOOL { return first.declaredVariants.count == 2; }, 5), @"B4 第一个视频获得新档位");
    NSLog(@"FIX-B B4: rows=%lu", (unsigned long)app.visibleMedia.count);
    Check(app.visibleMedia.count == 2, @"B4 更新后仍是两个视频");
    for (DetectedMedia *m in r.media) {
        if ([m.videoFamilyID isEqualToString:f2])
            Check(m.declaredVariants.count == 1, @"B4 第二个视频候选未被污染");
    }
}

// B5：档位更新前选中某视频，更新后表格选择仍是该视频；下载对应该视频当前档位。
static void FixB5_SelectionAndDownloadSurviveUpdate(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *v1 = [DetectedMedia new];
    v1.mediaURL = @"https://offline.invalid/w1-720.mp4"; v1.title = @"视频一";
    DetectedMedia *v2 = [DetectedMedia new];
    v2.mediaURL = @"https://offline.invalid/w2-720.mp4"; v2.title = @"视频二";
    NSString *f1 = [NSUUID UUID].UUIDString, *f2 = [NSUUID UUID].UUIDString;
    v1.videoFamilyID = f1; v2.videoFamilyID = f2;
    v1.declaredVariants = @[ @{ @"url": v1.mediaURL, @"label": @"720p", @"level": @720 } ];
    v2.declaredVariants = @[ @{ @"url": v2.mediaURL, @"label": @"720p", @"level": @720 } ];
    [app.results addObjectsFromArray:@[v1, v2]];
    table.selectedRow = 0;
    [app configureDetailForMedia:v1];
    Check([app.detailMedia.mediaURL isEqualToString:v1.mediaURL], @"B5 选中视频一");
    NSUInteger rowBefore = [app.visibleMedia indexOfObjectIdenticalTo:v1];
    service.snapshots[v1.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/w1-480.mp4", @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": v1.mediaURL, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:v1];
    Check(Wait(^BOOL { return v1.declaredVariants.count == 2; }, 5), @"B5 档位更新完成");
    NSUInteger rowAfter = [app.visibleMedia indexOfObjectIdenticalTo:v1];
    NSLog(@"FIX-B B5: row %lu → %lu, reloads=%lu restored=%ld",
          (unsigned long)rowBefore, (unsigned long)rowAfter,
          (unsigned long)table.reloads, (long)table.restoredSelections);
    Check(rowBefore == rowAfter, @"B5 该视频行位置稳定");
    Check([app.detailMedia.mediaURL hasPrefix:@"https://offline.invalid/w1-"],
          @"B5 详情仍是视频一（或其具体档位）");
    [app downloadSelected:nil];
    NSString *downloadURL = spy.enqueued.lastObject[@"url"];
    NSLog(@"FIX-B B5: DOWNLOAD_URL=%@", downloadURL);
    Check([downloadURL hasPrefix:@"https://offline.invalid/w1-"], @"B5 入队目标属于视频一");
}

// B6：扫描 A 未完成时开始扫描 B；A 的迟到回调不得修改 B 的结果。
static void FixB6_StaleGenerationCannotTouchNewResults(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    DetectedMedia *a = [DetectedMedia new];
    a.mediaURL = @"https://offline.invalid/page-a.mp4"; a.title = @"A";
    [app.results addObject:a];
    [app configureDetailForMedia:a];   // 扫描 A：详情订阅 A
    Check(service.updates[a.mediaURL] != nil, @"B6 A 的订阅已建立");
    void (^staleUpdate)(RDMetadataSnapshot *) = service.updates[a.mediaURL];
    // 扫描 B：列表整体替换（模拟 scan: 的 results 重建），详情切到 B
    DetectedMedia *b = [DetectedMedia new];
    b.mediaURL = @"https://offline.invalid/page-b.mp4"; b.title = @"B";
    b.declaredVariants = @[ @{ @"url": b.mediaURL, @"label": @"720p", @"level": @720 } ];
    [app.results removeAllObjects];
    [app.results addObject:b];
    [app configureDetailForMedia:b];
    NSUInteger bVariantsBefore = b.declaredVariants.count;
    NSUInteger rowsBefore = app.visibleMedia.count;
    // A 的迟到快照经取消的 token 投递：应被丢弃
    service.snapshots[a.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://offline.invalid/page-a-480.mp4", @"bandwidth": @800000, @"width": @854, @"height": @480 },
    ]);
    [service publishSnapshotForMedia:a];
    // 双重防护：即使迟到的 update 块被直接调用（token 之后取消前投递），
    // App 的 generation/详情指针检查也必须忽略它。
    if (staleUpdate) staleUpdate(service.snapshots[a.mediaURL]);
    Wait(^BOOL { return NO; }, 0.3); // 让主队列排空
    NSLog(@"FIX-B B6: rows=%lu bVariants=%lu detail=%@", (unsigned long)app.visibleMedia.count,
          (unsigned long)b.declaredVariants.count, app.detailMedia.mediaURL);
    Check(b.declaredVariants.count == bVariantsBefore, @"B6 B 的候选未被 A 的迟到快照修改");
    Check(app.visibleMedia.count == rowsBefore, @"B6 B 的行集合未被修改");
    Check(app.detailMedia == b, @"B6 详情仍是 B");
    Check(a.declaredVariants.count == 0, @"B6 旧扫描对象未被写入新档位");
}

// A7：用户在结果列表里选中的是「某一行的 1080p 档位对象」，随后异步腿返回并整体重建结果列表
//     （同一部影片在重建后仍然只占一行、行对象仍是 480p 档位）。
//     现场症状：详情显示 1080p 的 274.3 MB，⌘D 却下载 480p（实际落盘 854x480 / 72,919,887 字节），
//     且下载日志出现「预期=0 字节」。那些都不是站点问题，而是列表重建时的“保选择”错误。
static void FixA7_ResultReloadMustKeepSelectedTier(void) {
    RDChainMetadataService *service; RDEnqueueSpyManager *spy; RDChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    NSString *u480 = @"https://example.invalid/407597-sc-480p.mp4";
    NSString *u720 = @"https://example.invalid/407597-sc-720p.mp4";
    NSString *u1080 = @"https://example.invalid/407597-sc-1080p.mp4";
    NSArray *variants = @[ @{ @"label": @"480p", @"url": u480 },
                           @{ @"label": @"720p", @"url": u720 },
                           @{ @"label": @"1080p", @"url": u1080 } ];
    DetectedMedia *row = [DetectedMedia new];
    row.mediaURL = u480; row.resourceKind = RDResourceKindVideo; row.format = @"mp4";
    row.title = @"示例影片"; row.videoFamilyID = @"fam-407597"; row.declaredVariants = variants;
    [app.results addObject:row];
    [app.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    service.snapshots[u1080] = KnownSizeSnapshot(274331606);
    [app configureDetailForMedia:row];
    Check([app.variantPicker.itemTitles containsObject:@"1080p"], @"A7 前置：选择器提供 1080p 档位");

    // 用户选择 1080p
    [app.variantPicker selectItemWithTitle:@"1080p"];
    [app selectDeclaredVariant:nil];
    Check([[DetectedMedia dedupKeyForURL:app.currentDownloadMedia.mediaURL] isEqual:[DetectedMedia dedupKeyForURL:u1080]],
          @"A7 前置：用户已选中 1080p 档位");
    Wait(^BOOL { return app.currentDownloadMedia.sizeBytes == 274331606; }, 5);
    Check(app.currentDownloadMedia.sizeBytes == 274331606,
          [NSString stringWithFormat:@"A7 前置：1080p 档位已读到 274,331,606 字节（实际 %lld）", app.currentDownloadMedia.sizeBytes]);

    // 异步腿返回：整体重建结果列表（同一部影片的新行对象，仍是 480p 档位）
    DetectedMedia *row2 = [DetectedMedia new];
    row2.mediaURL = u480; row2.resourceKind = RDResourceKindVideo; row2.format = @"mp4";
    row2.title = @"示例影片"; row2.videoFamilyID = @"fam-407597"; row2.declaredVariants = variants;
    ZZResourceDiscoveryResult *result = [ZZResourceDiscoveryResult new];
    result.allMedia = @[ row2 ];
    [app applyDiscoveryResult:result final:YES];

    Check([[DetectedMedia dedupKeyForURL:app.currentDownloadMedia.mediaURL] isEqual:[DetectedMedia dedupKeyForURL:u1080]],
          [NSString stringWithFormat:@"A7 列表重建后 currentDownloadMedia 必须仍是用户选中的 1080p（实际 %@）",
           app.currentDownloadMedia.mediaURL]);
    Check([[DetectedMedia dedupKeyForURL:app.linkField.stringValue] isEqual:[DetectedMedia dedupKeyForURL:u1080]],
          [NSString stringWithFormat:@"A7 列表重建后链接必须仍是 1080p（实际 %@）", app.linkField.stringValue]);
    Check([app.variantPicker.selectedItem.title isEqualToString:@"1080p"],
          [NSString stringWithFormat:@"A7 列表重建后选择器必须仍显示 1080p（实际 %@）", app.variantPicker.selectedItem.title]);

    [app.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    // 真实节奏：用户重新看到 1080p 的大小（异步元数据回填）之后才会点下载。
    Wait(^BOOL { return app.currentDownloadMedia.sizeBytes == 274331606; }, 5);
    Check(app.currentDownloadMedia.sizeBytes == 274331606,
          [NSString stringWithFormat:@"A7 列表重建后 1080p 档位仍能回填 274,331,606 字节（实际 %lld）",
           app.currentDownloadMedia.sizeBytes]);
    [app downloadSelected:nil];
    Check(spy.enqueued.count == 1,
          [NSString stringWithFormat:@"A7 恰好入队一个下载任务（实际 %lu）", (unsigned long)spy.enqueued.count]);
    NSString *enqueuedURL = spy.enqueued.lastObject[@"url"];
    Check([[DetectedMedia dedupKeyForURL:enqueuedURL] isEqual:[DetectedMedia dedupKeyForURL:u1080]],
          [NSString stringWithFormat:@"A7 入队目标必须是用户选中的 1080p（实际 %@）", enqueuedURL]);
    Check([spy.enqueued.lastObject[@"expectedLength"] longLongValue] == 274331606,
          [NSString stringWithFormat:@"A7 入队预期字节必须沿用 1080p 的 274,331,606（实际 %@）",
           spy.enqueued.lastObject[@"expectedLength"]]);
}

@interface ResourceDetectorAppDelegate (FooterTests)
- (void)buildFooterButtons;
@end

@interface RDChainWindow : NSObject
@property NSView *contentView;
@end
@implementation RDChainWindow
@end

@interface RDChainTransfer : NSObject <RDDownloadTask>
@property NSUInteger suspends;
@property NSUInteger resumes;
@property NSURL *fileURL;
@property (copy) void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *);
@end
@implementation RDChainTransfer
- (void)rd_suspend { self.suspends++; }
- (void)rd_resume { self.resumes++; }
- (void)rd_cancel {
    if (self.completion) self.completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
    self.completion = nil;
}
@end

@interface RDChainHeldBackend : NSObject <RDDownloadBackend>
@property NSMutableArray<RDChainTransfer *> *transfers;
@end
@implementation RDChainHeldBackend
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request writeToURL:(NSURL *)fileURL
                          completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    if (!self.transfers) self.transfers = [NSMutableArray array];
    RDChainTransfer *transfer = [RDChainTransfer new];
    transfer.fileURL = fileURL;
    transfer.completion = completion;
    [[@"partial-transfer" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:fileURL atomically:YES];
    [self.transfers addObject:transfer];
    return transfer;
}
@end

static void FixC_SizeUnitsAndFooterPause(void) {
    NSString *suiteName = [@"rd.size-pause.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    NSString *repo = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
    repo = [[repo stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSURL *testRoot = [NSURL fileURLWithPath:[[repo stringByAppendingPathComponent:@"build/size-pause-fixtures"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL *tempRoot = [testRoot URLByAppendingPathComponent:@"parts"];
    NSURL *destination = [testRoot URLByAppendingPathComponent:@"output"];
    [[NSFileManager defaultManager] createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:nil];
    RDChainHeldBackend *backend = [RDChainHeldBackend new];
    DownloadManager *manager = [[DownloadManager alloc] initWithBackend:backend tempRoot:tempRoot
                                                                 store:[[DownloadStore alloc] initWithUserDefaults:defaults]];
    manager.rd_enableEndpointResolution = NO;
    manager.rd_resolver = ^NSArray *(NSString *host) { return @[@"93.184.216.34"]; };
    ResourceDetectorAppDelegate *app = MakeChainApp(NULL, NULL, NULL);
    app.downloadManager = manager;
    RDChainWindow *window = [RDChainWindow new];
    window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 438)];
    app.window = (RDSlashWindow *)window;
    app.homePage = window.contentView;
    app.statusNote = [NSTextField labelWithString:@""];
    app.sizeValue = [NSTextField labelWithString:@""];
    RDDownloadRowCellView *downloadRow = [[RDDownloadRowCellView alloc] initWithFrame:NSMakeRect(0, 0, 760, 72)];
    manager.delegate = app;
    if ([app respondsToSelector:@selector(buildFooterButtons)]) [app buildFooterButtons];
    NSButton *pause = nil;
    for (NSView *view in app.homePage.subviews) {
        if ([view isKindOfClass:NSButton.class] && [[(NSButton *)view title] isEqual:@"暂停下载"]) pause = (NSButton *)view;
    }
    Check(pause != nil && !pause.hidden, @"C1 主界面存在可见的暂停下载入口");
    Check(pause != nil && !pause.enabled, @"C1 无任务时暂停入口置灰");

    DetectedMedia *media = [DetectedMedia new];
    media.mediaURL = @"https://example.invalid/1080p.mp4";
    media.format = @"mp4";
    media.sizeBytes = 274331606;
    [app.results addObject:media];
    [app configureDetailForMedia:media];
    Check([app.sizeValue.stringValue isEqual:@"274.3 MB"], @"C2 详情初始大小为十进制 274.3 MB");
    [app applySnapshotForDisplay:KnownSizeSnapshot(274331606) media:media];
    Check([app.sizeValue.stringValue isEqual:@"274.3 MB"], @"C2 元数据到达后大小仍为 274.3 MB");
    ResourceResultRowView *row = [[ResourceResultRowView alloc] initWithFrame:NSMakeRect(0, 0, 300, 50)];
    [row configureWithMedia:media];
    NSTextField *rowDetail = [row valueForKey:@"detailField"];
    Check([rowDetail.stringValue containsString:@"274.3 MB"], @"C2 资源列表与详情使用相同大小单位");
    Check([[app formatBytes:274331606] isEqual:@"274.3 MB"], @"C2 进度大小不得把 261.6 MiB 错标成 MB");
    Check([[app formatBytes:5000000] isEqual:@"5 MB"], @"C2 速率 5000000 字节每秒显示 5 MB/s");
    Check([[app formatBytes:1000000000] isEqual:@"1 GB"], @"C2 大文件按十进制切换到 GB");
    Check([[app formatBytes:1000] isEqual:@"1 KB"], @"C2 KB 边界使用十进制");
    Check([[app formatBytes:0] containsString:@"0"], @"C2 零字节正常显示");
    Check([[app formatBytes:NAN] isEqual:@"—"] && [[app formatBytes:INFINITY] isEqual:@"—"], @"C2 无效速率不进入整型转换");

    DownloadJob *first = [manager enqueueItemWithSourceURL:[NSURL URLWithString:media.mediaURL] folder:destination
                                            preferredName:@"1080p.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:274331606];
    Check(first.state == DownloadJobStateRunning && backend.transfers.count == 1, @"C3 真实下载管理器启动受控传输");
    Check(Wait(^BOOL { return pause.enabled; }, 1), @"C3 下载状态通知自动启用按钮无需用户手动刷新");
    first.transferredBytes = 10000000;
    first.bytesPerSecond = 5000000;
    first.progress = (double)first.transferredBytes / (double)first.expectedContentLength;
    [downloadRow configureWithJob:first width:760 app:app];
    Check([downloadRow.metricsLabel.stringValue containsString:@"/ 274.3 MB"] &&
          [downloadRow.metricsLabel.stringValue containsString:@"5 MB/s"], @"C3 实际进度标签的总量和速率均使用十进制");
    Check(pause.enabled && [pause.title isEqual:@"暂停下载"], @"C3 运行中按钮可点击并显示暂停下载");
    if (pause.enabled) [pause performClick:nil];
    Check(first.state == DownloadJobStatePaused && backend.transfers.firstObject.suspends == 1, @"C3 点击按钮实际挂起传输而非只改变文案");
    Check(first.transferredBytes == 10000000 && [[NSFileManager defaultManager] fileExistsAtPath:backend.transfers.firstObject.fileURL.path], @"C3 暂停保留已下载字节和分段文件");
    [downloadRow configureWithJob:first width:760 app:app];
    Check(pause.enabled && [pause.title isEqual:@"继续下载"] && downloadRow.progressView.progress > 0, @"C3 暂停后提供继续下载并保留进度条");
    if (pause.enabled) [pause performClick:nil];
    Check(first.state == DownloadJobStateRunning && backend.transfers.firstObject.resumes == 1 && backend.transfers.count == 1, @"C3 继续恢复原传输而非新建下载");

    DownloadJob *second = [manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://example.invalid/second.mp4"] folder:destination
                                             preferredName:@"second.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:1000];
    [manager pauseJob:first.identifier];
    Check(Wait(^BOOL { return [pause.title isEqual:@"暂停下载"]; }, 1), @"C4 单任务操作后按钮自动跟随剩余运行任务");
    NSUInteger resumesBefore = backend.transfers.firstObject.resumes;
    Check(second.state == DownloadJobStateRunning && [pause.title isEqual:@"暂停下载"], @"C4 暂停与运行并存时入口仍优先暂停");
    if (pause.enabled) [pause performClick:nil];
    Check(first.state == DownloadJobStatePaused && second.state == DownloadJobStatePaused &&
          backend.transfers.firstObject.resumes == resumesBefore, @"C4 点击暂停不会意外恢复已有暂停任务");
    if (pause.enabled) [pause performClick:nil];
    Check(first.state == DownloadJobStateRunning && second.state == DownloadJobStateRunning, @"C4 再次点击继续可恢复所有暂停任务");

    if (pause) {
        for (NSNumber *width in @[@760, @980]) {
            window.contentView.frame = NSMakeRect(0, 0, width.doubleValue, 438);
            [app layoutFooterButtons];
            Check(NSContainsRect(app.homePage.bounds, pause.frame) &&
                  NSMaxX(pause.frame) < NSMinX(app.downloadFooter.frame) &&
                  NSMaxX(app.downloadFooter.frame) < NSMinX(app.downloadsFooter.frame), @"C5 最小及普通窗口下暂停按钮在下载选中左侧且不重叠");
        }
    }
    Check(first.expectedContentLength == 274331606 && first.authoritativeExpectedLength == 274331606, @"C5 格式化和暂停不改写任务真实字节数");
    [manager markInterruptedOnTerminate];
    Check(Wait(^BOOL { return [pause.title isEqual:@"继续下载"]; }, 1) && pause.enabled,
          @"C5 仅中断任务时提供继续入口");
    NSUInteger transfersBeforeRecovery = backend.transfers.count;
    if (pause.enabled) [pause performClick:nil];
    Check(first.state == DownloadJobStateRunning && second.state == DownloadJobStateRunning &&
          backend.transfers.count == transfersBeforeRecovery + 2, @"C5 继续入口通过真实管理器重新启动中断传输");
    [manager cancelAll];
    Check(!pause.enabled, @"C5 所有任务终态后暂停入口置灰");
    [manager beginBatchEnqueue];
    [manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://example.invalid/queued.mp4"] folder:destination
                       preferredName:@"queued.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:1000];
    Check(!pause.enabled, @"C5 仅排队无运行任务时按钮不可误操作");
    [manager cancelAll];
    [manager endBatchEnqueue];
    manager.delegate = nil;
    [app.metadataToken cancel];
    [defaults removePersistentDomainForName:suiteName];
    [[NSFileManager defaultManager] removeItemAtURL:testRoot error:nil];
}

int main(int argc, const char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    NSLog(@"== FIX-A / FIX-B 生产调用链专项测试 ==");
    FixA1_InitialMasterMustDownloadSelectedTier();
    FixA2_UserSwitchDownloadsChosenTier();
    FixA3_BackgroundUpdateKeepsUserSelection();
    FixA4_SameTierReplacementStaysInTier();
    FixA5_MediaTypesAndContexts();
    FixA6_StreamPlanContext();
    FixA7_ResultReloadMustKeepSelectedTier();
    FixB1_MetadataUpdateDoesNotSplitGroup();
    FixB2_FamilyMembersDifferentSnapshotOrder();
    FixB3_DuplicateAndReversedSnapshots();
    FixB4_TwoDistinctVideosNeverMerge();
    FixB5_SelectionAndDownloadSurviveUpdate();
    FixB6_StaleGenerationCannotTouchNewResults();
    FixC_SizeUnitsAndFooterPause();
    CheckSummary();
} }
