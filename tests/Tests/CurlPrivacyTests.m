// Production curl entry points with fake native, DNS and process boundaries only.
#import <Foundation/Foundation.h>
#import "RDCurlFallbackBackend.h"
#import "RDCurlHopper.h"
#import "RDNativeOnlyRequest.h"
#import "HTTPPrivacyPolicy.h"
#import "URLPolicy.h"
#import "RDLog.h"

// Test build renames NSTemporaryDirectory at compile time for all linked test
// translation units: no production header/body artifact leaves this fixture root.
NSString *RDCurlPrivacyTemporaryDirectory(void) {
    return [NSProcessInfo.processInfo.environment[@"RD_CURL_TEST_ROOT"] stringByAppendingPathComponent:@"tmp/"];
}

static NSUInteger checks, failures;
static NSString *root;
static NSString * const secret = @"CURL_PRIVACY_FIXTURE_SECRET_6719";
static void Check(BOOL ok, NSString *name) {
    checks++; if (!ok) failures++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
}
static void Wait(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    Check(done(), @"asynchronous operation completed within fixture deadline");
}
static NSURL *URL(NSString *s) { return [NSURL URLWithString:s]; }
static NSString *Value(NSArray *argv, NSString *flag) {
    NSUInteger i = [argv indexOfObject:flag];
    return i != NSNotFound && i + 1 < argv.count ? argv[i+1] : nil;
}
static NSDictionary *Headers(NSArray *argv) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i + 1 < argv.count; i++) {
        if (![argv[i] isEqual:@"-H"]) continue;
        NSString *line = argv[++i]; NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound)
            out[[line substringToIndex:colon.location].lowercaseString] =
                [[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return out;
}
static NSInteger Respond(NSString *h, NSString *b, NSInteger code, NSString *location, NSString *body) {
    NSString *text = [NSString stringWithFormat:@"HTTP/1.1 %ld Fixture\r\nContent-Type: video/mp4\r\n%@\r\n",
        (long)code, location ? [NSString stringWithFormat:@"Location: %@\r\n", location] : @""];
    BOOL ok = [text writeToFile:h atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return ok && [body writeToFile:b atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : 7;
}
static RDCurlHopper *Hopper(void) {
    RDCurlHopper *h = [RDCurlHopper new];
    h.resolver = ^NSArray *(NSString *host) { return @[@"93.184.216.34"]; };
    return h;
}
static RDCurlHopResult *Walk(RDCurlHopper *h, NSString *url, NSDictionary *headers, NSUInteger budget) {
    __block RDCurlHopResult *result;
    [h walkURL:URL(url) method:@"GET" headers:headers budget:budget
        deadline:CFAbsoluteTimeGetCurrent()+3 bodyToFile:NO completion:^(RDCurlHopResult *r) { result=r; }];
    Wait(^BOOL { return result != nil; });
    return result;
}

@interface PrivacyNativeTask : NSObject <RDDownloadTask>
@property (nonatomic, copy) void (^cancelAction)(void);
@property NSUInteger cancelCount;
@end
@implementation PrivacyNativeTask
- (void)rd_cancel { self.cancelCount++; if (self.cancelAction) self.cancelAction(); }
@end
@interface PrivacyNative : NSObject <RDDownloadBackend>
@property (nonatomic, copy) void (^pending)(NSURL *, NSHTTPURLResponse *, NSError *);
@property (nonatomic, strong) NSURLRequest *seen;
@property (nonatomic, strong) PrivacyNativeTask *task;
@property BOOL synchronous;
@property NSUInteger starts, reissues;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSURL *writtenURL;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@end
@implementation PrivacyNative
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)r writeToURL:(NSURL *)u completion:(void (^)(NSURL *,NSHTTPURLResponse *,NSError *))completion {
    self.starts++; self.seen=r; self.pending=completion; self.task=[PrivacyNativeTask new];
    if (self.synchronous) completion(self.writtenURL,self.response,self.error);
    return self.task;
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)r writeToURL:(NSURL *)u progress:(void (^)(int64_t,int64_t,int64_t))p completion:(void (^)(NSURL *,NSHTTPURLResponse *,NSError *))completion {
    return [self rd_startRequest:r writeToURL:u completion:completion];
}
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)r writeToURL:(NSURL *)u progress:(void (^)(int64_t,int64_t,int64_t))p completion:(void (^)(NSURL *,NSHTTPURLResponse *,NSError *))completion {
    self.reissues++;
    return [self rd_startRequest:r writeToURL:u completion:completion];
}
@end
static PrivacyNative *Native(void) {
    PrivacyNative *n=[PrivacyNative new];
    n.error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
    n.response=[[NSHTTPURLResponse alloc] initWithURL:URL(@"https://site.fixture.test/v.mp4") statusCode:403 HTTPVersion:@"HTTP/2" headerFields:@{}];
    return n;
}
static RDCurlFallbackBackend *Backend(PrivacyNative *n, NSMutableArray *argvs) {
    RDCurlFallbackBackend *b=[RDCurlFallbackBackend backendWithNativeBackend:n];
    b.resolver=^NSArray *(NSString *host) { return @[@"93.184.216.34"]; };
    b.curlRunner=^NSInteger(NSArray *args,NSString *h,NSString *body) {
        @synchronized (argvs) { [argvs addObject:args]; }
        return Respond(h,body,200,nil,@"FIXTURE-MEDIA");
    };
    return b;
}
static NSURL *Destination(void) { return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString]]; }

static void TestMarker(void) {
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:URL(@"https://site.fixture.test/v.mp4")];
    Check(!RDRequestRequiresNativeTransport(r), @"anonymous request has no native-only requirement");
    RDMarkRequestRequiresNativeTransport(r);
    Check(RDRequestRequiresNativeTransport(r), @"in-memory auth context requires native even with no Cookie");
    Check(RDRequestRequiresNativeTransport([r copy]) && RDRequestRequiresNativeTransport([r mutableCopy]), @"native-only marker survives immutable and mutable request copies");
    Check(r.allHTTPHeaderFields.count==0, @"auth context marker is never an HTTP field");
}
static void TestDirectCredentials(void) {
    for (NSString *name in @[@"Cookie",@"cookie",@"cOoKiE",@"Authorization",@"authorization",@"AUTHORIZATION",@"Proxy-Authorization",@"proxy-authorization",@"pRoXy-AuThOrIzAtIoN"]) {
        for (NSString *value in @[secret,@""]) {
            RDCurlHopper *h=Hopper(); __block NSUInteger calls=0, dnsCalls=0;
            h.resolver=^NSArray *(NSString *host) { dnsCalls++; return @[@"93.184.216.34"]; };
            h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { calls++; return Respond(hf,bf,200,nil,@"MEDIA"); };
            NSArray *before=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
            RDCurlHopResult *r=Walk(h,@"https://site.fixture.test/v.mp4",@{name:value},0);
            NSArray *after=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
            Check(calls==0 && dnsCalls==0, [NSString stringWithFormat:@"direct hopper refuses %@ before DNS/runner including empty value",name]);
            Check([r.error.domain isEqual:RDCurlHopErrorDomain] && r.error.code==RDCurlHopUnresolved, @"direct authenticated input returns unresolved, never anonymous success");
            Check([[NSSet setWithArray:before] isEqual:[NSSet setWithArray:after]], @"rejected auth input creates no temporary header/body file");
        }
    }
}
static void TestNativeCredentials(void) {
    for (NSString *name in @[@"Cookie",@"cookie",@"cOoKiE",@"Authorization",@"authorization",@"AUTHORIZATION",@"Proxy-Authorization",@"proxy-authorization",@"pRoXy-AuThOrIzAtIoN",@"context"]) {
        for (NSUInteger empty=0; empty<2; empty++) for (NSUInteger reissue=0; reissue<2; reissue++) {
            PrivacyNative *n=Native(); n.synchronous=empty==0;
            if (empty) n.response=nil; // Transport error without any HTTP response.
            else if (!reissue) n.error=nil; // A written 403 with no transport error.
            n.writtenURL=Destination();
            [@"ORIGINAL-NATIVE-FAILURE" writeToURL:n.writtenURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSMutableArray *args=[NSMutableArray array]; RDCurlFallbackBackend *b=Backend(n,args);
            NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:URL(@"https://site.fixture.test/v.mp4")];
            if ([name isEqual:@"context"]) RDMarkRequestRequiresNativeTransport(r);
            else [r setValue:empty?@"":secret forHTTPHeaderField:name];
            __block NSUInteger done=0; __block BOOL exact=NO;
            void (^completion)(NSURL *,NSHTTPURLResponse *,NSError *)=^(NSURL *u,NSHTTPURLResponse *resp,NSError *e) {
                done++; exact=u==n.writtenURL && resp==n.response && e==n.error;
            };
            if (reissue) [b rd_reissueRequest:r writeToURL:Destination() progress:nil completion:completion];
            else [b rd_startRequest:r writeToURL:Destination() completion:completion];
            // Mutating a caller's request after acceptance must not erase the gate.
            [r setAllHTTPHeaderFields:@{}];
            r.URL=URL(@"https://changed.fixture.test/changed");
            if (!n.synchronous) n.pending(n.writtenURL,n.response,n.error);
            Wait(^BOOL { return done>0; });
            Check(args.count==0 && exact && done==1, [NSString stringWithFormat:@"native %@ empty=%lu reissue=%lu preserves exact result without curl",name,(unsigned long)empty,(unsigned long)reissue]);
            Check(n.starts==1 && n.reissues==reissue, @"native transport still executes exactly once with fresh-reissue contract");
            Check([[[NSString alloc] initWithContentsOfURL:n.writtenURL encoding:NSUTF8StringEncoding error:nil] isEqual:@"ORIGINAL-NATIVE-FAILURE"], @"protected native output file remains byte-for-byte untouched");
            // Foundation's private concrete request class may inherit from the
            // mutable class even for -copy. Test snapshot behavior, not class name.
            Check(n.seen!=r && [n.seen.URL.absoluteString isEqual:@"https://site.fixture.test/v.mp4"] && RDRequestRequiresNativeTransport(n.seen), @"native acceptance snapshot survives caller URL/header mutations");
        }
    }
    PrivacyNative *n=Native(); n.error=nil;
    n.response=[[NSHTTPURLResponse alloc] initWithURL:URL(@"https://site.fixture.test/v.mp4") statusCode:200 HTTPVersion:@"HTTP/2" headerFields:@{}];
    n.synchronous=YES; NSMutableArray *args=[NSMutableArray array];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:URL(@"https://site.fixture.test/v.mp4")];
    [r setValue:secret forHTTPHeaderField:@"Cookie"]; __block NSUInteger done=0;
    [Backend(n,args) rd_startRequest:r writeToURL:Destination() completion:^(NSURL *u,NSHTTPURLResponse *resp,NSError *e) { done++; }];
    Check(done==1 && [[n.seen valueForHTTPHeaderField:@"Cookie"] isEqual:secret] && args.count==0, @"authenticated native success is preserved, never stripped to fake anonymous curl");
}
static void TestAnonymousAndCancel(void) {
    PrivacyNative *n=Native(); NSMutableArray *args=[NSMutableArray array]; RDCurlFallbackBackend *b=Backend(n,args);
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:URL(@"https://site.fixture.test/v.mp4")];
    [r setValue:@"bytes=0-10" forHTTPHeaderField:@"Range"];
    NSURL *dst=Destination(); __block NSUInteger done=0; __block BOOL success=NO;
    [b rd_startRequest:r writeToURL:dst completion:^(NSURL *u,NSHTTPURLResponse *resp,NSError *e) { done++; success=[u isEqual:dst] && resp.statusCode==200 && !e; }];
    [r setValue:secret forHTTPHeaderField:@"Authorization"]; r.URL=URL(@"https://changed.fixture.test/changed");
    n.pending(nil,n.response,n.error); Wait(^BOOL { return done>0; });
    Check(done==1 && success && args.count==1, @"anonymous acceptance remains anonymous after caller mutation and can fallback");
    Check([[args.firstObject lastObject] isEqual:@"https://site.fixture.test/v.mp4"] && [Headers(args.firstObject)[@"range"] isEqual:@"bytes=0-10"], @"anonymous fallback uses original immutable URL and Range");
    Check(![[args description] containsString:secret], @"caller-added credentials never enter captured anonymous argv");
    Check([[[NSString alloc] initWithContentsOfURL:dst encoding:NSUTF8StringEncoding error:nil] isEqual:@"FIXTURE-MEDIA"], @"anonymous curl result is actually moved into fixture destination");

    n=Native(); args=[NSMutableArray array]; b=Backend(n,args); done=0;
    id<RDDownloadTask> task=[b rd_startRequest:[NSURLRequest requestWithURL:URL(@"https://site.fixture.test/cancel")] writeToURL:Destination() completion:^(NSURL *u,NSHTTPURLResponse *resp,NSError *e) { done++; }];
    // Cancellation may synchronously invoke completion with a fallback-eligible error.
    void (^pending)(NSURL *,NSHTTPURLResponse *,NSError *)=[n.pending copy];
    NSHTTPURLResponse *response=n.response; NSError *error=n.error;
    n.task.cancelAction=^{ pending(nil,response,error); };
    [task rd_cancel]; [task rd_cancel]; Wait(^BOOL { return done>0; });
    Check(args.count==0 && done==1 && n.task.cancelCount==1, @"idempotent cancel sets gate before synchronous native completion");
    n.pending(nil,n.response,n.error);
    Check(done==1 && args.count==0, @"duplicate or late native completion cannot restart fallback or complete twice");

    n=Native(); args=[NSMutableArray array]; b=Backend(n,args); done=0;
    n.synchronous=YES;
    NSMutableURLRequest *context=[NSMutableURLRequest requestWithURL:URL(@"https://site.fixture.test/context")]; RDMarkRequestRequiresNativeTransport(context);
    __block id<RDDownloadTask> replacement;
    [b rd_startRequest:context writeToURL:Destination() completion:^(NSURL *u,NSHTTPURLResponse *resp,NSError *e) {
        done++;
        replacement=[b rd_reissueRequest:[context copy] writeToURL:Destination() progress:nil completion:^(NSURL *u2,NSHTTPURLResponse *r2,NSError *e2) { done++; }];
    }];
    Check(done==2 && n.starts==2 && n.reissues==1 && args.count==0 && replacement!=nil, @"synchronous completion reentry keeps native-only context for new request");
}
static void TestRefererWalk(void) {
    for (NSUInteger mode=0; mode<4; mode++) for (NSUInteger cross=0; cross<2; cross++) {
        [HTTPPrivacyPolicy setRefererModeOverride:@(mode)];
        NSString *start=cross?@"https://cdn.fixture.test/start":@"https://site.fixture.test/start";
        NSArray *urls=@[start,[start stringByAppendingString:@"/same"],@"https://other.fixture.test/away",@"https://site.fixture.test/back",@"https://site.fixture.test:444/port"];
        NSMutableArray *refs=[NSMutableArray array]; RDCurlHopper *h=Hopper();
        h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) {
            NSUInteger i=refs.count; NSDictionary *headers=Headers(a); [refs addObject:headers[@"referer"]?:@""];
            Check(![a containsObject:@"-L"] && ![a containsObject:@"--location"], @"each production hop disables blind curl redirect following");
            Check([headers[@"range"] isEqual:@"bytes=0-7"] && Value(a,@"--max-time")!=nil && Value(a,@"--max-filesize")!=nil, @"Range, finite deadline and budget survive sanitized hop");
            return Respond(hf,bf,i+1<urls.count?302:200,i+1<urls.count?urls[i+1]:nil,@"BODY");
        };
        RDCurlHopResult *r=Walk(h,start,@{@"rEfErEr":@"https://site.fixture.test/private/watch?token=FIXTURE#fragment",@"Range":@"bytes=0-7"},1024);
        Check(!r.error && refs.count==urls.count, @"anonymous same/cross/return/port redirect chain succeeds");
        for (NSUInteger i=0; i<refs.count; i++) {
            NSString *expected=@"";
            if (mode==HTTPRefererModeOrigin || mode==HTTPRefererModeCrossOrigin) expected=@"https://site.fixture.test";
            else if (mode==HTTPRefererModeFullPath && !cross && i<2) expected=@"https://site.fixture.test/private/watch?token=FIXTURE";
            Check([refs[i] isEqual:expected], [NSString stringWithFormat:@"Referer mode=%lu initialCross=%lu hop=%lu follows effective previous request",(unsigned long)mode,(unsigned long)cross,(unsigned long)i]);
        }
    }
    [HTTPPrivacyPolicy setRefererModeOverride:nil];
    for (NSString *source in @[@"https://user:password@site.fixture.test/private?x=1",@"file:///private",@"not a URL"]) {
        RDCurlHopper *h=Hopper(); __block BOOL absent=NO;
        h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { absent=Headers(a)[@"referer"]==nil; return Respond(hf,bf,200,nil,@"B"); };
        Walk(h,@"https://site.fixture.test/v",@{@"Referer":source},0);
        Check(absent, @"invalid or userinfo Referer never reaches anonymous argv");
    }
}
static void TestSafety(void) {
    for (NSString *url in @[@"file:///tmp/media",@"http://127.0.0.1/media",@"https://user:pass@site.fixture.test/media"]) {
        RDCurlHopper *h=Hopper(); __block NSUInteger calls=0;
        h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { calls++; return 7; };
        Check(Walk(h,url,@{},0).error.code==RDCurlHopBlocked && calls==0, @"URLPolicy text rejects disallowed target before runner");
    }
    RDCurlHopper *h=Hopper(); __block NSUInteger calls=0;
    h.resolver=^NSArray *(NSString *host) { return @[@"93.184.216.34",@"10.0.0.7"]; };
    h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { calls++; return 7; };
    Check(Walk(h,@"https://site.fixture.test/v",@{},0).error.code==RDCurlHopBlocked && calls==0, @"mixed public/private DNS answers are all checked before runner");
    h=Hopper(); calls=0;
    h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { calls++; return Respond(hf,bf,302,@"http://127.0.0.1/private",@""); };
    Check(Walk(h,@"https://site.fixture.test/v",@{},0).error.code==RDCurlHopBlocked && calls==1, @"redirect target cannot bypass URLPolicy");
    h=Hopper(); h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { return Respond(hf,bf,200,nil,[@"x" stringByPaddingToLength:2048 withString:@"x" startingAtIndex:0]); };
    Check(Walk(h,@"https://site.fixture.test/v",@{},16).error.code==RDCurlHopBudgetExceeded, @"body budget still rejects oversized fixture response");
    h=Hopper(); calls=0; h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { calls++; return 7; };
    __block RDCurlHopResult *result;
    [h walkURL:URL(@"https://site.fixture.test/v") method:@"GET" headers:@{} budget:0 deadline:CFAbsoluteTimeGetCurrent()-1 bodyToFile:NO completion:^(RDCurlHopResult *r){result=r;}];
    Wait(^BOOL{return result!=nil;});
    Check(result.error.code==RDCurlHopUnresolved && calls==0, @"expired deadline preserves unresolved result and prevents runner");
    h=Hopper(); [h cancel]; calls=0; h.runner=^NSInteger(NSArray *a,NSString *hf,NSString *bf) { calls++; return 7; };
    Check(Walk(h,@"https://site.fixture.test/v",@{},0).error.code==RDCurlHopUnresolved && calls==0, @"cancelled hopper cannot start new hop");
}
int main(void) { @autoreleasepool {
    root=NSProcessInfo.processInfo.environment[@"RD_CURL_TEST_ROOT"];
    if (!root.length || ![NSTemporaryDirectory() hasPrefix:root]) { fprintf(stderr,"fixture isolation is required\n"); return 2; }
    [URLPolicy setSystemProxyActiveOverride:@NO];
    TestMarker(); TestDirectCredentials(); TestNativeCredentials(); TestAnonymousAndCancel(); TestRefererWalk(); TestSafety();
    RDLogFlush();
    NSString *log=[[NSString alloc] initWithContentsOfFile:RDLogFilePath() encoding:NSUTF8StringEncoding error:nil]?:@"";
    Check(![log containsString:secret], @"real isolated production log contains no artificial credential value");
    BOOL clean=YES;
    NSDirectoryEnumerator *files=[[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:0 errorHandler:nil];
    for (NSURL *file in files) {
        NSNumber *regular=nil; [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue || [file.lastPathComponent isEqual:@"CurlPrivacyTests"]) continue;
        NSData *bytes=[NSData dataWithContentsOfURL:file];
        if ([bytes rangeOfData:[secret dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,bytes.length)].location!=NSNotFound) clean=NO;
    }
    Check(clean, @"all fixture temp files and logs contain zero artificial credential markers");
    printf("CURL-PRIVACY checks=%lu failed=%lu FAKE_NATIVE_DNS_CURL_ONLY=YES\n",(unsigned long)checks,(unsigned long)failures);
    return failures?1:0;
} }
