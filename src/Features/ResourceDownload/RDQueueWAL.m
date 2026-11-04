//
//  RDQueueWAL.m
//  Miliu
//

#import "RDQueueWAL.h"

const double RDQueueWALProgressStepPercent = 5.0;

static NSString * const RDWALOpEnqueued = @"enqueued";
static NSString * const RDWALOpStarted  = @"started";
static NSString * const RDWALOpProgress = @"progress";
static NSString * const RDWALOpTerminal = @"terminal";

NSString * _Nullable RDQueueWALEncodeLine(NSDictionary *record) {
    if (![record isKindOfClass:[NSDictionary class]] || record.count == 0) return nil;
    if (![NSJSONSerialization isValidJSONObject:record]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!data.length) return nil;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!line.length) return nil;
    // 一行一条：JSON 本身会把换行转义成 \n，这里再兜一层，防止调用方塞进裸换行
    // 把一条记录劈成两条（劈开后两半都不合法，会被当成坏行丢弃）。
    line = [line stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    line = [line stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return line;
}

NSArray<NSDictionary *> *RDQueueWALDecodeLines(NSString *text, NSUInteger *discarded) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSUInteger bad = 0;
    if (text.length == 0) { if (discarded) *discarded = 0; return out; }
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSDictionary class]] && [parsed[@"op"] isKindOfClass:[NSString class]]) {
            [out addObject:parsed];
        } else {
            // 只有文件末尾那行可能半截；中间出现坏行说明被人为改过，同样丢弃该行，
            // 绝不让一行坏数据把整条队列废掉。
            bad += 1;
        }
    }
    if (discarded) *discarded = bad;
    return out;
}

static NSString *RDWALString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

NSArray<NSDictionary *> *RDQueueWALReplay(NSArray<NSDictionary *> *records) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *live = [NSMutableDictionary dictionary];
    for (NSDictionary *r in records) {
        NSString *op = RDWALString(r[@"op"]);
        NSString *identifier = RDWALString(r[@"id"]);
        if (!op.length || !identifier.length) continue;
        if ([op isEqualToString:RDWALOpEnqueued]) {
            NSMutableDictionary *item = [r mutableCopy];
            [item removeObjectForKey:@"op"];
            [item setObject:identifier forKey:@"identifier"];
            if (![item[@"percent"] isKindOfClass:[NSNumber class]]) item[@"percent"] = @0;
            if (![item[@"wasRunning"] isKindOfClass:[NSNumber class]]) item[@"wasRunning"] = @NO;
            live[identifier] = item;
        } else if ([op isEqualToString:RDWALOpStarted]) {
            NSMutableDictionary *item = live[identifier];
            if (item) item[@"wasRunning"] = @YES;
        } else if ([op isEqualToString:RDWALOpProgress]) {
            NSMutableDictionary *item = live[identifier];
            NSNumber *pct = [r[@"percent"] isKindOfClass:[NSNumber class]] ? r[@"percent"] : nil;
            if (item && pct) item[@"percent"] = pct;
        } else if ([op isEqualToString:RDWALOpTerminal]) {
            // 终态即离开队列：与真实队列语义一致（完成后不再占位）。
            [live removeObjectForKey:identifier];
        }
    }
    NSArray<NSDictionary *> *items = live.allValues;
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger pa = [a[@"position"] integerValue];
        NSInteger pb = [b[@"position"] integerValue];
        if (pa != pb) return pa < pb ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"identifier"] compare:b[@"identifier"]];
    }];
}

BOOL RDQueueWALShouldLogProgress(double lastLogged, double current) {
    if (!isfinite(current)) return NO;
    double clamped = MAX(0.0, MIN(100.0, current));
    if (!isfinite(lastLogged) || lastLogged < 0) return clamped > 0.0;
    return fabs(clamped - lastLogged) >= RDQueueWALProgressStepPercent;
}

BOOL RDQueueWALCompactionNeeded(NSUInteger lineCount, NSUInteger liveCount) {
    // 200 行是个小文件（约几十 KB），超过它就开始有重放成本；
    // 终态记录多于存活任务 4 倍时即使行数不多也该收一次（大量短任务场景）。
    if (lineCount > 200) return YES;
    return liveCount > 0 && lineCount > liveCount * 4 + 20;
}

@interface RDQueueWAL ()
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastLoggedPercent;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation RDQueueWAL

+ (instancetype)shared {
    static RDQueueWAL *wal = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *base = [NSURL fileURLWithPath:[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Miliu"]];
        [[NSFileManager defaultManager] createDirectoryAtURL:base withIntermediateDirectories:YES attributes:nil error:nil];
        wal = [[RDQueueWAL alloc] initWithFileURL:[base URLByAppendingPathComponent:@"queue.wal"]];
    });
    return wal;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    if ((self = [super init])) {
        _fileURL = fileURL;
        _ioQueue = dispatch_queue_create("com.sevenzz.miliu.queuewal", DISPATCH_QUEUE_SERIAL);
        _lastLoggedPercent = [NSMutableDictionary dictionary];
        NSURL *dir = fileURL.URLByDeletingLastPathComponent;
        if (dir) [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            [[NSFileManager defaultManager] createFileAtPath:fileURL.path contents:nil attributes:nil];
        }
    }
    return self;
}

- (void)appendRecord:(NSDictionary *)record {
    NSString *line = RDQueueWALEncodeLine(record);
    if (!line.length) return;
    NSURL *url = self.fileURL;
    dispatch_async(self.ioQueue, ^{
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        if (!handle) {
            if (![[NSFileManager defaultManager] createFileAtPath:url.path contents:nil attributes:nil]) return;
            handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        }
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *e) {
            // 写不进去（磁盘满/权限）时队列仍可运行；恢复能力降级但不影响下载。
        } @finally {
            [handle closeFile];
        }
    });
}

- (void)appendEnqueuedRecord:(NSDictionary *)record position:(NSUInteger)position {
    NSMutableDictionary *line = [record mutableCopy];
    line[@"op"] = RDWALOpEnqueued;
    line[@"position"] = @(position);
    [self appendRecord:line];
}

- (void)appendStarted:(NSString *)identifier {
    if (!identifier.length) return;
    [self appendRecord:@{@"op": RDWALOpStarted, @"id": identifier}];
}

- (void)appendProgress:(NSString *)identifier percent:(double)percent {
    if (!identifier.length) return;
    __block BOOL shouldLog = NO;
    @synchronized (self.lastLoggedPercent) {
        NSNumber *last = self.lastLoggedPercent[identifier];
        shouldLog = RDQueueWALShouldLogProgress(last ? last.doubleValue : -1.0, percent);
        if (shouldLog) self.lastLoggedPercent[identifier] = @(MAX(0.0, MIN(100.0, percent)));
    }
    if (!shouldLog) return;
    [self appendRecord:@{@"op": RDWALOpProgress, @"id": identifier,
                         @"percent": @(MAX(0.0, MIN(100.0, percent)))}];
}

- (void)appendTerminal:(NSString *)identifier state:(NSInteger)state {
    if (!identifier.length) return;
    @synchronized (self.lastLoggedPercent) {
        [self.lastLoggedPercent removeObjectForKey:identifier];
    }
    [self appendRecord:@{@"op": RDWALOpTerminal, @"id": identifier, @"state": @(state)}];
}

- (NSString *)readText {
    NSString *text = [NSString stringWithContentsOfURL:self.fileURL encoding:NSUTF8StringEncoding error:nil];
    return text ?: @"";
}

- (NSArray<NSDictionary *> *)recoveredItems {
    NSUInteger discarded = 0;
    return RDQueueWALReplay(RDQueueWALDecodeLines([self readText], &discarded));
}

- (void)compactIfNeeded {
    dispatch_async(self.ioQueue, ^{
        NSString *text = [NSString stringWithContentsOfURL:self.fileURL encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSUInteger bad = 0;
        NSArray<NSDictionary *> *records = RDQueueWALDecodeLines(text, &bad);
        NSArray<NSDictionary *> *live = RDQueueWALReplay(records);
        if (!RDQueueWALCompactionNeeded(records.count, live.count) && bad == 0) return;
        NSMutableString *out = [NSMutableString string];
        for (NSDictionary *item in live) {
            NSMutableDictionary *record = [item mutableCopy];
            [record removeObjectForKey:@"percent"];
            [record removeObjectForKey:@"wasRunning"];
            [record removeObjectForKey:@"identifier"];
            record[@"id"] = item[@"identifier"];
            record[@"op"] = RDWALOpEnqueued;
            NSString *line = RDQueueWALEncodeLine(record);
            if (line) [out appendFormat:@"%@\n", line];
            double pct = [item[@"percent"] doubleValue];
            if (pct > 0) {
                NSString *progress = RDQueueWALEncodeLine(@{@"op": RDWALOpProgress, @"id": item[@"identifier"], @"percent": @(pct)});
                if (progress) [out appendFormat:@"%@\n", progress];
            }
        }
        // 原子替换：先写临时文件再 rename，绝不出现「压缩了一半」的日志。
        NSURL *tmp = [self.fileURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                      [self.fileURL.lastPathComponent stringByAppendingString:@".compact.tmp"]];
        if ([out writeToURL:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            [[NSFileManager defaultManager] replaceItemAtURL:self.fileURL withItemAtURL:tmp backupItemName:nil options:0 resultingItemURL:NULL error:nil];
        }
    });
}

- (void)truncate {
    dispatch_sync(self.ioQueue, ^{
        [@"" writeToURL:self.fileURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    @synchronized (self.lastLoggedPercent) {
        [self.lastLoggedPercent removeAllObjects];
    }
}

@end
