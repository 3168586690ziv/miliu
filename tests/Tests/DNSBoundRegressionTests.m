#import <Foundation/Foundation.h>
#import "DNSResolver.h"
#import <netdb.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <unistd.h>

static atomic_int activeCount, peakCount, lookupCount;
// Link-time test interposition: only *.fixture.invalid is substituted. The
// production resolver still executes real getaddrinfo calls and its deadlines.
int getaddrinfo(const char *host, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    static int (*original)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
    if (!original) original = dlsym(RTLD_NEXT, "getaddrinfo");
    if (!strstr(host, ".fixture.invalid")) return original(host, service, hints, result);
    atomic_fetch_add(&lookupCount, 1);
    int current = atomic_fetch_add(&activeCount, 1) + 1;
    int old = atomic_load(&peakCount);
    while (old < current && !atomic_compare_exchange_weak(&peakCount, &old, current)) {}
    if (strstr(host, "slow")) usleep(2500000);
    if (strstr(host, "medium")) usleep(300000);
    int rc = original("93.184.216.34", service, hints, result);
    atomic_fetch_sub(&activeCount, 1);
    return rc;
}
static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }
int main(void) { @autoreleasepool {
    // Warm up dlsym before concurrent calls.
    [DNSResolver resolveIPsForHost:@"warm.fixture.invalid"];
    dispatch_group_t congestion=dispatch_group_create();
    for(int i=0;i<4;i++)dispatch_group_async(congestion,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        [DNSResolver resolveIPsForHost:[NSString stringWithFormat:@"medium-%d.fixture.invalid",i]];
    });
    NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:1];
    while(atomic_load(&activeCount)<4&&ready.timeIntervalSinceNow>0)usleep(1000);
    DNSResolutionStatus healthyStatus;
    check([DNSResolver resolveIPsForHost:@"fifth.fixture.invalid" status:&healthyStatus].count>0 && healthyStatus==DNSResolutionSucceeded,
          "healthy fifth host waits for short congestion instead of immediate false timeout");
    dispatch_group_wait(congestion,DISPATCH_TIME_FOREVER);
    atomic_store(&lookupCount, 0);
    for (int i = 0; i < 3; i++) [DNSResolver resolveIPsForHost:@"cache.fixture.invalid"];
    check(atomic_load(&lookupCount) == 1, "short host cache avoids repeated system lookups");
    atomic_store(&lookupCount, 0); atomic_store(&peakCount, 0);
    dispatch_group_t group = dispatch_group_create();
    for (int i = 0; i < 16; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            DNSResolutionStatus status;
            NSArray *ips = [DNSResolver resolveIPsForHost:[NSString stringWithFormat:@"slow-%d.fixture.invalid", i] status:&status];
            if (ips.count) printf("NOTE late DNS success for fixture %d\n", i);
        });
    }
    check(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 8*NSEC_PER_SEC)) == 0, "timeout callers return within bounded total time");
    check(atomic_load(&peakCount) <= 4, "at most four uncancellable system DNS tasks globally");
    check(atomic_load(&lookupCount) <= 4, "saturated hosts do not enqueue hidden background DNS work or retries");
    usleep(3000000);
    NSDate *start = [NSDate date];
    check([DNSResolver resolveIPsForHost:@"healthy.fixture.invalid"].count > 0 && -start.timeIntervalSinceNow < 0.5,
          "healthy lookup resumes after old work drains");
    atomic_store(&lookupCount, 0);
    for (int i = 0; i < 8; i++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [DNSResolver resolveIPsForHost:@"slow-shared.fixture.invalid"];
    });
    check(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 8*NSEC_PER_SEC)) == 0, "coalesced host waiters time out without late callbacks");
    check(atomic_load(&lookupCount) == 1, "same-host in-flight requests share one getaddrinfo");
    usleep(3000000);
    printf("FAILURES=%d\n", failures); return failures ? 1 : 0;
} }
