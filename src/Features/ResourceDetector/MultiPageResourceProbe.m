//
//  MultiPageResourceProbe.m — 第 3 阶段｜多页面串行编排器实现
//
//  实现要点（对应提示词 §十二/§十三）：
//  · 所有可变状态只在自建的串行队列 stateQueue 上读写（串行队列天然互斥，
//    不新增并发队列、不加锁）；
//  · generation：每开始一个新任务 +1、取消时再 +1。页面完成回调先比对
//    generation，不匹配（迟到/已取消/已被新任务顶替）立即作废；
//  · 每页只接受第一次完成回调：idx 必须等于当前 currentIndex 且
//    currentPageCompletionAccepted == NO，第二次起直接作废；
//  · finishOnce：finished 标志保证 completion 恰好一次；回调固定主线程；
//  · 输入去重：过滤 nil 后按规范化 key（scheme/host 小写 + 显式端口 +
//    percent-encoded 路径 + query，不含 fragment）去重，保留首次出现的
//    NSURL 原对象，顺序即处理顺序（key 规则与第 2 阶段
//    SubpageLinkExtractor 的 SLEDedupKeyForURL 同思路，因该函数为
//    static 不可跨文件复用，此处实现等价的页面级最小版本）；
//  · 资源合并：复用 [DetectedMedia dedupKeyForURL:]（去 fragment、
//    scheme/host 小写、保留 query——满足"不同清晰度/不同 query 不误合并"）；
//    页面级结果原样保留该页全部资源，allMedia 跨页去重、按首次发现顺序。
//

#import "MultiPageResourceProbe.h"

#pragma mark - 页面 URL 规范化 key（仅用于输入去重）

static NSString *MPPageDedupKey(NSURL *u) {
    if (!u) return @"";
    NSString *abs = u.absoluteString;
    if (abs.length == 0) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithString:abs];
    if (!c || c.scheme.length == 0 || c.host.length == 0) {
        return abs;  // 解析退化：以原串为 key（保守可用，不崩溃）
    }
    NSMutableString *key = [NSMutableString
        stringWithFormat:@"%@://%@", c.scheme.lowercaseString, c.host.lowercaseString];
    if (c.port) [key appendFormat:@":%@", c.port];
    if (c.percentEncodedPath.length > 0) [key appendString:c.percentEncodedPath];
    if (c.percentEncodedQuery.length > 0) [key appendFormat:@"?%@", c.percentEncodedQuery];
    return key;
}

#pragma mark - 编排器

@interface MultiPageResourceProbe ()
@property (nonatomic, strong) dispatch_queue_t stateQueue;        // 串行状态队列
@property (nonatomic, assign) NSInteger generation;               // 迟到回调作废凭据
@property (nonatomic, copy) NSArray<NSURL *> *pages;              // 去重后的页面
@property (nonatomic, strong) NSArray<MultiPageProbePageResult *> *pageResults;
@property (nonatomic, copy, nullable) void (^currentCompletion)(MultiPageProbeSummary *);
@property (nonatomic, strong, nullable) id currentProbeToken;     // 当前页探测器凭据
@property (nonatomic, assign) NSUInteger currentIndex;
@property (nonatomic, assign) BOOL currentPageCompletionAccepted; // 每页只接受一次
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *activeProbeTokens;
@property (nonatomic, strong) NSMutableIndexSet *activeIndexes;
@property (nonatomic, strong) NSMutableIndexSet *acceptedIndexes;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *mediaKeys; // 资源去重 key
@property (nonatomic, strong) NSMutableArray<DetectedMedia *> *allMedia;  // 首次发现顺序
@end

@implementation MultiPageResourceProbe

- (instancetype)initWithPageProbe:(id<ZZSinglePageProbing>)pageProbe {
    return [self initWithPageProbe:pageProbe maxConcurrentProbes:1];
}

- (instancetype)initWithPageProbe:(id<ZZSinglePageProbing>)pageProbe
              maxConcurrentProbes:(NSUInteger)maxConcurrentProbes {
    self = [super init];
    if (self) {
        _pageProbe = pageProbe;
        _maxConcurrentProbes = MAX((NSUInteger)1, MIN((NSUInteger)32, maxConcurrentProbes));
        _stateQueue = dispatch_queue_create("zz.multipageprobe.state", DISPATCH_QUEUE_SERIAL);
        _pages = @[];
        _pageResults = @[];
        _mediaKeys = [NSMutableOrderedSet orderedSet];
        _allMedia = [NSMutableArray array];
        _activeProbeTokens = [NSMutableDictionary dictionary];
        _activeIndexes = [NSMutableIndexSet indexSet];
        _acceptedIndexes = [NSMutableIndexSet indexSet];
        _finished = YES;  // 无任务在运行
    }
    return self;
}

- (void)probePageURLs:(NSArray<NSURL *> *)pageURLs
           completion:(void (^)(MultiPageProbeSummary *summary))completion {
    NSArray<NSURL *> *input = pageURLs ?: @[];
    dispatch_sync(self.stateQueue, ^{
        [self beginTaskWithPageURLs:input completion:completion];
    });
}

- (void)cancelAll {
    dispatch_sync(self.stateQueue, ^{
        [self cancelCurrentTaskOnStateQueue];
    });
}

- (BOOL)isRunning {
    __block BOOL running = NO;
    dispatch_sync(self.stateQueue, ^{
        running = !self.finished;
    });
    return running;
}

#pragma mark - 任务生命周期（以下方法均在 stateQueue 上下文执行）

// 开始（或顶替）一个任务：若旧任务仍在运行，先取消旧任务（其 completion
// 以 cancelled 汇总恰好回调一次），再重置状态启动新任务。
- (void)beginTaskWithPageURLs:(NSArray<NSURL *> *)pageURLs
                   completion:(void (^)(MultiPageProbeSummary *))completion {
    if (!self.finished) {
        [self cancelCurrentTaskOnStateQueue];
    }

    // 过滤 nil + 按 key 去重，保留首次出现顺序
    NSMutableArray<NSURL *> *pages = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSURL *u in pageURLs) {
        if (!u) continue;
        NSString *key = MPPageDedupKey(u);
        if (key.length == 0) continue;
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [pages addObject:u];
    }

    self.generation += 1;
    self.pages = [pages copy];
    NSMutableArray<MultiPageProbePageResult *> *results = [NSMutableArray array];
    for (NSURL *u in self.pages) {
        [results addObject:[MultiPageProbePageResult resultWithPageURL:u]];
    }
    self.pageResults = [results copy];
    self.currentCompletion = completion;
    self.currentProbeToken = nil;
    self.currentIndex = 0;
    self.currentPageCompletionAccepted = NO;
    self.cancelled = NO;
    self.finished = NO;
    self.mediaKeys = [NSMutableOrderedSet orderedSet];
    self.allMedia = [NSMutableArray array];
    self.activeProbeTokens = [NSMutableDictionary dictionary];
    self.activeIndexes = [NSMutableIndexSet indexSet];
    self.acceptedIndexes = [NSMutableIndexSet indexSet];

    if (self.pages.count == 0) {
        [self finishOnceOnStateQueue];  // 空输入：不调用探测器，直接汇总
        return;
    }
    [self startAvailablePagesOnStateQueue];
}

// 按并发上限补满在途页面。默认上限为 1，因此旧串行时序完全保持。
- (void)startAvailablePagesOnStateQueue {
    while (!self.finished &&
           self.activeIndexes.count < MAX((NSUInteger)1, self.maxConcurrentProbes) &&
           self.currentIndex < self.pages.count) {
        NSUInteger idx = self.currentIndex++;
        self.pageResults[idx].status = MultiPageProbePageStatusProbing;
        [self.activeIndexes addIndex:idx];
        NSInteger gen = self.generation;
        NSURL *url = self.pages[idx];
        __weak typeof(self) w = self;
        id token = nil;
        if ([self.pageProbe respondsToSelector:@selector(probePageURL:incrementalCompletion:)]) {
            // 增量发布型探测器：可能先给一次「已能填列表」的临时结果，再给最终
            // 结果。临时回调只刷新本页结果、（可选）透出一次临时汇总，既不推进
            // 页面循环也不结束任务，因此动态腿独有的资源不会被丢掉。
            token = [self.pageProbe probePageURL:url
                           incrementalCompletion:^(NSArray<DetectedMedia *> *media, NSError *error, BOOL isFinal) {
                __strong typeof(w) s = w;
                if (!s) return;
                dispatch_async(s.stateQueue, ^{
                    [s handlePageIncrementalCompletionOnStateQueueWithGeneration:gen
                                                                            index:idx
                                                                           medium:media
                                                                            error:error
                                                                          isFinal:isFinal];
                });
            }];
        } else {
            token = [self.pageProbe probePageURL:url
                                      completion:^(NSArray<DetectedMedia *> *media, NSError *error) {
                __strong typeof(w) s = w;
                if (!s) return;
                dispatch_async(s.stateQueue, ^{
                    [s handlePageCompletionOnStateQueueWithGeneration:gen
                                                                index:idx
                                                               medium:media
                                                                error:error];
                });
            }];
        }
        if(token)self.activeProbeTokens[@(idx)]=token;
    }
    if(self.currentIndex>=self.pages.count&&self.activeIndexes.count==0)[self finishOnceOnStateQueue];
}

// 页面完成回调（stateQueue 上下文）：三重防线作废迟到/重复回调。
- (void)handlePageCompletionOnStateQueueWithGeneration:(NSInteger)gen
                                                  index:(NSUInteger)idx
                                                 medium:(nullable NSArray<DetectedMedia *> *)media
                                                  error:(nullable NSError *)error {
    if (self.finished) return;                          // 任务已结束
    if (gen != self.generation) return;                 // 迟到/取消/顶替后的回调
    if (![self.activeIndexes containsIndex:idx]) return;
    if ([self.acceptedIndexes containsIndex:idx]) return;
    [self.acceptedIndexes addIndex:idx];
    [self.activeIndexes removeIndex:idx];
    [self.activeProbeTokens removeObjectForKey:@(idx)];

    MultiPageProbePageResult *page = self.pageResults[idx];
    if (error != nil) {
        page.status = MultiPageProbePageStatusFailed;
        page.error = error;
        page.media = @[];
    } else {
        NSArray<DetectedMedia *> *m = media ?: @[];
        page.media = [m copy];
        page.status = (m.count > 0) ? MultiPageProbePageStatusSucceeded
                                   : MultiPageProbePageStatusEmpty;
        // 跨页资源合并去重（保留首次发现顺序；query 参与去重、fragment 不参与）
        for (DetectedMedia *item in m) {
            NSString *key = [DetectedMedia dedupKeyForURL:item.mediaURL];
            if (key.length == 0) continue;
            if ([self.mediaKeys containsObject:key]) continue;
            [self.mediaKeys addObject:key];
            [self.allMedia addObject:item];
        }
    }

    if (self.currentIndex >= self.pages.count && self.activeIndexes.count == 0) {
        [self finishOnceOnStateQueue];
    } else {
        [self startAvailablePagesOnStateQueue];
    }
}

// 增量发布回调（stateQueue 上下文）：isFinal=NO 是「已能填列表」的临时结果——
// 只原位刷新该页结果、（可选）向上层透出一次临时汇总，不推进页面循环、不结束
// 任务；isFinal=YES 才走既有的「接受该页最终结果」路径。这样多次发布（静态取页
// 腿先发布、动态腿回来再合并）不会把临时结果当成终态，动态腿独有资源不被丢弃。
- (void)handlePageIncrementalCompletionOnStateQueueWithGeneration:(NSInteger)gen
                                                            index:(NSUInteger)idx
                                                           medium:(nullable NSArray<DetectedMedia *> *)media
                                                            error:(nullable NSError *)error
                                                          isFinal:(BOOL)isFinal {
    if (isFinal) {
        [self handlePageCompletionOnStateQueueWithGeneration:gen index:idx medium:media error:error];
        return;
    }
    if (self.finished) return;                          // 任务已结束
    if (gen != self.generation) return;                 // 迟到/取消/顶替后的回调
    if (![self.activeIndexes containsIndex:idx]) return;
    if ([self.acceptedIndexes containsIndex:idx]) return;

    MultiPageProbePageResult *page = self.pageResults[idx];
    NSArray<DetectedMedia *> *m = media ?: @[];
    page.media = [m copy];
    page.status = (m.count > 0) ? MultiPageProbePageStatusSucceeded
                                : MultiPageProbePageStatusEmpty;
    page.error = error;

    void (^cb)(MultiPageProbeSummary *) = self.interimSummaryHandler;
    if (cb) {
        MultiPageProbeSummary *summary = [self summarySnapshotOnStateQueue];
        dispatch_async(dispatch_get_main_queue(), ^{ cb(summary); });
    }
}

- (NSArray<MultiPageProbePageResult *> *)pageResultsSnapshotSync {
    __block NSArray<MultiPageProbePageResult *> *snapshot = nil;
    dispatch_sync(self.stateQueue, ^{ snapshot = [self.pageResults copy]; });
    return snapshot ?: @[];
}

// 取消当前任务（stateQueue 上下文）：已完成页面保留，当前页标记取消，
// 未开始页面保持 NotStarted，completion 以 cancelled 汇总恰好一次。
- (void)cancelCurrentTaskOnStateQueue {
    if (self.finished) return;  // 已结束：重复取消无害
    self.generation += 1;       // 所有在途回调立即作废
    self.cancelled = YES;
    // A nil cancellation token does not mean the page has finished.
    [self.activeIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.pageResults.count) self.pageResults[idx].status = MultiPageProbePageStatusCancelled;
        id token = self.activeProbeTokens[@(idx)];
        if (token) [self.pageProbe cancelProbe:token];
    }];
    [self.activeProbeTokens removeAllObjects];
    [self.activeIndexes removeAllIndexes];
    self.currentProbeToken = nil;
    [self finishOnceOnStateQueue];
}

// 汇总快照（stateQueue 上下文）：临时汇总与最终汇总共用同一口径——始终按输入
// 页面顺序重建（并发完成顺序不稳定），资源跨页去重、保留首次发现顺序。
- (MultiPageProbeSummary *)summarySnapshotOnStateQueue {
    NSMutableOrderedSet<NSString *> *orderedKeys=[NSMutableOrderedSet orderedSet];
    NSMutableArray<DetectedMedia *> *orderedMedia=[NSMutableArray array];
    for(MultiPageProbePageResult *page in self.pageResults){
        for(DetectedMedia *item in page.media ?: @[]){
            NSString *key=[DetectedMedia dedupKeyForURL:item.mediaURL];
            if(!key.length||[orderedKeys containsObject:key])continue;
            [orderedKeys addObject:key];
            [orderedMedia addObject:item];
        }
    }
    MultiPageProbeSummary *summary = [MultiPageProbeSummary new];
    summary.pageResults = [self.pageResults copy];
    summary.allMedia = [orderedMedia copy];
    summary.cancelled = self.cancelled;
    return summary;
}

// 汇总并回调（stateQueue 上下文）：finished 标志保证恰好一次；回调在主线程。
- (void)finishOnceOnStateQueue {
    if (self.finished) return;
    self.finished = YES;

    MultiPageProbeSummary *summary = [self summarySnapshotOnStateQueue];

    void (^cb)(MultiPageProbeSummary *) = self.currentCompletion;
    self.currentCompletion = nil;
    self.currentProbeToken = nil;
    if (cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(summary);
        });
    }
}

@end
