//
//  ResourceDiscoveryCoordinator.m — 第 4 阶段｜策略协调器实现
//
//  实现要点：
//  · 复用第 3 阶段 MultiPageResourceProbe：每个页面作为一次单页任务探测，
//    继承其串行、取消、迟到回调作废与单次 completion 语义；
//  · 协调器用自建串行状态队列 + generation 驱动页面循环（页面间间隔、
//    有限重试都在协调器层，因此可注入 delayScheduler 而不真实等待）；
//  · 重试：仅对"可重试"的页面探测失败（非 URL 校验/权限/DRM 类错误）、
//    同一页面、次数 ≤ maxRetries；重试前经 delayScheduler；取消/顶替后
//    的重试调度被 generation 作废；
//  · 取消传播：loadingHTML 阶段取消 htmlProvider；probingPages 阶段
//    cancelAll 当前页任务（内部转探测器 cancelProbe:）；当前页标 Cancelled、
//    未开始页保持 NotStarted 一并写入结果；
//  · completion 恰好一次：finished 标志 + 全部结束路径统一走 finishOnce；
//  · Smart 首屏有资源即返回（不读 HTML）；无资源（含失败）才读 HTML 扩展，
//    但取消后绝不触发该扩展。
//

#import "ResourceDiscoveryCoordinator.h"
#import "RDLog.h"
#import "SubpageLinkExtractor.h"
#import "MultiPageResourceProbe.h"
#import "RDResourceModeFilter.h"
#import "URLPolicy.h"

NSString *const ZZResourceDiscoveryErrorDomain = @"ZZResourceDiscoveryErrorDomain";

#pragma mark - 错误可重试性

// 不可重试：策略层错误（InvalidURL/PermissionDenied/DRMProtected）与
// NSURLErrorBadURL/UnsupportedURL/NoPermissions。其余（超时、连接失败等
// 网络类）视为可重试，但受 maxRetries 次数限制。
static BOOL RDCIsRetryableError(NSError *e) {
    if (e == nil) return NO;
    if ([e.domain isEqualToString:ZZResourceDiscoveryErrorDomain]) return NO;
    if ([e.domain isEqualToString:NSURLErrorDomain]) {
        switch (e.code) {
            case NSURLErrorBadURL:
            case NSURLErrorUnsupportedURL:
            case NSURLErrorNoPermissionsToReadFile:
                return NO;
            default:
                return YES;
        }
    }
    return YES;
}

static NSError *RDCError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ZZResourceDiscoveryErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : (message ?: @"")}];
}

// A listing card describes one detail page, not every media URL the page
// happens to expose.  It is safe to inherit that card's title and cover only
// when the page contains one video (possibly with several quality variants).
static NSString *RDCMediaFamilyKey(DetectedMedia *media) {
    NSURL *url = [NSURL URLWithString:media.mediaURL ?: @""];
    NSString *filename = url.lastPathComponent;
    NSString *stem = filename.stringByDeletingPathExtension.lowercaseString;
    if (!stem.length) return @"";
    static NSRegularExpression *qualitySuffix = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        qualitySuffix = [NSRegularExpression regularExpressionWithPattern:@"^(.*?)[-_.](\\d{3,4})p$"
                                                                  options:0
                                                                    error:nil];
    });
    NSTextCheckingResult *match = [qualitySuffix firstMatchInString:stem
                                                               options:0
                                                                 range:NSMakeRange(0, stem.length)];
    if (!match || match.numberOfRanges < 3) return @"";
    NSString *base = [stem substringWithRange:[match rangeAtIndex:1]];
    if (!base.length) return @"";
    NSString *directory = [url.path stringByDeletingLastPathComponent].lowercaseString ?: @"";
    NSString *extension = filename.pathExtension.lowercaseString ?: @"";
    return [NSString stringWithFormat:@"%@|%@|%@|%@", url.host.lowercaseString ?: @"", directory, base, extension];
}

static BOOL RDCPageRepresentsOneVideo(NSArray<DetectedMedia *> *media) {
    if (media.count <= 1) return YES;
    NSString *family = RDCMediaFamilyKey(media.firstObject);
    if (!family.length) return NO;
    for (DetectedMedia *candidate in media) {
        if (![RDCMediaFamilyKey(candidate) isEqualToString:family]) return NO;
    }
    return YES;
}

#pragma mark - 适配器：ZZDiscoveryPageProbing → ZZSinglePageProbing

// 协调器逐页调用 MultiPageResourceProbe 时注入的适配器。
// token 透传，取消链路：multipageProbe.cancelAll → adapter.cancelProbe → rawProbe.cancelProbe。
@interface RDCPageProbeAdapter : NSObject <ZZSinglePageProbing>
@property (nonatomic, strong, readonly) id<ZZDiscoveryPageProbing> rawProbe;
- (instancetype)initWithRawProbe:(id<ZZDiscoveryPageProbing>)rawProbe;
@end

@implementation RDCPageProbeAdapter

- (instancetype)initWithRawProbe:(id<ZZDiscoveryPageProbing>)rawProbe {
    self = [super init];
    if (self) _rawProbe = rawProbe;
    return self;
}

- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(ZZSinglePageProbeCompletion)completion {
    return [self.rawProbe probePageURL:pageURL
                            completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
        if (completion) completion(media ?: @[], error);
    }];
}

// 增量发布：探测器支持时透传终态标志（上层编排器据此把临时结果与最终结果分开：
// 临时结果只用于先把列表显示出来，绝不当作终态）；不支持时把一次性结果包成
// 「最终」回调，行为与改动前完全一致。
- (nullable id)probePageURL:(NSURL *)pageURL
     incrementalCompletion:(ZZIncrementalPageProbeCompletion)completion {
    if ([self.rawProbe respondsToSelector:@selector(probePageURL:incrementalCompletion:)]) {
        return [self.rawProbe probePageURL:pageURL
                   incrementalCompletion:^(NSArray<DetectedMedia *> *media, NSError *error, BOOL isFinal) {
            if (completion) completion(media ?: @[], error, isFinal);
        }];
    }
    return [self probePageURL:pageURL completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
        if (completion) completion(media, error, YES);
    }];
}

- (void)cancelProbe:(id)probeToken {
    [self.rawProbe cancelProbe:probeToken];
}

@end

#pragma mark - 选项

@implementation ZZResourceDiscoveryOptions

+ (instancetype)defaultOptions {
    ZZResourceDiscoveryOptions *o = [ZZResourceDiscoveryOptions new];
    o.mode = ZZResourceDiscoveryModeSmart;
    o.maxSubpageCount = 50;
    o.maxDepth = 1;
    o.maxRetries = 1;
    o.requestInterval = 0.5;
    o.sameOriginOnly = YES;
    o.maxConcurrentPageProbes = 1;
    o.pageBatchDeadline = 0;
    return o;
}

@end

#pragma mark - 结果

@implementation ZZResourceDiscoveryResult
@end

#pragma mark - 协调器

typedef NS_ENUM(NSInteger, RDCPhase) {
    RDCPhaseIdle = 0,
    RDCPhaseLoadingHTML,
    RDCPhaseProbingPages,
    RDCPhaseFinished,
};

@interface ResourceDiscoveryCoordinator ()
@property (nonatomic, strong, readonly) id<ZZDiscoveryPageProbing> pageProbe;
@property (nonatomic, strong, readonly) id<ZZDiscoveryHTMLProviding> htmlProvider;
@property (nonatomic, copy, readonly, nullable) ZZDiscoveryDelayScheduler delayScheduler;
@property (nonatomic, strong, readonly) MultiPageResourceProbe *multipageProbe;

@property (nonatomic, strong) dispatch_queue_t stateQueue;   // 串行状态队列
@property (nonatomic, assign) NSInteger generation;
@property (nonatomic, assign) RDCPhase phase;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL cancelled;

@property (nonatomic, copy, nullable) void (^completion)(ZZResourceDiscoveryResult *);
@property (nonatomic, strong) ZZResourceDiscoveryOptions *options;
@property (nonatomic, copy) NSURL *seedURL;

@property (nonatomic, copy) NSArray<NSURL *> *pages;      // 当前页面循环
@property (nonatomic, assign) NSUInteger pageIndex;
@property (nonatomic, assign) NSUInteger pageAttempt;     // 当前页第几次尝试（0 起）
@property (nonatomic, assign) BOOL smartSeedStage;        // Smart 模式首屏探测阶段
@property (nonatomic, assign) BOOL parallelPageLoop;

@property (nonatomic, strong) NSMutableArray<MultiPageProbePageResult *> *pageResults;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *mediaKeys;
@property (nonatomic, strong) NSMutableArray<DetectedMedia *> *allMedia;
@property (nonatomic, copy) NSArray<NSURL *> *candidateURLs;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *preferredTitleByPageURL;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *preferredPosterByPageURL;
@property (nonatomic, assign) BOOL usedCurrentPageFallback;
@property (nonatomic, strong, nullable) NSError *error;

@property (nonatomic, strong, nullable) id htmlToken;
@end

@implementation ResourceDiscoveryCoordinator

static DetectedMedia *RDCMediaSnapshot(DetectedMedia *media) {
    if (!media) return nil;
    DetectedMedia *snapshot = [DetectedMedia new];
    snapshot.mediaURL = media.mediaURL;
    snapshot.declaredVariants = [media.declaredVariants copy];
    snapshot.videoFamilyID = media.videoFamilyID;
    snapshot.sourcePageURL = media.sourcePageURL;
    snapshot.mimeType = media.mimeType;
    snapshot.contentRange = media.contentRange;
    snapshot.parentMediaURL = media.parentMediaURL;
    snapshot.manifestInfo = [media.manifestInfo copy];
    snapshot.availabilityState = media.availabilityState;
    snapshot.discoveredAt = media.discoveredAt;
    snapshot.resourceKind = media.resourceKind;
    snapshot.discoverySource = media.discoverySource;
    snapshot.pixelWidth = media.pixelWidth;
    snapshot.pixelHeight = media.pixelHeight;
    snapshot.durationSeconds = [media.durationSeconds copy];
    snapshot.isLive = media.isLive;
    snapshot.isManifest = media.isManifest;
    snapshot.poster = media.poster;
    snapshot.title = media.title;
    snapshot.format = media.format;
    snapshot.quality = media.quality;
    snapshot.qualityDerivedFromPixelHeight = media.qualityDerivedFromPixelHeight;
    snapshot.sizeBytes = media.sizeBytes;
    snapshot.thumbnailStatus = media.thumbnailStatus;
    snapshot.drmType = media.drmType;
    return snapshot;
}

- (instancetype)initWithPageProbe:(id<ZZDiscoveryPageProbing>)pageProbe
                     htmlProvider:(id<ZZDiscoveryHTMLProviding>)htmlProvider {
    return [self initWithPageProbe:pageProbe htmlProvider:htmlProvider delayScheduler:nil];
}

- (instancetype)initWithPageProbe:(id<ZZDiscoveryPageProbing>)pageProbe
                     htmlProvider:(id<ZZDiscoveryHTMLProviding>)htmlProvider
                   delayScheduler:(nullable ZZDiscoveryDelayScheduler)delayScheduler {
    self = [super init];
    if (self) {
        _pageProbe = pageProbe;
        _htmlProvider = htmlProvider;
        _delayScheduler = delayScheduler ?: ^(NSTimeInterval delay, dispatch_block_t block) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, delay) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), block);
        };
        _multipageProbe = [[MultiPageResourceProbe alloc]
            initWithPageProbe:[[RDCPageProbeAdapter alloc] initWithRawProbe:pageProbe]];
        _stateQueue = dispatch_queue_create("zz.resourcediscovery.state", DISPATCH_QUEUE_SERIAL);
        _phase = RDCPhaseIdle;
        _finished = YES;
        _pages = @[];
        _pageResults = [NSMutableArray array];
        _mediaKeys = [NSMutableOrderedSet orderedSet];
        _allMedia = [NSMutableArray array];
        _candidateURLs = @[];
        _preferredTitleByPageURL = @{};
        _preferredPosterByPageURL = @{};
    }
    return self;
}

#pragma mark - 公共入口

- (void)discoverFromURL:(NSURL *)seedURL
                options:(ZZResourceDiscoveryOptions *)options
             completion:(void (^)(ZZResourceDiscoveryResult *))completion {
    RDLogWrite(@"probe", @"探测开始 mode=%ld url=%@", (long)self.options.mode, seedURL.host ?: @"(无host)");
    dispatch_sync(self.stateQueue, ^{
        if (!self.finished) {
            [self cancelTaskOnStateQueue];  // 顶替：旧任务以 cancelled 恰好回调一次
        }
        [self beginTaskWithSeedURL:seedURL
                           options:options ?: [ZZResourceDiscoveryOptions defaultOptions]
                        completion:completion];
    });
}

- (void)cancel {
    dispatch_sync(self.stateQueue, ^{
        [self cancelTaskOnStateQueue];
    });
}

#pragma mark - 任务生命周期（以下均在 stateQueue 上下文）

- (void)beginTaskWithSeedURL:(NSURL *)seedURL
                     options:(ZZResourceDiscoveryOptions *)options
                  completion:(void (^)(ZZResourceDiscoveryResult *))completion {
    // 重置状态
    self.generation += 1;
    self.phase = RDCPhaseIdle;
    self.finished = NO;
    self.cancelled = NO;
    self.completion = completion;
    self.options = options;
    self.seedURL = seedURL;
    self.pages = @[];
    self.pageIndex = 0;
    self.pageAttempt = 0;
    self.smartSeedStage = NO;
    self.parallelPageLoop = NO;
    self.pageResults = [NSMutableArray array];
    self.mediaKeys = [NSMutableOrderedSet orderedSet];
    self.allMedia = [NSMutableArray array];
    self.candidateURLs = @[];
    self.preferredTitleByPageURL = @{};
    self.preferredPosterByPageURL = @{};
    self.usedCurrentPageFallback = NO;
    self.error = nil;
    self.htmlToken = nil;

    // 生产列表页把整个“读取列表 HTML + 详情页探测”纳入同一预算。
    // 并发页循环在截止时取消在途请求并通过 summary 汇总已完成结果。
    if(options.pageBatchDeadline>0){
        NSInteger deadlineGeneration=self.generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(options.pageBatchDeadline*NSEC_PER_SEC)),
                       self.stateQueue,^{
            if(self.finished||deadlineGeneration!=self.generation)return;
            self.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
                                         userInfo:@{NSLocalizedDescriptionKey: @"页面探测超过总时间限制，已停止；结果可能不完整"}];
            [self stopTaskOnStateQueueWithUserCancellation:NO];
        });
    }

    // seedURL 校验：必须是非空 http/https
    if (![[URLPolicy new] evaluateTextURL:seedURL.absoluteString].allowed) {
        self.error = RDCError(ZZResourceDiscoveryErrorInvalidURL,
                              @"种子页面地址无效：仅支持 http/https 页面链接");
        [self finishOnceOnStateQueue];
        return;
    }

    switch (options.mode) {
        case ZZResourceDiscoveryModeCurrentPage:
            // 只探测 seedURL；不读 HTML、不提取子页面
            [self startPageLoopWithPages:@[seedURL] smartSeedStage:NO];
            break;
        case ZZResourceDiscoveryModeSite:
            [self loadHTMLOnStateQueue];
            break;
        case ZZResourceDiscoveryModeSmart:
            // 先探测当前页面；有资源直接返回，无资源再扩展
            [self startPageLoopWithPages:@[seedURL] smartSeedStage:YES];
            break;
        case ZZResourceDiscoveryModeSmartExpansion:
            // 首屏已由调用方完成且无资源：直接进入 HTML 提取与子页面探测
            [self loadHTMLOnStateQueue];
            break;
        default:
            [self startPageLoopWithPages:@[seedURL] smartSeedStage:YES];
            break;
    }
}

// 启动页面循环（Smart 首屏阶段 smartSeedStage=YES，循环结束走 Smart 判断）。
- (void)startPageLoopWithPages:(NSArray<NSURL *> *)pages smartSeedStage:(BOOL)smartSeedStage {
    self.pages = [pages copy];
    self.pageIndex = 0;
    self.pageAttempt = 0;
    self.smartSeedStage = smartSeedStage;
    self.phase = RDCPhaseProbingPages;
    if (self.pages.count == 0) {
        [self finishPageLoopOnStateQueue];
        return;
    }
    if(!smartSeedStage && self.options.maxConcurrentPageProbes>1 && self.pages.count>1){
        [self startParallelPageLoopOnStateQueue];
    }else{
        [self probeCurrentPageOnStateQueue];
    }
}

- (void)startParallelPageLoopOnStateQueue {
    self.parallelPageLoop=YES;
    self.multipageProbe.interimSummaryHandler=nil;   // 多页并发循环不透出临时结果
    self.multipageProbe.maxConcurrentProbes=MAX((NSUInteger)1,MIN((NSUInteger)32,self.options.maxConcurrentPageProbes));
    NSInteger gen=self.generation;
    __weak typeof(self) w=self;
    [self.multipageProbe probePageURLs:self.pages completion:^(MultiPageProbeSummary *summary) {
        __strong typeof(w) s=w;if(!s)return;
        dispatch_async(s.stateQueue,^{ [s handleParallelSummaryOnStateQueue:summary generation:gen]; });
    }];
}

- (void)handleParallelSummaryOnStateQueue:(MultiPageProbeSummary *)summary generation:(NSInteger)gen {
    if(self.finished||gen!=self.generation||!self.parallelPageLoop)return;
    self.parallelPageLoop=NO;
    for(MultiPageProbePageResult *page in summary.pageResults ?: @[]){
        [self acceptPageResultOnStateQueue:page];
    }
    [self finishPageLoopOnStateQueue];
}

// 探测当前页（每次一个单页任务，复用第 3 阶段编排器）。
- (void)probeCurrentPageOnStateQueue {
    NSInteger gen = self.generation;
    NSURL *url = self.pages[self.pageIndex];
    // 临时结果只对「单页阶段」（当前页模式 / 智能首屏）开放：子页面循环有几十页，
    // 逐页透出会让左侧列表被反复重建。页面探测器的静态取页腿先回来时先把列表
    // 显示出来，动态 WebKit 腿回来后再以最终结果（completion）收尾。
    if (self.pages.count == 1 && !self.parallelPageLoop) {
        __weak typeof(self) interimOwner = self;
        self.multipageProbe.interimSummaryHandler = ^(MultiPageProbeSummary *summary) {
            __strong typeof(interimOwner) s = interimOwner;
            if (!s) return;
            dispatch_async(s.stateQueue, ^{
                [s emitInterimResultOnStateQueue:summary generation:gen];
            });
        };
    } else {
        self.multipageProbe.interimSummaryHandler = nil;
    }
    __weak typeof(self) w = self;
    [self.multipageProbe probePageURLs:@[url]
                            completion:^(MultiPageProbeSummary *summary) {
        // MultiPageResourceProbe 的 completion 固定在主线程
        __strong typeof(w) s = w;
        if (!s) return;
        dispatch_async(s.stateQueue, ^{
            [s handlePageSummaryOnStateQueue:summary generation:gen];
        });
    }];
}

- (void)handlePageSummaryOnStateQueue:(MultiPageProbeSummary *)summary generation:(NSInteger)gen {
    if (self.finished || gen != self.generation) return;   // 迟到/取消/顶替作废
    MultiPageProbePageResult *pr = summary.pageResults.firstObject;
    if (!pr) {
        // 防御：异常空 summary 视为该页失败
        pr = [MultiPageProbePageResult resultWithPageURL:self.pages[self.pageIndex]];
        pr.status = MultiPageProbePageStatusFailed;
        pr.error = RDCError(ZZResourceDiscoveryErrorHTMLFetchFailed, @"探测器未返回页面结果");
    }
    // 取消路径：cancelTaskOnStateQueue 已写入 Cancelled 并 finishOnce，此处直接返回
    if (pr.status == MultiPageProbePageStatusCancelled) return;

    // 有限重试：同一页面、可重试错误、次数未用完
    if (pr.status == MultiPageProbePageStatusFailed &&
        self.pageAttempt < self.options.maxRetries &&
        RDCIsRetryableError(pr.error)) {
        self.pageAttempt += 1;
        [self scheduleDelayOnStateQueue:^{
            if (self.finished || gen != self.generation) return;
            [self probeCurrentPageOnStateQueue];
        }];
        return;
    }

    // 接受该页最终结果
    [self acceptPageResultOnStateQueue:pr];
    self.pageIndex += 1;
    self.pageAttempt = 0;
    if (self.pageIndex >= self.pages.count) {
        [self finishPageLoopOnStateQueue];
        return;
    }
    // 请求间隔：下一页开始前
    [self scheduleDelayOnStateQueue:^{
        if (self.finished || gen != self.generation) return;
        [self probeCurrentPageOnStateQueue];
    }];
}

// 单页阶段的临时结果（静态取页腿先回来）：只用于「先把列表显示出来」，
// 不写入协调器自身状态（allMedia/mediaKeys/pageResults 都不动）——最终结果仍由
// completion 单独给出。口径与最终结果一致：模式过滤 + 单视频时的标题/封面偏好。
- (void)emitInterimResultOnStateQueue:(MultiPageProbeSummary *)summary generation:(NSInteger)gen {
    if (self.finished || gen != self.generation) return;
    void (^handler)(ZZResourceDiscoveryResult *) = self.interimResultHandler;
    if (!handler) return;
    MultiPageProbePageResult *pr = summary.pageResults.firstObject;
    if (!pr || pr.media.count == 0) return;   // 还没有可显示的资源：不出临时结果

    NSMutableArray<DetectedMedia *> *allowed = [NSMutableArray array];
    for (DetectedMedia *media in pr.media) {
        if ([RDResourceModeFilter allowsMedia:media mode:self.options.mode]) [allowed addObject:media];
    }
    if (allowed.count == 0) return;
    NSString *preferredTitle = self.preferredTitleByPageURL[pr.pageURL.absoluteString];
    NSString *preferredPoster = self.preferredPosterByPageURL[pr.pageURL.absoluteString];
    // BUG-019: a temporary result is rendered immediately and outlives this call,
    // so it must never alias the production models. The hybrid probe enriches
    // those in place (`mediaByEnriching:with:` fills poster/title on the primary
    // object) once the dynamic WebKit leg returns, which would rewrite rows the
    // user is already looking at. Snapshot unconditionally: the previous version
    // only snapshotted when a preferred title or poster existed, but the only
    // path that emits an interim result is the single page stage, where both
    // dictionaries are always empty — so the snapshot never ran.
    // The enriched cover still reaches the screen: the final result carries the
    // production objects and the UI re-applies it (applyDiscoveryResult:final:),
    // so the fill-in becomes an explicit repaint instead of a silent mutation.
    BOOL oneVideo = RDCPageRepresentsOneVideo(allowed);
    for (NSUInteger index = 0; index < allowed.count; index++) {
        DetectedMedia *media = allowed[index];
        DetectedMedia *snapshot = RDCMediaSnapshot(media);
        if (oneVideo) {
            if (preferredTitle.length) snapshot.title = preferredTitle;
            if (preferredPoster.length) snapshot.poster = preferredPoster;
        }
        [allowed replaceObjectAtIndex:index withObject:snapshot];
    }

    ZZResourceDiscoveryResult *result = [ZZResourceDiscoveryResult new];
    result.seedURL = self.seedURL;
    result.mode = self.options.mode;
    result.pageResults = summary.pageResults ?: @[];
    result.allMedia = [allowed copy];
    result.candidateURLs = @[];
    result.preferredTitleByPageURL = self.preferredTitleByPageURL ?: @{};
    result.preferredPosterByPageURL = self.preferredPosterByPageURL ?: @{};
    dispatch_async(dispatch_get_main_queue(), ^{ handler(result); });
}

// 页面循环结束：Smart 首屏阶段判断是否扩展；否则任务完成。
- (void)finishPageLoopOnStateQueue {
    if (self.smartSeedStage) {
        // Smart 首屏探测完成：有资源直接返回（不读 HTML、不扩展）
        if (self.allMedia.count > 0) {
            [self finishOnceOnStateQueue];
            return;
        }
        // 无资源（含失败）：读取 HTML 提取子页面
        [self loadHTMLOnStateQueue];
        return;
    }
    [self finishOnceOnStateQueue];
}

- (void)acceptPageResultOnStateQueue:(MultiPageProbePageResult *)pr {

    RDLogWrite(@"probe", @"页面定稿 media=%lu", (unsigned long)pr.media.count);
    NSMutableArray<DetectedMedia *> *allowed = [NSMutableArray array];
    for (DetectedMedia *media in pr.media ?: @[]) {
        if ([RDResourceModeFilter allowsMedia:media mode:self.options.mode]) [allowed addObject:media];
    }
    pr.media = [allowed copy];
    NSString *preferredTitle = self.preferredTitleByPageURL[pr.pageURL.absoluteString];
    NSString *preferredPoster = self.preferredPosterByPageURL[pr.pageURL.absoluteString];
    BOOL oneVideo = RDCPageRepresentsOneVideo(pr.media);
    if (oneVideo && preferredTitle.length) {
        for (DetectedMedia *media in pr.media) media.title = preferredTitle;
    }
    if (oneVideo && preferredPoster.length) {
        for (DetectedMedia *media in pr.media) {
            // The listing card is the site's canonical work cover. Detail
            // pages often expose a landscape player poster or generated video
            // frame, which must not replace the portrait cover the user saw
            // while browsing the listing.
            media.poster = preferredPoster;
        }
    }
    [self.pageResults addObject:pr];
    for (DetectedMedia *m in pr.media) {
        NSString *key = [DetectedMedia dedupKeyForURL:m.mediaURL];
        if (key.length == 0 || [self.mediaKeys containsObject:key]) continue;
        [self.mediaKeys addObject:key];
        [self.allMedia addObject:m];
    }
}

#pragma mark - HTML 阶段

- (void)loadHTMLOnStateQueue {
    NSInteger gen = self.generation;
    self.phase = RDCPhaseLoadingHTML;
    __weak typeof(self) w = self;
    self.htmlToken = [self.htmlProvider loadHTMLForURL:self.seedURL
                                            completion:^(NSString *html, NSURL *finalURL, NSError *error) {
        // HTML provider 回调线程不限，统一转回状态队列
        __strong typeof(w) s = w;
        if (!s) return;
        dispatch_async(s.stateQueue, ^{
 RDLogWrite(@"probe", @"列表页抓取完成 bytes=%lu err=%@", (unsigned long)html.length, error.localizedDescription ?: @"无");
            [s handleHTMLOnStateQueue:html finalURL:finalURL error:error generation:gen];
        });
    }];
}

- (void)handleHTMLOnStateQueue:(NSString *)html
                      finalURL:(NSURL *)finalURL
                         error:(NSError *)error
                     generation:(NSInteger)gen {
    if (error) RDLogWrite(@"probe", @"列表页抓取失败 code=%ld 文案=%@", (long)error.code, error.localizedDescription ?: @"");
    if (self.finished || gen != self.generation) return;   // 迟到/取消/顶替作废
    if (error != nil) {
        // HTML 获取失败：独立错误状态，不回退、不触发页面重试
        self.error = [NSError errorWithDomain:ZZResourceDiscoveryErrorDomain
                                         code:ZZResourceDiscoveryErrorHTMLFetchFailed
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"种子页面 HTML 获取失败",
                                         NSUnderlyingErrorKey : error,
                                     }];
        [self finishOnceOnStateQueue];
        return;
    }

    // 提取候选子页面：base 用重定向后的最终 URL（更准确）
    NSURL *base = finalURL ?: self.seedURL;
    // 深度语义：>1 收敛为 1；0 = 不探测子页面（maxCount 传 0 → 提取结果为空）
    NSUInteger effectiveMaxSubpages =
        (self.options.maxDepth >= 1) ? self.options.maxSubpageCount : 0;
    NSArray<NSURL *> *candidates =
        [SubpageLinkExtractor extractSubpageLinksFromHTML:html
                                                  baseURL:base
                                                  maxCount:effectiveMaxSubpages];
    self.candidateURLs = candidates;
    // 封面/标题提取是纯 HTML 解析、代价很小，不应被“子页探测上限 50”（maxSubpageCount）
    // 绑住：列表页后半部分视频（如搜索页第 50 条之后）的封面在 HTML 里明明存在，
    // 却因 allowed 只有前 50 条链接而提取不到，导致“前半有封面、后半全占位”（2026-09-03 修复）。
    // 这里给封面/标题单独用一个足够大的上限（覆盖资源上限 500 及冗余 100）。
    NSUInteger metadataMax = MAX(effectiveMaxSubpages, 600);
    self.preferredTitleByPageURL =
        [SubpageLinkExtractor extractSubpageTitlesFromHTML:html
                                                   baseURL:base
                                                  maxCount:metadataMax];
    self.preferredPosterByPageURL =
        [SubpageLinkExtractor extractSubpagePreviewImagesFromHTML:html
                                                         baseURL:base
                                                        maxCount:metadataMax];
    // The listing page already gives us the stable website covers.  Surface
    // them now, before the (potentially much slower) detail-page probes run.
    if (self.preferredPosterByPageURL.count && self.listingPagePreviewHandler) {
        self.listingPagePreviewHandler(base, [self.preferredPosterByPageURL copy]);
    }

    if (candidates.count == 0) {
        if (self.options.mode == ZZResourceDiscoveryModeSite) {
            // 总站模式无候选子页面：回退探测 seedURL
            self.usedCurrentPageFallback = YES;
            [self startPageLoopWithPages:@[self.seedURL] smartSeedStage:NO];
        } else {
            // 智能/智能扩展模式无子页面：seed 已探测过，不重复探测，返回当前页面结果
            [self finishOnceOnStateQueue];
        }
        return;
    }
    [self startPageLoopWithPages:candidates smartSeedStage:NO];
}

#pragma mark - 取消

- (void)cancelTaskOnStateQueue {
    [self stopTaskOnStateQueueWithUserCancellation:YES];
}

// Both deadline and user cancellation stop work, but only the latter is cancelled.
// Invalidate the coordinator generation before cancelling the child orchestrator.
- (void)stopTaskOnStateQueueWithUserCancellation:(BOOL)userCancellation {
    if (self.finished) return;
    self.generation += 1;
    self.cancelled = userCancellation;

    if (self.phase == RDCPhaseLoadingHTML) {
        if (self.htmlToken) [self.htmlProvider cancelHTMLRequest:self.htmlToken];
        self.htmlToken = nil;
    } else if (self.phase == RDCPhaseProbingPages) {
        // 取消当前页任务（内部转 rawProbe.cancelProbe:）
        [self.multipageProbe cancelAll];
        // 并行模式下 cancelAll 已在编排器内部收尾：已完成页保留真实状态、
        // 在途页 Cancelled、未开始页 NotStarted。采纳其页面快照（含已完成页
        // 资源），而不是用 NotStarted 占位覆盖；迟到的取消 summary 仍会被
        // handleParallelSummaryOnStateQueue 的 generation 检查作废，此处是
        // 唯一采纳点。
        NSArray<MultiPageProbePageResult *> *snapshot = [self.multipageProbe pageResultsSnapshotSync];
        NSMutableSet<NSURL *> *knownPageURLs = [NSMutableSet set];
        for (MultiPageProbePageResult *page in self.pageResults) {
            if (page.pageURL) [knownPageURLs addObject:page.pageURL];
        }
        for (MultiPageProbePageResult *page in snapshot) {
            if (!userCancellation && page.status == MultiPageProbePageStatusCancelled) {
                page.status = MultiPageProbePageStatusFailed;
                page.error = self.error;
            }
            if (page.pageURL && ![knownPageURLs containsObject:page.pageURL]) {
                [knownPageURLs addObject:page.pageURL];
                // Same filtering, metadata enrichment and dedup as normal completion.
                [self acceptPageResultOnStateQueue:page];
            }
        }
        // Serial loops only have the current page in the child snapshot.
        for (NSURL *url in self.pages) {
            if (![knownPageURLs containsObject:url]) {
                [self.pageResults addObject:[MultiPageProbePageResult resultWithPageURL:url]];
                [knownPageURLs addObject:url];
            }
        }
        self.parallelPageLoop=NO;
    }
    [self finishOnceOnStateQueue];
}

#pragma mark - 完成

- (void)finishOnceOnStateQueue {
    if (self.finished) return;
    self.finished = YES;
    self.phase = RDCPhaseFinished;

    ZZResourceDiscoveryResult *r = [ZZResourceDiscoveryResult new];
    r.seedURL = self.seedURL;
    r.mode = self.options.mode;
    r.candidateURLs = [self.candidateURLs copy];
    r.pageResults = [self.pageResults copy];
    r.allMedia = [self.allMedia copy];
    r.preferredTitleByPageURL = [self.preferredTitleByPageURL copy];
    r.preferredPosterByPageURL = [self.preferredPosterByPageURL copy];
    r.listingPageResults = @[];
    r.usedCurrentPageFallback = self.usedCurrentPageFallback;
    r.cancelled = self.cancelled;
    r.error = self.error;

    void (^cb)(ZZResourceDiscoveryResult *) = self.completion;
    self.completion = nil;
    self.htmlToken = nil;
    if (cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(r);
        });
    }
}

#pragma mark - 延迟调度（stateQueue 上下文调用；block 回到 stateQueue）

- (void)scheduleDelayOnStateQueue:(dispatch_block_t)block {
    if (!self.delayScheduler) {
        block();
        return;
    }
    self.delayScheduler(MAX(0, self.options.requestInterval), ^{
        dispatch_async(self.stateQueue, block);
    });
}

@end
