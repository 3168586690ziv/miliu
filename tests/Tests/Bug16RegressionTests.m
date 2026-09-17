#import <Foundation/Foundation.h>
#import "ResourceDiscoveryCoordinator.h"
#import "MultiPageResourceProbe.h"
#import "WebProbe.h"
#import "URLPolicy.h"
#import "ResourceDetectorViewModel.h"
#import "HTTPPrivacyPolicy.h"
@interface HTTPPrivacyPolicy (RegressionDeclaration)
+ (void)sanitizeRedirectRequest:(NSMutableURLRequest *)request fromRequest:(NSURLRequest *)previous;
@end

static int failures = 0;
static void Check(BOOL ok, NSString *name) {
    printf("%s %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
    if (!ok) failures++;
}
static void Pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
@interface HangingProbe : NSObject <ZZDiscoveryPageProbing, ZZSinglePageProbing>
@property BOOL nilToken;
@property BOOL completeFirst;
@property NSUInteger starts;
@property NSUInteger cancels;
@property(copy) void (^late)(NSArray *, NSError *);
@end
@implementation HangingProbe
- (id)probePageURL:(NSURL *)url completion:(void (^)(NSArray<DetectedMedia *> *, NSError *))completion {
    self.starts++;
    self.late = completion;
    if (self.completeFirst && self.starts == 1) {
        DetectedMedia *m = [DetectedMedia new];
        m.mediaURL = @"https://example.com/keep.mp4";
        completion(@[m], nil);
    }
    return self.nilToken ? nil : @(self.starts);
}
- (void)cancelProbe:(id)token { self.cancels++; }
@end
@interface HTMLFixture : NSObject <ZZDiscoveryHTMLProviding>
@end
@implementation HTMLFixture
- (id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    completion(@"<a href='/one'>one</a><a href='/two'>two</a><a href='/three'>three</a>", url, nil);
    return nil;
}
- (void)cancelHTMLRequest:(id)token {}
@end
@interface SyncLoader : NSObject <RDProbeLoader>
@property BOOL fail;
@property BOOL hang;
@property(copy) void (^late)(NSString *, AppError *);
@end
@implementation SyncLoader
- (HTTPTask *)loadPageAtURL:(NSURL *)url policy:(URLPolicy *)policy completion:(void (^)(NSString *, AppError *))completion {
    self.late = completion;
    if (!self.hang) completion(self.fail ? nil : @"<html><title>OK</title></html>",
                              self.fail ? [AppError errorWithType:AppErrorParse message:@"fixture"] : nil);
    return nil;
}
- (void)cancelActiveLoad {
    if (self.late) self.late(nil, [AppError errorWithType:AppErrorCancelled message:@"cancelled"]);
}
@end
static void Deadlines(void) {
    for (NSNumber *concurrency in @[@1, @2]) {
        HangingProbe *probe = [HangingProbe new];
        probe.completeFirst = YES;
        ResourceDiscoveryCoordinator *c = [[ResourceDiscoveryCoordinator alloc] initWithPageProbe:probe htmlProvider:[HTMLFixture new]];
        ZZResourceDiscoveryOptions *o = [ZZResourceDiscoveryOptions defaultOptions];
        o.mode = ZZResourceDiscoveryModeSite;
        o.maxConcurrentPageProbes = concurrency.unsignedIntegerValue;
        o.pageBatchDeadline = 0.15;
        o.requestInterval = 0;
        o.maxRetries = 0;
        __block NSUInteger count = 0;
        __block ZZResourceDiscoveryResult *result;
        [c discoverFromURL:[NSURL URLWithString:@"https://example.com/index"] options:o completion:^(ZZResourceDiscoveryResult *r) { count++; result = r; }];
        Pump(0.35);
        NSString *label = [NSString stringWithFormat:@"deadline concurrency=%@", concurrency];
        Check(count == 1 && result.error != nil && !result.cancelled, [label stringByAppendingString:@" explicit timeout once"]);
        Check(result.allMedia.count == 1, [label stringByAppendingString:@" completed media retained"]);
        Check(probe.cancels > 0, [label stringByAppendingString:@" underlying cancellation"]);
        BOOL terminal = YES;
        for (MultiPageProbePageResult *p in result.pageResults)
            if (p.status == MultiPageProbePageStatusProbing || p.status == MultiPageProbePageStatusCancelled) terminal = NO;
        Check(result != nil && terminal, [label stringByAppendingString:@" system failure not user cancellation"]);
        if (probe.late) probe.late(@[], nil);
        Pump(0.1);
        Check(count == 1, [label stringByAppendingString:@" late callback ignored"]);
        [c cancel]; Pump(0.02);
    }
    HangingProbe *probe = [HangingProbe new];
    ResourceDiscoveryCoordinator *c = [[ResourceDiscoveryCoordinator alloc] initWithPageProbe:probe htmlProvider:[HTMLFixture new]];
    ZZResourceDiscoveryOptions *o = [ZZResourceDiscoveryOptions defaultOptions];
    o.mode = ZZResourceDiscoveryModeCurrentPage;
    o.maxConcurrentPageProbes = 1; o.pageBatchDeadline = 0.05;
    __block ZZResourceDiscoveryResult *result;
    __block int count = 0;
    [c discoverFromURL:[NSURL URLWithString:@"https://example.com/"] options:o completion:^(ZZResourceDiscoveryResult *r) { result = r; count++; }];
    Pump(0.15);
    Check(count == 1 && result.error && !result.cancelled && probe.cancels == 1, @"single hanging page positive deadline concurrency=1");
    [c cancel]; Pump(0.02);
}
static void NilTokens(void) {
    HangingProbe *probe = [HangingProbe new]; probe.nilToken = YES;
    MultiPageResourceProbe *mp = [[MultiPageResourceProbe alloc] initWithPageProbe:probe maxConcurrentProbes:2];
    __block MultiPageProbeSummary *summary; __block int count = 0;
    [mp probePageURLs:@[[NSURL URLWithString:@"https://example.com/one"], [NSURL URLWithString:@"https://example.com/two"]] completion:^(MultiPageProbeSummary *s) { summary = s; count++; }];
    [mp cancelAll]; Pump(0.05);
    BOOL allCancelled = summary.pageResults.count == 2;
    for (MultiPageProbePageResult *p in summary.pageResults) allCancelled &= p.status == MultiPageProbePageStatusCancelled;
    Check(allCancelled && summary.cancelled && count == 1 && !mp.isRunning && probe.cancels == 0, @"nil tokens no completion cancelAll closes every active page");
    probe.late(@[], nil); [mp cancelAll]; Pump(0.05);
    Check(count == 1, @"nil token cancellation late completion ignored");
}
static void SynchronousLoaders(void) {
    for (NSNumber *fail in @[@NO, @YES]) {
        WebProbe *probe = [[WebProbe alloc] initWithPolicy:[URLPolicy new]];
        SyncLoader *loader = [SyncLoader new]; loader.fail = fail.boolValue;
        probe.loader = loader; probe.hardTimeout = 0.05;
        __block int count = 0; __block BOOL firstCorrect = NO;
        [probe probeURL:@"https://example.com/" completion:^(RDProbeResult *r, AppError *e, NSUInteger g) {
            count++; if (count == 1) firstCorrect = fail.boolValue ? e != nil : r != nil && e == nil;
        }];
        Pump(0.2);
        Check(count == 1 && firstCorrect, [NSString stringWithFormat:@"sync loader fail=%@ only one completion after timeout", fail]);
        loader.late(@"<html></html>", nil); Pump(0.02);
        Check(count == 1, @"duplicate loader completion ignored");
    }
    WebProbe *probe = [[WebProbe alloc] initWithPolicy:[URLPolicy new]];
    SyncLoader *loader = [SyncLoader new]; loader.hang = YES;
    probe.loader = loader; probe.hardTimeout = 0.05;
    __block int count = 0;
    [probe probeURL:@"https://example.com/" completion:^(RDProbeResult *r, AppError *e, NSUInteger g) { count++; }];
    [probe cancelAll]; Pump(0.2);
    // Existing contract: explicit cancellation invalidates callbacks rather than delivering a result.
    Check(count == 0, @"cancel loader synchronous cancellation callback invalidated");
}
@interface VMProvider : NSObject <RDProbeProvider>
@property BOOL bad;
@property BOOL fail;
@end
@implementation VMProvider
- (NSUInteger)probeURL:(NSString *)url completion:(void (^)(RDProbeResult *, AppError *, NSUInteger))completion {
    RDProbeResult *r = [RDProbeResult new]; r.media = @[]; r.isBadPage = self.bad;
    completion(r, self.fail ? [AppError errorWithType:AppErrorOffline message:@"read failure"] : nil, 1);
    return 1;
}
- (void)cancelAll {}
@end
static void ViewModel(void) {
    for (NSNumber *mode in @[@0, @1, @2]) {
        VMProvider *provider = [VMProvider new]; provider.bad = mode.intValue == 1; provider.fail = mode.intValue == 2;
        ResourceDetectorViewModel *vm = [ResourceDetectorViewModel new]; vm.provider = provider;
        [vm probeURL:@"https://example.com/"];
        if (provider.bad) Check(vm.state != ResourceDetectorStateEmpty && vm.state != ResourceDetectorStateError, @"bad page distinct from empty and read failure");
        else Check(vm.state == (provider.fail ? ResourceDetectorStateError : ResourceDetectorStateEmpty), @"normal empty and read failure retain distinct states");
    }
}
static void Privacy(void) {
    NSURL *source = [NSURL URLWithString:@"https://example.com:443/media"];
    Check(![[HTTPPrivacyPolicy originForURL:source] isEqual:[HTTPPrivacyPolicy originForURL:[NSURL URLWithString:@"https://example.com:444/media"]]], @"privacy origin includes port");
    BOOL available = [HTTPPrivacyPolicy respondsToSelector:@selector(sanitizeRedirectRequest:fromRequest:)];
    Check(available, @"shared redirect privacy policy exists");
    if (!available) return;
    NSMutableURLRequest *previous = [NSMutableURLRequest requestWithURL:source];
    for (NSString *h in @[@"Authorization", @"Cookie", @"Referer"])
        [previous setValue:@"https://example.com/private?token=SECRET" forHTTPHeaderField:h];
    for (NSString *url in @[@"https://example.com/next", @"https://other.example/next", @"https://example.com:444/next"]) {
        NSMutableURLRequest *next = [previous mutableCopy]; next.URL = [NSURL URLWithString:url];
        [HTTPPrivacyPolicy sanitizeRedirectRequest:next fromRequest:previous];
        BOOL same = [url isEqual:@"https://example.com/next"];
        for (NSString *h in @[@"Authorization", @"Cookie", @"Referer"])
            Check([h isEqualToString:@"Referer"] ? [[next valueForHTTPHeaderField:h] isEqualToString:@"https://example.com"] :
                  (same ? [[next valueForHTTPHeaderField:h] isEqual:[previous valueForHTTPHeaderField:h]] : [next valueForHTTPHeaderField:h] == nil),
                  [NSString stringWithFormat:@"redirect privacy %@ %@", url, h]);
        if (!same) {
            NSMutableURLRequest *back = [previous mutableCopy];
            [HTTPPrivacyPolicy sanitizeRedirectRequest:back fromRequest:next];
            Check([[back valueForHTTPHeaderField:@"Referer"] isEqualToString:@"https://example.com"], @"redirect chain retains origin but never resurrects sensitive path/query");
        }
    }
}
static void Policy(void) {
    URLPolicy *p = [URLPolicy new];
    for (NSString *url in @[@"http:///path", @"https:///path", @"https://", @"https://user:pass@example.com/video.mp4", @"https://user@example.com/", @"https://:pass@example.com/", @"https://us%65r:p%61ss@example.com/", @"https://@example.com/"])
        Check(![p evaluateTextURL:url].allowed, [@"reject malformed/credentials " stringByAppendingString:url]);
    NSURL *https = [NSURL URLWithString:@"https://example.com/"];
    NSURL *http = [NSURL URLWithString:@"http://other.example/"];
    Check(![p evaluateRedirect:http fromURL:https].allowed, @"deny HTTPS to HTTP redirect");
    Check([p evaluateRedirect:https fromURL:http].allowed, @"allow HTTP to HTTPS redirect");
    Check([p evaluateRedirect:[NSURL URLWithString:@"https://other.example/"] fromURL:https].allowed, @"allow HTTPS to HTTPS redirect");
    Check(![p evaluateRedirect:[NSURL URLWithString:@"https://user:pass@example.com/"] fromURL:https].allowed, @"deny credentials in redirect");
}
@interface FilterProbe : NSObject <ZZDiscoveryPageProbing>
@property BOOL interim;
@property NSUInteger starts;
@property(copy) void (^late)(NSArray *,NSError *,BOOL);
@end
@implementation FilterProbe
- (id)probePageURL:(NSURL *)url completion:(void (^)(NSArray<DetectedMedia *> *,NSError *))completion {return nil;}
- (id)probePageURL:(NSURL *)url incrementalCompletion:(void (^)(NSArray<DetectedMedia *> *,NSError *,BOOL))completion {
    self.late=completion;
    if(++self.starts==1){
        DetectedMedia *image=[DetectedMedia new];image.mediaURL=@"https://example.com/poster.jpg";image.resourceKind=RDResourceKindImage;
        DetectedMedia *video=[DetectedMedia new];video.mediaURL=@"https://example.com/keep.mp4";video.resourceKind=RDResourceKindVideo;video.poster=@"https://example.com/cover.jpg";
        completion(@[image,video,video],nil,!self.interim);
    }
    return @(self.starts);
}
- (void)cancelProbe:(id)token {}
@end
static void StopUsesNormalFiltering(void) {
    for(NSNumber *parallel in @[@1,@2])for(NSNumber *cancel in @[@NO,@YES])for(NSNumber *interim in @[@NO,@YES]){
        FilterProbe *probe=[FilterProbe new];probe.interim=interim.boolValue;
        ResourceDiscoveryCoordinator *c=[[ResourceDiscoveryCoordinator alloc]initWithPageProbe:probe htmlProvider:[HTMLFixture new]];
        ZZResourceDiscoveryOptions *o=[ZZResourceDiscoveryOptions defaultOptions];o.mode=ZZResourceDiscoveryModeSite;o.maxConcurrentPageProbes=parallel.unsignedIntegerValue;o.maxRetries=0;o.requestInterval=0;o.pageBatchDeadline=.12;
        __block ZZResourceDiscoveryResult *result;__block int completions=0;
        [c discoverFromURL:[NSURL URLWithString:@"https://example.com/index"] options:o completion:^(ZZResourceDiscoveryResult *r){result=r;completions++;}];
        Pump(.05);if(cancel.boolValue)[c cancel];Pump(.16);
        NSString *label=[NSString stringWithFormat:@"stop filter concurrency=%@ userCancel=%@ interim=%@",parallel,cancel,interim];
        Check(result&&result.allMedia.count==1&&result.allMedia.firstObject.resourceKind==RDResourceKindVideo&&result.allMedia.firstObject.poster.length>0,[label stringByAppendingString:@" video/poster retained; images removed; dedup kept"]);
        Check(result.cancelled==cancel.boolValue&&(cancel.boolValue?result.error==nil:result.error.code==NSURLErrorTimedOut),[label stringByAppendingString:@" terminal reason consistent"]);
        for(MultiPageProbePageResult *page in result.pageResults)for(DetectedMedia *m in page.media)Check(m.resourceKind!=RDResourceKindImage,@"page-level snapshot uses same mode filter");
        probe.late(@[],nil,NO);probe.late(@[],nil,YES);probe.late(@[],nil,YES);Pump(.02);
        Check(completions==1,[label stringByAppendingString:@" duplicate/late/interim callbacks ignored"]);
    }
}
int main(void) { @autoreleasepool {
    Policy(); NilTokens(); Deadlines(); SynchronousLoaders(); ViewModel(); Privacy(); StopUsesNormalFiltering();
    printf("FAILURES=%d\n", failures);
    return failures ? 1 : 0;
} }
