//
//  RDCoverRecoveryEngine.m
//  7zz
//
//  封面自动恢复状态机实现。内部用一个串行队列（stateQueue）保护全部
//  状态；provider 回调可能来自任意线程，一律 hop 回 stateQueue 再推进；
//  最终结果只从主线程投递给调用方。
//

#import "RDCoverRecoveryEngine.h"

static const NSUInteger kRDCoverRecoveryDefaultMaxFetchAttempts = 3;
static const NSUInteger kRDCoverRecoveryHardMaxFetchAttempts = 3;
static const NSTimeInterval kRDCoverRecoveryDefaultBackoff = 0.4;
static const NSTimeInterval kRDCoverRecoveryDefaultWatchdog = 15.0;

// stateQueue 的队列级 specific key：init 时通过 dispatch_queue_set_specific 注册，
// syncOnStateQueue 用 dispatch_get_specific 检测“当前线程正在执行 stateQueue 的块”，
// 从而在串行队列内直接执行、避免 dispatch_sync 自派发死锁。
static const void * const kRDCoverStateQueueKey = &kRDCoverStateQueueKey;

@interface RDCoverRecoveryRecord : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong, nullable) NSURL *posterURL;
@property (nonatomic, strong, nullable) NSURL *sourcePageURL;
@property (nonatomic, assign) NSUInteger engineGeneration; // 创建时的引擎代次
@property (nonatomic, assign) BOOL inFlight;
@property (nonatomic, assign) BOOL terminal;
@property (nonatomic, assign) BOOL sourcePageAttempted;
@property (nonatomic, assign) RDCoverRecoveryOutcome outcome;
@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, strong, nullable) RDResourceDisplayMetadata *recoveredMetadata;
@property (nonatomic, strong) NSMutableArray<RDCoverRecoveryCompletion> *waiters;
@end

@implementation RDCoverRecoveryRecord
@end

@interface RDCoverRecoveryEngine ()
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDCoverRecoveryRecord *> *records;
@property (nonatomic, assign) NSUInteger engineGeneration;
@end

@implementation RDCoverRecoveryEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.sevenzz.cover-recovery", DISPATCH_QUEUE_SERIAL);
        // 注册队列级 specific，使 syncOnStateQueue 能可靠识别“已在 stateQueue 上”，
        // 避免在主线程/其它线程回调路径中 dispatch_sync 到自身串行队列造成死锁。
        dispatch_queue_set_specific(_stateQueue, kRDCoverStateQueueKey, (__bridge void *)self, NULL);
        _records = [NSMutableDictionary dictionary];
        _engineGeneration = 1;
        _maxFetchAttempts = kRDCoverRecoveryDefaultMaxFetchAttempts;
        _retryBackoffSeconds = kRDCoverRecoveryDefaultBackoff;
        _watchdogTimeout = kRDCoverRecoveryDefaultWatchdog;
    }
    return self;
}

#pragma mark - 公开查询（线程安全）

- (BOOL)isRecoveringKey:(NSString *)reuseKey {
    if (!reuseKey.length) return NO;
    return [[self syncOnStateQueue:^id{
        RDCoverRecoveryRecord *record = self->_records[reuseKey];
        return @(record && record.inFlight);
    }] boolValue];
}

- (BOOL)hasAttemptedKey:(NSString *)reuseKey {
    if (!reuseKey.length) return NO;
    return [[self syncOnStateQueue:^id{
        return @(self->_records[reuseKey] != nil);
    }] boolValue];
}

- (NSUInteger)recoveringKeyCount {
    return [[self syncOnStateQueue:^id{
        NSUInteger count = 0;
        for (RDCoverRecoveryRecord *record in self->_records.allValues) {
            if (record.inFlight) count += 1;
        }
        return @(count);
    }] unsignedIntegerValue];
}

- (void)cancelAllRecovery {
    dispatch_async(self.stateQueue, ^{
        self->_engineGeneration += 1;
        NSArray<RDCoverRecoveryRecord *> *records = [self->_records.allValues copy];
        for (RDCoverRecoveryRecord *record in records) {
            if (record.inFlight) [self finishRecord:record outcome:RDCoverRecoveryOutcomeSuperseded image:nil metadata:nil];
        }
    });
}

#pragma mark - 恢复入口

- (void)recoverCoverForReuseKey:(NSString *)reuseKey
                      posterURL:(NSURL *)posterURL
                  sourcePageURL:(NSURL *)sourcePageURL
                     completion:(RDCoverRecoveryCompletion)completion {
    if (!reuseKey.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, RDCoverRecoveryOutcomeFailed, nil);
        });
        return;
    }
    RDCoverRecoveryCompletion copied = completion;
    dispatch_async(self.stateQueue, ^{
        RDCoverRecoveryRecord *record = self->_records[reuseKey];
        if (record) {
            if (record.inFlight) {
                // 在途：共享同一条链路，绝不并发发起第二条恢复请求。
                if (copied) [record.waiters addObject:copied];
                return;
            }
            // 已终态：同一资源不再重复完整恢复（防请求风暴），直接复用结果。
            RDCoverRecoveryOutcome outcome = record.outcome;
            NSImage *image = record.image;
            RDResourceDisplayMetadata *metadata = record.recoveredMetadata;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (copied) copied(image, outcome, metadata);
            });
            return;
        }
        record = [[RDCoverRecoveryRecord alloc] init];
        record.key = reuseKey;
        record.posterURL = posterURL;
        record.sourcePageURL = sourcePageURL;
        record.engineGeneration = self->_engineGeneration;
        record.inFlight = YES;
        record.waiters = [NSMutableArray array];
        if (copied) [record.waiters addObject:copied];
        self->_records[reuseKey] = record;
        // 整体看门狗：任何一步挂起都不会无限等待，超时按失败收尾。
        NSTimeInterval timeout = self->_watchdogTimeout > 0 ? self->_watchdogTimeout : kRDCoverRecoveryDefaultWatchdog;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), self.stateQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && record.inFlight) {
                // 看门狗超时按失败收尾，但来源页若已带回结构化元数据（至少
                // 标题）仍随 completion 交回调用方，标题恢复不因封面超时丢失。
                [strongSelf finishRecord:record outcome:RDCoverRecoveryOutcomeFailed image:nil metadata:record.recoveredMetadata];
            }
        });
        [self stepMemory:record];
    });
}

#pragma mark - 恢复步骤（全部在 stateQueue 上编排；provider 一律主线程执行）

// 生产 provider 依赖主线程状态（App 层可变缓存字典、WKWebView.URL、
// WebKit Cookie Store 等），因此 provider 调用统一 hop 到主线程执行，
// 结果经其 completion 再回 stateQueue 推进状态机；引擎自身状态始终只在
// stateQueue 上读写。

// 步骤 1：内存缓存（同步 provider；主线程执行后回 stateQueue 处理）
- (void)stepMemory:(RDCoverRecoveryRecord *)record {
    if (![self recordStillActive:record]) return;
    if (!self.memoryCacheProvider) {
        [self stepDisk:record];
        return;
    }
    __weak typeof(self) weakSelf = self;
    NSImage *(^provider)(NSString *) = self.memoryCacheProvider;
    NSString *key = record.key;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSImage *image = provider(key); // 主线程：生产实现读取主线程可变缓存
        dispatch_async(weakSelf.stateQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf recordStillActive:record]) return;
            if (image) {
                [strongSelf finishRecord:record outcome:RDCoverRecoveryOutcomeSucceeded image:image metadata:nil];
                return;
            }
            [strongSelf stepDisk:record];
        });
    });
}

// 步骤 2：最近一次成功的磁盘缓存（只读；失败绝不覆盖成功缓存）
- (void)stepDisk:(RDCoverRecoveryRecord *)record {
    if (![self recordStillActive:record]) return;
    if (!self.diskCacheProvider) {
        [self stepFetch:record posterURL:record.posterURL attempt:0];
        return;
    }
    __block BOOL answered = NO;
    __weak typeof(self) weakSelf = self;
    void (^provider)(NSString *, void(^)(NSImage *)) = self.diskCacheProvider;
    NSString *key = record.key;
    dispatch_async(dispatch_get_main_queue(), ^{
        provider(key, ^(NSImage *image) {
            dispatch_async(weakSelf.stateQueue, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || answered || ![strongSelf recordStillActive:record]) return;
                answered = YES;
                if (image) {
                    [strongSelf finishRecord:record outcome:RDCoverRecoveryOutcomeSucceeded image:image metadata:nil];
                    return;
                }
                [strongSelf stepFetch:record posterURL:record.posterURL attempt:0];
            });
        });
    });
}

// 步骤 3：原封面 URL 有限次数重试（短退避）
- (void)stepFetch:(RDCoverRecoveryRecord *)record posterURL:(NSURL *)posterURL attempt:(NSUInteger)attempt {
    if (![self recordStillActive:record]) return;
    if (!posterURL || ![self urlAllowed:posterURL] || !self.posterFetchProvider) {
        [self stepSourcePage:record];
        return;
    }
    __block BOOL answered = NO;
    __weak typeof(self) weakSelf = self;
    void (^provider)(NSURL *, NSURL *, void(^)(NSImage *, NSInteger, NSError *)) = self.posterFetchProvider;
    NSURL *sourcePageURL = record.sourcePageURL;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 主线程：生产实现访问 WKWebView.URL 与 WebKit Cookie Store。
        provider(posterURL, sourcePageURL, ^(NSImage *image, NSInteger httpStatus, NSError *error) {
            dispatch_async(weakSelf.stateQueue, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || answered || ![strongSelf recordStillActive:record]) return;
                answered = YES;
                if (image) {
                    [strongSelf finishRecord:record outcome:RDCoverRecoveryOutcomeSucceeded image:image metadata:nil];
                    return;
                }
                NSUInteger maxAttempts = strongSelf->_maxFetchAttempts > 0
                    ? MIN(strongSelf->_maxFetchAttempts, kRDCoverRecoveryHardMaxFetchAttempts)
                    : kRDCoverRecoveryDefaultMaxFetchAttempts;
                BOOL recoverable = (error != nil) || [RDCoverRecoveryEngine isRecoverablePosterStatus:httpStatus];
                if (recoverable && attempt + 1 < maxAttempts) {
                    NSTimeInterval base = strongSelf->_retryBackoffSeconds > 0
                        ? strongSelf->_retryBackoffSeconds : kRDCoverRecoveryDefaultBackoff;
                    NSTimeInterval backoff = base * (double)(attempt + 1);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                                   strongSelf.stateQueue, ^{
                        [weakSelf stepFetch:record posterURL:posterURL attempt:attempt + 1];
                    });
                    return;
                }
                [strongSelf stepSourcePage:record];
            });
        });
    });
}

// 步骤 4：重新访问来源页面，提取新的封面 URL（每条链路最多一次）。
// 若注入 sourcePageMetadataProvider，则同时获得结构化展示元数据（标题 + 预览图）。
- (void)stepSourcePage:(RDCoverRecoveryRecord *)record {
    if (![self recordStillActive:record]) return;
    if (record.sourcePageAttempted) {
        [self stepLocalFrame:record];
        return;
    }
    record.sourcePageAttempted = YES;
    NSURL *pageURL = record.sourcePageURL;
    if (!pageURL || ![self urlAllowed:pageURL]) {
        [self stepLocalFrame:record];
        return;
    }

    // 优先使用结构化元数据 provider；否则退回到仅返回 posterURL 的旧 provider。
    if (self.sourcePageMetadataProvider) {
        [self stepSourcePageMetadata:record pageURL:pageURL];
        return;
    }
    if (self.sourcePagePosterProvider) {
        [self stepSourcePagePosterOnly:record pageURL:pageURL];
        return;
    }

    [self stepLocalFrame:record];
}

- (void)stepSourcePageMetadata:(RDCoverRecoveryRecord *)record
                       pageURL:(NSURL *)pageURL {
    __block BOOL answered = NO;
    __weak typeof(self) weakSelf = self;
    void (^provider)(NSURL *, void(^)(RDResourceDisplayMetadata *)) = self.sourcePageMetadataProvider;
    dispatch_async(dispatch_get_main_queue(), ^{
        provider(pageURL, ^(RDResourceDisplayMetadata *metadata) {
            dispatch_async(weakSelf.stateQueue, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || answered || ![strongSelf recordStillActive:record]) return;
                answered = YES;
                NSURL *newPosterURL = nil;
                if (metadata.posterURLString.length) {
                    newPosterURL = [NSURL URLWithString:metadata.posterURLString];
                }
                record.recoveredMetadata = metadata;
                if (newPosterURL && [strongSelf urlAllowed:newPosterURL]) {
                    [strongSelf stepFetchSourcePage:record posterURL:newPosterURL metadata:metadata attempt:0];
                    return;
                }
                [strongSelf stepLocalFrame:record];
            });
        });
    });
}

- (void)stepSourcePagePosterOnly:(RDCoverRecoveryRecord *)record
                         pageURL:(NSURL *)pageURL {
    __block BOOL answered = NO;
    __weak typeof(self) weakSelf = self;
    void (^provider)(NSURL *, void(^)(NSURL *)) = self.sourcePagePosterProvider;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 主线程：生产实现读取 WKWebView.URL / 复用网络会话。
        provider(pageURL, ^(NSURL *newPosterURL) {
            dispatch_async(weakSelf.stateQueue, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || answered || ![strongSelf recordStillActive:record]) return;
                answered = YES;
                if (newPosterURL && [strongSelf urlAllowed:newPosterURL]) {
                    // 新 URL 独立计数；其失败会回到这里，但 sourcePageAttempted
                    // 已置位，不会再重复解析来源页（链路严格有限步）。
                    [strongSelf stepFetch:record posterURL:newPosterURL attempt:0];
                    return;
                }
                [strongSelf stepLocalFrame:record];
            });
        });
    });
}

// 来源页提供的封面：获取成功后把结构化元数据一并带回调用方。
- (void)stepFetchSourcePage:(RDCoverRecoveryRecord *)record
                  posterURL:(NSURL *)posterURL
                   metadata:(RDResourceDisplayMetadata *)metadata
                     attempt:(NSUInteger)attempt {
    if (![self recordStillActive:record]) return;
    if (!posterURL || ![self urlAllowed:posterURL] || !self.posterFetchProvider) {
        [self stepLocalFrame:record];
        return;
    }
    __block BOOL answered = NO;
    __weak typeof(self) weakSelf = self;
    void (^provider)(NSURL *, NSURL *, void(^)(NSImage *, NSInteger, NSError *)) = self.posterFetchProvider;
    NSURL *sourcePageURL = record.sourcePageURL;
    dispatch_async(dispatch_get_main_queue(), ^{
        provider(posterURL, sourcePageURL, ^(NSImage *image, NSInteger httpStatus, NSError *error) {
            dispatch_async(weakSelf.stateQueue, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || answered || ![strongSelf recordStillActive:record]) return;
                answered = YES;
                if (image) {
                    [strongSelf finishRecord:record outcome:RDCoverRecoveryOutcomeSucceeded image:image metadata:metadata];
                    return;
                }
                NSUInteger maxAttempts = strongSelf->_maxFetchAttempts > 0
                    ? MIN(strongSelf->_maxFetchAttempts, kRDCoverRecoveryHardMaxFetchAttempts)
                    : kRDCoverRecoveryDefaultMaxFetchAttempts;
                BOOL recoverable = (error != nil) || [RDCoverRecoveryEngine isRecoverablePosterStatus:httpStatus];
                if (recoverable && attempt + 1 < maxAttempts) {
                    NSTimeInterval base = strongSelf->_retryBackoffSeconds > 0
                        ? strongSelf->_retryBackoffSeconds : kRDCoverRecoveryDefaultBackoff;
                    NSTimeInterval backoff = base * (double)(attempt + 1);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                                   strongSelf.stateQueue, ^{
                        [weakSelf stepFetchSourcePage:record posterURL:posterURL metadata:metadata attempt:attempt + 1];
                    });
                    return;
                }
                [strongSelf stepLocalFrame:record];
            });
        });
    });
}

// 步骤 5：本地安全首帧（provider 决定是否可用）
- (void)stepLocalFrame:(RDCoverRecoveryRecord *)record {
    if (![self recordStillActive:record]) return;
    if (!self.localFrameProvider) {
        // 无本地首帧兜底也按失败收尾，但已恢复的元数据（至少标题）必须交回。
        [self finishRecord:record outcome:RDCoverRecoveryOutcomeFailed image:nil metadata:record.recoveredMetadata];
        return;
    }
    __block BOOL answered = NO;
    __weak typeof(self) weakSelf = self;
    void (^provider)(NSString *, void(^)(NSImage *)) = self.localFrameProvider;
    NSString *key = record.key;
    dispatch_async(dispatch_get_main_queue(), ^{
        provider(key, ^(NSImage *image) {
            dispatch_async(weakSelf.stateQueue, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || answered || ![strongSelf recordStillActive:record]) return;
                answered = YES;
                // 标题恢复与封面恢复相互独立：来源页若已带回结构化元数据
                // （标题 + 预览图），即使本地首帧/封面最终失败，元数据（至少
                // 标题）也必须随 completion 交回调用方，绝不因封面失败丢弃。
                [strongSelf finishRecord:record
                                 outcome:image ? RDCoverRecoveryOutcomeSucceeded : RDCoverRecoveryOutcomeFailed
                                    image:image
                                 metadata:record.recoveredMetadata];
            });
        });
    });
}

#pragma mark - 内部工具

- (BOOL)recordStillActive:(RDCoverRecoveryRecord *)record {
    // stateQueue 上调用：换代或已收尾的记录不再推进。
    return record.inFlight && record.engineGeneration == self->_engineGeneration;
}

- (BOOL)urlAllowed:(NSURL *)url {
    if (!self.urlAllowedProvider) return YES;
    return self.urlAllowedProvider(url);
}

- (void)finishRecord:(RDCoverRecoveryRecord *)record
             outcome:(RDCoverRecoveryOutcome)outcome
                image:(nullable NSImage *)image
            metadata:(nullable RDResourceDisplayMetadata *)metadata {
    // stateQueue 上调用。
    if (!record.inFlight) return;
    record.inFlight = NO;
    record.terminal = YES;
    record.outcome = outcome;
    record.image = image;
    record.recoveredMetadata = metadata;
    NSArray<RDCoverRecoveryCompletion> *waiters = [record.waiters copy];
    [record.waiters removeAllObjects];
    if (outcome == RDCoverRecoveryOutcomeSuperseded) {
        // 换代/取消不是该资源的真实终态：从记录表中移除，允许后续（新页面/
        // 新会话）对同一资源重新发起完整恢复。真正的 Succeeded/Failed 才缓存，
        // 避免同一资源在引擎生命周期内重复完整恢复（防请求风暴）。
        [self->_records removeObjectForKey:record.key];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (RDCoverRecoveryCompletion waiter in waiters) waiter(image, outcome, metadata);
    });
}

- (id)syncOnStateQueue:(id (^)(void))work {
    if (!work) return nil;
    // dispatch_get_specific 检测当前线程是否正在执行本引擎 stateQueue 的块
    // （含嵌套队列），且必须与 self 匹配：多个引擎实例共享同一静态 key，
    // 只有 specific 值等于当前实例才说明“正在本队列内”，否则误判为已入队
    // 会在另一引擎的队列内直接执行导致竞态。命中 → 直接执行，绝不
    // dispatch_sync 到自己（防死锁）；未命中 → 同步派发到本引擎 stateQueue。
    if (dispatch_get_specific(kRDCoverStateQueueKey) == (__bridge void *)self) {
        return work();
    }
    __block id result = nil;
    dispatch_sync(self.stateQueue, ^{
        result = work();
    });
    return result;
}

#pragma mark - 纯分类函数

+ (BOOL)isAcceptablePosterMIME:(NSString *)mime {
    if (!mime.length) return YES;
    NSString *lower = mime.lowercaseString;
    return [lower hasPrefix:@"image/"] || [lower isEqualToString:@"application/octet-stream"];
}

+ (BOOL)isRecoverablePosterStatus:(NSInteger)httpStatus {
    if (httpStatus == 403 || httpStatus == 429) return YES;
    return httpStatus >= 500 && httpStatus < 600;
}

@end
