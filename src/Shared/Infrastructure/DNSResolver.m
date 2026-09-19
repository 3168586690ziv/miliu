// DNS safety preflight only: NSURLSession/WebKit resolve again when connecting.
// These answers are not evidence of the actual peer IP or strict rebinding protection.
#import "DNSResolver.h"
#import "RDLog.h"
#import <netdb.h>
#import <arpa/inet.h>
#import <netinet/in.h>

static const NSUInteger DNSMaxActive = 4;
static const NSUInteger DNSMaxCachedHosts = 128;
static const NSTimeInterval DNSWaitSeconds = 2.0;
static const NSTimeInterval DNSCacheSeconds = 0.5;

@interface RDLookup : NSObject
@property(nonatomic, strong) dispatch_group_t done;
@property(nonatomic, copy) NSArray<NSString *> *ips;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) NSTimeInterval expires;
@property(nonatomic) BOOL startedSystem;
@property(nonatomic) BOOL completed;
@property(nonatomic) DNSResolutionStatus status;
@property(nonatomic, weak) NSOperation *operation;
@end
@implementation RDLookup
@end

static NSMutableDictionary<NSString *, RDLookup *> *DNSLookups(void) {
    static NSMutableDictionary *lookups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lookups = [NSMutableDictionary dictionary]; });
    return lookups;
}
static NSUInteger DNSOutstanding; // queued + running, protected by DNSLookups()
static NSOperationQueue *DNSResolverWorkQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new];
        queue.name = @"com.sevenzz.resource-detector.dns-resolver";
        queue.maxConcurrentOperationCount = DNSMaxActive;
        queue.qualityOfService = NSQualityOfServiceUtility;
    });
    return queue;
}

@implementation DNSResolver
+ (NSArray<NSString *> *)resolveIPsForHost:(NSString *)host {
    return [self resolveIPsForHost:host status:NULL];
}

+ (NSArray<NSString *> *)resolveIPsForHost:(NSString *)host status:(out DNSResolutionStatus *)status {
    if (status) *status = DNSResolutionSucceeded;
    if (!host.length) {
        if (status) *status = DNSResolutionFailed;
        return @[];
    }
    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, host.UTF8String, &v4) == 1 || inet_pton(AF_INET6, host.UTF8String, &v6) == 1) return @[host];

    NSString *key = host.lowercaseString;
    NSMutableDictionary *lookups = DNSLookups();
    __block RDLookup *lookup;
    @synchronized (lookups) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        for (NSString *cachedHost in lookups.allKeys) {
            RDLookup *entry = lookups[cachedHost];
            if (entry.expires > 0 && entry.expires <= now) [lookups removeObjectForKey:cachedHost];
        }
        lookup = lookups[key];
        if (!lookup) {
            // Admission happens BEFORE dispatch_async. A semaphore inside the
            // worker would merely accumulate unbounded queued/thread-blocking work.
            if (DNSOutstanding >= 20) {
                // Bounded backlog: capacity exhaustion is not a dangerous IP
                // and is not a fabricated DNS timeout. Callers can retry later.
                RDLogWriteLevel(RDLogLevelWarn, @"probe", @"DNS 队列已满（在途 %lu），本次解析直接返回忙 host=%@",
                                (unsigned long)DNSOutstanding, key);
                if (status) *status = DNSResolutionBusy;
                return @[];
            }
            if (lookups.count >= DNSMaxCachedHosts) {
                for (NSString *cachedHost in lookups.allKeys) {
                    if (((RDLookup *)lookups[cachedHost]).expires > 0) {
                        [lookups removeObjectForKey:cachedHost]; break;
                    }
                }
            }
            lookup = [RDLookup new];
            lookup.done = dispatch_group_create();
            dispatch_group_enter(lookup.done);
            lookup.started = now;
            lookups[key] = lookup;
            DNSOutstanding++;
            NSBlockOperation *operation=[NSBlockOperation blockOperationWithBlock:^{
                @synchronized(lookups) {
                    if(lookup.completed)return;
                    lookup.startedSystem=YES;
                }
                @autoreleasepool {
                    struct addrinfo hints = {0};
                    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
                    struct addrinfo *results = NULL;
                    // Queue wait consumes the same two-second budget. Expired
                    // queued work never starts a new uncancellable system lookup.
                    BOOL expired = NSProcessInfo.processInfo.systemUptime - lookup.started >= DNSWaitSeconds;
                    int rc = expired ? EAI_AGAIN : getaddrinfo(key.UTF8String, NULL, &hints, &results);
                    NSMutableArray<NSString *> *ips = [NSMutableArray array];
                    if (rc == 0) {
                        for (struct addrinfo *ai = results; ai; ai = ai->ai_next) {
                            const void *address = NULL;
                            if (ai->ai_family == AF_INET) address = &((struct sockaddr_in *)ai->ai_addr)->sin_addr;
                            else if (ai->ai_family == AF_INET6) address = &((struct sockaddr_in6 *)ai->ai_addr)->sin6_addr;
                            char buffer[INET6_ADDRSTRLEN] = {0};
                            if (address && inet_ntop(ai->ai_family, address, buffer, sizeof(buffer))) {
                                NSString *ip = [NSString stringWithUTF8String:buffer];
                                if (ip.length && ![ips containsObject:ip]) [ips addObject:ip];
                            }
                        }
                    }
                    if (results) freeaddrinfo(results);
                    if (rc != 0) {
                        // 解析失败/超时此前完全不可见：只有"探测失败"这个结果，没有原因。
                        RDLogWriteLevel(RDLogLevelWarn, @"probe",
                                        @"DNS 解析未成功 host=%@ rc=%d(%s) 结果=%lu 个地址",
                                        key, rc, gai_strerror(rc), (unsigned long)ips.count);
                    }
                    @synchronized (lookups) {
                        DNSOutstanding--;
                        NSTimeInterval finished = NSProcessInfo.processInfo.systemUptime;
                        if (finished - lookup.started >= DNSWaitSeconds) {
                            // getaddrinfo cannot be cancelled. Discard late results,
                            // including for later coalesced waiters; never cache them.
                            lookup.ips = @[];
                            lookup.status = expired ? DNSResolutionBusy : DNSResolutionTimedOut;
                            [lookups removeObjectForKey:key];
                        } else {
                            lookup.ips = [ips copy];
                            lookup.status = ips.count ? DNSResolutionSucceeded : DNSResolutionFailed;
                            lookup.expires = finished + DNSCacheSeconds;
                        }
                        lookup.completed=YES;
                        dispatch_group_leave(lookup.done);
                    }
                }
            }];
            lookup.operation=operation;
            [DNSResolverWorkQueue() addOperation:operation];
        }
    }
    if (dispatch_group_wait(lookup.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DNSWaitSeconds * NSEC_PER_SEC)))) {
        @synchronized(lookups) {
            // A waiting caller owns no system resolver thread. Remove its
            // expired queued operation even when all four system calls hang.
            if(!lookup.startedSystem && !lookup.completed) {
                lookup.completed=YES;lookup.status=DNSResolutionBusy;lookup.ips=@[];
                DNSOutstanding--;[lookups removeObjectForKey:key];
                [lookup.operation cancel];dispatch_group_leave(lookup.done);
            }
            // A resolver completion can land after the wait times out.  In that
            // case report the resolver's real answer, not a transient timeout.
            // status 可为 NULL（便捷封装 resolveIPsForHost: 传 NULL），写前必须判空。
            if (lookup.completed) { if (status) *status = lookup.status; }
            else if (status) *status = lookup.startedSystem ? DNSResolutionTimedOut : DNSResolutionBusy;
        }
        return @[];
    }
    @synchronized (lookups) {
        if (!lookup.ips.count && status) *status = lookup.status;
        return lookup.ips ?: @[];
    }
}
@end
