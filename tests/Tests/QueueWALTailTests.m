// Stage 1: invoke the production WAL with isolated files; no App or preferences.
#import <Foundation/Foundation.h>
#import "RDQueueWAL.h"

static NSUInteger checks, failed;
static void Check(BOOL ok, NSString *name) {
    checks++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
    if (!ok) failed++;
}
static void Drain(RDQueueWAL *wal) {
    dispatch_queue_t queue = [wal valueForKey:@"ioQueue"];
    dispatch_sync(queue, ^{});
}
static NSData *Line(NSString *identifier, BOOL newline) {
    NSString *s = RDQueueWALEncodeLine(@{@"op": @"enqueued", @"id": identifier, @"position": @0});
    return [(newline ? [s stringByAppendingString:@"\n"] : s) dataUsingEncoding:NSUTF8StringEncoding];
}
static NSArray *IDs(RDQueueWAL *wal) {
    Drain(wal);
    return [[wal recoveredItems] valueForKey:@"identifier"];
}
static void RunCase(NSString *root, NSString *name, NSData *tail, BOOL completeTail) {
    NSURL *url = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[name stringByAppendingString:@".wal"]]];
    NSMutableData *seed = [Line(@"A", YES) mutableCopy];
    [seed appendData:tail];
    Check([seed writeToURL:url atomically:YES], [name stringByAppendingString:@" seed written"]);
    RDQueueWAL *wal = [[RDQueueWAL alloc] initWithFileURL:url];
    NSArray *before = IDs(wal);
    Check([before containsObject:@"A"], [name stringByAppendingString:@" existing A survives recovery"]);
    if (completeTail) Check([before containsObject:@"T"], [name stringByAppendingString:@" complete unterminated record is valid"]);
    [wal appendEnqueuedRecord:@{@"id": @"B"} position:1];
    [wal compactIfNeeded]; // Exactly the production enqueue ordering.
    NSArray *after = IDs(wal);
    Check([after containsObject:@"A"] && [after containsObject:@"B"], [name stringByAppendingString:@" append B then compact preserves A+B"]);
    if (completeTail) Check([after containsObject:@"T"], [name stringByAppendingString:@" preserves complete tail T"]);
    RDQueueWAL *again = [[RDQueueWAL alloc] initWithFileURL:url];
    [again appendEnqueuedRecord:@{@"id": @"C"} position:2];
    [again compactIfNeeded];
    NSArray *reopened = IDs(again);
    Check([reopened containsObject:@"A"] && [reopened containsObject:@"B"] && [reopened containsObject:@"C"],
          [name stringByAppendingString:@" reopen/append C/recover preserves A+B+C"]);
    // Force compaction after many terminal events; verify ordering and live IDs.
    for (NSUInteger i=0; i<205; i++) [again appendTerminal:[NSString stringWithFormat:@"unused-%lu", (unsigned long)i] state:4];
    [again appendProgress:@"B" percent:35];
    [again compactIfNeeded];
    NSArray *compacted = IDs(again);
    Check([compacted containsObject:@"A"] && [compacted containsObject:@"B"] && [compacted containsObject:@"C"],
          [name stringByAppendingString:@" forced compaction preserves live tasks"]);
    NSDictionary *b = nil;
    for (NSDictionary *item in [again recoveredItems]) if ([item[@"identifier"] isEqual:@"B"]) b = item;
    Check([b[@"percent"] doubleValue] == 35, [name stringByAppendingString:@" compaction retains progress"]);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
        printf("ISOLATED_WAL_ROOT=%s\n", root.UTF8String);
        RunCase(root, @"normal", NSData.data, NO);
        RunCase(root, @"torn-json", [@"{\"op\":\"prog" dataUsingEncoding:NSUTF8StringEncoding], NO);
        const unsigned char tornUTF8[] = {'{', '"', 'o', 'p', '"', ':', '"', 0xe4, 0xb8};
        RunCase(root, @"torn-utf8", [NSData dataWithBytes:tornUTF8 length:sizeof(tornUTF8)], NO);
        RunCase(root, @"complete-no-newline", Line(@"T", NO), YES);
        RunCase(root, @"whitespace-tail", [@" \r\t" dataUsingEncoding:NSUTF8StringEncoding], NO);
        NSMutableData *middle = [NSMutableData dataWithBytes:tornUTF8 length:sizeof(tornUTF8)];
        [middle appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [middle appendData:Line(@"T", NO)];
        RunCase(root, @"bad-utf8-middle-valid-tail", middle, YES);
        NSString *longTail = [@"{\"op\":\"" stringByAppendingString:[@"x" stringByPaddingToLength:9000 withString:@"x" startingAtIndex:0]];
        RunCase(root, @"long-torn-tail", [longTail dataUsingEncoding:NSUTF8StringEncoding], NO);
        NSString *longRecord = RDQueueWALEncodeLine(@{@"op": @"enqueued", @"id": @"T", @"title": longTail});
        RunCase(root, @"long-complete-tail", [longRecord dataUsingEncoding:NSUTF8StringEncoding], YES);
        RunCase(root, @"json-without-op", [@"{\"id\":\"invalid\"}" dataUsingEncoding:NSUTF8StringEncoding], NO);
        NSURL *terminalURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"terminal-tail.wal"]];
        NSMutableData *terminalSeed = [Line(@"A", YES) mutableCopy];
        [terminalSeed appendData:[RDQueueWALEncodeLine(@{@"op": @"terminal", @"id": @"A", @"state": @4}) dataUsingEncoding:NSUTF8StringEncoding]];
        Check([terminalSeed writeToURL:terminalURL atomically:YES], @"terminal tail seed written");
        RDQueueWAL *terminal = [[RDQueueWAL alloc] initWithFileURL:terminalURL];
        [terminal appendEnqueuedRecord:@{@"id": @"B"} position:1];
        [terminal compactIfNeeded];
        Check([IDs(terminal) isEqual:@[@"B"]], @"complete terminal tail is preserved, never resurrects A");
        printf("WAL-TAIL checks=%lu failed=%lu\n", (unsigned long)checks, (unsigned long)failed);
        return failed ? 1 : 0;
    }
}
