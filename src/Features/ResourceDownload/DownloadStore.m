//
//  DownloadStore.m
//  7zz
//

#import "DownloadStore.h"

static NSString *const kCompletedKey = @"CompletedResourceURLs";
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
