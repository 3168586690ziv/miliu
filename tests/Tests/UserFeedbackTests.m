//
//  UserFeedbackTests.m — 本轮用户反馈专项验收
//
//  问题一：同一影片两行（一行可选画质、一行不能）。
//  问题二：详情信息读取极慢（时长/尺寸路径多次串行往返；缩略图可接受）。
//
//  全部经过生产代码：RDProbeAnalyzer analyzeHTML:baseURL:、生产 App
//  visibleMedia / configureDetailForMedia / selectDeclaredVariant /
//  downloadSelected、生产 RDMetadataService + 生产 RDBoundedMovie。
//  只替换最底层网络（transport 投递）与下载后端（入队记录），夹具网络延迟
//  固定（普通请求 0.4s、海报 0.05s），不缩短延迟、不预置结果。
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "WebProbe.h"
#import "RDBoundedMovie.h"

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
    NSLog(@"PASS: ALL USER-FEEDBACK TESTS");
}
static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}

// 档位断言辅助：排序后的标准档位标签集合 / 某档位指向的 URL。
static NSArray<NSString *> *UFVariantLabels(DetectedMedia *m) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSDictionary *v in m.declaredVariants) if ([v[@"label"] isKindOfClass:NSString.class]) [labels addObject:v[@"label"]];
    [labels sortUsingSelector:@selector(compare:)];
    return labels;
}
static NSString *UFVariantURL(DetectedMedia *m, NSString *label) {
    for (NSDictionary *v in m.declaredVariants) if ([v[@"label"] isEqualToString:label]) return v[@"url"];
    return nil;
}

#pragma mark - 受控替身（只替换网络投递与下载后端；与 FixChainTests 同款）

@interface UFChainMetadataService : RDMetadataService
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDMetadataSnapshot *> *snapshots;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDMetadataToken *> *tokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(RDMetadataSnapshot *)> *updates;
@end
@implementation UFChainMetadataService
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
    dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) update(snapshot); });
}
@end

@interface UFEnqueueSpyManager : DownloadManager
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *enqueued;
@end
@implementation UFEnqueueSpyManager
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
    record[@"job"] = job;
    [self.enqueued addObject:record];
    return job;
}
@end

@interface UFChainRow : NSObject
@property NSUInteger updates;
@end
@implementation UFChainRow
- (BOOL)isKindOfClass:(Class)cls { return cls == ResourceResultRowView.class || [super isKindOfClass:cls]; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint { self.updates++; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint sizeHint:(NSString *)sizeHint { self.updates++; }
@end
@interface UFChainTable : NSObject
@property UFChainRow *row;
@property NSUInteger reloads;
@property NSInteger selectedRow;
@end
@implementation UFChainTable
- (id)viewAtColumn:(NSInteger)c row:(NSInteger)r makeIfNecessary:(BOOL)make { return self.row; }
- (void)reloadData { self.reloads++; }
- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend { self.selectedRow = (NSInteger)indexes.firstIndex; }
@end

static ResourceDetectorAppDelegate *MakeChainApp(UFChainMetadataService **outService,
                                                 UFEnqueueSpyManager **outSpy,
                                                 UFChainTable **outTable) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    UFChainMetadataService *service = [UFChainMetadataService new];
    UFEnqueueSpyManager *spy = [UFEnqueueSpyManager new];
    UFChainTable *table = [UFChainTable new];
    table.row = [UFChainRow new];
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
    app.variantPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 20) pullsDown:NO];
    app.linkField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    if (outService) *outService = service;
    if (outSpy) *outSpy = spy;
    if (outTable) *outTable = table;
    return app;
}

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

#pragma mark - 问题一：重复行（生产解析器 + 生产列表）

static NSString * const kPlaying = @"https://fixture.invalid/playing.mp4";
static NSString * const k480 = @"https://fixture.invalid/480.mp4";
static NSString * const k720 = @"https://fixture.invalid/720.mp4";

// 夹具一：<video src=playing> + 两个带 size 的 source。
static NSString *FixtureVideoSrc(void) {
    return [NSString stringWithFormat:
        @"<html><body><video src='%@'><source src='%@' size='480'><source src='%@' size='720'></video></body></html>",
        kPlaying, k480, k720];
}
// 夹具二：无 size 的 playing source + 两个带 size 的 source。
static NSString *FixtureUnlabelledSource(void) {
    return [NSString stringWithFormat:
        @"<html><body><video><source src='%@'><source src='%@' size='480'><source src='%@' size='720'></video></body></html>",
        kPlaying, k480, k720];
}

// D1：夹具一 → 一行，行上保留 480p/720p 选项（修复前：playing 与 480 两行）。
static void D1_VideoSrcPlusLabelledSourcesSingleRow(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:FixtureVideoSrc()
                                          baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    Check(r.media.count == 3, [NSString stringWithFormat:@"D1 生产解析得到 3 个候选（实际 %lu）", (unsigned long)r.media.count]);
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D1 rows=%lu urls=%@", (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]);
    Check(rows.count == 1, [NSString stringWithFormat:@"D1 夹具一只显示一行（实际 %lu 行：%@）",
          (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]]);
    DetectedMedia *row = rows.firstObject;
    Check(row.declaredVariants.count == 2, @"D1 行上保留两个画质选项");
    NSArray *labels = [row.declaredVariants valueForKey:@"label"];
    Check([labels containsObject:@"480p"] && [labels containsObject:@"720p"], @"D1 选项为 480p/720p");
    Check(row.videoFamilyID.length > 0, @"D1 代表行带同播放器分组身份");
    Check([row.mediaURL isEqual:k480] || [row.mediaURL isEqual:k720], @"D1 代表行是声明过画质的成员");
    // 未知画质成员 playing 不得被伪造档位，也不得再作为第二行出现。
    for (DetectedMedia *m in r.media) {
        if (![m.mediaURL isEqual:kPlaying]) continue;
        Check(m.declaredVariants.count == 2 && ![m.declaredVariants.firstObject[@"url"] isEqual:kPlaying],
              @"D1 playing 成员共享分组选项且自身没有被伪造成档位");
    }
}

// D2：夹具二 → 一行（修复前：两行）。
static void D2_UnlabelledPlayingSourceSingleRow(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:FixtureUnlabelledSource()
                                          baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D2 rows=%lu urls=%@", (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]);
    Check(rows.count == 1, [NSString stringWithFormat:@"D2 夹具二只显示一行（实际 %lu 行：%@）",
          (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]]);
    Check(rows.firstObject.declaredVariants.count == 2, @"D2 行上保留 480p/720p 选项");
}

// D3：当前播放 URL 与某 source 完全相同时 → 一行，且该 source 的画质声明不得被去重逻辑丢弃。
static void D3_PlayingURLMatchesSourceSingleRow(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    Check(r.media.count == 2, @"D3 重复 URL 去重后剩两个候选");
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    Check(rows.count == 1, [NSString stringWithFormat:@"D3 播放地址与 source 相同时一行（实际 %lu）", (unsigned long)rows.count]);
    // 关键补强：video.src 与 source.src 相同，不代表该 source 的 size 声明可以丢弃。
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D3 相同地址的 source 画质声明必须保留（期望 480p+720p，实际 %@）", labels]);
    for (DetectedMedia *m in r.media)
        Check([UFVariantLabels(m) isEqualToArray:@[@"480p", @"720p"]], @"D3 全部成员共享 480p/720p 两个档位");
}

// D4：两个独立 video 即使同标题、同海报也仍两行（不得误合并）。
static void D4_DistinctVideosStaySeparate(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><head><title>同一标题</title></head><body>"
        @"<video poster='https://fixture.invalid/p.jpg'><source src='https://fixture.invalid/v1-480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/v1-720.mp4' size='720'></video>"
        @"<video poster='https://fixture.invalid/p.jpg'><source src='https://fixture.invalid/v2-480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/v2-720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D4 rows=%lu", (unsigned long)rows.count);
    Check(rows.count == 2, [NSString stringWithFormat:@"D4 两个独立视频仍两行（实际 %lu）", (unsigned long)rows.count]);
    NSString *f1 = nil, *f2 = nil;
    for (DetectedMedia *m in r.media) {
        if (!m.videoFamilyID.length) continue;
        if (!f1) f1 = m.videoFamilyID;
        else if (![m.videoFamilyID isEqualToString:f1]) f2 = m.videoFamilyID;
    }
    Check(f1.length && f2.length && ![f1 isEqualToString:f2], @"D4 两个 video 块分组身份不同");
}

// D5：未知画质资源仍可见、可下载；且不伪造档位。
static void D5_UnknownQualityStillVisibleAndDownloadable(void) {
    {
        ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
        RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
            @"<html><body><video src='https://fixture.invalid/only.mp4'></video></body></html>"
            baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
        app.results = [r.media mutableCopy];
        Check(r.media.count == 1 && app.visibleMedia.count == 1, @"D5 单个未知画质视频仍显示一行");
        Check(app.visibleMedia.firstObject.declaredVariants.count == 0, @"D5 未知画质不伪造档位");
    }
    {
        // 同一 video 内两个都没有画质声明：同属一个播放器，折叠为一行；
        // 不合并成一个档位、不伪造档位，也不隐藏整个资源（代表行可见可下载）。
        ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
        RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
            @"<html><body><video><source src='https://fixture.invalid/a.mp4'>"
            @"<source src='https://fixture.invalid/b.mp4'></video></body></html>"
            baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
        app.results = [r.media mutableCopy];
        NSArray<DetectedMedia *> *rows = app.visibleMedia;
        Check(r.media.count == 2, @"D5 两个未知画质候选都被发现");
        Check(rows.count == 1, [NSString stringWithFormat:@"D5 同一 video 的未知画质成员折叠为一行（实际 %lu 行）", (unsigned long)rows.count]);
        Check(rows.firstObject.declaredVariants.count == 0, @"D5 未知画质成员无伪造档位");
    }
    {
        // 未知画质独立视频可直接入队下载。
        UFChainMetadataService *service; UFEnqueueSpyManager *spy; UFChainTable *table;
        ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
        DetectedMedia *only = [DetectedMedia new];
        only.mediaURL = @"https://fixture.invalid/only.mp4";
        only.resourceKind = RDResourceKindVideo;
        only.format = @"mp4";
        [app.results addObject:only];
        [app configureDetailForMedia:only];
        [app downloadSelected:nil];
        Check(spy.enqueued.count == 1 && [spy.enqueued.lastObject[@"url"] isEqual:only.mediaURL],
              @"D5 未知画质视频可下载且对象正确");
        Check([spy.enqueued.lastObject[@"kind"] integerValue] == DownloadResourceVideo, @"D5 未知画质按视频入队");
    }
}

// D6：静态块 + 动态桥接合成标签（同一播放地址）合并后仍一行，动态元数据不丢。
static void D6_StaticPlusDynamicBridgeSingleRow(void) {
    NSString *dynamic = [RDBridgeEventSynthesizer syntheticHTMLForEvent:@{
        @"action": @"resource",
        @"url": kPlaying,
        @"kind": @"video",
        @"durationSeconds": @120,
        @"pixelWidth": @854,
        @"pixelHeight": @480,
        @"poster": @"https://fixture.invalid/poster.png",
    }];
    Check(dynamic.length > 0, @"D6 桥接合成标签生成");
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:[FixtureVideoSrc() stringByAppendingString:dynamic]
                                          baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    Check(r.media.count == 3, [NSString stringWithFormat:@"D6 静态+动态去重后仍 3 个候选（实际 %lu）", (unsigned long)r.media.count]);
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D6 rows=%lu urls=%@", (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]);
    Check(rows.count == 1, [NSString stringWithFormat:@"D6 静态+动态合并后一行（实际 %lu 行：%@）",
          (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]]);
    DetectedMedia *playing = nil;
    for (DetectedMedia *m in r.media) if ([m.mediaURL isEqual:kPlaying]) playing = m;
    Check(playing && playing.durationSeconds.doubleValue == 120, @"D6 动态时长元数据合并到 playing 成员");
    Check(playing && playing.videoFamilyID.length > 0, @"D6 playing 成员获得同播放器身份");
    Check(playing && playing.declaredVariants.count == 2, @"D6 playing 成员共享分组画质选项");
}

// D7：元数据更新（清单档位到达）后仍一行。
static void D7_MetadataUpdateKeepsSingleRow(void) {
    UFChainMetadataService *service; UFEnqueueSpyManager *spy; UFChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:FixtureVideoSrc()
                                          baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    [app.results addObjectsFromArray:r.media];
    DetectedMedia *member480 = nil;
    for (DetectedMedia *m in r.media) if ([m.mediaURL isEqual:k480]) member480 = m;
    Check(member480 != nil, @"D7 找到 480 成员");
    DetectedMedia *detail = app.visibleMedia.firstObject;
    [app configureDetailForMedia:detail];
    Check(app.detailMedia != nil, @"D7 详情已配置");
    service.snapshots[app.detailMedia.mediaURL] = VariantSnapshot(@[
        @{ @"url": @"https://fixture.invalid/playing-1080.mp4", @"bandwidth": @8000000, @"width": @1920, @"height": @1080 },
        @{ @"url": k480, @"bandwidth": @800000, @"width": @854, @"height": @480 },
        @{ @"url": k720, @"bandwidth": @5000000, @"width": @1280, @"height": @720 },
    ]);
    [service publishSnapshotForMedia:app.detailMedia];
    // 家族传播后 480 成员的候选应从 2 档变为 3 档（1080p 新档到达）。
    Check(Wait(^BOOL { return member480.declaredVariants.count == 3; }, 5), @"D7 新档位合并并传播到家族成员");
    NSUInteger rows = app.visibleMedia.count;
    NSLog(@"D7 rows=%lu variants480=%lu", (unsigned long)rows, (unsigned long)member480.declaredVariants.count);
    Check(rows == 1, [NSString stringWithFormat:@"D7 元数据更新后仍一行（实际 %lu）", (unsigned long)rows]);
}

// D8：选择画质后入队对象与所选一致，且列表仍一行（FIX-A 不回归）。
static void D8_QualitySwitchEnqueuesTarget(void) {
    UFChainMetadataService *service; UFEnqueueSpyManager *spy; UFChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:FixtureVideoSrc()
                                          baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    [app.results addObjectsFromArray:r.media];
    [app configureDetailForMedia:app.visibleMedia.firstObject];
    Check(Wait(^BOOL { return [app.variantPicker.itemTitles containsObject:@"720p"]; }, 5), @"D8 画质选项就绪");
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    Check([app.detailMedia.mediaURL isEqual:k720], [NSString stringWithFormat:@"D8 切换后详情为 720（实际 %@）", app.detailMedia.mediaURL]);
    Check([app.linkField.stringValue isEqual:k720], @"D8 复制链接目标为 720");
    [app downloadSelected:nil];
    NSLog(@"D8 DOWNLOAD_URL=%@ rows=%lu", spy.enqueued.lastObject[@"url"], (unsigned long)app.visibleMedia.count);
    Check(spy.enqueued.count == 1 && [spy.enqueued.lastObject[@"url"] isEqual:k720], @"D8 实际入队对象是所选 720 档位");
    Check([spy.enqueued.lastObject[@"kind"] integerValue] == DownloadResourceVideo, @"D8 720p 按 MP4 视频类型入队");
    Check(app.visibleMedia.count == 1, @"D8 切换画质后列表仍一行");
}

#pragma mark - 问题二：详情读取（生产 RDMetadataService + 生产 RDBoundedMovie + 固定延迟 transport）

static void Put32(NSMutableData *d, NSUInteger offset, uint32_t value) { value=CFSwapInt32HostToBig(value); memcpy((uint8_t *)d.mutableBytes+offset,&value,4); }
static NSData *UFBox(const char *type, NSData *body) { NSMutableData *d=[NSMutableData dataWithLength:8]; Put32(d,0,(uint32_t)body.length+8); memcpy((uint8_t *)d.mutableBytes+4,type,4); [d appendData:body]; return d; }
static NSData *UFJoin(NSArray *items) { NSMutableData *d=[NSMutableData data]; for (NSData *item in items) [d appendData:item]; return d; }
static NSData *UFMovieMoov(void) {
    NSMutableData *mvhd=[NSMutableData dataWithLength:100]; Put32(mvhd,12,1000); Put32(mvhd,16,12500);
    NSMutableData *tkhd=[NSMutableData dataWithLength:84]; Put32(tkhd,40,0); Put32(tkhd,44,65536); Put32(tkhd,52,(uint32_t)-65536); Put32(tkhd,72,0x40000000); Put32(tkhd,76,320*65536); Put32(tkhd,80,180*65536);
    NSMutableData *hdlr=[NSMutableData dataWithLength:24]; memcpy((uint8_t *)hdlr.mutableBytes+8,"vide",4);
    NSMutableData *url=[NSMutableData dataWithLength:4]; Put32(url,0,1);
    NSMutableData *dref=[NSMutableData dataWithLength:8]; Put32(dref,4,1); [dref appendData:UFBox("url ",url)];
    NSData *mdia=UFBox("mdia",UFJoin(@[UFBox("hdlr",hdlr),UFBox("minf",UFBox("dinf",UFBox("dref",dref)))]));
    return UFBox("moov",UFJoin(@[UFBox("mvhd",mvhd),UFBox("trak",UFJoin(@[UFBox("tkhd",tkhd),mdia]))]));
}

// 固定延迟 transport：海报 0.05s，其余每个请求 0.4s（可调）。64MiB mdat 永不真实分配。
@interface UFSlowTransport : NSObject<RDMetadataTransporting>
@property NSDictionary *segments;
@property NSData *png;
@property unsigned long long total;
@property BOOL tail;                 // moov 在尾部（mdat 之后）
@property BOOL failFirstPrefixProbe;// 首个前缀探测（bytes=0-1048575）临时超时一次
@property BOOL ignoreRange;         // 服务器不支持 Range：一律 200 + BudgetExceeded
@property BOOL failMedia;           // 所有媒体请求返回网络错误（海报仍成功）
@property BOOL failPoster;          // 海报请求返回错误
@property double mediaDelay;        // 媒体请求延迟（默认 0.4）
@property double posterDelay;       // 海报请求延迟（默认 0.05）
@property double started;
@property NSMutableArray<NSString *> *events;
@property NSMutableArray<NSArray<NSNumber *> *> *mediaSpans;  // 每个媒体请求 [开始, 结束]
@property NSMutableArray<NSString *> *requestPaths;          // 每个请求的路径（按 URL 分别计数）
@property NSUInteger bytes;
@property NSUInteger cancellations;
@property NSUInteger posterRequests;
@property NSUInteger mediaRequests;
@property BOOL prefixProbeFailed;
@end
@implementation UFSlowTransport
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))done {
    RDMetadataToken *token=[RDMetadataToken new];
    __weak typeof(self) weak=self;
    [token addCancellation:^{ weak.cancellations++; }];
    NSString *range=[request valueForHTTPHeaderField:@"Range"];
    BOOL poster=[request.URL.path containsString:@"poster"], head=[request.HTTPMethod isEqual:@"HEAD"];
    double elapsed=CFAbsoluteTimeGetCurrent()-self.started;
    [self.events addObject:[NSString stringWithFormat:@"%.3f %@ %@",elapsed,request.HTTPMethod,poster?@"poster":(range?:@"whole-resource")]];
    if (!self.requestPaths) self.requestPaths=[NSMutableArray array];
    [self.requestPaths addObject:request.URL.path ?: @""];
    if (poster) self.posterRequests++; else self.mediaRequests++;
    RDMetadataResponse *r=[RDMetadataResponse new];
    NSMutableDictionary *hdr=[@{@"Content-Type":poster?@"image/png":@"video/mp4",@"Content-Length":@(self.total).stringValue} mutableCopy];
    NSInteger status=200;
    double delay=poster?self.posterDelay:self.mediaDelay;
    if (poster) {
        if (self.failPoster) { r.error=[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataHTTPFailure userInfo:nil]; }
        else { r.data=self.png; hdr[@"Content-Length"]=@(self.png.length).stringValue; }
    }
    else if (self.failMedia) {
        r.error=[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataHTTPFailure userInfo:nil];
    }
    else if (head) { /* 只回响应头 */ }
    else if (range && self.ignoreRange) {
        r.error=[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBudgetExceeded userInfo:nil];
        hdr[@"Content-Length"]=@(self.total).stringValue; status=200;
    }
    else if (range) {
        if (self.failFirstPrefixProbe && [range isEqual:@"bytes=0-1048575"] && !self.prefixProbeFailed) {
            self.prefixProbeFailed=YES;
            delay=0.05;
            r.error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        } else {
            unsigned long long lo=0,hi=0; sscanf(range.UTF8String,"bytes=%llu-%llu",&lo,&hi);
            NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)(hi-lo+1)];
            for (NSNumber *key in self.segments){NSData *part=self.segments[key];uint64_t at=key.unsignedLongLongValue;uint64_t begin=MAX(lo,at),end=MIN(hi+1,at+part.length);if(end>begin)memcpy((uint8_t *)data.mutableBytes+begin-lo,(const uint8_t *)part.bytes+begin-at,(NSUInteger)(end-begin));}
            r.data=data; status=206; self.bytes+=data.length;
            hdr[@"Content-Range"]=[NSString stringWithFormat:@"bytes %llu-%llu/%llu",lo,hi,self.total];
            hdr[@"Content-Length"]=@(data.length).stringValue;
        }
    } else r.error=[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBudgetExceeded userInfo:nil];
    r.response=[[NSHTTPURLResponse alloc]initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:hdr];
    if (!poster) {
        if (!self.mediaSpans) self.mediaSpans=[NSMutableArray array];
        double start=CFAbsoluteTimeGetCurrent();
        [self.mediaSpans addObject:@[@(start),@(start+delay)]];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(!token.cancelled)done(r);});
    return token;
}
@end

static UFSlowTransport *MakeMovieTransport(BOOL tail) {
    NSData *ftyp=UFBox("ftyp",[NSMutableData dataWithLength:16]);
    NSData *free=UFBox("free",[NSMutableData dataWithLength:8]);
    NSData *moov=UFMovieMoov();
    NSMutableData *mdatHeader=[NSMutableData dataWithLength:8];
    Put32(mdatHeader,0,64*1024*1024); memcpy((uint8_t *)mdatHeader.mutableBytes+4,"mdat",4);
    uint64_t mdatAt, moovAt, total;
    if (tail) { mdatAt=ftyp.length; moovAt=mdatAt+64*1024*1024; total=moovAt+moov.length; }
    else { moovAt=ftyp.length+free.length; mdatAt=moovAt+moov.length; total=mdatAt+64*1024*1024; }
    UFSlowTransport *t=[UFSlowTransport new];
    t.tail=tail; t.events=[NSMutableArray new];
    t.mediaDelay=0.4; t.posterDelay=0.05;
    t.total=total;
    t.segments=tail?@{@0:ftyp,@(mdatAt):mdatHeader,@(moovAt):moov}:@{@0:ftyp,@(ftyp.length):free,@(moovAt):moov,@(mdatAt):mdatHeader};
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    t.png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return t;
}

// 一次订阅：记录 duration/dimensions/size/preview 首次 Known 的时间与终态。
static void RunMetadataCase(UFSlowTransport *t, double budget,
                            double *outDuration, double *outDimensions, double *outSize, double *outPreview,
                            RDMetadataSnapshot **outTerminal) {
    RDMetadataService *service=[[RDMetadataService alloc]initWithTransport:t];
    DetectedMedia *m=[DetectedMedia new];
    m.mediaURL=@"https://fixture.invalid/movie.mp4";
    m.poster=@"https://fixture.invalid/poster.png";
    m.resourceKind=RDResourceKindVideo;
    __block double firstPreview=-1, firstDuration=-1, firstDimensions=-1, firstSize=-1;
    __block RDMetadataSnapshot *terminal=nil;
    t.started=CFAbsoluteTimeGetCurrent();
    RDMetadataToken *token=[service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s){
        double e=CFAbsoluteTimeGetCurrent()-t.started;
        if (firstPreview<0 && s.preview.state==RDMetadataKnown) firstPreview=e;
        if (firstDuration<0 && s.duration.state==RDMetadataKnown) firstDuration=e;
        if (firstDimensions<0 && s.dimensions.state==RDMetadataKnown) firstDimensions=e;
        if (firstSize<0 && s.size.state==RDMetadataKnown) firstSize=e;
        if (s.preview.state!=RDMetadataLoading && s.duration.state!=RDMetadataLoading
            && s.size.state!=RDMetadataLoading && s.dimensions.state!=RDMetadataLoading) terminal=s;
    }];
    BOOL finished=Wait(^BOOL{ return terminal!=nil; }, budget);
    Check(finished, @"元数据订阅在预算时间内到达终态");
    [token cancel];
    *outDuration=firstDuration; *outDimensions=firstDimensions;
    *outSize=firstSize; *outPreview=firstPreview; *outTerminal=terminal;
}

// P1：头部 moov、普通请求 0.4s/海报 0.05s。时长/尺寸不得走五次串行往返。
static void P1_HeadMoovWithinTwoRoundTrips(void) {
    UFSlowTransport *t=MakeMovieTransport(NO);
    double duration,dimensions,size,preview; RDMetadataSnapshot *terminal=nil;
    RunMetadataCase(t,15,&duration,&dimensions,&size,&preview,&terminal);
    NSLog(@"PERF P1 head-moov: preview=%.3f duration=%.3f dimensions=%.3f size=%.3f requests=%lu bytes=%lu",
          preview,duration,dimensions,size,(unsigned long)t.events.count,(unsigned long)t.bytes);
    for (NSString *e in t.events) NSLog(@"P1 REQUEST %@",e);
    Check(terminal.duration.state==RDMetadataKnown && [terminal.duration.value doubleValue]==12.5, @"P1 时长值正确 12.5s");
    NSSize dims=[(NSValue *)terminal.dimensions.value sizeValue];
    Check(terminal.dimensions.state==RDMetadataKnown && dims.width==180 && dims.height==320, @"P1 尺寸值正确 180x320（旋转后）");
    Check([terminal.size.value longLongValue]==(long long)t.total, @"P1 大小值等于文件总长");
    Check(preview>=0 && preview<=0.2, [NSString stringWithFormat:@"P1 缩略图（海报）仍快速出现（%.3fs）",preview]);
    Check(duration<=1.2, [NSString stringWithFormat:@"P1 时长在两个 0.4s 往返内出现（实际 %.3fs）",duration]);
    Check(dimensions<=1.2, [NSString stringWithFormat:@"P1 尺寸在两个 0.4s 往返内出现（实际 %.3fs）",dimensions]);
    Check(size<=1.2, [NSString stringWithFormat:@"P1 大小在两个 0.4s 往返内出现（实际 %.3fs）",size]);
    Check(t.events.count<=4, [NSString stringWithFormat:@"P1 请求数受控（实际 %lu）",(unsigned long)t.events.count]);
    // 前缀探测窗口自 2026-09-10 起为 1MB（`bytes=0-1048575`，详情提速：本站
    // faststart 文件 moov 在偏移 1024，1KB 窗口需要 3 次串行往返）。因此传输量
    // 的上界是「前缀窗口 + moov 段」，绝不允许接近 64MiB 的 mdat / 整片体积。
    Check(t.bytes<=2*1024*1024 && t.bytes<t.total/8,
          [NSString stringWithFormat:@"P1 传输量受前缀窗口限制、远小于文件体积（实际 %lu / 总长 %llu）",
           (unsigned long)t.bytes,t.total]);
}

// P2：尾部 moov（mdat 之后）：按合法 atom 偏移跳过 mdat，不得扫描媒体数据。
static void P2_TailMoovSkipsMdat(void) {
    UFSlowTransport *t=MakeMovieTransport(YES);
    double duration,dimensions,size,preview; RDMetadataSnapshot *terminal=nil;
    RunMetadataCase(t,15,&duration,&dimensions,&size,&preview,&terminal);
    NSLog(@"PERF P2 tail-moov: preview=%.3f duration=%.3f dimensions=%.3f size=%.3f requests=%lu bytes=%lu",
          preview,duration,dimensions,size,(unsigned long)t.events.count,(unsigned long)t.bytes);
    for (NSString *e in t.events) NSLog(@"P2 REQUEST %@",e);
    Check(terminal.duration.state==RDMetadataKnown && [terminal.duration.value doubleValue]==12.5, @"P2 尾部 moov 时长正确");
    NSSize dims=[(NSValue *)terminal.dimensions.value sizeValue];
    Check(terminal.dimensions.state==RDMetadataKnown && dims.width==180 && dims.height==320, @"P2 尾部 moov 尺寸正确");
    Check([terminal.size.value longLongValue]==(long long)t.total, @"P2 大小等于总长");
    Check(duration<=1.6, [NSString stringWithFormat:@"P2 尾部 moov 时长在四次往返内出现（实际 %.3fs）",duration]);
    Check(t.events.count<=5, [NSString stringWithFormat:@"P2 请求数受控（实际 %lu）",(unsigned long)t.events.count]);
    // 尾部 moov：1MB 前缀窗口 + 按 atom 偏移直接跳到 moov，绝不传输 64MiB mdat
    //（若发生 mdat 扫描，传输量会是 MiB 级以上的整段媒体数据）。
    Check(t.bytes<=2*1024*1024 && t.bytes<t.total/8,
          [NSString stringWithFormat:@"P2 未扫描 64MiB mdat（传输 %lu / 总长 %llu）",
           (unsigned long)t.bytes,t.total]);
}

// P3：前缀探测临时超时一次（自动重试）后仍得到正确元数据。
static void P3_TransientProbeTimeoutRecovers(void) {
    UFSlowTransport *t=MakeMovieTransport(NO);
    t.failFirstPrefixProbe=YES;
    double duration,dimensions,size,preview; RDMetadataSnapshot *terminal=nil;
    RunMetadataCase(t,15,&duration,&dimensions,&size,&preview,&terminal);
    NSLog(@"PERF P3 transient-timeout: duration=%.3f dimensions=%.3f size=%.3f requests=%lu bytes=%lu",
          duration,dimensions,size,(unsigned long)t.events.count,(unsigned long)t.bytes);
    Check(terminal.duration.state==RDMetadataKnown && [terminal.duration.value doubleValue]==12.5, @"P3 临时超时重试后时长正确");
    Check(terminal.dimensions.state==RDMetadataKnown, @"P3 临时超时重试后尺寸正确");
    Check(t.events.count<=6, [NSString stringWithFormat:@"P3 重试后请求数受控（实际 %lu）",(unsigned long)t.events.count]);
}

// P4：取消订阅：在途请求被取消，之后不再发出新请求。
static void P4_CancelStopsRequests(void) {
    UFSlowTransport *t=MakeMovieTransport(NO);
    RDMetadataService *service=[[RDMetadataService alloc]initWithTransport:t];
    DetectedMedia *m=[DetectedMedia new];
    m.mediaURL=@"https://fixture.invalid/movie.mp4";
    m.poster=@"https://fixture.invalid/poster.png";
    m.resourceKind=RDResourceKindVideo;
    t.started=CFAbsoluteTimeGetCurrent();
    RDMetadataToken *token=[service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s){}];
    Wait(^BOOL{ return NO; },0.15);
    NSUInteger fired=t.events.count;
    Check(fired>=2, [NSString stringWithFormat:@"P4 取消前已有请求在途（%lu）",(unsigned long)fired]);
    [token cancel];
    Wait(^BOOL{ return NO; },1.0);
    NSUInteger after=t.events.count;
    NSLog(@"P4 fired=%lu afterCancel=%lu cancellations=%lu",(unsigned long)fired,(unsigned long)after,(unsigned long)t.cancellations);
    Check(t.cancellations>0, @"P4 底层请求被真正取消");
    Check(after<=fired+1, [NSString stringWithFormat:@"P4 取消后不再连环发起新请求（%lu → %lu）",(unsigned long)fired,(unsigned long)after]);
}

// P5：服务器不支持 Range（200 + BudgetExceeded）：大小仍取响应头长度，流程不悬挂。
static void P5_NoRangeServerStillTerminates(void) {
    UFSlowTransport *t=MakeMovieTransport(NO);
    t.ignoreRange=YES;
    RDMetadataService *service=[[RDMetadataService alloc]initWithTransport:t];
    DetectedMedia *m=[DetectedMedia new];
    m.mediaURL=@"https://fixture.invalid/movie.mp4";
    m.resourceKind=RDResourceKindVideo;
    __block RDMetadataSnapshot *terminal=nil;
    t.started=CFAbsoluteTimeGetCurrent();
    RDMetadataToken *token=[service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s){
        if (s.preview.state!=RDMetadataLoading && s.duration.state!=RDMetadataLoading
            && s.size.state!=RDMetadataLoading && s.dimensions.state!=RDMetadataLoading) terminal=s;
    }];
    Check(Wait(^BOOL{ return terminal!=nil; },12), @"P5 不支持 Range 时仍到达终态（不悬挂）");
    [token cancel];
    NSLog(@"P5 sizeState=%ld sizeValue=%@ durationState=%ld requests=%lu",
          (long)terminal.size.state, terminal.size.value, (long)terminal.duration.state, (unsigned long)t.events.count);
    Check(terminal.size.state==RDMetadataKnown && [terminal.size.value longLongValue]==(long long)t.total,
          @"P5 无 Range 时大小来自完整响应头长度");
}

#pragma mark - 问题三：重复行（同一 video 元素内未知画质/共享地址）

// D9：同一 video 元素内 video.src + 无画质 source：未知画质不能伪造标准档，
// 但绝不能作为第二行（修复前：2 行）。
static void D9_UnknownQualityMembersStayInOneRow(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/playing.mp4'>"
        @"<source src='https://fixture.invalid/extra.mp4'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    Check(r.media.count == 2, [NSString stringWithFormat:@"D9 同一 video 内两个候选都被发现（实际 %lu）", (unsigned long)r.media.count]);
    NSString *family = r.media.firstObject.videoFamilyID;
    Check(family.length > 0, @"D9 同一 video 元素写入稳定 family ID");
    for (DetectedMedia *m in r.media) Check([m.videoFamilyID isEqualToString:family], @"D9 成员共享同一 family ID");
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D9 rows=%lu urls=%@", (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]);
    Check(rows.count == 1, [NSString stringWithFormat:@"D9 未知画质成员不产生第二行（实际 %lu 行：%@）",
          (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]]);
    Check(rows.firstObject.declaredVariants.count == 0, @"D9 未知画质不伪造标准档");
}

// D10：同一 video 内非标准像素（800x800）的 source：不归档为档位，也不产生第二行。
static void D10_NonStandardPixelMembersStayInOneRow(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/playing.mp4'>"
        @"<source src='https://fixture.invalid/a.mp4' width='800' height='800'>"
        @"<source src='https://fixture.invalid/b.mp4' width='800' height='800'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D10 rows=%lu urls=%@", (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]);
    Check(r.media.count == 3, @"D10 三个成员都被发现");
    Check(rows.count == 1, [NSString stringWithFormat:@"D10 非标准像素成员不产生额外行（实际 %lu）", (unsigned long)rows.count]);
    Check(rows.firstObject.declaredVariants.count == 0, @"D10 非标准像素不伪装档位");
}

// D11：同一地址被两个 video 块共享：首次分组身份保持，第二个块的其他成员
// 不得被吞掉（修复前 c.mp4 从列表消失）。
static void D11_SharedURLKeepsAllBlockMembersVisible(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body>"
        @"<video><source src='https://fixture.invalid/a.mp4' size='480'><source src='https://fixture.invalid/b.mp4' size='480'></video>"
        @"<video><source src='https://fixture.invalid/b.mp4' size='480'><source src='https://fixture.invalid/c.mp4' size='480'></video>"
        @"</body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray *urls = [rows valueForKey:@"mediaURL"];
    NSLog(@"D11 rows=%lu urls=%@", (unsigned long)rows.count, urls);
    Check(rows.count == 2, [NSString stringWithFormat:@"D11 两个播放器块各占一行（实际 %lu）", (unsigned long)rows.count]);
    Check([urls containsObject:@"https://fixture.invalid/c.mp4"], @"D11 第二块的非共享成员仍可见（未被吞掉）");
}

// D12：静态 + 动态桥接合并后仍一行，family ID 不丢（防回归）。
static void D12_DynamicBridgeKeepsFamilyGrouping(void) {
    NSString *dynamic = [RDBridgeEventSynthesizer syntheticHTMLForEvent:@{
        @"action": @"resource", @"url": kPlaying, @"kind": @"video",
        @"durationSeconds": @120, @"pixelWidth": @854, @"pixelHeight": @480,
        @"poster": @"https://fixture.invalid/poster.png",
    }];
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:[FixtureVideoSrc() stringByAppendingString:dynamic]
                                          baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSLog(@"D12 rows=%lu urls=%@", (unsigned long)rows.count, [rows valueForKey:@"mediaURL"]);
    Check(rows.count == 1, @"D12 静态+动态桥接合并后一行");
    for (DetectedMedia *m in r.media) Check(m.videoFamilyID.length > 0, @"D12 动态元数据合并后 family ID 不丢");
    DetectedMedia *playing = nil;
    for (DetectedMedia *m in r.media) if ([m.mediaURL isEqual:kPlaying]) playing = m;
    Check(playing != nil && playing.durationSeconds.doubleValue == 120, @"D12 动态时长合并到 playing 成员");
}

#pragma mark - 问题三：缓存复用（真实 RDMetadataService + 真实 App 详情订阅）

static DetectedMedia *UFMovieMedia(NSString *url, NSString *poster) {
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = url;
    m.poster = poster;
    m.resourceKind = RDResourceKindVideo;
    m.format = @"mp4";
    m.title = @"缓存测试视频";
    return m;
}

static ResourceDetectorAppDelegate *MakeRealMetadataApp(RDMetadataService *service,
                                                        NSArray<DetectedMedia *> *results,
                                                        NSImageView **outThumb) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.metadataService = service;
    app.durationCache = [NSMutableDictionary dictionary];
    app.results = [results mutableCopy];
    UFChainTable *table = [UFChainTable new];
    table.row = [UFChainRow new];
    app.table = (NSTableView *)table;
    app.variantPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 20) pullsDown:NO];
    app.linkField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    app.thumbView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 120, 68)];
    app.thumbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 20)];
    if (outThumb) *outThumb = app.thumbView;
    return app;
}

static NSUInteger UFCountPath(UFSlowTransport *t, NSString *path) {
    NSUInteger count = 0;
    for (NSString *p in t.requestPaths) if ([p isEqualToString:path]) count++;
    return count;
}
static RDMetadataSnapshot *UFReadMetadata(RDMetadataService *service, DetectedMedia *m) {    __block RDMetadataSnapshot *terminal = nil;
    RDMetadataToken *token = [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {
        if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading
            && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) terminal = s;
    }];
    Wait(^BOOL { return terminal != nil; }, 15);
    [token cancel];
    return terminal;
}

// C1：字段级缓存——海报成功、媒体字段失败时，成功字段必须可复用，失败字段仍会重试。
static void C1_PartialSuccessFieldsSurviveFailure(void) {
    UFSlowTransport *t = MakeMovieTransport(NO);
    t.failMedia = YES;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    DetectedMedia *m = UFMovieMedia(@"https://fixture.invalid/movie.mp4", @"https://fixture.invalid/poster.png");
    t.started = CFAbsoluteTimeGetCurrent();
    __block RDMetadataSnapshot *first = nil;
    RDMetadataToken *token = [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {
        if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading
            && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) first = s;
    }];
    Check(Wait(^BOOL { return first != nil; }, 10), @"C1 首次订阅到达终态");
    Check(first.preview.state == RDMetadataKnown, @"C1 海报成功，缩略图字段为已知");
    Check(first.duration.state != RDMetadataKnown, @"C1 媒体字段显式失败/未知，不伪装成功");
    [token cancel];
    NSUInteger posters = t.posterRequests, media = t.mediaRequests;
    __block RDMetadataSnapshot *second = nil;
    RDMetadataToken *again = [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {
        if (second == nil && s.preview.state == RDMetadataKnown) second = s;
    }];
    Check(Wait(^BOOL { return second != nil; }, 3), @"C1 再次订阅立即收到已缓存的缩略图");
    Check(t.posterRequests == posters, [NSString stringWithFormat:@"C1 成功字段不重复请求海报（%lu → %lu）",
          (unsigned long)posters, (unsigned long)t.posterRequests]);
    Check(Wait(^BOOL { return t.mediaRequests > media; }, 3), @"C1 失败字段仍会重试，不缓存成永久空白");
    [again cancel];
}

// C2：真实 App 详情订阅 A → B → A：缩略图同步立即恢复，且不重复已完成请求。
static void C2_AppReselectRestoresThumbnailWithoutRepeatRequests(void) {
    UFSlowTransport *t = MakeMovieTransport(YES);
    t.mediaDelay = 0.4; t.posterDelay = 0.05;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    DetectedMedia *a = UFMovieMedia(@"https://fixture.invalid/movie-a.mp4", @"https://fixture.invalid/poster-a.png");
    DetectedMedia *b = UFMovieMedia(@"https://fixture.invalid/movie-b.mp4", @"https://fixture.invalid/poster-b.png");
    NSImageView *thumb = nil;
    ResourceDetectorAppDelegate *app = MakeRealMetadataApp(service, @[a, b], &thumb);
    t.started = CFAbsoluteTimeGetCurrent();
    [app configureDetailForMedia:a];
    Check(Wait(^BOOL { return thumb.image != nil; }, 3), @"C2 首次打开缩略图出现（海报）");
    Wait(^BOOL { return NO; }, 0.12);   // 详情仍在途（moov 在尾部，0.4s+）
    NSUInteger aPosters = UFCountPath(t, @"/poster-a.png"), aMedia = UFCountPath(t, @"/movie-a.mp4");
    [app configureDetailForMedia:b];    // 切换离开：取消 A 的订阅
    Check(thumb.image == nil, @"C2 切换到不同海报的媒体后缩略图清空");
    [app configureDetailForMedia:a];    // 立即切回
    Check(thumb.image != nil, @"C2 切回后缩略图同步立即恢复（不得先清空再等网络）");
    Wait(^BOOL { return NO; }, 0.2);
    Check(UFCountPath(t, @"/poster-a.png") == aPosters, [NSString stringWithFormat:@"C2 切回不重复请求海报（%lu → %lu）",
          (unsigned long)aPosters, (unsigned long)UFCountPath(t, @"/poster-a.png")]);
    Check(UFCountPath(t, @"/movie-a.mp4") <= aMedia + 1, [NSString stringWithFormat:@"C2 切回只补缺失字段（A 的媒体请求 %lu → %lu）",
          (unsigned long)aMedia, (unsigned long)UFCountPath(t, @"/movie-a.mp4")]);
    Check(Wait(^BOOL { return a.pixelWidth == 180; }, 5), @"C2 切回后详情继续完成");
}

// C3：同一 URL 的不同规范化写法命中同一缓存；不同媒体不串数据。
static void C3_CanonicalURLFormsShareCacheAndNoCrossHit(void) {
    UFSlowTransport *t = MakeMovieTransport(NO);
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    DetectedMedia *m1 = UFMovieMedia(@"https://fixture.invalid/movie.mp4", @"https://fixture.invalid/poster.png");
    RDMetadataSnapshot *first = UFReadMetadata(service, m1);
    Check(first != nil && first.duration.state == RDMetadataKnown, @"C3 首次读取成功并进入缓存");
    NSUInteger requests = t.events.count;
    DetectedMedia *m2 = UFMovieMedia(@"HTTPS://FIXTURE.INVALID:443/movie.mp4", @"https://fixture.invalid/poster.png");
    RDMetadataSnapshot *second = UFReadMetadata(service, m2);
    NSLog(@"C3 canonical: requests %lu → %lu, duration=%@", (unsigned long)requests, (unsigned long)t.events.count, second.duration.value);
    Check(t.events.count == requests, [NSString stringWithFormat:@"C3 同 URL 不同写法命中同一缓存（请求 %lu → %lu）",
          (unsigned long)requests, (unsigned long)t.events.count]);
    Check(second.duration.state == RDMetadataKnown && [second.duration.value doubleValue] == 12.5, @"C3 缓存值正确");
    DetectedMedia *other = UFMovieMedia(@"https://fixture.invalid/other.mp4", @"https://fixture.invalid/poster.png");
    t.total += 64 * 1024;   // 不同媒体必须重新请求（不得误命中）
    RDMetadataSnapshot *third = UFReadMetadata(service, other);
    Check(t.events.count > requests && third != nil, @"C3 不同媒体不串数据且重新请求");
}

// C4：取消（切换离开）后，已完成的字段缓存不得丢失；再次订阅命中缓存。
static void C4_CancelKeepsCompletedFieldCache(void) {
    UFSlowTransport *t = MakeMovieTransport(YES);
    t.mediaDelay = 0.6; t.posterDelay = 0.05;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    DetectedMedia *m = UFMovieMedia(@"https://fixture.invalid/movie.mp4", @"https://fixture.invalid/poster.png");
    t.started = CFAbsoluteTimeGetCurrent();
    RDMetadataToken *token = [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {}];
    Check(Wait(^BOOL { return t.posterRequests >= 1; }, 1), @"C4 海报请求已发出");
    Wait(^BOOL { return NO; }, 0.15);
    [token cancel];                     // 媒体请求仍在途时切换离开
    Wait(^BOOL { return NO; }, 0.7);
    NSUInteger posters = t.posterRequests;
    __block RDMetadataSnapshot *second = nil;
    RDMetadataToken *again = [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {
        if (second == nil && s.preview.state == RDMetadataKnown) second = s;
    }];
    Check(Wait(^BOOL { return second != nil; }, 2), @"C4 取消后再次订阅仍命中已完成的缩略图缓存");
    Check(t.posterRequests == posters, [NSString stringWithFormat:@"C4 取消不丢已完成缓存（海报请求 %lu → %lu）",
          (unsigned long)posters, (unsigned long)t.posterRequests]);
    [again cancel];
}

// C5：预取与用户点击共享同一在途 work：点击已预取媒体不重复发请求。
static void C5_PrefetchAndClickShareInflightWork(void) {
    UFSlowTransport *t = MakeMovieTransport(NO);
    t.mediaDelay = 0.6; t.posterDelay = 0.05;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    DetectedMedia *m = UFMovieMedia(@"https://fixture.invalid/movie.mp4", @"https://fixture.invalid/poster.png");
    t.started = CFAbsoluteTimeGetCurrent();
    RDMetadataToken *prefetch = [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {}];
    Check(Wait(^BOOL { return t.posterRequests >= 1 && t.mediaRequests >= 1; }, 2), @"C5 预取已发出底层请求");
    NSUInteger media = t.mediaRequests, posters = t.posterRequests;
    NSImageView *thumb = nil;
    ResourceDetectorAppDelegate *app = MakeRealMetadataApp(service, @[m], &thumb);
    [app configureDetailForMedia:m];    // 用户点击同一项
    Check(Wait(^BOOL { return thumb.image != nil; }, 3), @"C5 点击后缩略图可用");
    Check(t.mediaRequests == media, [NSString stringWithFormat:@"C5 点击不重复媒体请求（%lu → %lu）",
          (unsigned long)media, (unsigned long)t.mediaRequests]);
    Check(t.posterRequests == posters, [NSString stringWithFormat:@"C5 点击不重复海报请求（%lu → %lu）",
          (unsigned long)posters, (unsigned long)t.posterRequests]);
    [prefetch cancel];
}

// C6：显式 reload 才清除成功缓存（重新读取）；不同媒体不互相污染。
static void C6_ReloadExplicitlyClearsSuccessCache(void) {
    UFSlowTransport *t = MakeMovieTransport(NO);
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    DetectedMedia *m = UFMovieMedia(@"https://fixture.invalid/movie.mp4", @"https://fixture.invalid/poster.png");
    UFReadMetadata(service, m);
    NSUInteger requests = t.events.count;
    __block RDMetadataSnapshot *terminal = nil;
    RDMetadataToken *token = [service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *s) {
        if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading
            && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) terminal = s;
    }];
    Check(Wait(^BOOL { return terminal != nil; }, 10), @"C6 reload 重新读取完成");
    Check(t.events.count > requests, @"C6 reload 明确清除成功缓存并重新请求");
    [token cancel];
}

#pragma mark - 问题三：性能（相同夹具 + 固定 0.4s 延迟的前后对照）

// P6：点击排在预取队列后面的资源，缩略图不得等待详情 work 队列。
static void P6_ClickedThumbnailIndependentOfDetailQueue(void) {
    UFSlowTransport *t = MakeMovieTransport(YES);
    t.mediaDelay = 1.0; t.posterDelay = 0.05;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:t];
    NSMutableArray<DetectedMedia *> *results = [NSMutableArray array];
    for (NSUInteger i = 0; i < 12; i++) {
        DetectedMedia *m = UFMovieMedia([NSString stringWithFormat:@"https://fixture.invalid/movie-%lu.mp4", (unsigned long)i],
                                        @"https://fixture.invalid/poster.png");
        m.title = [NSString stringWithFormat:@"视频%lu", (unsigned long)i];
        [results addObject:m];
    }
    t.started = CFAbsoluteTimeGetCurrent();
    NSMutableArray<RDMetadataToken *> *prefetch = [NSMutableArray array];
    for (DetectedMedia *m in results) [prefetch addObject:[service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {}]];
    Wait(^BOOL { return NO; }, 0.15);   // 并发槽占满，其余排队
    NSImageView *thumb = nil;
    ResourceDetectorAppDelegate *app = MakeRealMetadataApp(service, results, &thumb);
    NSDate *clickAt = NSDate.date;
    [app configureDetailForMedia:results[10]];
    BOOL appeared = Wait(^BOOL { return thumb.image != nil; }, 1.0);
    double elapsed = -[clickAt timeIntervalSinceNow];
    NSLog(@"PERF P6 clicked-thumbnail elapsed=%.3fs posterRequests=%lu mediaRequests=%lu",
          elapsed, (unsigned long)t.posterRequests, (unsigned long)t.mediaRequests);
    Check(appeared && elapsed < 0.5, [NSString stringWithFormat:@"P6 缩略图不等待详情队列（实际 %.3fs）", elapsed]);
    for (RDMetadataToken *token in prefetch) [token cancel];
}

// P7：大文件详情：前缀探测与 moov 读取不得重叠，不得发 HEAD，不得重跑本体 GET。
static void P7_NoOverlappingMediaRequestsAndStagedFields(void) {
    UFSlowTransport *t = MakeMovieTransport(YES);
    double duration, dimensions, size, preview; RDMetadataSnapshot *terminal = nil;
    RunMetadataCase(t, 15, &duration, &dimensions, &size, &preview, &terminal);
    NSUInteger overlaps = 0;
    for (NSUInteger i = 0; i < t.mediaSpans.count; i++)
        for (NSUInteger j = i + 1; j < t.mediaSpans.count; j++) {
            double s1 = t.mediaSpans[i][0].doubleValue, e1 = t.mediaSpans[i][1].doubleValue;
            double s2 = t.mediaSpans[j][0].doubleValue, e2 = t.mediaSpans[j][1].doubleValue;
            if (s1 < e2 - 0.01 && s2 < e1 - 0.01) overlaps++;
        }
    BOOL anyHead = NO;
    for (NSString *e in t.events) if ([e containsString:@" HEAD "]) anyHead = YES;
    NSLog(@"PERF P7 tail-moov: size=%.3f duration=%.3f preview=%.3f totalRequests=%lu mediaRequests=%lu overlaps=%lu",
          size, duration, preview, (unsigned long)t.events.count, (unsigned long)t.mediaRequests, (unsigned long)overlaps);
    for (NSString *e in t.events) NSLog(@"P7 REQUEST %@", e);
    Check(overlaps == 0, [NSString stringWithFormat:@"P7 媒体请求不重叠（实际 %lu 对）", (unsigned long)overlaps]);
    Check(!anyHead, @"P7 视频详情路径不发送 HEAD");
    Check(t.mediaRequests <= 2, [NSString stringWithFormat:@"P7 大文件媒体请求 ≤2（前缀探测 + 一次 moov 读取，实际 %lu）",
          (unsigned long)t.mediaRequests]);
    Check(t.events.count <= 3, [NSString stringWithFormat:@"P7 总请求数 ≤3（实际 %lu）", (unsigned long)t.events.count]);
    Check(size > 0 && duration > 0 && size <= duration,
          [NSString stringWithFormat:@"P7 大小先于时长发布（size=%.3fs duration=%.3fs）", size, duration]);
}

#pragma mark - 问题一补强：同一地址的画质声明不得被成员去重吞掉

// A：video.src 与 480p source 同址：source 上的 size=480 必须仍然参与归一化。
static void D13_VideoSrcMatchesLabelledSourceKeepsBothTiers(void) {
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D13 candidates=%lu rows=%lu labels=%@ rep=%@", (unsigned long)r.media.count, (unsigned long)rows.count,
          labels, rows.firstObject.mediaURL);
    Check(r.media.count == 2, [NSString stringWithFormat:@"D13 候选数 2（实际 %lu）", (unsigned long)r.media.count]);
    Check(rows.count == 1, [NSString stringWithFormat:@"D13 一行（实际 %lu）", (unsigned long)rows.count]);
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D13 video.src 同址的 source 声明必须保留 480p+720p（实际 %@）", labels]);
    Check([UFVariantURL(rows.firstObject, @"480p") hasSuffix:@"480.mp4"] && [UFVariantURL(rows.firstObject, @"720p") hasSuffix:@"720.mp4"],
          @"D13 两个档位分别指向 480.mp4 / 720.mp4");
    for (DetectedMedia *m in r.media)
        Check([UFVariantLabels(m) isEqualToArray:@[@"480p", @"720p"]], @"D13 全部成员共享同一份 480p/720p");
}

// B：video.src 与 720p source 同址：档位集合不变。
static void D14_VideoSrcMatches720SourceKeepsBothTiers(void) {
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/720.mp4'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D14 candidates=%lu rows=%lu labels=%@ rep=%@", (unsigned long)r.media.count, (unsigned long)rows.count,
          labels, rows.firstObject.mediaURL);
    Check(rows.count == 1, [NSString stringWithFormat:@"D14 一行（实际 %lu）", (unsigned long)rows.count]);
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D14 video.src 同址的 source 声明必须保留 480p+720p（实际 %@）", labels]);
}

// C：调换 source 顺序：档位集合不因先后顺序丢失。
static void D15_SourceOrderDoesNotChangeTierSet(void) {
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D15 candidates=%lu rows=%lu labels=%@", (unsigned long)r.media.count, (unsigned long)rows.count, labels);
    Check(rows.count == 1, @"D15 一行");
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D15 调换顺序后档位集合仍为 480p+720p（实际 %@）", labels]);
}

// D：同一 URL 先以无画质 source 出现、后以带 size/label 的 source 出现：
// 有效画质声明必须保留（去重只去地址，不去声明）。
static void D16_BareThenLabelledDuplicateKeepsDeclaration(void) {
    RDProbeResult *bareFirst = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video><source src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [bareFirst.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D16a candidates=%lu rows=%lu labels=%@", (unsigned long)bareFirst.media.count, (unsigned long)rows.count, labels);
    Check(rows.count == 1, @"D16a 一行");
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D16a 先无画质后带声明的同址 source 保留档位（实际 %@）", labels]);
    // 反向：先带声明、后无画质（不得把已收集的声明清掉）。
    RDProbeResult *labelledFirst = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video><source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    app.results = [labelledFirst.media mutableCopy];
    rows = app.visibleMedia;
    labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D16b candidates=%lu rows=%lu labels=%@", (unsigned long)labelledFirst.media.count, (unsigned long)rows.count, labels);
    Check(rows.count == 1, @"D16b 一行");
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D16b 先带声明后无画质的同址 source 保留档位（实际 %@）", labels]);
}

// E：同一 URL 重复出现相同画质声明：不产生重复选项或重复行。
static void D17_RepeatedIdenticalDeclarationNoDuplicateOption(void) {
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D17 candidates=%lu rows=%lu labels=%@", (unsigned long)r.media.count, (unsigned long)rows.count, labels);
    Check(r.media.count == 2, [NSString stringWithFormat:@"D17 同址候选按 URL 去重后仍 2 个（实际 %lu）", (unsigned long)r.media.count]);
    Check(rows.count == 1, @"D17 一行");
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D17 恰好两个选项、无重复 480p（实际 %@）", labels]);
}

// F：同一 URL 的 width/height 声明也必须被收集（不能只修 size）。
static void D18_WidthHeightOnDuplicateMemberCollected(void) {
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/720.mp4'>"
        @"<source src='https://fixture.invalid/720.mp4' width='1280' height='720'>"
        @"<source src='https://fixture.invalid/480.mp4' width='854' height='480'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [r.media mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSArray<NSString *> *labels = UFVariantLabels(rows.firstObject);
    NSLog(@"D18 candidates=%lu rows=%lu labels=%@", (unsigned long)r.media.count, (unsigned long)rows.count, labels);
    Check(rows.count == 1, @"D18 一行");
    Check([labels isEqualToArray:@[@"480p", @"720p"]],
          [NSString stringWithFormat:@"D18 width/height 声明同样被收集（实际 %@）", labels]);
    Check([UFVariantURL(rows.firstObject, @"720p") hasSuffix:@"720.mp4"] && [UFVariantURL(rows.firstObject, @"480p") hasSuffix:@"480.mp4"],
          @"D18 两个档位分别指向 720.mp4 / 480.mp4");
}

// G：真实 App 选择 + downloadSelected: 分别选择 480p、720p，实际 enqueue 参数一致。
static void D19_BothTiersSelectableAndEnqueueMatches(void) {
    UFChainMetadataService *service; UFEnqueueSpyManager *spy; UFChainTable *table;
    ResourceDetectorAppDelegate *app = MakeChainApp(&service, &spy, &table);
    RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src='https://fixture.invalid/480.mp4'>"
        @"<source src='https://fixture.invalid/480.mp4' size='480'>"
        @"<source src='https://fixture.invalid/720.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://fixture.invalid/"]];
    [app.results addObjectsFromArray:r.media];
    [app configureDetailForMedia:app.visibleMedia.firstObject];
    Check([app.variantPicker.itemTitles containsObject:@"480p"] && [app.variantPicker.itemTitles containsObject:@"720p"],
          [NSString stringWithFormat:@"D19 选择器同时提供 480p/720p（实际 %@）", app.variantPicker.itemTitles]);
    // 选择 480p：详情、链接、入队三处一致。
    [app.variantPicker selectItemWithTitle:@"480p"];
    [app selectDeclaredVariant:nil];
    Check([app.variantPicker.selectedItem.title isEqualToString:@"480p"], @"D19 当前选择为 480p");
    Check([app.detailMedia.mediaURL hasSuffix:@"480.mp4"], [NSString stringWithFormat:@"D19 详情为 480.mp4（实际 %@）", app.detailMedia.mediaURL]);
    Check([app.linkField.stringValue hasSuffix:@"480.mp4"], @"D19 复制链接为 480.mp4");
    [app downloadSelected:nil];
    Check(spy.enqueued.count == 1 && [spy.enqueued.lastObject[@"url"] hasSuffix:@"480.mp4"],
          [NSString stringWithFormat:@"D19 实际入队 480.mp4（实际 %@）", spy.enqueued.lastObject[@"url"]]);
    Check([spy.enqueued.lastObject[@"kind"] integerValue] == DownloadResourceVideo, @"D19 480p 按视频类型入队");
    // 选择 720p：三处同步切换，入队目标为 720.mp4。
    [app.variantPicker selectItemWithTitle:@"720p"];
    [app selectDeclaredVariant:nil];
    Check([app.variantPicker.selectedItem.title isEqualToString:@"720p"], @"D19 当前选择为 720p");
    Check([app.detailMedia.mediaURL hasSuffix:@"720.mp4"], [NSString stringWithFormat:@"D19 详情为 720.mp4（实际 %@）", app.detailMedia.mediaURL]);
    Check([app.linkField.stringValue hasSuffix:@"720.mp4"], @"D19 复制链接为 720.mp4");
    [app downloadSelected:nil];
    NSLog(@"D19 ENQUEUED=%@", [spy.enqueued valueForKey:@"url"]);
    Check(spy.enqueued.count == 2 && [spy.enqueued.lastObject[@"url"] hasSuffix:@"720.mp4"],
          [NSString stringWithFormat:@"D19 实际入队 720.mp4（实际 %@）", spy.enqueued.lastObject[@"url"]]);
    Check([spy.enqueued.lastObject[@"kind"] integerValue] == DownloadResourceVideo, @"D19 720p 按视频类型入队");
    Check(app.visibleMedia.count == 1, @"D19 选择档位后列表仍一行");
}

int main(int argc, const char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    NSLog(@"== 用户反馈专项：重复行 + 详情读取 ==");
    D1_VideoSrcPlusLabelledSourcesSingleRow();
    D2_UnlabelledPlayingSourceSingleRow();
    D3_PlayingURLMatchesSourceSingleRow();
    D4_DistinctVideosStaySeparate();
    D5_UnknownQualityStillVisibleAndDownloadable();
    D6_StaticPlusDynamicBridgeSingleRow();
    D7_MetadataUpdateKeepsSingleRow();
    D8_QualitySwitchEnqueuesTarget();
    D9_UnknownQualityMembersStayInOneRow();
    D10_NonStandardPixelMembersStayInOneRow();
    D11_SharedURLKeepsAllBlockMembersVisible();
    D12_DynamicBridgeKeepsFamilyGrouping();
    D13_VideoSrcMatchesLabelledSourceKeepsBothTiers();
    D14_VideoSrcMatches720SourceKeepsBothTiers();
    D15_SourceOrderDoesNotChangeTierSet();
    D16_BareThenLabelledDuplicateKeepsDeclaration();
    D17_RepeatedIdenticalDeclarationNoDuplicateOption();
    D18_WidthHeightOnDuplicateMemberCollected();
    D19_BothTiersSelectableAndEnqueueMatches();
    C1_PartialSuccessFieldsSurviveFailure();
    C2_AppReselectRestoresThumbnailWithoutRepeatRequests();
    C3_CanonicalURLFormsShareCacheAndNoCrossHit();
    C4_CancelKeepsCompletedFieldCache();
    C5_PrefetchAndClickShareInflightWork();
    C6_ReloadExplicitlyClearsSuccessCache();
    P1_HeadMoovWithinTwoRoundTrips();
    P2_TailMoovSkipsMdat();
    P3_TransientProbeTimeoutRecovers();
    P4_CancelStopsRequests();
    P5_NoRangeServerStillTerminates();
    P6_ClickedThumbnailIndependentOfDetailQueue();
    P7_NoOverlappingMediaRequestsAndStagedFields();
    CheckSummary();
} }
