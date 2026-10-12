//
//  RDMetadataRecoveryCoordinator.m — 元数据恢复编排实现（2026-10-12 第 38 轮接线）
//

#import "RDMetadataRecoveryCoordinator.h"
#import "RDDisplayMetadataRecoveryStore.h"
#import "ResourceTitleTranslator.h"
#import "RDCoverRecoveryEngine.h"
#import "RDTLSTrust.h"
#import "PreferencesStore.h"
#import "URLPolicy.h"

/// 封面内存缓存上限（与恢复引擎第 1 步「当前有效内存缓存」对应）。
static const NSUInteger kRDCoverMemoryCapacity = 32;

#pragma mark - 封面请求会话（带证书信任容错）

/// 恢复链第 3 步「原封面 URL 有限次重试」用的会话委托。
/// 只做 server trust 容错接管；其余形态仍由系统默认处理。
@interface RDMetadataCoverSessionDelegate : NSObject <NSURLSessionDataDelegate>
@end

@implementation RDMetadataCoverSessionDelegate
- (void)URLSession:(NSURLSession *)session
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if (RDTLSHandleServerTrustChallenge(challenge, @"meta/cover", completionHandler)) return;
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

#pragma mark -

@interface RDMetadataRecoveryCoordinator ()
@property (nonatomic, strong) RDDisplayMetadataRecoveryStore *store;
@property (nonatomic, strong) ResourceTitleTranslator *translator;
@property (nonatomic, strong) RDCoverRecoveryEngine *engine;
@property (nonatomic, strong, nullable) URLPolicy *policy;
@property (nonatomic, copy, nullable) RDMetadataReprobeHandler reprobeHandler;
@property (nonatomic, strong) PreferencesStore *preferences;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *coverMemory;
@property (nonatomic, strong) NSMutableArray<NSString *> *coverMemoryOrder;
@property (nonatomic, strong) NSURLSession *coverSession;
@property (nonatomic, strong) RDMetadataCoverSessionDelegate *coverDelegate;

@property (nonatomic, assign) NSUInteger recordedMediaCount;
@property (nonatomic, assign) NSUInteger translatedTitleCount;
@property (nonatomic, assign) NSUInteger coverRecoveryAttemptCount;
@end

@implementation RDMetadataRecoveryCoordinator

- (instancetype)initWithPolicy:(URLPolicy *)policy reprobeHandler:(RDMetadataReprobeHandler)reprobeHandler {
    return [self initWithPolicy:policy reprobeHandler:reprobeHandler preferences:nil];
}

- (instancetype)initWithPolicy:(URLPolicy *)policy
                reprobeHandler:(RDMetadataReprobeHandler)reprobeHandler
                   preferences:(PreferencesStore *)preferences {
    self = [super init];
    if (self) {
        _policy = policy;
        _reprobeHandler = [reprobeHandler copy];
        _preferences = preferences ?: PreferencesStore.shared;
        _store = [RDDisplayMetadataRecoveryStore new];
        _translator = [[ResourceTitleTranslator alloc] initWithSessionConfiguration:nil];
        _engine = [RDCoverRecoveryEngine new];
        _coverMemory = [NSMutableDictionary dictionary];
        _coverMemoryOrder = [NSMutableArray array];
        [self wireEngineProviders];
    }
    return self;
}

- (void)dealloc {
    [_coverSession invalidateAndCancel];
}

#pragma mark - 恢复引擎的 provider 注入（每条都对应引擎文档里的一步）

- (void)wireEngineProviders {
    __weak typeof(self) weak = self;

    // 1) 当前有效内存缓存（同步、廉价）
    _engine.memoryCacheProvider = ^NSImage *(NSString *reuseKey) {
        __strong typeof(weak) self = weak;
        return reuseKey.length ? self.coverMemory[reuseKey] : nil;
    };

    // 2) 最近一次成功的磁盘缓存 —— 本 App 没有封面磁盘缓存，如实留空
    //    （引擎允许 provider 为空，该步直接跳过；绝不伪造一个假缓存）。
    _engine.diskCacheProvider = nil;

    // 3) 单次「已验证」的封面请求：校验 HTTP 状态 + 图片解码，只有完全合法才回图
    _engine.posterFetchProvider = ^(NSURL *posterURL, NSURL *sourcePageURL,
                                    void (^completion)(NSImage *, NSInteger, NSError *)) {
        __strong typeof(weak) self = weak;
        [self fetchPosterAtURL:posterURL referer:sourcePageURL completion:completion];
    };

    // 4) 重新访问来源页并提取结构化展示元数据（引擎文档第 4 步）
    _engine.sourcePageMetadataProvider = ^(NSURL *sourcePageURL,
                                           void (^completion)(RDResourceDisplayMetadata *)) {
        __strong typeof(weak) self = weak;
        [self reprobeMetadataForSourcePageURL:sourcePageURL completion:completion];
    };

    // 5) 本地安全首帧 —— 本 App 无该能力，如实留空
    _engine.localFrameProvider = nil;

    // 6) URL 文本校验（安全策略）
    _engine.urlAllowedProvider = ^BOOL(NSURL *url) {
        __strong typeof(weak) self = weak;
        if (!url) return NO;
        if (!self.policy) return YES;   // 未注入策略时与引擎默认一致：视为放行
        URLPolicyDecision *d = [self.policy evaluateTextURL:url.absoluteString ?: @""];
        return d ? d.allowed : NO;
    };
}

#pragma mark - 记录（探测结果落地）

- (void)recordDetectedMedia:(NSArray<DetectedMedia *> *)media {
    for (DetectedMedia *m in media) {
        if (!m.sourcePageURL.length) continue;
        if (!m.title.length && !m.poster.length) continue;
        RDResourceDisplayMetadata *md =
            [RDResourceDisplayMetadata metadataWithTitle:m.title
                                         posterURLString:m.poster
                                     sourcePageURLString:m.sourcePageURL
                                              confidence:RDDisplayMetadataConfidenceMedium];
        [self.store recordRecoveredMetadata:md forSourcePageURL:m.sourcePageURL];
        self.recordedMediaCount += 1;
    }
}

- (void)recordListingPosters:(NSDictionary<NSString *, NSString *> *)posterByPageURL {
    for (NSString *pageURL in posterByPageURL) {
        NSString *poster = posterByPageURL[pageURL];
        if (!pageURL.length || !poster.length) continue;
        RDResourceDisplayMetadata *md =
            [RDResourceDisplayMetadata metadataWithTitle:nil
                                         posterURLString:poster
                                     sourcePageURLString:pageURL
                                              confidence:RDDisplayMetadataConfidenceLow];
        [self.store recordRecoveredMetadata:md forSourcePageURL:pageURL];
        self.recordedMediaCount += 1;
    }
}

- (RDResourceDisplayMetadata *)metadataForSourcePageURL:(NSString *)sourcePageURL {
    if (!sourcePageURL.length) return nil;
    return [self.store metadataForSourcePageURL:sourcePageURL];
}

#pragma mark - 标题翻译

- (void)resolvedTitleFor:(NSString *)title completion:(void (^)(NSString *))completion {
    if (!completion) return;
    if (!title.length || ![ResourceTitleTranslator titleNeedsChineseTranslation:title]) {
        completion(title ?: @"");
        return;
    }
    __weak typeof(self) weak = self;
    [self.translator translateTitle:title completion:^(NSString *translated) {
        __strong typeof(weak) self = weak;
        NSString *final = translated.length ? translated : title;
        if (translated.length && ![translated isEqualToString:title]) self.translatedTitleCount += 1;
        completion(final ?: @"");
    }];
}

#pragma mark - 封面恢复

- (void)rememberCover:(NSImage *)image forReuseKey:(NSString *)reuseKey {
    if (!image || !reuseKey.length) return;
    self.coverMemory[reuseKey] = image;
    [self.coverMemoryOrder removeObject:reuseKey];
    [self.coverMemoryOrder addObject:reuseKey];
    while (self.coverMemoryOrder.count > kRDCoverMemoryCapacity) {
        NSString *victim = self.coverMemoryOrder.firstObject;
        [self.coverMemoryOrder removeObjectAtIndex:0];
        [self.coverMemory removeObjectForKey:victim];
    }
}

- (void)recoverCoverForMedia:(DetectedMedia *)media completion:(void (^)(NSImage *))completion {
    if (!media || !completion) return;
    NSString *key = media.mediaURL.length ? media.mediaURL : (media.sourcePageURL ?: @"");
    if (!key.length) { completion(nil); return; }
    NSURL *posterURL = media.poster.length ? [NSURL URLWithString:media.poster] : nil;
    NSURL *sourcePageURL = media.sourcePageURL.length ? [NSURL URLWithString:media.sourcePageURL] : nil;
    self.coverRecoveryAttemptCount += 1;
    __weak typeof(self) weak = self;
    [self.engine recoverCoverForReuseKey:key
                               posterURL:posterURL
                           sourcePageURL:sourcePageURL
                              completion:^(NSImage *image, RDCoverRecoveryOutcome outcome,
                                           RDResourceDisplayMetadata *recovered) {
        __strong typeof(weak) self = weak;
        if (outcome == RDCoverRecoveryOutcomeSucceeded && image) [self rememberCover:image forReuseKey:key];
        // 恢复链带回的展示元数据同样落库（这正是「来源页重探测」这一步的价值）
        if (outcome == RDCoverRecoveryOutcomeSucceeded && recovered && sourcePageURL.absoluteString.length) {
            [self.store recordRecoveredMetadata:recovered forSourcePageURL:sourcePageURL.absoluteString];
        }
        completion(image);
    }];
}

#pragma mark - 封面请求（恢复链第 3 步）

- (void)fetchPosterAtURL:(NSURL *)posterURL
                 referer:(NSURL *)sourcePageURL
              completion:(void (^)(NSImage *, NSInteger, NSError *))completion {
    if (!posterURL.absoluteString.length) { completion(nil, 0, nil); return; }
    BOOL allowed = self.engine.urlAllowedProvider ? self.engine.urlAllowedProvider(posterURL) : YES;
    if (!allowed) {
        // 与引擎约定一致：不安全 URL 视为「不可重试的失败」
        completion(nil, 0, [NSError errorWithDomain:@"RDMetadataRecovery" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"封面 URL 未通过安全校验"}]);
        return;
    }
    if (!self.coverSession) {
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.HTTPCookieStorage = nil;          // 与探测/下载一致：封面链路无 Cookie
        cfg.HTTPShouldSetCookies = NO;
        cfg.URLCache = nil;
        cfg.timeoutIntervalForRequest = 10;
        self.coverDelegate = [RDMetadataCoverSessionDelegate new];
        self.coverSession = [NSURLSession sessionWithConfiguration:cfg
                                                          delegate:self.coverDelegate
                                                     delegateQueue:nil];
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:posterURL];
    req.timeoutInterval = 10;
    if (sourcePageURL.absoluteString.length) [req setValue:sourcePageURL.absoluteString forHTTPHeaderField:@"Referer"];
    __weak typeof(self) weak = self;
    NSURLSessionDataTask *task = [self.coverSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weak) self = weak;
        if (!self) { completion(nil, 0, err); return; }
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (err || !data.length || (status && (status < 200 || status >= 300))) {
            completion(nil, status, err);
            return;
        }
        // 「已验证」：MIME 可接受 + 能真正解码出图片，二者缺一不可
        NSString *mime = resp.MIMEType;
        if (![RDCoverRecoveryEngine isAcceptablePosterMIME:mime]) {
            completion(nil, status, [NSError errorWithDomain:@"RDMetadataRecovery" code:2
                                                   userInfo:@{NSLocalizedDescriptionKey: @"封面 MIME 不可接受"}]);
            return;
        }
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image.isValid) {
            completion(nil, status, [NSError errorWithDomain:@"RDMetadataRecovery" code:3
                                                   userInfo:@{NSLocalizedDescriptionKey: @"封面解码失败"}]);
            return;
        }
        [self rememberCover:image forReuseKey:posterURL.absoluteString];
        completion(image, status, nil);
    }];
    [task resume];
}

#pragma mark - 来源页重探测（恢复链第 4 步）

- (void)reprobeMetadataForSourcePageURL:(NSURL *)sourcePageURL
                             completion:(void (^)(RDResourceDisplayMetadata *))completion {
    if (!sourcePageURL.absoluteString.length || !self.reprobeHandler) {
        // 没有重探测能力时：退回到本地已记录的元数据（绝不伪造）
        RDResourceDisplayMetadata *known = [self.store metadataForSourcePageURL:sourcePageURL.absoluteString];
        completion(known);
        return;
    }
    __weak typeof(self) weak = self;
    self.reprobeHandler(sourcePageURL, ^(NSArray<DetectedMedia *> *media) {
        __strong typeof(weak) self = weak;
        if (!self) { completion(nil); return; }
        RDResourceDisplayMetadata *best = nil;
        for (DetectedMedia *m in media) {
            if (!m.poster.length && !m.title.length) continue;
            RDResourceDisplayMetadata *candidate =
                [RDResourceDisplayMetadata metadataWithTitle:m.title
                                             posterURLString:m.poster
                                         sourcePageURLString:sourcePageURL.absoluteString
                                                  confidence:RDDisplayMetadataConfidenceMedium];
            // 优先取「标题与封面都齐」的那条
            if (!best || (candidate.title.length && candidate.posterURLString.length)) best = candidate;
            if (best.title.length && best.posterURLString.length) break;
        }
        if (best) [self.store recordRecoveredMetadata:best forSourcePageURL:sourcePageURL.absoluteString];
        completion(best);
    });
}

#pragma mark - 持久化

- (void)persist {
    NSDictionary *dict = [self.store historyDictionary];
    [self.preferences setDictionary:dict ?: @{} forKey:SevenZZKeyDisplayMetadataHistory];
}

- (void)loadPersistedState {
    NSDictionary *dict = [self.preferences dictionaryForKey:SevenZZKeyDisplayMetadataHistory];
    if (dict.count) [self.store loadFromHistoryDictionary:dict];
}

#pragma mark - 取消

- (void)cancelAll {
    [self.translator cancelAll];
    [self.engine cancelAllRecovery];
}

@end
