//
//  DiscoverySessionController.m — 第 5 阶段｜资源发现会话控制器实现
//

#import "DiscoverySessionController.h"
#import "RDResourceModeFilter.h"
#import "ProductionDiscoveryPageProbe.h"
#import "StaticHTMLDiscoveryPageProbe.h"
#import "RDHybridPageProbe.h"
#import "ProductionDiscoveryHTMLProvider.h"
#import "URLPolicy.h"

static const NSUInteger kDSCInteractiveSubpageLimit = 10;
static const NSUInteger kDSCMaxListingPageRetries = 2;

// Listing HTML is the entry point for a whole page of results.  A transient
// transport/server failure must not turn that entire listing into a permanent
// failure, but invalid URLs and explicit access denials should not be retried.
static BOOL DSCShouldRetryListingPageError(NSError *error) {
    if (!error || ![error.domain isEqualToString:ZZResourceDiscoveryErrorDomain] ||
        error.code != ZZResourceDiscoveryErrorHTMLFetchFailed) return NO;
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (!underlying) return YES; // coordinator deadline: one fresh request is worthwhile
    if ([underlying.domain isEqualToString:NSURLErrorDomain]) {
        switch (underlying.code) {
            case NSURLErrorCancelled:
            case NSURLErrorBadURL:
            case NSURLErrorUnsupportedURL:
            case NSURLErrorNoPermissionsToReadFile:
                return NO;
            default:
                return YES;
        }
    }
    if (underlying.code == ZZResourceDiscoveryErrorInvalidURL ||
        underlying.code == ZZResourceDiscoveryErrorPermissionDenied) return NO;
    // HTTP 4xx is normally a stable request/access problem, except the
    // temporary overload/rate-limit responses below.  5xx is retryable.
    if (underlying.code >= 400 && underlying.code < 500) {
        return underlying.code == 408 || underlying.code == 425 || underlying.code == 429;
    }
    return YES;
}

static NSTimeInterval DSCListingRetryDelay(NSUInteger retryAttempt) {
    // retryAttempt is one-based.  The cap keeps an outage bounded and keeps
    // a successful retry perceptibly quick.
    return retryAttempt <= 1 ? 0.5 : 1.0;
}

#pragma mark - 计数探测包装器（观测页面开始/完成/重试，产生中文状态）

@interface DSCCountingProbe : NSObject <ZZDiscoveryPageProbing>
@property (nonatomic, strong) id<ZZDiscoveryPageProbing> inner;
@property (nonatomic, copy, nullable) void (^onStatus)(NSString *status);
@property (nonatomic, strong) NSMutableSet<NSString *> *startedURLs;
@property (nonatomic, strong) NSMutableSet<NSString *> *completedURLs;
@property (nonatomic, assign) NSUInteger pageCount;
@property (nonatomic, assign) NSUInteger completedCount;
@property (nonatomic, assign) NSUInteger pageLimit;
@property (nonatomic, copy, nullable) void (^onProgress)(double progress);
@end

@implementation DSCCountingProbe

- (instancetype)init {
    self = [super init];
    if (self) {
        _startedURLs = [NSMutableSet set];
        _completedURLs = [NSMutableSet set];
    }
    return self;
}

// 一次页面探测的开始（状态文案 + 页计数）：返回是否为同一 URL 的重试。
- (BOOL)noteProbeStartForURLString:(NSString *)urlString {
    __block BOOL isRetry = NO;
    __block NSUInteger pageCountSnapshot = 0;
    __block NSUInteger pageLimitSnapshot = 1;
    // stateQueue starts probes while inner completions can arrive on the main
    // queue. One synchronized URL ledger replaces the old racy scalar state.
    // The counters derived from that ledger are read inside the same critical
    // section: reading them outside let a parallel page's completion advance
    // pageCount between the increment and the status string (TSan: data race).
    @synchronized (self) {
        isRetry = [self.startedURLs containsObject:urlString];
        if (!isRetry) {
            [self.startedURLs addObject:urlString];
            self.pageCount += 1;
        }
        pageCountSnapshot = self.pageCount;
        pageLimitSnapshot = MAX((NSUInteger)1, self.pageLimit);
    }
    if (self.onStatus) {
        if (isRetry) {
            self.onStatus(@"页面加载失败，正在重试…");
        } else {
            self.onStatus([NSString stringWithFormat:@"正在探测第 %lu/%lu 个页面：%@",
                                                      (unsigned long)pageCountSnapshot,
                                                      (unsigned long)pageLimitSnapshot,
                                                      [self shortDisplayForURLString:urlString]]);
        }
    }
    return isRetry;
}

// 一次页面探测的完成（进度推进）：只在「最终」结果上调用，避免增量发布的临时
// 结果把同一页的进度算两次。
- (void)noteProbeFinishedForURLString:(NSString *)urlString {
    __block BOOL newlyFinished = NO;
    __block double progress = 0.0;
    // Same reasoning as noteProbeStartForURLString: the counter and the limit it
    // is divided by must be sampled under the same lock that guards the ledger,
    // otherwise a parallel page's completion races this read (TSan reported
    // setCompletedCount: vs completedCount here) and progress can go backwards.
    @synchronized (self) {
        if (![self.startedURLs containsObject:urlString]) return;
        if (![self.completedURLs containsObject:urlString]) {
            [self.completedURLs addObject:urlString];
            self.completedCount += 1;
            newlyFinished = YES;
        }
        double total = MAX(1.0, (double)self.pageLimit);
        progress = MIN(0.95, MAX(0.0, (double)self.completedCount / total));
    }
    if (newlyFinished && self.onProgress) {
        self.onProgress(progress);
    }
}

- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(void (^)(NSArray<DetectedMedia *> * _Nullable,
                                      NSError * _Nullable))completion {
    NSString *urlString = pageURL.absoluteString ?: @"";
    [self noteProbeStartForURLString:urlString];
    __weak typeof(self) w = self;
    return [self.inner probePageURL:pageURL
                          completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
        __strong typeof(w) s = w;
        if (s) [s noteProbeFinishedForURLString:urlString];
        if (completion) completion(media, error);
    }];
}

// 增量发布：探测器支持时透传终态标志；不支持时把一次性结果包成「最终」回调。
- (nullable id)probePageURL:(NSURL *)pageURL
     incrementalCompletion:(void (^)(NSArray<DetectedMedia *> * _Nullable,
                                     NSError * _Nullable, BOOL))completion {
    if (![self.inner respondsToSelector:@selector(probePageURL:incrementalCompletion:)]) {
        return [self probePageURL:pageURL completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
            if (completion) completion(media, error, YES);
        }];
    }
    NSString *urlString = pageURL.absoluteString ?: @"";
    [self noteProbeStartForURLString:urlString];
    __weak typeof(self) w = self;
    return [self.inner probePageURL:pageURL
              incrementalCompletion:^(NSArray<DetectedMedia *> *media, NSError *error, BOOL isFinal) {
        __strong typeof(w) s = w;
        if (s && isFinal) [s noteProbeFinishedForURLString:urlString];
        if (completion) completion(media, error, isFinal);
    }];
}

- (void)cancelProbe:(nullable id)probeToken {
    [self.inner cancelProbe:probeToken];
}

// 状态栏展示用短地址：host + 截断 path
- (NSString *)shortDisplayForURLString:(NSString *)urlString {
    NSURL *u = [NSURL URLWithString:urlString];
    if (!u || u.host.length == 0) {
        return urlString.length > 48 ? [NSString stringWithFormat:@"%@…", [urlString substringToIndex:45]] : urlString;
    }
    NSString *path = u.path ?: @"";
    if (path.length > 36) path = [NSString stringWithFormat:@"%@…%@", [path substringToIndex:18], [path substringFromIndex:path.length - 15]];
    return path.length ? [NSString stringWithFormat:@"%@%@", u.host, path] : u.host;
}

@end

#pragma mark - 会话控制器

@interface DiscoverySessionController ()
@property (nonatomic, strong, readonly) ResourceDiscoveryCoordinator *coordinator;
@property (nonatomic, strong) DSCCountingProbe *countingProbe;
@property (nonatomic, strong) id<ZZDiscoveryHTMLProviding> htmlProvider;
@property (nonatomic, assign) NSInteger sessionGeneration;
@property (nonatomic, assign) BOOL batchActive;
@property (nonatomic, assign) BOOL batchCancelRequested;
@property (nonatomic, copy, nullable) NSURL *batchSeedURL;
@property (nonatomic, assign) NSUInteger batchListingPageCount;
@property (nonatomic, assign) NSUInteger batchListingPageIndex;
@property (nonatomic, assign) NSUInteger batchListingPageRetryAttempt;
@property (nonatomic, assign) BOOL batchListingPageRetryScheduled;
@property (nonatomic, strong) NSMutableArray<ZZResourceDiscoveryResult *> *batchResults;
@property (nonatomic, copy, nullable) NSString *lastStatusMessage;
@property (nonatomic, copy) ZZDiscoveryDelayScheduler retryScheduler;
@end

@implementation DiscoverySessionController

- (instancetype)initWithDefaultDependencies {
    RDHybridPageProbe *probe = [[RDHybridPageProbe alloc] initWithPolicy:[URLPolicy new]];
    DiscoverySessionController *controller = [self initWithPageProbe:probe
                                                         htmlProvider:probe
                                                       delayScheduler:nil];
    // Eight parallel detail probes saturate normal connections without the
    // same-origin request burst caused by the former 32-wide default.
    controller.maxConcurrentPageProbes = 2;
    controller.pageBatchDeadline = 0;
    return controller;
}

- (instancetype)initWithPageProbe:(id<ZZDiscoveryPageProbing>)pageProbe
                     htmlProvider:(id<ZZDiscoveryHTMLProviding>)htmlProvider
                   delayScheduler:(nullable ZZDiscoveryDelayScheduler)delayScheduler {
    self = [super init];
    if (self) {
        _countingProbe = [DSCCountingProbe new];
        _countingProbe.inner = pageProbe;
        _htmlProvider = htmlProvider;
        _maxConcurrentPageProbes = 1;
        _pageBatchDeadline = 0;
        _retryScheduler = delayScheduler ?: ^(NSTimeInterval delay, dispatch_block_t block) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(MAX(0, delay) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), block);
        };
        __weak typeof(self) w = self;
        _countingProbe.onStatus = ^(NSString *status) {
            __strong typeof(w) s = w;
            if (!s || !s.statusHandler) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s.batchActive) {
                    NSUInteger current = MIN(s.batchListingPageIndex + 1, s.batchListingPageCount);
                    NSString *message = [status containsString:@"重试"]
                        ? [NSString stringWithFormat:@"列表页 %lu/%lu：视频页加载失败，正在重试…",
                           (unsigned long)current, (unsigned long)s.batchListingPageCount]
                        : [NSString stringWithFormat:@"正在扫描列表页 %lu/%lu 的视频…",
                           (unsigned long)current, (unsigned long)s.batchListingPageCount];
                    [s emitStatus:message];
                } else {
                    [s emitStatus:status];
                }
            });
        };
        _countingProbe.onProgress = ^(double progress) {
            __strong typeof(w) s = w;
            if (!s || !s.progressHandler) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!s.progressHandler) return;
                if (s.batchActive && s.batchListingPageCount > 0) {
                    double combined = ((double)s.batchListingPageIndex + MIN(0.95, MAX(0, progress))) /
                                      (double)s.batchListingPageCount;
                    s.progressHandler(MIN(0.99, combined));
                } else {
                    s.progressHandler(progress);
                }
            });
        };
        _coordinator = [[ResourceDiscoveryCoordinator alloc] initWithPageProbe:_countingProbe
                                                                   htmlProvider:htmlProvider
                                                                 delayScheduler:_retryScheduler];
    }
    return self;
}

- (void)emitStatus:(NSString *)status {
    if(!status.length)return;
    if(!NSThread.isMainThread){
        __weak typeof(self) w=self;
        dispatch_async(dispatch_get_main_queue(),^{ [w emitStatus:status]; });
        return;
    }
    if([self.lastStatusMessage isEqualToString:status])return;
    self.lastStatusMessage=[status copy];
    if(self.statusHandler)self.statusHandler(status);
}

- (void)startWithURL:(NSURL *)url mode:(ZZResourceDiscoveryMode)mode {
    [self startWithURL:url mode:mode maxSubpageCount:kDSCInteractiveSubpageLimit];
}

- (void)configureCoordinatorPreviewHandlerForGeneration:(NSInteger)generation {
    BOOL suppressPreviewsForBatch = self.batchActive;
    __weak typeof(self) weakSelf = self;
    self.coordinator.listingPagePreviewHandler = ^(NSURL *listingPageURL,
                                                    NSDictionary<NSString *, NSString *> *posterByPageURL) {
        if (!posterByPageURL.count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.sessionGeneration || !self.listingPagePreviewHandler) return;
            // Website covers are retained in the result, but network preheat
            // waits for the complete listing batch.  Starting dozens of image
            // requests while the next listing is loading caused same-origin
            // contention and made transient failures much more likely.
            if (suppressPreviewsForBatch) return;
            self.listingPagePreviewHandler(listingPageURL, posterByPageURL);
        });
    };
}

- (void)startWithURL:(NSURL *)url
                mode:(ZZResourceDiscoveryMode)mode
     maxSubpageCount:(NSUInteger)maxSubpageCount {
    NSInteger generation = ++self.sessionGeneration;
    self.batchActive = NO;
    self.batchCancelRequested = NO;
    self.batchResults = nil;
    self.batchListingPageRetryAttempt = 0;
    self.batchListingPageRetryScheduled = NO;
    self.lastStatusMessage = nil;
    ZZResourceDiscoveryOptions *options = [ZZResourceDiscoveryOptions defaultOptions];
    options.mode = mode;
    // WebView 会话结束本身会回到主队列；不再额外固定等待，
    // 避免几十个详情页累加空转时间。
    options.requestInterval = 0;
    options.maxConcurrentPageProbes = MAX((NSUInteger)1, self.maxConcurrentPageProbes);
    options.pageBatchDeadline = self.pageBatchDeadline;
    options.maxRetries = 0;
    NSUInteger pageLimit=MAX((NSUInteger)1,MIN((NSUInteger)50,maxSubpageCount));
    if (mode != ZZResourceDiscoveryModeCurrentPage) {
        options.maxSubpageCount = pageLimit;
    }
    // Reset the ledger and the counters it derives under the same lock the
    // probes use, so a late completion from the previous session cannot race
    // this initialization.
    @synchronized (self.countingProbe) {
        self.countingProbe.pageLimit=(mode==ZZResourceDiscoveryModeCurrentPage)?1:pageLimit;
        self.countingProbe.pageCount = 0;
        self.countingProbe.completedCount = 0;
    }
    [self.countingProbe.startedURLs removeAllObjects];
    [self.countingProbe.completedURLs removeAllObjects];
    if(self.progressHandler)self.progressHandler(0);
    switch (mode) {
        case ZZResourceDiscoveryModeCurrentPage:
            [self emitStatus:@"正在探测当前页面…"];
            break;
        case ZZResourceDiscoveryModeSmart:
            [self emitStatus:@"智能模式：正在探测当前页面…"];
            break;
        case ZZResourceDiscoveryModeSmartExpansion:
            [self emitStatus:@"智能模式：正在读取页面链接…"];
            break;
        default:
            [self emitStatus:@"正在读取页面链接…"];
            break;
    }
    [self configureCoordinatorPreviewHandlerForGeneration:generation];
    __weak typeof(self) w = self;
    // 临时（非终态）结果：静态取页腿先回来时把列表透出。批量任务不透出
    // （一次批次由多个列表页拼装，逐页临时结果会把列表反复重建）。
    self.coordinator.interimResultHandler = ^(ZZResourceDiscoveryResult *result) {
        __strong typeof(w) s = w;
        if (!s || generation != s.sessionGeneration || s.batchActive) return;
        if (s.interimResultHandler) s.interimResultHandler(result);
    };
    [self.coordinator discoverFromURL:url options:options completion:^(ZZResourceDiscoveryResult *result) {
        __strong typeof(w) s = w;
        if (!s || generation != s.sessionGeneration) return;
        if(s.progressHandler)s.progressHandler(1);
        if(s.resultHandler)s.resultHandler(result);
    }];
}

- (void)startSiteBatchWithURL:(NSURL *)url listingPageCount:(NSUInteger)count {
    NSInteger generation = ++self.sessionGeneration;
    self.batchActive = YES;
    self.batchCancelRequested = NO;
    self.batchSeedURL = url;
    self.batchListingPageCount = MAX((NSUInteger)1, MIN((NSUInteger)self.class.siteMaxPages, count));
    self.batchListingPageIndex = 0;
    self.batchListingPageRetryAttempt = 0;
    self.batchListingPageRetryScheduled = NO;
    self.batchResults = [NSMutableArray array];
    self.lastStatusMessage = nil;
    if (self.progressHandler) self.progressHandler(0);
    [self emitStatus:[NSString stringWithFormat:@"正在读取列表页 1/%lu…",
                      (unsigned long)self.batchListingPageCount]];
    [self startBatchListingPageForGeneration:generation];
}

- (void)startBatchListingPageForGeneration:(NSInteger)generation {
    if (!self.batchActive || self.batchCancelRequested || generation != self.sessionGeneration) return;
    self.batchListingPageRetryScheduled = NO;
    NSInteger firstPage = [self.class sitePageNumberFromURL:self.batchSeedURL];
    NSInteger pageNumber = firstPage + (NSInteger)self.batchListingPageIndex;
    NSURL *pageURL = [self.class sitePageURLForSeed:self.batchSeedURL page:pageNumber];
    if (!pageURL) {
        [self finishBatchForGeneration:generation cancelled:NO];
        return;
    }
    @synchronized (self.countingProbe) {
        self.countingProbe.pageLimit = 50;
        self.countingProbe.pageCount = 0;
        self.countingProbe.completedCount = 0;
    }
    [self.countingProbe.startedURLs removeAllObjects];
    [self.countingProbe.completedURLs removeAllObjects];
    [self emitStatus:[NSString stringWithFormat:@"正在读取列表页 %lu/%lu…",
                      (unsigned long)(self.batchListingPageIndex + 1),
                      (unsigned long)self.batchListingPageCount]];
    ZZResourceDiscoveryOptions *options = [ZZResourceDiscoveryOptions defaultOptions];
    options.mode = ZZResourceDiscoveryModeSite;
    options.maxSubpageCount = 50;
    options.requestInterval = 0;
    options.maxConcurrentPageProbes = MAX((NSUInteger)1, self.maxConcurrentPageProbes);
    options.pageBatchDeadline = self.pageBatchDeadline;
    options.maxRetries = 0;
    [self configureCoordinatorPreviewHandlerForGeneration:generation];
    __weak typeof(self) w = self;
    [self.coordinator discoverFromURL:pageURL options:options completion:^(ZZResourceDiscoveryResult *result) {
        __strong typeof(w) s = w;
        if (!s || generation != s.sessionGeneration || !s.batchActive) return;
        if (!s.batchCancelRequested && !result.cancelled &&
            s.batchListingPageRetryAttempt < kDSCMaxListingPageRetries &&
            DSCShouldRetryListingPageError(result.error)) {
            s.batchListingPageRetryAttempt += 1;
            NSUInteger retryAttempt = s.batchListingPageRetryAttempt;
            NSTimeInterval delay = DSCListingRetryDelay(retryAttempt);
            s.batchListingPageRetryScheduled = YES;
            [s emitStatus:[NSString stringWithFormat:@"列表页 %lu/%lu 暂时无法读取，正在重试（%lu/%lu）…",
                           (unsigned long)(s.batchListingPageIndex + 1),
                           (unsigned long)s.batchListingPageCount,
                           (unsigned long)retryAttempt,
                           (unsigned long)kDSCMaxListingPageRetries]];
            __weak typeof(s) weakSelf = s;
            s.retryScheduler(delay, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.batchActive || strongSelf.batchCancelRequested ||
                    generation != strongSelf.sessionGeneration) return;
                strongSelf.batchListingPageRetryScheduled = NO;
                [strongSelf startBatchListingPageForGeneration:generation];
            });
            return;
        }
        s.batchListingPageRetryAttempt = 0;
        if (result) [s.batchResults addObject:result];
        if (s.batchCancelRequested || result.cancelled) {
            [s finishBatchForGeneration:generation cancelled:YES];
            return;
        }
        s.batchListingPageIndex += 1;
        if (s.progressHandler) {
            s.progressHandler(MIN(0.99, (double)s.batchListingPageIndex /
                                          (double)s.batchListingPageCount));
        }
        if (s.batchListingPageIndex >= s.batchListingPageCount) {
            [s finishBatchForGeneration:generation cancelled:NO];
        } else {
            [s startBatchListingPageForGeneration:generation];
        }
    }];
}

- (void)finishBatchForGeneration:(NSInteger)generation cancelled:(BOOL)cancelled {
    if (!self.batchActive || generation != self.sessionGeneration) return;
    NSArray<ZZResourceDiscoveryResult *> *pages = [self.batchResults copy] ?: @[];
    ZZResourceDiscoveryResult *batch = [ZZResourceDiscoveryResult new];
    batch.seedURL = self.batchSeedURL;
    batch.mode = ZZResourceDiscoveryModeSite;
    batch.listingPageResults = pages;
    batch.requestedListingPageCount = self.batchListingPageCount;
    batch.cancelled = cancelled;

    NSMutableArray *pageResults = [NSMutableArray array];
    NSMutableArray *candidateURLs = [NSMutableArray array];
    NSMutableArray *allMedia = [NSMutableArray array];
    NSMutableSet<NSString *> *mediaKeys = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *posters = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *candidateKeys = [NSMutableSet set];
    static const NSUInteger kBatchResultLimit = 500;
    NSError *firstError = nil;
    NSUInteger completed = 0;
    for (ZZResourceDiscoveryResult *page in pages) {
        if (pageResults.count < kBatchResultLimit) {
            NSUInteger remaining = kBatchResultLimit - pageResults.count;
            [pageResults addObjectsFromArray:[(page.pageResults ?: @[]) subarrayWithRange:NSMakeRange(0, MIN(remaining, page.pageResults.count))]];
        }
        for (NSURL *candidate in page.candidateURLs ?: @[]) {
            if (candidateURLs.count >= kBatchResultLimit) break;
            NSString *key = candidate.absoluteString ?: @"";
            if (!key.length || [candidateKeys containsObject:key]) continue;
            [candidateKeys addObject:key];
            [candidateURLs addObject:candidate];
        }
        [titles addEntriesFromDictionary:page.preferredTitleByPageURL ?: @{}];
        [posters addEntriesFromDictionary:page.preferredPosterByPageURL ?: @{}];
        if (!page.cancelled && page.error == nil) completed += 1;
        if (!firstError && page.error) firstError = page.error;
        for (DetectedMedia *media in [RDResourceModeFilter allowedMedia:page.allMedia mode:ZZResourceDiscoveryModeSite]) {
            NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL];
            if (!key.length || [mediaKeys containsObject:key]) continue;
            if (allMedia.count >= kBatchResultLimit) break;
            [mediaKeys addObject:key];
            [allMedia addObject:media];
        }
    }
    batch.pageResults = pageResults;
    batch.candidateURLs = candidateURLs;
    batch.allMedia = allMedia;
    batch.preferredTitleByPageURL = titles;
    batch.preferredPosterByPageURL = posters;
    batch.completedListingPageCount = completed;
    // 同批带上「是否回退探测当前页」（2026-10-13 第 42 轮接线）：该标志此前只写到
    // 单页结果（ResourceDiscoveryCoordinator 的 r.usedCurrentPageFallback），批次层
    // 从不设置、也无人读取——算出来等于不存在。现在由各分页结果汇入批次。
    for (ZZResourceDiscoveryResult *page in pages) {
        if (page.usedCurrentPageFallback) { batch.usedCurrentPageFallback = YES; break; }
    }
    if (completed == 0 && firstError) batch.error = firstError;

    self.batchActive = NO;
    self.batchCancelRequested = NO;
    self.batchListingPageRetryAttempt = 0;
    self.batchListingPageRetryScheduled = NO;
    // Defer thumbnail network work until every listing page has released its
    // probe connections.  Consumers still receive the same per-page results.
    if (!cancelled && self.listingPageResultHandler) {
        NSUInteger index = 0;
        for (ZZResourceDiscoveryResult *page in pages) {
            index += 1;
            self.listingPageResultHandler(page, index, self.batchListingPageCount);
        }
    }
    if (!cancelled && self.progressHandler) self.progressHandler(1);
    if (self.resultHandler) self.resultHandler(batch);
}

- (void)cancel {
    if (self.batchActive) {
        self.batchCancelRequested = YES;
        // During retry backoff there is no active coordinator request to
        // deliver the cancellation completion.  Finish the batch directly.
        if (self.batchListingPageRetryScheduled) {
            self.batchListingPageRetryScheduled = NO;
            [self finishBatchForGeneration:self.sessionGeneration cancelled:YES];
        }
    }
    [self.coordinator cancel];
}

#pragma mark - 探测失败后的公开信号检查（会话延续配套）

// 复用探测自己的 HTML 来源（生产实现是共用同一 WebKit 会话存储的离屏 WebView）。
// 这是一条独立的、只读的页面读取：不进入探测会话的状态机，也不影响在途探测任务。
- (nullable id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    if (!url || !completion) return nil;
    return [self.htmlProvider loadHTMLForURL:url completion:completion];
}

- (void)cancelHTMLRequest:(nullable id)token {
    [self.htmlProvider cancelHTMLRequest:token];
}

#pragma mark - 站点模式翻页（纯 URL 工具）

// ── 多形态分页 ───────────────────────────────────────────────────────────────
// 真实站点的分页标记远不止 `?page=N`：`/page/2`、`/page2`、`_p2`、`-2`、`?p=2`、
// `?pg=2`、`?paged=2`、`/index_2.html` 都很常见。此前只认 `?page=N`，这类站点
// 填了页数也只会重复请求同一页（甚至 404）。风格由种子 URL 自身推断，用户不选。
//
// 两条不变量（先后顺序要紧，改代码前先读）：
//
// ① **零回归**：默认风格 QueryPage 走的是**与历史实现逐字相同**的一段代码——
//    连「用 NSURLQueryItem 重组 query」这一步都原样保留。原因是实测：换成
//    「原始字节」路线会改动历史上被 queryItems 解码过的形态（`a=%2B` → `a=+`、
//    `a=%7e` → `a=~`、`%41` → `A`），与「逐字相同」冲突。零回归优先级更高，
//    故 QueryPage 原路保留。
// ② **新风格一律按原始字节处理** path 与 query（`percentEncodedPath` /
//    `percentEncodedQuery`），不经 `.string` 重组，别的参数（筛选条件）连同其
//    原始 percent-encoding 一起原样搬运 —— 与 HTTPPrivacyPolicy.m 的
//    `fullPageURLStringForURL:` 同一手法、同一理由。

/// 去掉尾部多余斜杠（保留根路径的单个 "/"）。
static NSString *RDPGTrimTrailingSlashes(NSString *path) {
    NSString *s = path ?: @"";
    while (s.length > 1 && [s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

/// 非空且首字符不是 "/" 时补一个（避免构造出相对路径形态）。
static NSString *RDPGAbsolutePath(NSString *path) {
    NSString *s = path ?: @"";
    if (s.length == 0) return @"";
    return [s hasPrefix:@"/"] ? s : [@"/" stringByAppendingString:s];
}

static BOOL RDPGIsAllDigits(NSString *s) {
    if (s.length == 0) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if (ch < '0' || ch > '9') return NO;
    }
    return YES;
}

/// 末段拆成「主干 + 扩展名（含点）」。无扩展名时 ext 为空串。
/// 只把「非首位、非末位、且点后非空」的最后一个点当分隔符，`/name.` 与 `/.hidden`
/// 都按无扩展名处理（宁可少拆，不可把名字拆坏）。
static void RDPGSplitExtension(NSString *segment, NSString **outStem, NSString **outExt) {
    NSString *s = segment ?: @"";
    NSString *stem = s;
    NSString *ext = @"";
    NSRange dot = [s rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0 && dot.location + 1 < s.length) {
        stem = [s substringToIndex:dot.location];
        ext = [s substringFromIndex:dot.location];
    }
    if (outStem) *outStem = stem;
    if (outExt) *outExt = ext;
}

/// 末段主干是否为 `base + separator + 数字` 形态；是则回传去掉标记的主干与页码。
/// 返回 0 表示不是该形态（或页码 < 1）。不做上限判断——上限在生成侧拦截。
static NSInteger RDPGTrailingPageMark(NSString *stem, NSString *separator, NSString **outBase) {
    if (stem.length == 0 || separator.length == 0) return 0;
    NSUInteger idx = stem.length;
    while (idx > 0) {
        unichar ch = [stem characterAtIndex:idx - 1];
        if (ch < '0' || ch > '9') break;
        idx--;
    }
    if (idx == stem.length) return 0;          // 没有尾随数字
    if (idx < separator.length) return 0;      // 数字前面放不下分隔符
    NSString *sep = [stem substringWithRange:NSMakeRange(idx - separator.length, separator.length)];
    if ([sep caseInsensitiveCompare:separator] != NSOrderedSame) return 0;
    long long v = [[stem substringFromIndex:idx] longLongValue];
    if (v < 1) return 0;
    if (outBase) *outBase = [stem substringToIndex:idx - separator.length];
    return (NSInteger)v;
}

/// 在原始（未解码）query 上按段名去掉一个参数，page>=2 时再追加 `name=page`。
/// 其余段落**逐字**保留：不重排、不重编码、不丢顺序。全部为空段 → nil（避免尾部 "?"）。
static NSString *RDPGRebuiltRawQuery(NSString *rawQuery, NSString *name, NSInteger page) {
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    // 空 query 必须当成「零段」：`[@"" componentsSeparatedByString:@"&"]` 会返回 @[@""]，
    // 直接遍历会留下一个空段，拼出来就是 `?&paged=2` 这种多一个 & 的形态。
    NSString *raw = rawQuery ?: @"";
    NSArray<NSString *> *segments = raw.length ? [raw componentsSeparatedByString:@"&"] : @[];
    for (NSString *seg in segments) {
        if (seg.length == 0) { [kept addObject:seg]; continue; }
        NSString *key = [[seg componentsSeparatedByString:@"="] firstObject];
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) continue;   // 旧标记丢弃
        [kept addObject:seg];
    }
    if (page >= 2) [kept addObject:[NSString stringWithFormat:@"%@=%ld", name, (long)page]];
    // 只留非空段再拼；全空 → nil（否则 URL 尾部残留 "?" 或孤立的 "&"）。
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *seg in kept) if (seg.length > 0) [nonEmpty addObject:seg];
    return nonEmpty.count ? [nonEmpty componentsJoinedByString:@"&"] : nil;
}

/// 原始 query 里按段名读页码。`found` 仅在「参数存在**且**值像页码」时为 YES。
/// 这一点很关键：`?p=12345` 这类参数存在但不是页码（WordPress 文章 ID），若 `found=YES`
/// 探测就会认成 QueryP 风格，然后 page 1 → 剥掉 `p` 参数（退化成首页）、或者页码超上限
/// 直接返回 nil —— 都比「什么都不做」更糟。故不像页码就当我们没看见它。
static NSInteger RDPGRawQueryPage(NSString *rawQuery, NSString *name, BOOL *found) {
    if (found) *found = NO;
    for (NSString *seg in [(rawQuery ?: @"") componentsSeparatedByString:@"&"]) {
        if (seg.length == 0) continue;
        NSArray<NSString *> *kv = [seg componentsSeparatedByString:@"="];
        if ([kv.firstObject caseInsensitiveCompare:name] != NSOrderedSame) continue;
        NSString *value = kv.count > 1 ? [kv objectAtIndex:1] : @"";
        NSInteger v = value.integerValue;     // 非数字/空串 → 0
        if (!RDPGPageIsPlausibleMark(v)) return 1;   // 存在但不像页码 → 不认作分页标记
        if (found) *found = YES;
        return v;
    }
    return 1;
}

/// 把「基础路径 + 若干段」拼成绝对路径（base 为空时从根开始）。
static NSString *RDPGPathAppendingSegments(NSString *basePath, NSArray<NSString *> *segments) {
    NSString *s = RDPGTrimTrailingSlashes(basePath);
    NSMutableString *out = [NSMutableString stringWithString:s ?: @""];
    for (NSString *seg in segments) {
        if (out.length == 0) [out appendString:@"/"];
        else if (![out hasSuffix:@"/"]) [out appendString:@"/"];
        [out appendString:seg];
    }
    return RDPGAbsolutePath(out);
}

/// 替换末段（其余段原样保留）。
static NSString *RDPGPathReplacingLastSegment(NSString *path, NSString *newLast) {
    NSString *trimmed = RDPGTrimTrailingSlashes(path);
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithArray:[trimmed componentsSeparatedByString:@"/"]];
    if (out.count == 0) [out addObject:@""];
    [out removeLastObject];
    [out addObject:newLast ?: @""];
    return RDPGAbsolutePath([out componentsJoinedByString:@"/"]);
}

/// 判定一个「疑似页码」是否可信。
///
/// 为什么需要这道闸门（真实误判，不是防御性编程）：路径/参数末段的数字**未必**是页码。
/// 实测反例：WordPress 的 `?p=12345` 是文章 ID（不是第 12345 页）、`photo_2024.html`
/// 是年份、`name-1080` 是分辨率、`clip_2160p` 是画质档。若照字面认成页码，生成器会把
/// `photo_2024.html` 剥成 `photo.html`、把 `?p=12345` 整个剥掉（退化成首页）——**比不改
/// 更糟**：原本能探测的站点直接 404。
///
/// 判据就是本工具自己的翻页上限：`siteMaxPages` 之外的数字不可能是我们要翻的页，
/// 故一律当「不是分页标记」，退回默认风格（= 历史行为，零回归），绝不猜。
static BOOL RDPGPageIsPlausibleMark(NSInteger page) {
    return page >= 1 && page <= (NSInteger)[DiscoverySessionController siteMaxPages];
}

/// `/page/N`（含 /page/N/）：回传去掉该段的基路径与页码。
static BOOL RDPGPathSlashMark(NSString *path, NSString **outBase, NSInteger *outPage) {
    NSArray<NSString *> *segs = [RDPGTrimTrailingSlashes(path) componentsSeparatedByString:@"/"];
    NSUInteger n = segs.count;
    if (n < 2) return NO;
    NSString *last = segs[n - 1];
    NSString *prev = segs[n - 2];
    if (!RDPGIsAllDigits(last)) return NO;
    if ([prev caseInsensitiveCompare:@"page"] != NSOrderedSame) return NO;
    long long v = [last longLongValue];
    if (!RDPGPageIsPlausibleMark((NSInteger)v)) return NO;
    NSMutableArray<NSString *> *base = [NSMutableArray array];
    for (NSUInteger i = 0; i + 2 < n; i++) [base addObject:segs[i]];
    if (outBase) *outBase = [base componentsJoinedByString:@"/"];
    if (outPage) *outPage = (NSInteger)v;
    return YES;
}

/// `/pageN`：回传去掉该段的基路径与页码。
static BOOL RDPGPathConcatMark(NSString *path, NSString **outBase, NSInteger *outPage) {
    NSArray<NSString *> *segs = [RDPGTrimTrailingSlashes(path) componentsSeparatedByString:@"/"];
    if (segs.count == 0) return NO;
    NSString *last = segs.lastObject ?: @"";
    if (last.length < 5) return NO;                       // "page" + 至少一位数字
    if ([[last substringToIndex:4] caseInsensitiveCompare:@"page"] != NSOrderedSame) return NO;
    NSString *digits = [last substringFromIndex:4];
    if (!RDPGIsAllDigits(digits)) return NO;
    long long v = [digits longLongValue];
    if (!RDPGPageIsPlausibleMark((NSInteger)v)) return NO;
    NSMutableArray<NSString *> *base = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < segs.count; i++) [base addObject:segs[i]];
    if (outBase) *outBase = [base componentsJoinedByString:@"/"];
    if (outPage) *outPage = (NSInteger)v;
    return YES;
}

/// 末段 `name_sepN.ext`（分隔符由风格定）。回传去掉标记后的末段与页码。
static BOOL RDPGSuffixMark(NSString *segment, NSString *separator, NSString **outSegment, NSInteger *outPage) {
    NSString *stem = nil, *ext = nil;
    RDPGSplitExtension(segment, &stem, &ext);
    NSString *base = nil;
    NSInteger v = RDPGTrailingPageMark(stem, separator, &base);
    if (!RDPGPageIsPlausibleMark(v)) return NO;
    if (outSegment) *outSegment = [(base ?: @"") stringByAppendingString:ext];
    if (outPage) *outPage = v;
    return YES;
}

/// `index_N.html`：须扩展名为 .html 且主干去掉标记后恰为 "index"。
static BOOL RDPGIndexHTMLMark(NSString *segment, NSString **outSegment, NSInteger *outPage) {
    NSString *stem = nil, *ext = nil;
    RDPGSplitExtension(segment, &stem, &ext);
    if ([ext caseInsensitiveCompare:@".html"] != NSOrderedSame) return NO;
    NSString *base = nil;
    NSInteger v = RDPGTrailingPageMark(stem, @"_", &base);
    if (!RDPGPageIsPlausibleMark(v)) return NO;
    if ([(base ?: @"") caseInsensitiveCompare:@"index"] != NSOrderedSame) return NO;
    if (outSegment) *outSegment = [base stringByAppendingString:ext];
    if (outPage) *outPage = v;
    return YES;
}

/// 用原始字节组装结果：path / query 原样搬运，query 为空必须置 nil（否则尾部残留 "?"），
/// fragment 一律丢弃（对探测无意义）。
static NSURL *RDPGBuildURL(NSURLComponents *components, NSString *encodedPath, NSString *encodedQuery) {
    NSURLComponents *out = [components copy];
    if (!out) return nil;
    out.percentEncodedPath = RDPGAbsolutePath(encodedPath);
    out.percentEncodedQuery = (encodedQuery.length > 0) ? encodedQuery : nil;
    out.fragment = nil;
    return out.URL;
}

/// 各查询型风格的参数名。非查询型返回 nil。
static NSString *RDPGQueryMarkName(RDPaginationStyle style) {
    switch (style) {
        case RDPaginationStyleQueryPage:  return @"page";
        case RDPaginationStyleQueryP:     return @"p";
        case RDPaginationStyleQueryPg:    return @"pg";
        case RDPaginationStyleQueryPaged: return @"paged";
        default:                          return nil;
    }
}

/// 各后缀型风格的分隔符。非后缀型返回 nil。
static NSString *RDPGSuffixSeparator(RDPaginationStyle style) {
    switch (style) {
        case RDPaginationStyleSuffixP:          return @"_p";
        case RDPaginationStyleSuffixDash:       return @"-";
        case RDPaginationStyleSuffixUnderscore: return @"_";
        default:                                return nil;
    }
}

/// 种子 URL 的健全性检查（下游 URLPolicy 还会再校验，这里只做本函数自洽所需的最基本判断）。
static BOOL RDPGSeedComponents(NSURL *seedURL, NSURLComponents **outComponents) {
    if (!seedURL) return NO;
    NSString *scheme = seedURL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    NSURLComponents *c = [NSURLComponents componentsWithURL:seedURL resolvingAgainstBaseURL:NO];
    if (!c) return NO;
    if (c.host.length == 0) return NO;
    // userinfo：解析属性与原始 URL 两路都查一遍，防止解析路径差异漏判。
    if (c.user != nil || c.password != nil) return NO;
    if (seedURL.user.length > 0 || seedURL.password.length > 0) return NO;
    if (outComponents) *outComponents = c;
    return YES;
}

+ (NSInteger)siteMaxPages {
    return 10;
}

+ (NSInteger)sitePageNumberFromURL:(NSURL *)url {
    if (!url) return 1;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return 1;
    for (NSURLQueryItem *item in c.queryItems ?: @[]) {
        if ([item.name.lowercaseString isEqualToString:@"page"]) {
            NSInteger v = item.value.integerValue;   // 非数字/空串 → 0
            return (v >= 1) ? v : 1;
        }
    }
    return 1;
}

+ (NSInteger)sitePageNumberFromURL:(NSURL *)url style:(RDPaginationStyle)style {
    // QueryPage 与既有单参方法同一口径（同一段代码），保证两处永不漂移。
    if (style == RDPaginationStyleQueryPage) return [self sitePageNumberFromURL:url];
    if (!url) return 1;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return 1;
    NSString *rawQuery = c.percentEncodedQuery ?: @"";
    NSString *path = c.percentEncodedPath ?: @"";
    NSString *segment = [RDPGTrimTrailingSlashes(path) componentsSeparatedByString:@"/"].lastObject ?: @"";

    NSString *queryName = RDPGQueryMarkName(style);
    if (queryName) {
        BOOL found = NO;
        NSInteger v = RDPGRawQueryPage(rawQuery, queryName, &found);
        return found ? v : 1;
    }
    if (style == RDPaginationStylePathSlash) {
        NSString *base = nil; NSInteger v = 1;
        return RDPGPathSlashMark(path, &base, &v) ? v : 1;
    }
    if (style == RDPaginationStylePathConcat) {
        NSString *base = nil; NSInteger v = 1;
        return RDPGPathConcatMark(path, &base, &v) ? v : 1;
    }
    if (style == RDPaginationStyleIndexHtml) {
        NSString *seg = nil; NSInteger v = 1;
        return RDPGIndexHTMLMark(segment, &seg, &v) ? v : 1;
    }
    NSString *separator = RDPGSuffixSeparator(style);
    if (separator) {
        NSString *seg = nil; NSInteger v = 1;
        return RDPGSuffixMark(segment, separator, &seg, &v) ? v : 1;
    }
    return 1;
}

+ (RDPaginationStyle)detectPaginationStyleForURL:(NSURL *)url {
    // 纯函数：只看 URL 自身，不触网、不读 HTML（从 HTML 里找「下一页」链接需要
    // 额外一次请求，超出本工具范围）。识别不出就退回历史默认风格。
    if (!url) return RDPaginationStyleQueryPage;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return RDPaginationStyleQueryPage;
    NSString *rawQuery = c.percentEncodedQuery ?: @"";
    NSString *path = c.percentEncodedPath ?: @"";
    NSString *segment = [RDPGTrimTrailingSlashes(path) componentsSeparatedByString:@"/"].lastObject ?: @"";

    // ① 查询参数形态。顺序即优先级：page 最具体（也是历史行为），故先判。
    for (RDPaginationStyle s = RDPaginationStyleQueryPage; s <= RDPaginationStyleQueryPaged; s++) {
        NSString *name = RDPGQueryMarkName(s);
        BOOL found = NO;
        RDPGRawQueryPage(rawQuery, name, &found);
        if (found) return s;
    }
    // ② 路径形态。
    NSString *base = nil; NSInteger v = 1;
    if (RDPGPathSlashMark(path, &base, &v)) return RDPaginationStylePathSlash;
    if (RDPGPathConcatMark(path, &base, &v)) return RDPaginationStylePathConcat;
    // ③ 末段形态。IndexHtml 必须在 SuffixUnderscore 之前（`index_9.html` 两者都像）。
    NSString *seg = nil;
    if (RDPGIndexHTMLMark(segment, &seg, &v)) return RDPaginationStyleIndexHtml;
    if (RDPGSuffixMark(segment, @"_p", &seg, &v)) return RDPaginationStyleSuffixP;
    if (RDPGSuffixMark(segment, @"-", &seg, &v)) return RDPaginationStyleSuffixDash;
    if (RDPGSuffixMark(segment, @"_", &seg, &v)) return RDPaginationStyleSuffixUnderscore;
    return RDPaginationStyleQueryPage;   // 默认
}

+ (NSURL *)sitePageURLForSeed:(NSURL *)seedURL page:(NSInteger)page {
    return [self sitePageURLForSeed:seedURL page:page style:[self detectPaginationStyleForURL:seedURL]];
}

+ (NSURL *)sitePageURLForSeed:(NSURL *)seedURL page:(NSInteger)page style:(RDPaginationStyle)style {
    // page < 1 返回 nil（不静默当 1）。
    if (page < 1) return nil;
    // 上限按**种子自己的起始页**相对计算，而不是「页码绝对 ≤ 10」。
    // 依据（实测，不是推测）：调用点第 388-390 行是 pageNumber = firstPage + index，
    // 第 373 行夹紧的是「页数 count ≤ siteMaxPages」，不是页码绝对值。若这里改用绝对上限，
    // 一个 `?page=15` 的种子会在第一页就拿到 nil、整批直接结束（0 结果）——
    // 那比改前更糟，也违背「任何带 ?page=N 的 URL 输出逐字相同」这条硬约束。
    // 相对口径下两种保证同时成立：无标记种子（firstPage=1）区间 1..10，
    // 故 page=11 → nil、page=10 → 正常；`?page=15` 种子区间 15..24，与改前逐字相同。
    NSInteger firstPage = [self sitePageNumberFromURL:seedURL style:style];
    if (firstPage < 1) firstPage = 1;
    NSInteger maxPage = firstPage + (NSInteger)[self siteMaxPages] - 1;
    if (page > maxPage) return nil;
    NSURLComponents *c = nil;
    if (!RDPGSeedComponents(seedURL, &c)) return nil;

    NSString *encodedPath = c.percentEncodedPath ?: @"";
    NSString *encodedQuery = c.percentEncodedQuery;
    NSString *queryName = RDPGQueryMarkName(style);

    if (style == RDPaginationStyleQueryPage) {
        // ── 零回归分支：历史实现逐字保留（连 queryItems 重组这一步也不换）。
        // 保留除 page 外的全部查询参数（筛选条件如 genre 不丢）；旧 page 丢弃
        NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
        for (NSURLQueryItem *item in c.queryItems ?: @[]) {
            if ([item.name.lowercaseString isEqualToString:@"page"]) continue;
            [items addObject:item];
        }
        if (page >= 2) {
            [items addObject:[NSURLQueryItem
                queryItemWithName:@"page" value:[NSString stringWithFormat:@"%ld", (long)page]]];
        }
        // 空数组必须置 nil，否则 URL 尾部会残留 "?"
        c.queryItems = items.count ? [items copy] : nil;
        c.fragment = nil;   // fragment 对探测无意义
        return c.URL;
    }

    if (queryName) {
        // 其余查询型：原始字节处理，别的参数连同其 percent-encoding 原样保留。
        NSString *q = RDPGRebuiltRawQuery(encodedQuery, queryName, page);
        return RDPGBuildURL(c, encodedPath, q);
    }

    if (style == RDPaginationStylePathSlash || style == RDPaginationStylePathConcat) {
        BOOL isSlash = (style == RDPaginationStylePathSlash);
        NSString *base = nil; NSInteger ignored = 1;
        BOOL hasMark = isSlash ? RDPGPathSlashMark(encodedPath, &base, &ignored)
                               : RDPGPathConcatMark(encodedPath, &base, &ignored);
        if (!hasMark) base = RDPGTrimTrailingSlashes(encodedPath);   // 种子还没有标记
        NSString *newPath = base;
        if (page >= 2) {
            NSString *num = [NSString stringWithFormat:@"%ld", (long)page];
            newPath = isSlash ? RDPGPathAppendingSegments(base, @[@"page", num])
                              : RDPGPathAppendingSegments(base, @[[@"page" stringByAppendingString:num]]);
        }
        // query 全部保留（原样，不重编码）
        return RDPGBuildURL(c, newPath, encodedQuery);
    }

    // ── 末段型：后缀 / index_N.html ──
    BOOL isIndex = (style == RDPaginationStyleIndexHtml);
    NSString *separator = isIndex ? @"_" : RDPGSuffixSeparator(style);
    if (!separator) return nil;
    NSString *segment = [RDPGTrimTrailingSlashes(encodedPath) componentsSeparatedByString:@"/"].lastObject ?: @"";
    NSString *stem = nil, *ext = nil;
    RDPGSplitExtension(segment, &stem, &ext);
    // 种子已带本风格标记时先剥掉，否则「前进再后退」会叠出 name_p2_p1 这类垃圾路径。
    NSString *stripped = nil;
    NSInteger strippedPage = 1;
    if (isIndex) {
        if (RDPGIndexHTMLMark(segment, &stripped, &strippedPage)) {
            RDPGSplitExtension(stripped ?: @"", &stem, &ext);
        }
    } else if (RDPGTrailingPageMark(stem, separator, &stripped) >= 1) {
        stem = stripped ?: @"";
    }
    if (isIndex && ext.length == 0) ext = @".html";
    NSString *newSegment = (page >= 2)
        ? [NSString stringWithFormat:@"%@%@%ld%@", stem, separator, (long)page, ext]
        : [stem stringByAppendingString:ext];
    return RDPGBuildURL(c, RDPGPathReplacingLastSegment(encodedPath, newSegment), encodedQuery);
}

@end
