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

+ (NSURL *)sitePageURLForSeed:(NSURL *)seedURL page:(NSInteger)page {
    if (!seedURL) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:seedURL resolvingAgainstBaseURL:NO];
    if (!c) return nil;
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

@end
