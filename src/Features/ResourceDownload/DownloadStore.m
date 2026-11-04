//
//  DownloadStore.m
//  7zz
//

#import "DownloadStore.h"

// 已下载 URL 集合的键（2026-10-26 修，两个约束必须同时满足）：
//  ① 值只有一个来源 —— 必须与 PreferencesStore 的 SevenZZKeyCompletedResourceURLs 相同，
//     不能各写一份字面量任由两侧漂移；
//  ② 本文件**不得**因此获得对新符号的链接依赖 —— download-integrity 等套件只编译
//     DownloadStore.m、不链接 PreferencesStore.m（实测引用 extern 常量会
//     `Undefined symbols: _SevenZZKeyCompletedResourceURLs` 链接失败；这与本项目
//     第 28/35/36/38 轮反复踩过的「套件因新增依赖而链接失败」是同一类坑）。
// 因此这里保留字面量，但把「与常量一致」做成**编译期/套件期**两条断言：
//  · verify.sh 断言本行字面量 == PreferencesStore 里的常量值（分叉即红）；
//  · 上面的注释与行内容成对出现，改一侧忘另一侧会被当场抓到。
static NSString *const kCompletedKey = @"CompletedResourceURLs";
// 以下三个是本模块私有的下载队列持久化键，PreferencesStore 未登记，保持在本地。
static NSString *const kInterruptedKey = @"InterruptedDownloadJobs";
static NSString *const kFinishedJobsKey = @"FinishedDownloadJobs";
static NSString *const kLatestEnqueuedJobKey = @"LatestEnqueuedDownloadJob";

@interface DownloadStore ()
@property (nonatomic, strong) NSUserDefaults *ud;
@end

@implementation DownloadStore

- (instancetype)initWithUserDefaults:(NSUserDefaults *)ud {
    self = [super init];
    if (self) _ud = ud ?: [NSUserDefaults standardUserDefaults];
    return self;
}

- (BOOL)isCompletedURL:(NSURL *)url {
    if (url.absoluteString.length == 0) return NO;
    NSArray *list = [self.ud arrayForKey:kCompletedKey] ?: @[];
    return [list containsObject:url.absoluteString];
}

- (void)recordCompletedURL:(NSURL *)url {
    if (url.absoluteString.length == 0) return;
    NSMutableOrderedSet *history = [NSMutableOrderedSet orderedSetWithArray:[self.ud arrayForKey:kCompletedKey] ?: @[]];
    [history addObject:url.absoluteString];
    while (history.count > 300) [history removeObjectAtIndex:0];
    [self.ud setObject:history.array forKey:kCompletedKey];
}

- (void)setInterruptedRecords:(NSDictionary<NSString *, NSString *> *)records {
    [self.ud setObject:records ?: @{} forKey:kInterruptedKey];
}

- (NSDictionary<NSString *, NSString *> *)interruptedRecords {
    return [self.ud dictionaryForKey:kInterruptedKey] ?: @{};
}

- (void)clearInterruptedRecords {
    [self.ud removeObjectForKey:kInterruptedKey];
}

- (void)removeInterruptedRecord:(NSString *)identifier {
    if (identifier.length == 0) return;
    NSMutableDictionary *records = [[self.ud dictionaryForKey:kInterruptedKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (![records objectForKey:identifier]) return;
    [records removeObjectForKey:identifier];
    [self.ud setObject:records forKey:kInterruptedKey];
}

// 记录条目必须是可被 plist 直接序列化的类型（NSString/NSNumber/NSDate），
// 否则 NSUserDefaults 写入会失败、重启后历史丢失。
- (void)recordFinishedJob:(NSDictionary<NSString *, id> *)record {
    if (!record.count) return;
    NSMutableArray *history = [[self.ud arrayForKey:kFinishedJobsKey] mutableCopy] ?: [NSMutableArray array];
    NSString *identifier = record[@"identifier"];
    if (identifier.length) {
        NSMutableArray *stale = [NSMutableArray array];
        for (id existing in history) {
            if ([existing isKindOfClass:NSDictionary.class] && [existing[@"identifier"] isEqualToString:identifier]) [stale addObject:existing];
        }
        [history removeObjectsInArray:stale];
    }
    [history insertObject:record atIndex:0];
    while (history.count > 50) [history removeLastObject];
    [self.ud setObject:history forKey:kFinishedJobsKey];
}

- (NSArray<NSDictionary<NSString *, id> *> *)finishedJobRecords {
    NSArray *list = [self.ud arrayForKey:kFinishedJobsKey] ?: @[];
    return [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *d, NSDictionary *b) {
        return [d isKindOfClass:NSDictionary.class];
    }]];
}

- (void)setLatestEnqueuedJobIdentifier:(NSString *)identifier { [self.ud setObject:identifier ?: @"" forKey:kLatestEnqueuedJobKey]; }
- (NSString *)latestEnqueuedJobIdentifier { return [self.ud stringForKey:kLatestEnqueuedJobKey]; }

- (void)clearAllDownloadRecords {
    [self.ud removeObjectForKey:kCompletedKey];
    [self.ud removeObjectForKey:kInterruptedKey];
    [self.ud removeObjectForKey:kFinishedJobsKey];
}

@end
