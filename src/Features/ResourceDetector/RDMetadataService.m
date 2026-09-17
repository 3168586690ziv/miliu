#import "RDMetadataService.h"
#import "RDLog.h"
#import "RDManifestParser.h"
#import "RDThumbnailGenerator.h"
#import "RDBoundedMovie.h"
#import "RDRangeAsset.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
// Reject QuickTime/ISO external data references before AVFoundation sees the local file.
static BOOL LocalAtoms(const uint8_t *bytes, NSUInteger length, NSUInteger depth) {
    if (depth > 16) return NO;
    NSUInteger offset = 0;
    while (offset < length) {
        if (length-offset < 8) return NO;
        uint32_t raw; memcpy(&raw,bytes+offset,4); uint64_t size = CFSwapInt32BigToHost(raw); NSUInteger header = 8;
        if (size == 1) { if (length-offset < 16) return NO; uint64_t big; memcpy(&big,bytes+offset+8,8); size = CFSwapInt64BigToHost(big); header = 16; }
        if (!size) size = length-offset;
        if (size < header || size > length-offset) return NO;
        const uint8_t *type = bytes+offset+4, *body = bytes+offset+header; NSUInteger count = (NSUInteger)size-header;
        if (!memcmp(type,"dref",4)) {
            if (count < 8 || body[0] || body[1] || body[2] || body[3]) return NO;
            uint32_t entries; memcpy(&entries,body+4,4); entries=CFSwapInt32BigToHost(entries);
            if (!entries || entries > 1024) return NO;
            NSUInteger pos=8;
            for (uint32_t i=0;i<entries;i++) {
                if (count-pos<12) return NO; uint32_t n; memcpy(&n,body+pos,4); n=CFSwapInt32BigToHost(n);
                if (n!=12 || (memcmp(body+pos+4,"url ",4) && memcmp(body+pos+4,"alis",4)) || body[pos+8] || body[pos+9] || body[pos+10] || body[pos+11]!=1) return NO;
                pos+=n;
            }
            if (pos!=count) return NO;
        }
        if (!memcmp(type,"rmra",4) || !memcmp(type,"rmda",4) || !memcmp(type,"rdrf",4)) return NO;
        if (!memcmp(type,"moov",4) || !memcmp(type,"trak",4) || !memcmp(type,"mdia",4) || !memcmp(type,"minf",4) || !memcmp(type,"dinf",4))
            if (!LocalAtoms(body,count,depth+1)) return NO;
        offset += (NSUInteger)size;
    }
    return YES;
}
@implementation RDMetadataField
- (NSString *)statusText { return @[@"已读取", @"未知", @"不支持", @"读取超时", @"读取失败", @"读取中…"][_state]; }
@end
static RDMetadataField *Field(RDMetadataState state, id value, NSString *source) {
    RDMetadataField *f = [RDMetadataField new]; f.state = state; f.value = value; f.source = source ?: @""; return f;
}
@implementation RDMetadataSnapshot
- (instancetype)init { if ((self = [super init])) { _duration = Field(RDMetadataLoading,nil,nil); _size = Field(RDMetadataLoading,nil,nil); _dimensions = Field(RDMetadataLoading,nil,nil); _preview = Field(RDMetadataLoading,nil,nil); } return self; }
@end

static NSArray<NSString *> *RDFieldNames(void) { return @[@"duration",@"size",@"dimensions",@"preview"]; }
// 显式取字段，避免 KVC 的 `state` 选择器被推断成 NSURLSessionTaskState。
static RDMetadataField *RDFieldNamed(RDMetadataSnapshot *s, NSString *name) {
    if ([name isEqualToString:@"duration"]) return s.duration;
    if ([name isEqualToString:@"size"]) return s.size;
    if ([name isEqualToString:@"dimensions"]) return s.dimensions;
    return s.preview;
}
static void RDSetFieldNamed(RDMetadataSnapshot *s, NSString *name, RDMetadataField *f) {
    if ([name isEqualToString:@"duration"]) s.duration = f;
    else if ([name isEqualToString:@"size"]) s.size = f;
    else if ([name isEqualToString:@"dimensions"]) s.dimensions = f;
    else s.preview = f;
}

// 字段级缓存条目：每个字段独立状态与写入时间。成功字段（Known/Unsupported）
// 与结构性未知（清单无总大小、live 无时长）复用 5 分钟；普通未知 30 秒；
// 失败/超时不写入缓存——下次订阅必须重试，绝不缓存成永久空白。
@interface RDMetadataCacheEntry : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, RDMetadataField *> *fields;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *stamps;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *variants;
@property (nonatomic, strong, nullable) NSDate *variantsStamp;
@end
@implementation RDMetadataCacheEntry
- (instancetype)init { if ((self = [super init])) { _fields = [NSMutableDictionary dictionary]; _stamps = [NSMutableDictionary dictionary]; } return self; }
@end

static NSTimeInterval RDTTLForField(RDMetadataField *f) {
    if (!f) return 0;
    if (f.state == RDMetadataKnown || f.state == RDMetadataUnsupported) return 300.0;
    if (f.state == RDMetadataUnknown)
        return ([f.source containsString:@"manifest"] || [f.source containsString:@"live"]) ? 300.0 : 30.0;
    return 0.0;   // Failed/Timeout/Loading 不参与复用
}
static BOOL RDFieldReusable(RDMetadataField *f, NSDate *stamp) {
    if (!f || !stamp) return NO;
    NSTimeInterval ttl = RDTTLForField(f);
    return ttl > 0 && [NSDate.date timeIntervalSinceDate:stamp] < ttl;
}

// 缩略图独立通道：海报请求不占元数据 work 的并发槽位，订阅时立即排队，
// 点击项可插队；排队中可取消，已在途的请求完成后写入字段缓存（不丢结果）。
@interface RDMetadataPreviewFetch : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *poster;
@property (nonatomic, copy, nullable) NSString *referer;
@property (nonatomic, strong) RDMetadataToken *token;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL finished;
@end
@implementation RDMetadataPreviewFetch
@end

@interface RDMetadataWork : NSObject
@property RDMetadataToken *token;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) DetectedMedia *media;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(RDMetadataSnapshot *)> *subscribers;
@property (nonatomic, strong) RDMetadataSnapshot *snapshot;
@property (nonatomic, strong, nullable) RDMetadataSnapshot *published;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL queued;
@property (nonatomic, assign) BOOL mediaLegsStarted;
// 首屏预热的 work 不等媒体腿：mediaLegsStarted 仍为 NO 是预期状态。
@property (nonatomic, assign) BOOL previewOnly;
@property (nonatomic, assign) NSUInteger pending;
@property (nonatomic, assign) NSUInteger rangeReserved;
// 前缀探测（bytes=0-1023）结果：经校验的头部数据、Content-Range 总长与
// ETag，供受限 moov 读取复用；probeResolved 表示该 leg 已结束（无论成败）。
@property (nonatomic, strong, nullable) NSData *probeHead;
@property (nonatomic, strong, nullable) NSData *probeData;
@property (nonatomic, strong, nullable) NSHTTPURLResponse *probeResponse;
@property (nonatomic, strong, nullable) NSError *probeError;
@property (nonatomic, assign) unsigned long long probeTotal;
@property (nonatomic, copy, nullable) NSString *probeEtag;
@property (nonatomic, assign) BOOL probeResolved;
// 本 work 的缩略图通道任务（可能已被更早的 work 启动并复用）。
@property (nonatomic, strong, nullable) RDMetadataPreviewFetch *previewFetch;
@end
@implementation RDMetadataWork
@end

@interface RDMetadataService ()
@property id<RDMetadataTransporting> transport;
@property NSMutableDictionary<NSString *, RDMetadataWork *> *inflight;
@property NSMutableDictionary<NSString *, RDMetadataPreviewFetch *> *previewInflight;
@property NSMutableDictionary<NSString *, RDMetadataCacheEntry *> *cache;
@property NSMutableArray<NSString *> *order;          // 字段缓存 LRU（全部字段）
@property NSMutableArray<NSString *> *previewOrder;   // 缩略图 LRU（单独容量上限）
// 海报按 URL 共享缓存：同一张海报会被同一影片的多个画质、以及“海报本身就是列表
// 里一条图片资源”两种身份分别订阅。只按媒体身份缓存会让同一张图被取多次
// （真实网址实测：同一张 408160h.jpg 被取 2 次）。按 URL 缓存后一次取回即共享。
@property NSMutableDictionary<NSString *, NSImage *> *posterURLCache;
@property NSMutableArray<NSString *> *posterURLOrder;
// 元数据并发上限（测试锁定）：同时活跃的 work ≤ 4，其余按订阅顺序排队；
// 排队中的 work 全部订阅者取消时直接出队，不发起任何底层请求。
@property NSUInteger activeWorks;
@property NSMutableArray<NSArray *> *startQueue;      // @[@[media, work, key], …]
// 缩略图通道并发上限：独立于元数据队列，保证首屏缩略图不等待详情。
@property NSUInteger activePreviews;
@property NSMutableArray<RDMetadataPreviewFetch *> *previewQueue;
@end

@implementation RDMetadataService
+ (NSTimeInterval)requestTimeoutForMethod:(NSString *)method budget:(NSUInteger)budget {
    // 分阶段超时预算（测试锁定）：HEAD 3s；≤2MB 的 Range 读取按 64KB/s 保守吞吐
    // 外推（1KB 探测仍 10s，1MB 约 16s，2MB 封顶 30s 与全局看门狗一致）；更大的
    // 块按 256KB/s 外推并同样封顶 30s。
    // 依据：真实网址实测 981KB moov 读取需要 6–12s（约 140KB/s）。旧的固定 10s
    // 会把仍在正常传输的读取判成超时，随后整段重传一次（实测多花 10s + 981KB）。
    if ([method isEqualToString:@"HEAD"]) return 3.0;
    if (budget <= 2 * 1024 * 1024) return MIN(30.0, MAX(10.0, budget / 65536.0));
    return MIN(30.0, MAX(10.0, budget / 262144.0));
}
- (instancetype)init { return [self initWithTransport:[RDMetadataTransport new]]; }
- (instancetype)initWithTransport:(id<RDMetadataTransporting>)transport {
    if ((self = [super init])) {
        _transport = transport;
        _inflight = [NSMutableDictionary dictionary];
        _previewInflight = [NSMutableDictionary dictionary];
        _cache = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _previewOrder = [NSMutableArray array];
        _startQueue = [NSMutableArray array];
        _previewQueue = [NSMutableArray array];
        _posterURLCache = [NSMutableDictionary dictionary];
        _posterURLOrder = [NSMutableArray array];
    }
    return self;
}

static const NSUInteger kRDMetadataMaxActiveWorks = 4;
static const NSUInteger kRDMetadataMaxActivePreviews = 3;
static const NSUInteger kRDMetadataCacheCapacity = 64;
static const NSUInteger kRDMetadataPreviewCapacity = 16;
static const NSUInteger kRDPosterURLCacheCapacity = 8;

#pragma mark - 媒体身份与字段缓存

// 规范化媒体身份：URL 走统一 canonical（host/scheme 小写、默认端口与 fragment
// 归一），同一地址的不同字符串写法命中同一缓存；poster/sourcePage 同样规范化。
// isManifest 不参与 key：清单身份可能在前缀探测后确认，若提前参与 key 会造成
// 同一地址在工作/缓存间漂移。
static DetectedMedia *RDNormalizedMedia(DetectedMedia *m) {
    DetectedMedia *input = [DetectedMedia new];
    input.mediaURL = m.mediaURL; input.poster = m.poster; input.sourcePageURL = m.sourcePageURL;
    input.resourceKind = m.resourceKind; input.isManifest = m.isManifest;
    input.durationSeconds = m.durationSeconds; input.pixelWidth = m.pixelWidth; input.pixelHeight = m.pixelHeight;
    input.sizeBytes = m.sizeBytes;
    return input;
}
static NSString *RDMetadataIdentityKey(DetectedMedia *m) {
    NSString *url = [DetectedMedia dedupKeyForURL:m.mediaURL ?: @""];
    NSString *poster = m.poster.length ? [DetectedMedia dedupKeyForURL:m.poster] : @"";
    NSString *page = m.sourcePageURL.length ? [DetectedMedia dedupKeyForURL:m.sourcePageURL] : @"";
    return [@[url, poster, page, @(m.resourceKind).stringValue] componentsJoinedByString:@"\n"];
}
- (RDMetadataCacheEntry *)cacheEntryForKey:(NSString *)key create:(BOOL)create {
    RDMetadataCacheEntry *entry = _cache[key];
    if (entry || !create) return entry;
    entry = [RDMetadataCacheEntry new];
    _cache[key] = entry;
    [_order removeObject:key];
    [_order addObject:key];
    while (_order.count > kRDMetadataCacheCapacity) {
        NSString *oldest = _order.firstObject;
        [_order removeObjectAtIndex:0];
        [_cache removeObjectForKey:oldest];
        [_previewOrder removeObject:oldest];
    }
    return entry;
}
- (void)touchCacheKey:(NSString *)key {
    [_order removeObject:key];
    [_order addObject:key];
}
- (void)removeCacheForKey:(NSString *)key {
    [_cache removeObjectForKey:key];
    [_order removeObject:key];
    [_previewOrder removeObject:key];
}
- (void)storeField:(RDMetadataField *)f forKey:(NSString *)key field:(NSString *)name {
    if (!f || f.state == RDMetadataFailed || f.state == RDMetadataTimeout || f.state == RDMetadataLoading) return;
    RDMetadataCacheEntry *entry = [self cacheEntryForKey:key create:YES];
    entry.fields[name] = Field(f.state, f.value, f.source);
    entry.stamps[name] = NSDate.date;
    [self touchCacheKey:key];
    if ([name isEqualToString:@"preview"]) {
        [_previewOrder removeObject:key];
        [_previewOrder addObject:key];
        while (_previewOrder.count > kRDMetadataPreviewCapacity) {
            NSString *oldest = _previewOrder.firstObject;
            [_previewOrder removeObjectAtIndex:0];
            RDMetadataCacheEntry *victim = _cache[oldest];
            [victim.fields removeObjectForKey:@"preview"];
            [victim.stamps removeObjectForKey:@"preview"];
        }
    }
}
- (void)storeVariants:(NSArray<NSDictionary *> *)variants forKey:(NSString *)key {
    if (!variants.count) return;
    RDMetadataCacheEntry *entry = [self cacheEntryForKey:key create:YES];
    entry.variants = variants;
    entry.variantsStamp = NSDate.date;
}
- (RDMetadataSnapshot *)cachedSnapshotForKey:(NSString *)key {
    RDMetadataCacheEntry *entry = _cache[key];
    if (!entry) return nil;
    RDMetadataSnapshot *s = [RDMetadataSnapshot new];
    BOOL any = NO;
    for (NSString *name in RDFieldNames()) {
        RDMetadataField *f = entry.fields[name];
        if (RDFieldReusable(f, entry.stamps[name])) {
            [s setValue:Field(f.state, f.value, f.source) forKey:name];
            any = YES;
        }
    }
    if (entry.variants.count && entry.variantsStamp && [NSDate.date timeIntervalSinceDate:entry.variantsStamp] < 300) {
        s.variants = entry.variants;
        any = YES;
    }
    return any ? s : nil;
}
// App 在切换回同一媒体时同步调用：立即拿回已缓存的字段/缩略图，再只请求缺失项。
- (RDMetadataSnapshot *)cachedSnapshotForMedia:(DetectedMedia *)media {
    NSAssert(NSThread.isMainThread, @"main queue");
    if (!media) return nil;
    return [self cachedSnapshotForKey:RDMetadataIdentityKey(RDNormalizedMedia(media))];
}

#pragma mark - 订阅入口

- (RDMetadataToken *)subscribeMedia:(DetectedMedia *)m reload:(BOOL)reload update:(void (^)(RDMetadataSnapshot *))update {
    return [self subscribeMedia:m reload:reload previewOnly:NO update:update];
}

- (RDMetadataToken *)subscribePreviewOnlyForMedia:(DetectedMedia *)m update:(void (^)(RDMetadataSnapshot *))update {
    return [self subscribeMedia:m reload:NO previewOnly:YES update:update];
}

- (RDMetadataToken *)subscribeMedia:(DetectedMedia *)m reload:(BOOL)reload previewOnly:(BOOL)previewOnly update:(void (^)(RDMetadataSnapshot *))update {

    RDLogWrite(@"meta", @"订阅 previewOnly=%d", previewOnly ? 1 : 0);
    NSAssert(NSThread.isMainThread, @"main queue");
    if (!update) return [RDMetadataToken new];
    m = RDNormalizedMedia(m);
    NSString *key = RDMetadataIdentityKey(m);
    RDMetadataToken *subscriber = [RDMetadataToken new];
    NSString *sid = NSUUID.UUID.UUIDString;
    if (reload) [self removeCacheForKey:key];
    RDMetadataWork *w = _inflight[key];
    if (!w) {
        RDMetadataSnapshot *cached = [self cachedSnapshotForKey:key];
        RDMetadataSnapshot *start = [RDMetadataSnapshot new];
        if (cached) {
            for (NSString *name in RDFieldNames()) {
                RDMetadataField *f = RDFieldNamed(cached,name);
                if (f) RDSetFieldNamed(start,name,Field(f.state, f.value, f.source));
            }
            start.variants = cached.variants;
        }
        // DOM 直接观测值（桥接上报的时长/像素）无需联网即可作为已知字段。
        if (start.duration.state == RDMetadataLoading && m.durationSeconds && isfinite(m.durationSeconds.doubleValue) && m.durationSeconds.doubleValue >= 0)
            start.duration = Field(RDMetadataKnown, m.durationSeconds, @"observed DOM metadata");
        if (start.dimensions.state == RDMetadataLoading && m.pixelWidth > 0 && m.pixelHeight > 0 && (double)m.pixelWidth * m.pixelHeight <= 100000000)
            start.dimensions = Field(RDMetadataKnown, [NSValue valueWithSize:NSMakeSize(m.pixelWidth, m.pixelHeight)], @"observed dimensions");
        BOOL anyLoading = NO;
        for (NSString *name in RDFieldNames()) if (RDFieldNamed(start,name).state == RDMetadataLoading) anyLoading = YES;
        if (!anyLoading) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (!subscriber.cancelled) update(start); });
            return subscriber;
        }
        w = [RDMetadataWork new];
        w.token = [RDMetadataToken new];
        w.key = key; w.media = m; w.snapshot = start;
        w.subscribers = [NSMutableDictionary dictionary];
        w.previewOnly = previewOnly;
        _inflight[key] = w;
    }
    w.subscribers[sid] = [^(RDMetadataSnapshot *s) { if (!subscriber.cancelled) update(s); } copy];
    __weak typeof(self) weak = self;
    __weak RDMetadataWork *weakWork = w;
    [subscriber addCancellation:^{
        RDMetadataWork *work = weakWork;
        [work.subscribers removeObjectForKey:sid];
        if (work && !work.subscribers.count && !work.finished) {
            work.finished = YES;
            [work.token cancel];
            // 排队中的缩略图预取可取消；已在途的请求允许完成并写入缓存。
            if (work.previewFetch && !work.previewFetch.started) [work.previewFetch.token cancel];
            if (weak.inflight[key] == work) [weak.inflight removeObjectForKey:key];
            [weak deactivateWork:work];
        }
    }];
    // 缩略图通道：订阅即启动，不等元数据 work 队列。
    if (w.snapshot.preview.state == RDMetadataLoading && m.poster.length && !w.previewFetch) {
        [self startPreviewForWork:w media:m];
    }
    // 元数据通道：只在前缀探测/moov/清单等 leg 真正需要时入队。
    // previewOnly（列表首屏预热）绝不出队媒体 leg：那些读取留给用户真正选中
    // 该资源时进行，避免首屏十几个预热任务与用户点击的详情抢同一批连接。
    if (!previewOnly && [self workNeedsMediaLegs:w]) {
        [self enqueueOrStart:w media:m key:key];
    } else if (!w.previewFetch) {
        [self publish:w];
        [self maybeFinishWork:w];
    }
    RDMetadataSnapshot *deliver = [self snapshotForWork:w];
    dispatch_async(dispatch_get_main_queue(), ^{ if (!subscriber.cancelled) update(deliver); });
    return subscriber;
}

- (void)prioritizeMedia:(DetectedMedia *)m {
    NSAssert(NSThread.isMainThread, @"main queue");
    NSString *key = RDMetadataIdentityKey(RDNormalizedMedia(m));
    RDMetadataWork *w = _inflight[key];
    if (w && !w.started && !w.finished) {
        NSUInteger index = [_startQueue indexOfObjectPassingTest:^BOOL(NSArray *entry, NSUInteger idx, BOOL *stop) { return [entry[2] isEqual:key]; }];
        if (index != NSNotFound && index != 0) {
            NSArray *entry = _startQueue[index];
            [_startQueue removeObjectAtIndex:index];
            [_startQueue insertObject:entry atIndex:0];
        }
    }
    RDMetadataPreviewFetch *f = _previewInflight[key];
    if (f && !f.started && !f.finished) {
        NSUInteger index = [_previewQueue indexOfObjectIdenticalTo:f];
        if (index != NSNotFound && index != 0) {
            [_previewQueue removeObjectAtIndex:index];
            [_previewQueue insertObject:f atIndex:0];
        }
    }
}

#pragma mark - work 生命周期与队列

- (BOOL)active:(RDMetadataWork *)w { return w && !w.finished && !w.token.cancelled; }
- (BOOL)workNeedsMediaLegs:(RDMetadataWork *)w {
    if (w.mediaLegsStarted) return NO;
    for (NSString *name in @[@"duration",@"size",@"dimensions"])
        if (RDFieldNamed(w.snapshot,name).state == RDMetadataLoading) return YES;
    // 没有海报时，首帧提取必须走媒体 leg。
    if (w.snapshot.preview.state == RDMetadataLoading && !w.media.poster.length) return YES;
    return NO;
}
- (void)deactivateWork:(RDMetadataWork *)w {
    if (!w.started) return;
    w.started = NO;
    if (self.activeWorks > 0) self.activeWorks--;
    [self pumpStartQueue];
}
- (void)pumpStartQueue {
    while (self.activeWorks < kRDMetadataMaxActiveWorks && self.startQueue.count) {
        NSArray *entry = self.startQueue.firstObject;
        [self.startQueue removeObjectAtIndex:0];
        RDMetadataWork *w = entry[1];
        w.queued = NO;
        if (w.finished || w.token.cancelled) continue;   // 排队中被取消：出队，不发请求
        self.activeWorks++; w.started = YES;
        [self startWork:entry[0] work:w key:entry[2]];
    }
}
- (void)enqueueOrStart:(RDMetadataWork *)w media:(DetectedMedia *)m key:(NSString *)key {
    if (w.started || w.queued || w.finished) return;
    if (self.activeWorks < kRDMetadataMaxActiveWorks) { self.activeWorks++; w.started = YES; [self startWork:m work:w key:key]; return; }
    w.queued = YES;
    NSArray *entry = @[m, w, key];
    [self.startQueue addObject:entry];
    __weak typeof(self) weak = self;
    __weak RDMetadataWork *weakWork = w;
    [w.token addCancellation:^{
        RDMetadataWork *work = weakWork;
        work.queued = NO;
        [weak.startQueue removeObject:entry];
    }];
}
- (void)startWork:(DetectedMedia *)m work:(RDMetadataWork *)w key:(NSString *)key {
    __weak typeof(self) weak = self; __weak RDMetadataWork *weakWork = w;
    // 30s 全局看门狗：任何字段仍停留 Loading 即判 Timeout 并收尾，
    // UI 绝不无限“读取中”。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        RDMetadataWork *work = weakWork;
        if (work && [weak active:work]) {
            for (NSString *name in RDFieldNames()) {
                RDMetadataField *f = RDFieldNamed(work.snapshot,name);
                if (f.state == RDMetadataLoading) RDSetFieldNamed(work.snapshot,name,Field(RDMetadataTimeout,nil,f.source));
            }
            work.pending = 0;
            [weak finish:work key:key];
        }
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self active:w]) { [self deactivateWork:w]; return; }
        [self publish:w];
        [self begin:m work:w key:key];
    });
}

#pragma mark - 缩略图独立通道

- (void)startPreviewForWork:(RDMetadataWork *)w media:(DetectedMedia *)m {
    // 同一海报 URL 已经解码过：直接写入本媒体的字段缓存与快照，不发网络请求。
    NSImage *shared = m.poster.length ? _posterURLCache[m.poster] : nil;
    if (shared) {
        [self storeField:Field(RDMetadataKnown, shared, @"poster URL cache") forKey:w.key field:@"preview"];
        w.snapshot.preview = Field(RDMetadataKnown, shared, @"poster URL cache");
        [self publish:w];
        [self maybeFinishWork:w];
        return;
    }
    RDMetadataPreviewFetch *f = _previewInflight[w.key];
    if (!f || f.finished || f.token.cancelled) {
        f = [RDMetadataPreviewFetch new];
        f.key = w.key; f.poster = m.poster; f.referer = m.sourcePageURL;
        f.token = [RDMetadataToken new];
        _previewInflight[w.key] = f;
        __weak typeof(self) weak = self;
        __weak RDMetadataPreviewFetch *weakFetch = f;
        [f.token addCancellation:^{
            RDMetadataPreviewFetch *fetch = weakFetch;
            [weak.previewQueue removeObject:fetch];
            if (fetch && fetch.started && !fetch.finished) [weak endPreviewFetch:fetch image:nil state:RDMetadataFailed source:@"cancelled"];
        }];
        [self enqueuePreviewFetch:f];
    }
    w.previewFetch = f;
}
- (void)enqueuePreviewFetch:(RDMetadataPreviewFetch *)f {
    if (self.activePreviews < kRDMetadataMaxActivePreviews) { [self startPreviewFetch:f]; return; }
    [_previewQueue addObject:f];
}
- (void)pumpPreviewQueue {
    while (self.activePreviews < kRDMetadataMaxActivePreviews && _previewQueue.count) {
        RDMetadataPreviewFetch *f = _previewQueue.firstObject;
        [_previewQueue removeObjectAtIndex:0];
        if (f.finished || f.token.cancelled) continue;
        [self startPreviewFetch:f];
    }
}
- (void)startPreviewFetch:(RDMetadataPreviewFetch *)f {
    if (!f || f.started || f.finished) return;
    f.started = YES; self.activePreviews++;
    NSDictionary *headers = f.referer.length ? @{@"Referer":f.referer,@"Accept-Encoding":@"identity"} : @{@"Accept-Encoding":@"identity"};
    __weak typeof(self) weak = self;
    __weak RDMetadataPreviewFetch *weakFetch = f;
    [self get:f.poster method:@"GET" headers:headers budget:2*1024*1024 token:f.token active:^BOOL{
        RDMetadataPreviewFetch *fetch = weakFetch;
        return fetch && !fetch.finished && !fetch.token.cancelled;
    } rangeOwner:nil attempt:0 maxAttempt:0 completion:^(RDMetadataResponse *r) {
        RDMetadataPreviewFetch *fetch = weakFetch;
        if (!fetch || fetch.finished || fetch.token.cancelled) { [weak endPreviewFetch:fetch image:nil state:RDMetadataFailed source:@"cancelled"]; return; }
        if (r.error) { [weak endPreviewFetch:fetch image:nil state:[weak state:r.error] source:@"poster HTTP"]; return; }
        [weak decodeImageData:r.data done:^(NSImage *image, NSValue *size, BOOL safe, BOOL hadProperties) {
            [weak endPreviewFetch:fetch image:image state:image ? RDMetadataKnown : (safe ? RDMetadataFailed : RDMetadataUnsupported) source:image ? @"poster / ImageIO" : @"ImageIO pixel budget"];
        }];
    }];
}
- (void)endPreviewFetch:(RDMetadataPreviewFetch *)f image:(NSImage *)image state:(RDMetadataState)state source:(NSString *)source {
    if (!f || f.finished) return;
    f.finished = YES;
    if (f.started && self.activePreviews > 0) self.activePreviews--;
    [_previewQueue removeObject:f];
    if (_previewInflight[f.key] == f) [_previewInflight removeObjectForKey:f.key];
    if (image) {
        [self storeField:Field(RDMetadataKnown, image, source ?: @"poster / ImageIO") forKey:f.key field:@"preview"];
        if (f.poster.length) {
            _posterURLCache[f.poster] = image;
            [_posterURLOrder removeObject:f.poster];
            [_posterURLOrder addObject:f.poster];
            while (_posterURLOrder.count > kRDPosterURLCacheCapacity) {
                NSString *victim = _posterURLOrder.firstObject;
                [_posterURLOrder removeObjectAtIndex:0];
                [_posterURLCache removeObjectForKey:victim];
            }
        }
    }
    RDMetadataWork *w = _inflight[f.key];
    if (w && w.previewFetch == f) {
        if (image) w.snapshot.preview = Field(RDMetadataKnown, image, source ?: @"poster / ImageIO");
        else if (w.snapshot.preview.state == RDMetadataLoading) {
            // 海报失败不立即定性：媒体 leg 仍在途/已排队时首帧仍可能补齐
            // （旧行为：poster 失败回退视频首帧）；只有确实没有媒体 leg 时才
            // 把失败/不支持写死。
            BOOL framePossible = w.started || w.queued;
            if (!framePossible) w.snapshot.preview = Field(state, nil, source);
        }
        w.previewFetch = nil;
        [self publish:w];
        [self maybeFinishWork:w];
    }
    [self pumpPreviewQueue];
}

#pragma mark - 网络请求（统一重试/预算/取消/超时）

- (void)get:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers budget:(NSUInteger)budget work:(RDMetadataWork *)w completion:(void (^)(RDMetadataResponse *))done {
    [self get:url method:method headers:headers budget:budget work:w maxAttempt:2 completion:done];
}
- (void)get:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers budget:(NSUInteger)budget work:(RDMetadataWork *)w maxAttempt:(NSUInteger)maxAttempt completion:(void (^)(RDMetadataResponse *))done {
    __weak typeof(self) weak = self;
    [self get:url method:method headers:headers budget:budget token:w.token active:^BOOL{ return [weak active:w]; } rangeOwner:w attempt:0 maxAttempt:maxAttempt completion:done];
}
- (void)get:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers budget:(NSUInteger)budget token:(RDMetadataToken *)token active:(BOOL (^)(void))active rangeOwner:(RDMetadataWork *)owner attempt:(NSUInteger)attempt maxAttempt:(NSUInteger)maxAttempt completion:(void (^)(RDMetadataResponse *))done {
    if (!done) return;
    if (active && !active()) return;
    if (headers[@"Range"]) {
        // moov 可达 1.5-4MB，逐块 Range 累计预留按 16MB 封顶（仍远小于整片体积）。
        if (owner) {
            if (budget > 16*1024*1024-owner.rangeReserved) { RDMetadataResponse *r=[RDMetadataResponse new]; r.error=[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBudgetExceeded userInfo:nil]; done(r); return; }
            owner.rangeReserved += budget; // Includes retries, conservatively reserves each response cap.
        }
    }
    NSURL *u = [NSURL URLWithString:url ?: @""];
    if (!u) { RDMetadataResponse *r = [RDMetadataResponse new]; r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBlocked userInfo:nil]; done(r); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u]; req.HTTPMethod = method; req.allHTTPHeaderFields = headers;
    // 分阶段超时预算：HEAD/小请求/大块传输各不相同（requestTimeoutForMethod 有测试锁定）。
    NSTimeInterval requestTimeout = [RDMetadataService requestTimeoutForMethod:method budget:budget];
    __weak typeof(self) weak = self;
    RDMetadataToken *t = [_transport request:req budget:budget timeout:requestTimeout completion:^(RDMetadataResponse *r) {
        __strong typeof(weak) s = weak;
        if (!s || (active && !active())) return;
        BOOL network = [r.error.domain isEqual:NSURLErrorDomain] && [@[@(NSURLErrorTimedOut),@(NSURLErrorNetworkConnectionLost),@(NSURLErrorCannotConnectToHost),@(NSURLErrorCannotFindHost),@(NSURLErrorNotConnectedToInternet)] containsObject:@(r.error.code)];
        BOOL timeout = [r.error.domain isEqual:RDMetadataErrorDomain] && r.error.code == RDMetadataTimedOut;
        BOOL http = r.response.statusCode == 429 || (r.response.statusCode >= 500 && r.response.statusCode <= 599);
        BOOL blocked = [r.error.domain isEqual:RDMetadataErrorDomain] && r.error.code == RDMetadataBlocked;
        if (attempt < maxAttempt && !blocked && (network || timeout || http)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((attempt ? .35 : .15)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                if (!active || active()) [s get:url method:method headers:headers budget:budget token:token active:active rangeOwner:owner attempt:attempt+1 maxAttempt:maxAttempt completion:done];
            });
        } else done(r);
    }];
    [token addCancellation:^{ [t cancel]; }];
}
- (RDMetadataState)state:(NSError *)error {
    if ([error.domain isEqual:RDMetadataErrorDomain] && error.code == RDMetadataBudgetExceeded) return RDMetadataUnsupported;
    if (([error.domain isEqual:RDMetadataErrorDomain] && error.code == RDMetadataTimedOut) || ([error.domain isEqual:NSURLErrorDomain] && error.code == NSURLErrorTimedOut)) return RDMetadataTimeout;
    return RDMetadataFailed;
}
static BOOL HasMediaSizeHeaders(NSHTTPURLResponse *response, DetectedMedia *media) {
    NSString *mime = response.MIMEType.lowercaseString ?: @"";
    NSString *encoding = [response valueForHTTPHeaderField:@"Content-Encoding"].lowercaseString;
    if (encoding.length && ![encoding isEqual:@"identity"]) return NO;
    if (media.isManifest || media.resourceKind == RDResourceKindManifest) return NO;
    if (media.resourceKind == RDResourceKindImage) return [mime hasPrefix:@"image/"];
    return [mime hasPrefix:@"video/"] && ![mime containsString:@"mpegurl"];
}

#pragma mark - 快照发布 / 字段级落缓存 / 收尾

- (RDMetadataSnapshot *)snapshotForWork:(RDMetadataWork *)w {
    RDMetadataSnapshot *s = [RDMetadataSnapshot new];
    for (NSString *key in RDFieldNames()) {
        RDMetadataField *f = RDFieldNamed(w.snapshot,key), *previous = RDFieldNamed(w.published,key);
        if (f.state != RDMetadataKnown && previous.state == RDMetadataKnown && previous) {
            f = previous; RDSetFieldNamed(w.snapshot,key,f);
        }
        [s setValue:Field(f.state,f.value,f.source) forKey:key];
    }
    s.variants = w.snapshot.variants;
    return s;
}
static BOOL RDSnapshotEquals(RDMetadataSnapshot *a, RDMetadataSnapshot *b) {
    if (!a || !b) return NO;
    if ((a.variants || b.variants) && ![a.variants isEqualToArray:b.variants ?: @[]]) return NO;
    for (NSString *name in RDFieldNames()) {
        RDMetadataField *x = RDFieldNamed(a,name), *y = RDFieldNamed(b,name);
        if (x.state != y.state) return NO;
        if (x.value != y.value && ![x.value isEqual:y.value]) return NO;
        if (![x.source isEqualToString:y.source]) return NO;
    }
    return YES;
}
- (void)publish:(RDMetadataWork *)w {
    if (![self active:w]) return;
    RDMetadataSnapshot *s = [self snapshotForWork:w];
    BOOL changed = !RDSnapshotEquals(s, w.published);
    w.published = s;
    // 每个字段独立落缓存：另一个字段失败/超时/取消都不影响已成功字段复用。
    for (NSString *name in RDFieldNames()) {
        RDMetadataField *f = RDFieldNamed(w.snapshot,name);
        if (f.state != RDMetadataLoading) [self storeField:f forKey:w.key field:name];
    }
    if (w.snapshot.variants.count) [self storeVariants:w.snapshot.variants forKey:w.key];
    if (!changed) return;   // 状态未变化的重复发布不再打扰订阅者（分阶段发布只在字段真正变化时投递）
    for (void (^callback)(RDMetadataSnapshot *) in w.subscribers.allValues) callback(s);
}
- (void)legFinished:(RDMetadataWork *)w key:(NSString *)key {
    if (w.pending > 0) w.pending--;
    [self publish:w];
    [self maybeFinishWork:w];
}
- (void)maybeFinishWork:(RDMetadataWork *)w {
    if (![self active:w] || w.pending > 0) return;
    if (w.previewFetch && !w.previewFetch.finished) return;
    if (w.queued) return;                                            // 元数据 leg 仍在排队
    if (!w.previewOnly && !w.mediaLegsStarted && [self workNeedsMediaLegs:w]) return;  // leg 尚未开始
    // 所有能改变字段状态的 leg 都已结束：finish: 把残留 Loading 显式定为 Unknown，
    // 绝不让 UI 无限“读取中”（与旧 finish 语义一致）。
    [self finish:w key:w.key];
}
- (void)finish:(RDMetadataWork *)w key:(NSString *)key {
    if (![self active:w] || w.finished) return;
    for (NSString *name in RDFieldNames()) {
        RDMetadataField *f = RDFieldNamed(w.snapshot,name);
        if (f.state == RDMetadataLoading) RDSetFieldNamed(w.snapshot,name,Field(RDMetadataUnknown,nil,f.source));
    }
    w.pending = 0;
    [self publish:w];
    w.finished = YES;
    if (_inflight[key] == w) [_inflight removeObjectForKey:key];
    [w.subscribers removeAllObjects];
    [w.token cancel];
    [self deactivateWork:w];
}

#pragma mark - 各类型 leg

- (void)begin:(DetectedMedia *)m work:(RDMetadataWork *)w key:(NSString *)key {
    NSDictionary *headers = m.sourcePageURL.length ? @{@"Referer":m.sourcePageURL,@"Accept-Encoding":@"identity"} : @{@"Accept-Encoding":@"identity"};
    BOOL manifest = m.isManifest || m.resourceKind == RDResourceKindManifest;
    w.mediaLegsStarted = YES;
    if (manifest) {
        BOOL needsManifest = NO;
        for (NSString *name in @[@"duration",@"dimensions"]) if (RDFieldNamed(w.snapshot,name).state == RDMetadataLoading) needsManifest = YES;
        if (needsManifest) {
            w.pending++;
            [self manifest:m.mediaURL headers:headers work:w visited:[NSMutableSet set] depth:0 done:^{ [self legFinished:w key:key]; }];
        }
        if (w.snapshot.size.state == RDMetadataLoading) w.snapshot.size = Field(RDMetadataUnknown,nil,@"manifest is not media size");
        if (!needsManifest) [self legFinished:w key:key];
        return;
    }
    if (m.resourceKind == RDResourceKindImage) {
        if (w.snapshot.duration.state == RDMetadataLoading) w.snapshot.duration = Field(RDMetadataUnsupported,nil,@"not-applicable");
        BOOL needSize = w.snapshot.size.state == RDMetadataLoading;
        BOOL needImage = w.snapshot.dimensions.state == RDMetadataLoading || w.snapshot.preview.state == RDMetadataLoading;
        if (needSize) { w.pending++; [self sizeFor:m headers:headers work:w done:^{ [self legFinished:w key:key]; }]; }
        if (needImage) { w.pending++; [self imageBodyFor:m headers:headers work:w key:key]; }
        if (!needSize && !needImage) [self legFinished:w key:key];
        return;
    }
    // 视频：前缀探测先行（大小 + 经校验头部），探测落地后才决定 moov 读取，
    // 绝不与本体 GET 并行重叠；本体 GET 仅作为“服务器不支持 Range”的退回路径。
    w.pending++;
    __weak typeof(self) weak = self;
    [self probeFor:m headers:headers work:w done:^{
        [weak afterProbeFor:m headers:headers work:w key:key];
        [weak legFinished:w key:key];
    }];
}

- (void)afterProbeFor:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w key:(NSString *)key {
    if (![self active:w]) return;
    BOOL needDuration = w.snapshot.duration.state == RDMetadataLoading;
    BOOL needDimensions = w.snapshot.dimensions.state == RDMetadataLoading;
    BOOL needPreviewFrame = w.snapshot.preview.state == RDMetadataLoading && !m.poster.length;
    if (!needDuration && !needDimensions && !needPreviewFrame) return;
    // 1) 播放列表伪装成视频文件：前缀探测已带回完整清单文本，直接解析（零额外请求）。
    NSString *headText = (!w.probeError && w.probeData.length) ? [[NSString alloc] initWithData:[w.probeData subdataWithRange:NSMakeRange(0,MIN(w.probeData.length,256))] encoding:NSUTF8StringEncoding] : nil;
    if (headText && ([headText containsString:@"#EXTM3U"] || [headText containsString:@"<MPD"])) {
        RDMetadataResponse *r = [RDMetadataResponse new];
        r.data = w.probeData; r.response = w.probeResponse;
        m.isManifest = YES;
        w.pending++;
        [self parseManifestResponse:r headers:headers work:w visited:[NSMutableSet setWithObject:m.mediaURL] depth:0 done:^{ [self legFinished:w key:key]; }];
        return;
    }
    // 2) 服务器返回了完整小响应体（≤ 探测预算）：直接本地解码，不再重发请求。
    if (!w.probeError && (!w.probeResponse.statusCode || (w.probeResponse.statusCode == 200 && w.probeData.length > 0
        && w.probeResponse.expectedContentLength > 0 && w.probeData.length == (NSUInteger)w.probeResponse.expectedContentLength))) {
        w.pending++;
        [self decodeMovieData:w.probeData media:m headers:headers work:w key:key];
        return;
    }
    // 3) 有经校验的 Range 头部与总长：受限读取（只取 moov 与首帧，绝不整片下载）。
    if (w.probeResolved && w.probeHead.length && w.probeTotal > 0) {
        w.pending++;
        [self boundedMovieFor:m headers:headers work:w key:key];
        return;
    }
    // 4) 无 Range 且响应体未完整到达：仅当体积可信且 ≤2MB 时才退回完整读取。
    if (w.probeResponse.statusCode == 200 && w.probeResponse.expectedContentLength > 0
        && (unsigned long long)w.probeResponse.expectedContentLength <= 2*1024*1024
        && HasMediaSizeHeaders(w.probeResponse, m)) {
        w.pending++;
        [self videoBodyFor:m headers:headers work:w key:key];
        return;
    }
    // 5) 无法在安全预算内取得：显式终态，不伪装成功。HTTP 错误（403/410 等）
    // 归入可见 Failed，与“读取中”可区分；服务器不支持 Range 才归 Unsupported。
    BOOL probeHTTPError = w.probeResponse.statusCode >= 400
        || (w.probeError && !([w.probeError.domain isEqual:RDMetadataErrorDomain] && w.probeError.code == RDMetadataBudgetExceeded));
    RDMetadataState terminal = probeHTTPError ? [self state:w.probeError] : RDMetadataUnsupported;
    NSString *terminalSource = probeHTTPError
        ? [NSString stringWithFormat:@"HTTP %ld / %@", (long)w.probeResponse.statusCode, w.probeResponse.MIMEType ?: @""]
        : @"server does not support bounded range reads";
    if (w.snapshot.duration.state == RDMetadataLoading) w.snapshot.duration = Field(terminal,nil,terminalSource);
    if (w.snapshot.dimensions.state == RDMetadataLoading) w.snapshot.dimensions = Field(terminal,nil,terminalSource);
    if (w.snapshot.preview.state == RDMetadataLoading && (!w.previewFetch || w.previewFetch.finished))
        w.snapshot.preview = Field(terminal,nil,terminalSource);
}

- (void)sizeFor:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w done:(dispatch_block_t)done {
    [self get:m.mediaURL method:@"HEAD" headers:headers budget:0 work:w completion:^(RDMetadataResponse *r) {
        long long length = r.response.expectedContentLength;
        if (m.resourceKind == RDResourceKindImage && !r.error && r.response.statusCode == 200 && length > 0 && HasMediaSizeHeaders(r.response,m)) { w.snapshot.size = Field(RDMetadataKnown,@(length),@"HEAD Content-Length"); done(); return; }
        if (r.error.code == RDMetadataBlocked && [r.error.domain isEqual:RDMetadataErrorDomain]) { w.snapshot.size = Field(RDMetadataFailed,nil,@"URLPolicy"); done(); return; }
        // 一次 bytes=0-31 同时承担"取 Content-Range 总长"与"校验 MP4 签名"两种
        // 职能：高 RTT 站点每个串行往返都 2-7 秒，合并探测直接省掉 1-2 个往返。
        // 兼容两种服务器行为：0-31 原样返回（32B）或钳制为 0-0（1B）。
        NSMutableDictionary *range = [headers mutableCopy]; range[@"Range"] = @"bytes=0-31"; range[@"Accept-Encoding"] = @"identity";
        [self get:m.mediaURL method:@"GET" headers:range budget:32 work:w completion:^(RDMetadataResponse *rr) {
            NSString *rangeText = [rr.response valueForHTTPHeaderField:@"Content-Range"] ?: @"";
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^bytes (?:0-31|0-0)/([1-9][0-9]*)$" options:0 error:nil];
            NSTextCheckingResult *match = [re firstMatchInString:rangeText options:0 range:NSMakeRange(0,rangeText.length)];
            BOOL totalValid = NO; unsigned long long total = 0;
            if (match) { NSScanner *scanner = [NSScanner scannerWithString:[rangeText substringWithRange:[match rangeAtIndex:1]]]; totalValid = [scanner scanUnsignedLongLong:&total] && scanner.isAtEnd && total <= LLONG_MAX; }
            const uint8_t *firstBytes = rr.data.bytes;
            BOOL signature = rr.data.length == 32 && !memcmp(firstBytes+4,"ftyp",4);
            if (!rr.error && rr.response.statusCode == 206 && match && totalValid && rr.data.length <= 32 && HasMediaSizeHeaders(rr.response,m)) {
                w.snapshot.size = Field(RDMetadataKnown,@(total),@"Content-Range");
            } else if (!rr.error && rr.response.statusCode == 206 && totalValid && rr.data.length == 32 && signature && total >= 32) {
                NSString *encoding = [rr.response valueForHTTPHeaderField:@"Content-Encoding"].lowercaseString;
                if (!encoding.length || [encoding isEqual:@"identity"]) w.snapshot.size = Field(RDMetadataKnown,@(total),@"MP4 signature and validated Content-Range total");
            } else if (rr.response.statusCode == 200 && rr.response.expectedContentLength > 0 && HasMediaSizeHeaders(rr.response,m) && (!rr.error || ([rr.error.domain isEqual:RDMetadataErrorDomain] && rr.error.code == RDMetadataBudgetExceeded))) {
                w.snapshot.size = Field(RDMetadataKnown,@(rr.response.expectedContentLength),@"GET Content-Length");
            }
            if (w.snapshot.size.state == RDMetadataKnown) {
                if (length > 0 && length != [w.snapshot.size.value longLongValue] && HasMediaSizeHeaders(r.response,m)) w.snapshot.size.source = [w.snapshot.size.source stringByAppendingString:@"; HEAD differs, using media GET response"];
                done(); return;
            }
            NSString *mime = rr.response.MIMEType.lowercaseString ?: @"";
            BOOL binary = !mime.length || [mime isEqual:@"application/octet-stream"] || [mime isEqual:@"binary/octet-stream"];
            // 二进制 MIME 且第一次探测没拿到 32B 前缀（如被钳制为 0-0）时才需要
            // 第二次探测校验 ftyp 签名。
            if (binary && !signature && !m.isManifest && m.resourceKind != RDResourceKindManifest && (rr.response.statusCode == 200 || rr.response.statusCode == 206)) {
                [self get:m.mediaURL method:@"GET" headers:range budget:32 work:w completion:^(RDMetadataResponse *body) {
                    const uint8_t *bb = body.data.bytes;
                    BOOL sig = body.data.length == 32 && !memcmp(bb+4,"ftyp",4);
                    NSString *bodyRange = [body.response valueForHTTPHeaderField:@"Content-Range"] ?: @"";
                    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^bytes (?:0-31|0-0)/([1-9][0-9]*)$" options:0 error:nil];
                    NSTextCheckingResult *m2 = [pattern firstMatchInString:bodyRange options:0 range:NSMakeRange(0,bodyRange.length)];
                    unsigned long long t2 = 0; BOOL t2ok = NO;
                    if (m2) { NSScanner *s2 = [NSScanner scannerWithString:[bodyRange substringWithRange:[m2 rangeAtIndex:1]]]; t2ok = [s2 scanUnsignedLongLong:&t2] && s2.isAtEnd && t2 >= 32 && t2 <= LLONG_MAX; }
                    NSString *encoding = [body.response valueForHTTPHeaderField:@"Content-Encoding"].lowercaseString;
                    if (!body.error && sig && m2 && t2ok && body.response.statusCode == 206 && (!encoding.length || [encoding isEqual:@"identity"])) {
                        w.snapshot.size = Field(RDMetadataKnown,@(t2),@"MP4 signature and validated Content-Range total");
                    }
                    if (w.snapshot.size.state == RDMetadataLoading) w.snapshot.size = Field(body.error ? [self state:body.error] : RDMetadataUnknown,nil,@"unverified binary response");
                    done();
                }];
                return;
            }
            if (w.snapshot.size.state == RDMetadataLoading) w.snapshot.size = Field(rr.error ? [self state:rr.error] : RDMetadataUnknown,nil,[NSString stringWithFormat:@"HTTP %ld / %@",(long)rr.response.statusCode,mime]);
            done();
        }];
    }];
}

// 视频 leg 的前缀探测：一次 bytes=0-1048575（1MB）往返同时取得（1）经 Content-Range
// 校验的文件总长（2）MP4 签名（3）整个 moov。头部数据与总长保存在 work 上供受限
// moov 读取复用，大小在此尽早发布，不等缩略图或 moov 解析。
//
// 窗口为什么是 1MB 而不是 1KB（2026-09-10 真实现场驱动）：详情腿实测是 2–4 次
// **严格串行** Range 往返之和（4.39/6.52/8.67s，界面 detail-first-row 4.36/6.49/8.84s），
// 每次请求在本站要 1.4–3.5s。本站文件是 faststart（moov 在偏移 1024，约 318KB–1.44MB），
// 1KB 窗口只够看头部：盒遍历还要为 1KB 的 box 头、moov 主体各发一次请求。
// 取 1MB 让 ftyp+moov 一次到手——RDBoundedMovie 把探测头当初始窗口复用，
// 落在窗口内的盒不再补请求，于是 3 次串行变 1 次。代价是非 faststart 文件
// 会多传最多 1MB（实测吞吐约 3.5MB/s ≈ 0.3s），远小于省下的一个往返。
- (void)probeFor:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w done:(dispatch_block_t)done {
    NSMutableDictionary *range = [headers mutableCopy]; range[@"Range"] = @"bytes=0-1048575"; range[@"Accept-Encoding"] = @"identity";
    [self get:m.mediaURL method:@"GET" headers:range budget:1024*1024 work:w completion:^(RDMetadataResponse *r) {
        w.probeResponse = r.response;
        w.probeData = r.data;
        w.probeError = r.error;
        void (^finishProbe)(void) = ^{
            w.probeResolved = YES;
            done();
        };
        NSString *rangeText = [r.response valueForHTTPHeaderField:@"Content-Range"] ?: @"";
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^bytes 0-([0-9]+)/([1-9][0-9]*)$" options:0 error:nil];
        NSTextCheckingResult *match = [re firstMatchInString:rangeText options:0 range:NSMakeRange(0,rangeText.length)];
        unsigned long long hi = 0, total = 0; BOOL totalsValid = NO;
        if (match) {
            NSScanner *scanner = [NSScanner scannerWithString:[rangeText substringWithRange:[match rangeAtIndex:1]]];
            NSScanner *totalScanner = [NSScanner scannerWithString:[rangeText substringWithRange:[match rangeAtIndex:2]]];
            totalsValid = [scanner scanUnsignedLongLong:&hi] && scanner.isAtEnd
                && [totalScanner scanUnsignedLongLong:&total] && totalScanner.isAtEnd
                && hi <= 1048575 && total > hi && total <= LLONG_MAX;
        }
        totalsValid = totalsValid && !r.error && r.response.statusCode == 206
            && r.data.length == (NSUInteger)hi + 1;
        NSString *encoding = [r.response valueForHTTPHeaderField:@"Content-Encoding"].lowercaseString;
        BOOL identityEncoding = !encoding.length || [encoding isEqual:@"identity"];
        const uint8_t *firstBytes = r.data.bytes;
        BOOL signature = r.data.length >= 8 && !memcmp(firstBytes+4,"ftyp",4);
        if (totalsValid && identityEncoding) {
            w.probeHead = r.data; w.probeTotal = total;
            w.probeEtag = [r.response valueForHTTPHeaderField:@"ETag"];
            if (HasMediaSizeHeaders(r.response,m)) w.snapshot.size = Field(RDMetadataKnown,@(total),@"Content-Range");
            else if (signature && total >= 32) w.snapshot.size = Field(RDMetadataKnown,@(total),@"MP4 signature and validated Content-Range total");
        } else if (r.response.statusCode == 200 && r.response.expectedContentLength > 0 && HasMediaSizeHeaders(r.response,m)
                   && (!r.error || ([r.error.domain isEqual:RDMetadataErrorDomain] && r.error.code == RDMetadataBudgetExceeded))) {
            // 服务器不支持 Range：完整响应头仍给出可信长度。
            w.snapshot.size = Field(RDMetadataKnown,@(r.response.expectedContentLength),@"GET Content-Length");
        }
        if (w.snapshot.size.state == RDMetadataKnown) { finishProbe(); return; }
        NSString *mime = r.response.MIMEType.lowercaseString ?: @"";
        BOOL binary = !mime.length || [mime isEqual:@"application/octet-stream"] || [mime isEqual:@"binary/octet-stream"];
        // 二进制 MIME 且 1KB 前缀没带回 MP4 签名（部分 CDN 把 0-1023 钳制为
        // 0-0）时，用旧的 bytes=0-31 窄探测补签名校验。
        if (binary && !signature && !m.isManifest && m.resourceKind != RDResourceKindManifest && (r.response.statusCode == 200 || r.response.statusCode == 206)) {
            NSMutableDictionary *narrow = [headers mutableCopy]; narrow[@"Range"] = @"bytes=0-31"; narrow[@"Accept-Encoding"] = @"identity";
            [self get:m.mediaURL method:@"GET" headers:narrow budget:32 work:w completion:^(RDMetadataResponse *body) {
                const uint8_t *bb = body.data.bytes;
                BOOL sig = body.data.length == 32 && !memcmp(bb+4,"ftyp",4);
                NSString *bodyRange = [body.response valueForHTTPHeaderField:@"Content-Range"] ?: @"";
                NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^bytes (?:0-31|0-0)/([1-9][0-9]*)$" options:0 error:nil];
                NSTextCheckingResult *m2 = [pattern firstMatchInString:bodyRange options:0 range:NSMakeRange(0,bodyRange.length)];
                unsigned long long t2 = 0; BOOL t2ok = NO;
                if (m2) { NSScanner *s2 = [NSScanner scannerWithString:[bodyRange substringWithRange:[m2 rangeAtIndex:1]]]; t2ok = [s2 scanUnsignedLongLong:&t2] && s2.isAtEnd && t2 >= 32 && t2 <= LLONG_MAX; }
                NSString *bodyEncoding = [body.response valueForHTTPHeaderField:@"Content-Encoding"].lowercaseString;
                if (!body.error && sig && m2 && t2ok && body.response.statusCode == 206 && (!bodyEncoding.length || [bodyEncoding isEqual:@"identity"])) {
                    w.snapshot.size = Field(RDMetadataKnown,@(t2),@"MP4 signature and validated Content-Range total");
                    // 窄探测与 1KB 前缀的总长不一致时放弃前缀窗口（防跨表示拼接）。
                    if (w.probeHead.length && t2 != w.probeTotal) { w.probeHead = nil; w.probeEtag = nil; }
                }
                if (w.snapshot.size.state == RDMetadataLoading) w.snapshot.size = Field(body.error ? [self state:body.error] : RDMetadataUnknown,nil,@"unverified binary response");
                finishProbe();
            }];
            return;
        }
        if (r.error.code == RDMetadataBlocked && [r.error.domain isEqual:RDMetadataErrorDomain]) w.snapshot.size = Field(RDMetadataFailed,nil,@"URLPolicy");
        else if (w.snapshot.size.state == RDMetadataLoading) w.snapshot.size = Field(r.error ? [self state:r.error] : RDMetadataUnknown,nil,[NSString stringWithFormat:@"HTTP %ld / %@",(long)r.response.statusCode,mime]);
        finishProbe();
    }];
}

// 图像 leg：HEAD 取大小 + 单次完整读取解码尺寸/预览。
- (void)imageBodyFor:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w key:(NSString *)key {
    [self get:m.mediaURL method:@"GET" headers:headers budget:12*1024*1024 work:w completion:^(RDMetadataResponse *r) {
        if (r.error) {
            RDMetadataState state = [self state:r.error];
            if (w.snapshot.preview.state == RDMetadataLoading) w.snapshot.preview = Field(state,nil,@"HTTP");
            if (w.snapshot.dimensions.state == RDMetadataLoading) w.snapshot.dimensions = Field(state,nil,@"HTTP");
            [self legFinished:w key:key];
            return;
        }
        [self decodeImageData:r.data done:^(NSImage *image, NSValue *size, BOOL safe, BOOL hadProperties) {
            if (w.snapshot.dimensions.state == RDMetadataLoading)
                w.snapshot.dimensions = Field(safe && image ? RDMetadataKnown : (hadProperties && !safe ? RDMetadataUnsupported : RDMetadataFailed), safe && image ? size : nil, @"ImageIO");
            if (image && w.snapshot.preview.state != RDMetadataKnown) w.snapshot.preview = Field(RDMetadataKnown, image, @"ImageIO");
            else if (!image && w.snapshot.preview.state == RDMetadataLoading) w.snapshot.preview = Field(w.snapshot.dimensions.state, nil, @"ImageIO pixel budget");
            [self legFinished:w key:key];
        }];
    }];
}
// 图像解码核心（后台）：方向归一后的真实像素尺寸 + 受限降采样预览。
- (void)decodeImageData:(NSData *)data done:(void (^)(NSImage *image, NSValue *size, BOOL safe, BOOL hadProperties))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        static dispatch_semaphore_t imageSlots; static dispatch_once_t once; dispatch_once(&once, ^{ imageSlots=dispatch_semaphore_create(2); });
        dispatch_semaphore_wait(imageSlots, DISPATCH_TIME_FOREVER);
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
        NSDictionary *props = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)) : nil;
        double width = [props[(id)kCGImagePropertyPixelWidth] doubleValue], height = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
        NSInteger orientation = [props[(id)kCGImagePropertyOrientation] integerValue];
        BOOL safe = width > 0 && height > 0 && isfinite(width*height) && width*height <= 100000000;
        CGImageRef image = safe ? CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)@{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(id)kCGImageSourceCreateThumbnailWithTransform:@YES,(id)kCGImageSourceThumbnailMaxPixelSize:@1024,(id)kCGImageSourceShouldCacheImmediately:@YES}) : NULL;
        NSImage *preview = nil;
        if (image) { NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image]; preview = [[NSImage alloc] initWithSize:NSMakeSize(CGImageGetWidth(image),CGImageGetHeight(image))]; [preview addRepresentation:rep]; }
        if (image) CGImageRelease(image); if (source) CFRelease(source); dispatch_semaphore_signal(imageSlots);
        NSValue *size = safe ? [NSValue valueWithSize:(orientation >= 5 && orientation <= 8) ? NSMakeSize(height,width) : NSMakeSize(width,height)] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(preview, size, safe, props != nil); });
    });
}
// 受限 moov 读取（复用探测头，只取缺口字节），成功后再按需提取首帧。
- (void)boundedMovieFor:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w key:(NSString *)key {
    [RDBoundedMovie readWithHeadData:w.probeHead total:w.probeTotal etag:w.probeEtag request:^(NSDictionary *range, NSUInteger budget, void (^done)(RDMetadataResponse *)) {
        NSMutableDictionary *h = [headers mutableCopy]; [h addEntriesFromDictionary:range];
        [self get:m.mediaURL method:@"GET" headers:h budget:budget work:w completion:done];
    } completion:^(NSDictionary *metadata, NSError *error) {
        if (![self active:w]) { [self legFinished:w key:key]; return; }
        if (metadata[@"duration"] || w.snapshot.duration.state != RDMetadataKnown) w.snapshot.duration = Field(metadata[@"duration"] ? RDMetadataKnown : RDMetadataUnsupported, metadata[@"duration"], @"bounded moov Range metadata");
        if (metadata[@"dimensions"] || w.snapshot.dimensions.state != RDMetadataKnown) w.snapshot.dimensions = Field(metadata[@"dimensions"] ? RDMetadataKnown : RDMetadataUnsupported, metadata[@"dimensions"], @"bounded moov transformed track");
        if (metadata[@"size"]) w.snapshot.size = Field(RDMetadataKnown, metadata[@"size"], @"validated Range total");
        [self publish:w];
        if (!metadata || !metadata[@"dimensions"]) {
            // 没有可用的 moov 尺寸信息时首帧提取不会发生，preview 绝不能停留在 Loading。
            if (w.snapshot.preview.state == RDMetadataLoading) w.snapshot.preview = Field(RDMetadataUnsupported,nil,@"large movie frame unavailable; bounded metadata only");
            [self legFinished:w key:key];
            return;
        }
        if (w.snapshot.preview.state != RDMetadataLoading) { [self legFinished:w key:key]; return; }
        __weak typeof(self) weakSelf = self;
        RDRangeAsset *loader = [[RDRangeAsset alloc] initWithLength:[metadata[@"size"] longLongValue] etag:metadata[@"etag"] request:^(NSDictionary *range, NSUInteger budget, void (^done)(RDMetadataResponse *)) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                RDMetadataResponse *response = [RDMetadataResponse new];
                response.error = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataHTTPFailure userInfo:@{NSLocalizedDescriptionKey: @"元数据服务已结束"}];
                if (done) done(response);
                return;
            }
            NSMutableDictionary *h = [headers mutableCopy]; [h addEntriesFromDictionary:range];
            [strongSelf get:m.mediaURL method:@"GET" headers:h budget:budget work:w completion:done];
        }];
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:loader.asset];
        gen.appliesPreferredTrackTransform = YES; gen.maximumSize = CGSizeMake(512,512);
        [w.token addCancellation:^{ [gen cancelAllCGImageGeneration]; [loader cancel]; }];
        double duration = [metadata[@"duration"] doubleValue];
        [gen generateCGImageAsynchronouslyForTime:CMTimeMakeWithSeconds(MIN(1.5,duration*.25),600) completionHandler:^(CGImageRef image, CMTime actualTime, NSError *error) {
            CGImageRef owned = image ? CGImageRetain(image) : NULL;
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self active:w]) {
                    if (w.snapshot.preview.state != RDMetadataKnown)
                        w.snapshot.preview = Field(owned ? RDMetadataKnown : RDMetadataUnsupported, owned ? [[NSImage alloc] initWithCGImage:owned size:NSZeroSize] : nil, @"validated on-demand video frame");
                    [self legFinished:w key:key];
                }
                if (owned) CGImageRelease(owned);
            });
        }];
    }];
}
// 服务器不支持 Range 时的退回路径：≤2MB 的完整读取 + 本地严格校验 + 本地解码。
- (void)videoBodyFor:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w key:(NSString *)key {
    [self get:m.mediaURL method:@"GET" headers:headers budget:2*1024*1024 work:w completion:^(RDMetadataResponse *r) {
        if ([r.error.domain isEqual:RDMetadataErrorDomain] && r.error.code == RDMetadataBudgetExceeded) {
            if (w.probeHead.length && w.probeTotal > 0) { [self boundedMovieFor:m headers:headers work:w key:key]; return; }
            if (w.snapshot.duration.state == RDMetadataLoading) w.snapshot.duration = Field(RDMetadataUnsupported,nil,@"bounded range unavailable");
            if (w.snapshot.dimensions.state == RDMetadataLoading) w.snapshot.dimensions = Field(RDMetadataUnsupported,nil,@"bounded range unavailable");
            if (w.snapshot.preview.state == RDMetadataLoading) w.snapshot.preview = Field(RDMetadataUnsupported,nil,@"large movie frame unavailable; bounded metadata only");
            [self legFinished:w key:key];
            return;
        }
        if (r.error) {
            RDMetadataState state = [self state:r.error];
            if (w.snapshot.duration.state != RDMetadataKnown) w.snapshot.duration = Field(state,nil,@"bounded local asset");
            if (w.snapshot.dimensions.state != RDMetadataKnown) w.snapshot.dimensions = Field(state,nil,@"bounded local asset");
            if (w.snapshot.preview.state != RDMetadataKnown) w.snapshot.preview = Field(state,nil,@"bounded local asset");
            [self legFinished:w key:key];
            return;
        }
        [self decodeMovieData:r.data media:m headers:headers work:w key:key];
    }];
}
- (void)decodeMovieData:(NSData *)body media:(DetectedMedia *)m headers:(NSDictionary *)headers work:(RDMetadataWork *)w key:(NSString *)key {
    // Never create AVURLAsset from a remote URL. Only a complete bounded file is decoded.
    NSString *ext = [NSURL URLWithString:m.mediaURL].pathExtension.lowercaseString;
    NSSet *safeExtensions = [NSSet setWithArray:@[@"mp4",@"mov",@"m4v",@"mp3",@"m4a",@"wav",@"aac"]];
    if (![safeExtensions containsObject:ext]) ext = @"mp4";
    NSURL *local = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rd-metadata-%@.%@",NSUUID.UUID.UUIDString,ext]]];
    // 前缀嗅探、落盘与本地原子校验（最多 2MB 全缓冲遍历）都在后台队列完成，
    // 主线程只接收结论与状态发布。
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Reject playlist/XML payloads even when advertised as a movie.
        NSString *prefix = [[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(0,MIN(body.length,128))] encoding:NSUTF8StringEncoding];
        BOOL isPlaylist = [prefix containsString:@"#EXTM3U"] || [prefix containsString:@"<MPD"];
        BOOL wrote = !isPlaylist && [body writeToURL:local options:NSDataWritingAtomic error:nil];
        BOOL localAtoms = wrote && (([ext isEqual:@"mp4"] || [ext isEqual:@"mov"] || [ext isEqual:@"m4v"] || [ext isEqual:@"m4a"]) ? LocalAtoms(body.bytes,body.length,0) : YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            // 本地解码临时文件必须在本 leg 的每条出口路径上删除，否则每次读取
            // 视频元数据都会在 TMPDIR 里留下一个 rd-metadata-*.mov（用户反馈：
            // 用久了机器上到处是残留文件）。取消路径另有删除（见下）。
            void (^finishLeg)(void) = ^{
                [[NSFileManager defaultManager] removeItemAtURL:local error:nil];
                [weak legFinished:w key:key];
            };
            if (![weak active:w]) { finishLeg(); return; }
            if (isPlaylist) {
                m.isManifest = YES;
                w.snapshot.size = Field(RDMetadataUnknown,nil,@"manifest response is not complete media size");
                RDMetadataResponse *response = [RDMetadataResponse new];
                response.data = body; response.response = w.probeResponse;
                [weak parseManifestResponse:response headers:headers work:w visited:[NSMutableSet setWithObject:m.mediaURL] depth:0 done:^{ finishLeg(); }];
                return;
            }
            if (!wrote) { w.snapshot.duration = Field(RDMetadataUnsupported,nil,@"not a safe local media file"); finishLeg(); return; }
            if (!localAtoms) {
                [[NSFileManager defaultManager] removeItemAtURL:local error:nil];
                w.snapshot.duration = Field(RDMetadataUnsupported,nil,@"external or invalid local media references");
                w.snapshot.dimensions = Field(RDMetadataUnsupported,nil,@"external or invalid local media references");
                if (w.snapshot.preview.state != RDMetadataKnown) w.snapshot.preview = Field(RDMetadataUnsupported,nil,@"external or invalid local media references");
                finishLeg(); return;
            }
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:local options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
            RDThumbnailGenerator *generator = [RDThumbnailGenerator new];
            [w.token addCancellation:^{ [asset cancelLoading]; [generator cancel]; [[NSFileManager defaultManager] removeItemAtURL:local error:nil]; }];
            [asset loadValuesAsynchronouslyForKeys:@[@"duration",@"tracks"] completionHandler:^{
                double duration = [asset statusOfValueForKey:@"duration" error:nil] == AVKeyValueStatusLoaded ? CMTimeGetSeconds(asset.duration) : NAN;
                CGSize dimensions = CGSizeZero;
                if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) for (AVAssetTrack *track in asset.tracks) if ([track.mediaType isEqual:AVMediaTypeVideo]) { CGRect rect = CGRectApplyAffineTransform((CGRect){CGPointZero,track.naturalSize},track.preferredTransform); dimensions = CGSizeMake(fabs(rect.size.width),fabs(rect.size.height)); break; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![weak active:w]) { finishLeg(); return; }
                    if (w.snapshot.duration.state != RDMetadataKnown) w.snapshot.duration = Field(isfinite(duration) && duration >= 0 ? RDMetadataKnown : RDMetadataUnknown,isfinite(duration) && duration >= 0 ? @(duration) : nil,@"local AVAsset duration");
                    BOOL valid = isfinite(dimensions.width) && isfinite(dimensions.height) && dimensions.width > 0 && dimensions.height > 0 && dimensions.width*dimensions.height <= 100000000;
                    if (w.snapshot.dimensions.state != RDMetadataKnown) w.snapshot.dimensions = Field(valid ? RDMetadataKnown : RDMetadataUnknown,valid ? [NSValue valueWithSize:dimensions] : nil,@"local AVAsset transformed track");
                    [weak publish:w];
                    if (w.snapshot.preview.state != RDMetadataLoading) { finishLeg(); return; }
                    if (!valid) { w.snapshot.preview = Field(RDMetadataUnknown,nil,@"no video track"); finishLeg(); return; }
                    CMTime time = CMTimeMakeWithSeconds(isfinite(duration) && duration > 0 ? MIN(1.5,duration*0.25) : 0,600);
                    [generator generateThumbnailForURL:local atTime:time completion:^(CGImageRef image, AppError *error) {
                        if (image) { if ([weak active:w] && w.snapshot.preview.state != RDMetadataKnown) w.snapshot.preview = Field(RDMetadataKnown,[[NSImage alloc] initWithCGImage:image size:NSZeroSize],@"local video frame"); CGImageRelease(image); finishLeg(); }
                        else if ([weak active:w]) [generator generateThumbnailForURL:local atTime:kCMTimeZero completion:^(CGImageRef first, AppError *e) {
                            if (first) { if ([weak active:w]) w.snapshot.preview = Field(RDMetadataKnown,[[NSImage alloc] initWithCGImage:first size:NSZeroSize],@"local first frame"); CGImageRelease(first); }
                            else w.snapshot.preview = Field(RDMetadataUnknown,nil,@"no decodable local frame");
                            finishLeg();
                        }];
                    }];
                });
            }];
        });
    });
}
- (void)manifest:(NSString *)url headers:(NSDictionary *)headers work:(RDMetadataWork *)w visited:(NSMutableSet *)visited depth:(NSUInteger)depth done:(dispatch_block_t)done {
    if (depth >= 4 || [visited containsObject:url]) { w.snapshot.duration = Field(RDMetadataUnsupported,nil,@"manifest recursion limit/cycle"); done(); return; }
    [visited addObject:url];
    [self get:url method:@"GET" headers:headers budget:2*1024*1024 work:w completion:^(RDMetadataResponse *r) {
        if (r.error) { w.snapshot.duration = Field([self state:r.error],nil,@"manifest HTTP"); done(); return; }
        [self parseManifestResponse:r headers:headers work:w visited:visited depth:depth done:done];
    }];
}
- (void)parseManifestResponse:(RDMetadataResponse *)r headers:(NSDictionary *)headers work:(RDMetadataWork *)w visited:(NSMutableSet *)visited depth:(NSUInteger)depth done:(dispatch_block_t)done {
        // 清单结构性关键字是 ASCII：UTF-8 失败时用 Latin-1 兜底，避免非 UTF-8
        // 字节（如 GBK 注释/NAME）把结构完好的清单误判为“清单为空”。
        NSString *text = [[NSString alloc] initWithData:r.data encoding:NSUTF8StringEncoding]
                         ?: [[NSString alloc] initWithData:r.data encoding:NSISOLatin1StringEncoding];
        NSDictionary *parsed = [RDManifestParser parseManifest:text baseURL:r.response.URL];
        if (![parsed[@"isValid"] boolValue]) { w.snapshot.duration = Field(RDMetadataFailed,nil,@"manifest parser"); done(); return; }
        if ([parsed[@"isMaster"] boolValue] && !w.snapshot.variants.count) w.snapshot.variants = parsed[@"variants"];
        // 多 Representation：维度来源优先取声明了分辨率的视频轨中分辨率最高的一档
        // （最佳画质），绝不盲目取 firstObject——那通常是最低码率档；音频轨/无
        // 分辨率条目不参与。都没有时才回退 firstObject 保持既有行为。
        // HLS 变体只有 RESOLUTION="WxH" 字符串而没有 width/height 数值键，
        // 必须同样解析进比较，否则"取最高"静默退化为"取第一条"。
        NSDictionary *variant = nil;
        double bestArea = 0;
        for (NSDictionary *candidate in parsed[@"variants"] ?: @[]) {
            double cw = [candidate[@"width"] doubleValue], ch = [candidate[@"height"] doubleValue];
            NSArray *res = [candidate[@"resolution"] componentsSeparatedByString:@"x"];
            if (res.count == 2) { cw = [res[0] doubleValue]; ch = [res[1] doubleValue]; }
            if (!(cw > 0 && ch > 0) || !isfinite(cw * ch)) continue;
            if (!variant || cw * ch > bestArea) { variant = candidate; bestArea = cw * ch; }
        }
        if (!variant) variant = [parsed[@"variants"] firstObject];
        double width = [variant[@"width"] doubleValue], height = [variant[@"height"] doubleValue];
        NSArray *resolution = [variant[@"resolution"] componentsSeparatedByString:@"x"];
        if (resolution.count == 2) { width = [resolution[0] doubleValue]; height = [resolution[1] doubleValue]; }
        if (width > 0 && height > 0 && isfinite(width*height)) w.snapshot.dimensions = Field(RDMetadataKnown,[NSValue valueWithSize:NSMakeSize(width,height)],@"manifest declaration");
        [self publish:w];
        // 只有 HLS master 才有子媒体清单可递归；DASH 的 Representation 在同一
        // MPD 内完整描述（BaseURL 是分片目录），递归只会读到目录/404。
        BOOL hlsMaster = [parsed[@"isMaster"] boolValue] && [parsed[@"kind"] isEqual:@"hls"];
        if (hlsMaster && [variant[@"url"] length]) { [self manifest:variant[@"url"] headers:headers work:w visited:visited depth:depth+1 done:done]; return; }
        NSNumber *duration = parsed[@"durationSeconds"];
        w.snapshot.duration = Field(duration && ![parsed[@"isLive"] boolValue] ? RDMetadataKnown : RDMetadataUnknown,duration && ![parsed[@"isLive"] boolValue] ? duration : nil,[parsed[@"isLive"] boolValue] ? @"live manifest" : @"manifest declaration");
        done();
}
@end
