//
//  RDWatchlistStore.m — 追更观察库实现（纯 Foundation）
//
//  跨进程一致性：所有变更走「独占文件锁（flock 同目录 .lock）内 读→改→原子写回」，
//  写入用临时文件 + rename，读不到/损坏时整体回退为空库（绝不崩溃、绝不猜内容）。
//

#import "RDWatchlistStore.h"
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *const kKeyVersion = @"version";
static NSString *const kKeyEntries = @"entries";
static NSString *const kKeyId = @"id";
static NSString *const kKeyURL = @"url";
static NSString *const kKeyTitle = @"title";
static NSString *const kKeyInterval = @"intervalMinutes";
static NSString *const kKeyEnabled = @"enabled";
static NSString *const kKeyVideoOnly = @"videoOnly";
static NSString *const kKeyLastProbe = @"lastProbeAt";
static NSString *const kKeyLastResult = @"lastResultAt";
static NSString *const kKeyKnown = @"knownKeys";
static NSString *const kKeyPending = @"pendingNewKeys";
static NSString *const kKeyLastError = @"lastError";

static NSArray<NSNumber *> *RDAllowedIntervals(void) { return @[@15, @30, @60, @120]; }

static NSInteger RDSanitizeInterval(NSInteger m) {
    for (NSNumber *allowed in RDAllowedIntervals())
        if (allowed.integerValue == m) return m;
    return 30;
}

static NSDateFormatter *RDISO8601(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });
    return f;
}

static NSString *RDDateToString(NSDate *d) { return d ? [RDISO8601() stringFromDate:d] : @""; }
static NSDate *RDStringToDate(NSString *s) {
    if (s.length == 0) return nil;
    return [RDISO8601() dateFromString:s];
}

/// 页面地址规范化：小写 scheme/host、去 fragment、去结尾斜杠。仅用于条目身份，
/// 与资源级 dedupKey（DetectedMedia）无关。
NSString *RDWatchlistCanonicalPageURL(NSString *rawURL) {
    if (rawURL.length == 0) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithString:rawURL];
    if (!c || !c.scheme.length || !c.host.length) return rawURL;
    c.scheme = c.scheme.lowercaseString;
    c.host = c.host.lowercaseString;
    c.fragment = nil;
    NSString *s = c.string ?: rawURL;
    while (s.length > 1 && [s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

#pragma mark - RDWatchlistEntry

@interface RDWatchlistEntry ()
@end

@implementation RDWatchlistEntry

- (instancetype)init {
    return [self initWithCanonicalURL:@""];
}

- (instancetype)initWithCanonicalURL:(NSString *)url {
    self = [super init];
    if (self) {
        _identifier = [[NSUUID UUID] UUIDString];
        _pageURL = [url copy] ?: @"";
        _intervalMinutes = 30;
        _enabled = YES;
        _videoOnly = YES;   // v1 判定范围：仅视频/清单
        _knownKeys = @[];
        _pendingNewKeys = @[];
    }
    return self;
}

+ (instancetype)entryWithPageURL:(NSString *)pageURL {
    return [[RDWatchlistEntry alloc] initWithCanonicalURL:RDWatchlistCanonicalPageURL(pageURL ?: @"")];
}

- (void)setIntervalMinutes:(NSInteger)m { _intervalMinutes = RDSanitizeInterval(m); }

- (id)copyWithZone:(NSZone *)zone {
    RDWatchlistEntry *c = [[[self class] allocWithZone:zone] initWithCanonicalURL:_pageURL];
    c.identifier = _identifier;
    c.title = _title;
    c->_intervalMinutes = _intervalMinutes;
    c->_enabled = _enabled;
    c->_videoOnly = _videoOnly;
    c.lastProbeAt = _lastProbeAt;
    c.lastResultAt = _lastResultAt;
    c.knownKeys = _knownKeys;
    c.pendingNewKeys = _pendingNewKeys;
    c.lastError = _lastError;
    return c;
}

- (NSArray<NSString *> *)filterNewKeys:(NSArray<NSString *> *)keys {
    if (keys.count == 0) return @[];
    NSSet *known = [NSSet setWithArray:_knownKeys];
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    for (NSString *k in keys) if (k.length && ![known containsObject:k]) [out addObject:k];
    return out.array;
}

- (NSDictionary *)JSONDictionary {
    return @{
        kKeyId: _identifier ?: @"",
        kKeyURL: _pageURL ?: @"",
        kKeyTitle: _title ?: @"",
        kKeyInterval: @(_intervalMinutes),
        kKeyEnabled: @(_enabled),
        kKeyVideoOnly: @(_videoOnly),
        kKeyLastProbe: RDDateToString(_lastProbeAt),
        kKeyLastResult: RDDateToString(_lastResultAt),
        kKeyKnown: _knownKeys ?: @[],
        kKeyPending: _pendingNewKeys ?: @[],
        kKeyLastError: _lastError ?: @"",
    };
}

+ (nullable instancetype)entryFromJSONDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    NSString *url = [d[kKeyURL] isKindOfClass:NSString.class] ? d[kKeyURL] : nil;
    if (url.length == 0) return nil;
    RDWatchlistEntry *e = [[RDWatchlistEntry alloc] initWithCanonicalURL:RDWatchlistCanonicalPageURL(url)];
    NSString *id_ = [d[kKeyId] isKindOfClass:NSString.class] ? d[kKeyId] : nil;
    e.identifier = id_.length ? id_ : [[NSUUID UUID] UUIDString];
    e.title = [d[kKeyTitle] isKindOfClass:NSString.class] ? d[kKeyTitle] : nil;
    if ([d[kKeyInterval] respondsToSelector:@selector(integerValue)])
        e.intervalMinutes = [d[kKeyInterval] integerValue];
    e.enabled = [d[kKeyEnabled] boolValue];   // 缺省 NO：保守，需显式开启
    e.videoOnly = [d[kKeyVideoOnly] boolValue] ? YES : e.videoOnly;
    e.lastProbeAt = RDStringToDate([d[kKeyLastProbe] isKindOfClass:NSString.class] ? d[kKeyLastProbe] : @"");
    e.lastResultAt = RDStringToDate([d[kKeyLastResult] isKindOfClass:NSString.class] ? d[kKeyLastResult] : @"");
    e.knownKeys = [d[kKeyKnown] isKindOfClass:NSArray.class] ? d[kKeyKnown] : @[];
    e.pendingNewKeys = [d[kKeyPending] isKindOfClass:NSArray.class] ? d[kKeyPending] : @[];
    e.lastError = [d[kKeyLastError] isKindOfClass:NSString.class] ? d[kKeyLastError] : nil;
    return e;
}

@end

#pragma mark - RDWatchlistStore

@interface RDWatchlistStore ()
@property (nonatomic, copy) NSURL *storeURL;
@property (nonatomic, copy) NSURL *lockURL;
@property (nonatomic, strong) NSMutableArray<RDWatchlistEntry *> *cache;   // 仅在锁内与磁盘同步
@end

@implementation RDWatchlistStore

+ (instancetype)sharedStore {
    static RDWatchlistStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
                         @"Library/Application Support/MiliuWatchlist"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        shared = [[RDWatchlistStore alloc] initWithStoreURL:
                  [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"watchlist.json"]]];
    });
    return shared;
}

- (instancetype)initWithStoreURL:(NSURL *)storeURL {
    self = [super init];
    if (self) {
        _storeURL = [storeURL copy];
        _lockURL = [[storeURL URLByAppendingPathExtension:@"lock"] copy];
        _cache = [NSMutableArray array];
        [self reloadLocked];   // init 尚未对外发布，直接读一次
    }
    return self;
}

// ── 锁与磁盘 ──

- (void)withLock:(void (^)(void))body {
    int fd = open(self.lockURL.path.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
    if (fd < 0) { body(); return; }   // 锁不可用时退化为直接执行，功能不失效
    flock(fd, LOCK_EX);
    @try { body(); } @finally { flock(fd, LOCK_UN); close(fd); }
}

- (void)reloadLocked {
    NSArray *arr = @[];
    NSData *data = [NSData dataWithContentsOfURL:self.storeURL];
    if (data.length) {
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([root isKindOfClass:NSDictionary.class]) arr = root[kKeyEntries] ?: @[];
    }
    NSMutableArray<RDWatchlistEntry *> *loaded = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];
    for (NSDictionary *d in arr) {
        RDWatchlistEntry *e = [RDWatchlistEntry entryFromJSONDictionary:d];
        if (!e) continue;
        if ([seenURLs containsObject:e.pageURL]) continue;   // 文件若出现重复地址，保留首条
        [seenURLs addObject:e.pageURL];
        [loaded addObject:e];
    }
    self.cache = loaded;
}

- (BOOL)saveLocked {
    NSMutableArray *arr = [NSMutableArray array];
    for (RDWatchlistEntry *e in self.cache) [arr addObject:[e JSONDictionary]];
    NSDictionary *root = @{ kKeyVersion: @1, kKeyEntries: arr };
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                  error:&err];
    if (!data || err) return NO;
    NSURL *tmp = [self.storeURL URLByAppendingPathExtension:@"tmp"];
    if (![data writeToURL:tmp options:NSDataWritingAtomic error:&err]) return NO;
    // 首次保存时目标不存在，remove 失败属预期，忽略其返回值
    [[NSFileManager defaultManager] removeItemAtURL:self.storeURL error:nil];
    return [[NSFileManager defaultManager] moveItemAtURL:tmp toURL:self.storeURL error:nil];
}

// ── 查询（锁外走缓存拷贝）──

- (NSArray<RDWatchlistEntry *> *)entries {
    return [self.cache copy];
}

- (nullable RDWatchlistEntry *)entryForURL:(NSString *)pageURL {
    NSString *key = RDWatchlistCanonicalPageURL(pageURL ?: @"");
    for (RDWatchlistEntry *e in self.cache)
        if ([e.pageURL isEqualToString:key]) return e;
    return nil;
}

- (NSInteger)totalPendingNewCount {
    NSInteger total = 0;
    for (RDWatchlistEntry *e in self.cache) total += e.pendingNewKeys.count;
    return total;
}

- (NSArray<RDWatchlistEntry *> *)dueEntriesBeforeDate:(NSDate *)date {
    NSMutableArray *out = [NSMutableArray array];
    for (RDWatchlistEntry *e in self.cache) {
        if (!e.enabled) continue;
        if (!e.lastProbeAt) { [out addObject:e]; continue; }
        NSTimeInterval due = [e.lastProbeAt timeIntervalSinceDate:date] + e.intervalMinutes * 60;
        if (due <= 0) [out addObject:e];   // lastProbeAt ≤ date − interval
    }
    return out;
}

// ── 变更（锁内 读→改→写回）──

- (RDWatchlistEntry *)upsertEntryForURL:(NSString *)pageURL title:(nullable NSString *)title {
    __block RDWatchlistEntry *result = nil;
    [self withLock:^{
        [self reloadLocked];
        NSString *key = RDWatchlistCanonicalPageURL(pageURL ?: @"");
        RDWatchlistEntry *existing = nil;
        for (RDWatchlistEntry *e in self.cache)
            if ([e.pageURL isEqualToString:key]) { existing = e; break; }
        if (existing) {
            RDWatchlistEntry *copy = [existing copy];
            if (title.length) copy.title = title;
            [self.cache replaceObjectAtIndex:[self.cache indexOfObject:existing] withObject:copy];
            result = copy;
        } else {
            RDWatchlistEntry *e = [RDWatchlistEntry entryWithPageURL:pageURL];
            if (title.length) e.title = title;
            [self.cache addObject:e];
            result = e;
        }
        [self saveLocked];
    }];
    return result;
}

- (void)updateEntry:(RDWatchlistEntry *)entry {
    if (!entry) return;
    [self withLock:^{
        [self reloadLocked];
        NSUInteger idx = NSNotFound;
        for (NSUInteger i = 0; i < self.cache.count; i++)
            if ([self.cache[i].identifier isEqualToString:entry.identifier]) { idx = i; break; }
        RDWatchlistEntry *copy = [entry copy];
        if (idx == NSNotFound) [self.cache addObject:copy];
        else [self.cache replaceObjectAtIndex:idx withObject:copy];
        [self saveLocked];
    }];
}

- (BOOL)removeEntryWithIdentifier:(NSString *)identifier {
    __block BOOL removed = NO;
    [self withLock:^{
        [self reloadLocked];
        for (NSUInteger i = 0; i < self.cache.count; i++)
            if ([self.cache[i].identifier isEqualToString:identifier]) {
                [self.cache removeObjectAtIndex:i];
                removed = YES;
                break;
            }
        if (removed) [self saveLocked];
    }];
    return removed;
}

- (void)recordProbeResult:(RDWatchlistEntry *)entry
              fetchedKeys:(NSArray<NSString *> *)fetchedKeys
                    error:(nullable NSString *)error {
    if (!entry) return;
    [self withLock:^{
        [self reloadLocked];
        for (NSUInteger i = 0; i < self.cache.count; i++) {
            RDWatchlistEntry *e = self.cache[i];
            if (![e.identifier isEqualToString:entry.identifier]) continue;
            RDWatchlistEntry *copy = [e copy];
            copy.lastProbeAt = [NSDate date];
            if (error.length > 0) {
                copy.lastError = error;
            } else {
                copy.lastError = nil;
                copy.lastResultAt = [NSDate date];
                NSArray *fresh = [copy filterNewKeys:fetchedKeys ?: @[]];
                if (fresh.count) {
                    NSMutableOrderedSet *pending = [NSMutableOrderedSet orderedSetWithArray:copy.pendingNewKeys];
                    [pending addObjectsFromArray:fresh];
                    copy.pendingNewKeys = pending.array;
                }
                NSMutableOrderedSet *known = [NSMutableOrderedSet orderedSetWithArray:copy.knownKeys];
                [known addObjectsFromArray:fetchedKeys ?: @[]];
                copy.knownKeys = known.array;
            }
            [self.cache replaceObjectAtIndex:i withObject:copy];
            [self saveLocked];
            break;
        }
    }];
}

- (void)markPendingRead:(NSString *)identifier {
    [self withLock:^{
        [self reloadLocked];
        for (NSUInteger i = 0; i < self.cache.count; i++) {
            RDWatchlistEntry *e = self.cache[i];
            if (![e.identifier isEqualToString:identifier]) continue;
            RDWatchlistEntry *copy = [e copy];
            copy.pendingNewKeys = @[];
            [self.cache replaceObjectAtIndex:i withObject:copy];
            [self saveLocked];
            break;
        }
    }];
}

@end
