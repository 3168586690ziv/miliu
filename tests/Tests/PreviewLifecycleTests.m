// Real preview orchestration with transport/player/window/socket boundaries replaced.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "RDPreviewController.h"
#import "RDPreviewWindow.h"
#import "DetectedMedia.h"
#import "HTTPPrivacyPolicy.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <string.h>
extern NSUInteger RDPreviewTestPlaybackGeneration(void);
extern void RDPreviewTestPlaybackFailure(NSUInteger generation);
extern void RDPreviewTestLoopbackFailed(NSUInteger generation);
extern NSURL *RDPreviewTestStartLoopback(NSString *body);
extern NSURLRequest *RDPreviewTestRedirect(id task, NSURLRequest *request);
extern void RDPreviewTestSetSessions(id master, id trust);
extern void RDPreviewTestSetBoundaries(void (^playback)(NSURL *, NSDictionary *, NSString *), BOOL (^loopback)(NSString *));
static NSUInteger checks, failed, loops, errors;
static NSMutableArray<NSString *> *played;
static NSDictionary *lastOptions;
static void Check(BOOL ok, NSString *name) { checks++; printf("%s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String); if (!ok) failed++; }
static void Pump(void) {
    for (NSUInteger i=0; i<3; i++) {
        __block BOOL done=NO;
        dispatch_async(dispatch_get_main_queue(), ^{ done=YES; });
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:0.3];
        while (!done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
        if (!done) { fprintf(stderr,"MAIN_QUEUE_DRAIN_TIMEOUT\n"); abort(); }
    }
}
@interface FixtureTask : NSObject
@property (nonatomic, copy) void (^callback)(NSData *, NSURLResponse *, NSError *);
@property (nonatomic, copy) void (^onResume)(FixtureTask *);
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic) NSUInteger resumed, cancelled;
- (void)resume;
- (void)cancel;
- (void)finish:(NSData *)data url:(NSString *)url error:(NSError *)error;
@end
@implementation FixtureTask
- (void)resume { self.resumed++; if (self.onResume) self.onResume(self); }
- (void)cancel { self.cancelled++; if (self.onCancel) self.onCancel(); }
- (void)finish:(NSData *)data url:(NSString *)url error:(NSError *)error {
    NSURLResponse *response=url ? [[NSURLResponse alloc] initWithURL:[NSURL URLWithString:url] MIMEType:@"video/mp4" expectedContentLength:data.length textEncodingName:nil] : nil;
    self.callback(data,response,error);
}
@end
@interface FixtureSession : NSObject
@property (nonatomic, strong) NSMutableArray<FixtureTask *> *tasks;
@property (nonatomic, copy) void (^onCreate)(void);
@property (nonatomic, copy) void (^onResume)(FixtureTask *);
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))completion;
@end
@implementation FixtureSession
- (instancetype)init { if ((self=[super init])) _tasks=[NSMutableArray array]; return self; }
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))completion {
    FixtureTask *task=[FixtureTask new]; task.callback=completion; task.onResume=self.onResume;
    [self.tasks addObject:task];
    if (self.onCreate) { void (^block)(void)=self.onCreate; self.onCreate=nil; block(); }
    return task;
}
@end
NSString * const RDPreviewWindowDidCloseNotification=@"RDPreviewWindowDidClose";
@implementation RDPreviewWindow
+ (void)attachPlayer:(AVPlayer *)player title:(NSString *)title { fprintf(stderr,"REAL_PLAYER_BOUNDARY_REACHED\n"); abort(); }
+ (void)showError:(NSString *)message title:(NSString *)title { errors++; }
+ (void)close {}
@end
static FixtureSession *Reset(void) {
    [RDPreviewController stopPreview]; Pump();
    loops=errors=0; played=[NSMutableArray array]; lastOptions=nil;
    FixtureSession *session=[FixtureSession new];
    RDPreviewTestSetSessions(session,session);
    RDPreviewTestSetBoundaries(^(NSURL *url,NSDictionary *options,NSString *title) { [played addObject:title ?: @""]; lastOptions=options; }, ^BOOL(NSString *body) { loops++; return YES; });
    [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeNone)];
    return session;
}
static DetectedMedia *Media(NSString *title,BOOL pinned) {
    DetectedMedia *m=[DetectedMedia new]; m.title=title; m.format=pinned ? @"hls" : @"mp4";
    m.mediaURL=pinned ? @"https://cdn.example/720.m3u8" : @"https://cdn.example/video.mp4";
    m.sourcePageURL=@"https://site.example/watch?q=FIXTURE";
    if (pinned) { m.parentMediaURL=@"https://cdn.example/master.m3u8"; m.declaredVariants=@[@{@"url":m.mediaURL},@{@"url":@"https://cdn.example/480.m3u8"}]; }
    return m;
}
static NSData *Master(void) { return [@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n720.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=500000\n480.m3u8\n" dataUsingEncoding:NSUTF8StringEncoding]; }
static NSError *Error(void) { return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]; }
@interface FixtureDecision : NSObject
@property (nonatomic) BOOL allowed;
@property (nonatomic, copy) NSString *userMessage;
@end
@implementation FixtureDecision
@end
@interface FixturePolicy : NSObject
- (id)evaluateTextURL:(NSString *)url;
- (id)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current;
@end
@implementation FixturePolicy
- (id)evaluateTextURL:(NSString *)url {
    FixtureDecision *decision=[FixtureDecision new];
    decision.allowed=![[NSURL URLWithString:url].host isEqual:@"blocked.example"];
    decision.userMessage=@"fixture policy blocked";
    return decision;
}
- (id)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current { return [self evaluateTextURL:target.absoluteString]; }
@end
static NSString *LocalGET(NSURL *url) {
    // POSIX socket, fixed loopback family/address: no proxy, DNS or HTTP store.
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0) return @"";
    int noSignal=1;
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));
    struct timeval timeout={.tv_sec=2,.tv_usec=0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    struct sockaddr_in address={0}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK); address.sin_port=htons(url.port.intValue);
    if (connect(fd,(struct sockaddr *)&address,sizeof(address))!=0) { close(fd); return @""; }
    NSData *request=[[NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",url.path] dataUsingEncoding:NSUTF8StringEncoding];
    (void)send(fd,request.bytes,request.length,0);
    NSMutableData *received=[NSMutableData data]; char buffer[4096]; ssize_t length;
    while ((length=recv(fd,buffer,sizeof(buffer),0))>0) [received appendBytes:buffer length:(NSUInteger)length];
    close(fd);
    return [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding] ?: @"";
}
static void TestLoopback(void) {
    NSURL *first=RDPreviewTestStartLoopback(@"#EXTM3U\n# FIRST_FIXTURE\n");
    NSURL *last=first;
    NSString *response=LocalGET(first);
    Check([response hasPrefix:@"HTTP/1.1 200"] && [response hasSuffix:@"#EXTM3U\n# FIRST_FIXTURE\n"],@"production loopback serves complete nonempty body on first start");
    for (NSUInteger i=0;i<12;i++) {
        NSString *body=[NSString stringWithFormat:@"#EXTM3U\n# CURRENT_FIXTURE_%lu\n",(unsigned long)i];
        NSUInteger previousGeneration=RDPreviewTestPlaybackGeneration();
        NSURL *current=RDPreviewTestStartLoopback(body);
        last=current;
        // Deliver the production cleanup callback late in a deterministic order;
        // the socket scheduler alone cannot reliably reproduce this race.
        RDPreviewTestLoopbackFailed(previousGeneration); Pump();
        response=LocalGET(current);
        Check([response hasPrefix:@"HTTP/1.1 200"] && [response hasSuffix:body],@"old accept-loop cleanup cannot stop or overwrite new listener");
        NSURL *wrong=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/wrong-path",current.port]];
        Check([LocalGET(wrong) hasPrefix:@"HTTP/1.1 404"],@"production loopback serves only its token path");
    }
    [RDPreviewController stopPreview]; Pump();
    Check(LocalGET(last).length==0,@"stop actually prevents old listener from returning any response");
    printf("LOOPBACK_ONLY=127.0.0.1 NO_PLAYER_NO_WINDOWS=YES\n");
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    if (argc>1 && strcmp(argv[1],"--loopback-only")==0) {
        TestLoopback();
        printf("PREVIEW-LOOPBACK checks=%lu failed=%lu\n",(unsigned long)checks,(unsigned long)failed);
        return failed ? 1 : 0;
    }
    if (argc>1 && strcmp(argv[1],"--timeout-only")==0) {
        FixtureSession *session=Reset();
        [RDPreviewController startPreviewForMedia:Media(@"timeout fallback",NO) policy:nil];
        FixtureTask *task=session.tasks.lastObject;
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
        while (!played.count && deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
        Check([played isEqual:@[@"timeout fallback"]] && task.cancelled==1,@"async watchdog cancels pending resolution and falls back exactly once");
        [task finish:NSData.data url:@"https://cdn.example/too-late.mp4" error:nil]; Pump();
        Check(played.count==1 && errors==0,@"completion after timeout cannot play a second time");
        [RDPreviewController stopPreview];
        printf("NO_NETWORK_NO_WINDOWS=YES\nPREVIEW-TIMEOUT checks=%lu failed=%lu\n",(unsigned long)checks,(unsigned long)failed);
        return failed ? 1 : 0;
    }
    FixtureTask *a=nil, *b=nil;
    FixtureSession *s=Reset();
    NSTimeInterval began=NSDate.timeIntervalSinceReferenceDate;
    [RDPreviewController startPreviewForMedia:Media(@"pending",NO) policy:nil];
    Check(NSDate.timeIntervalSinceReferenceDate-began < 0.2,@"direct preview start returns without waiting for network");
    Check(played.count==0,@"pending resolution does not play original URL early");
    Check([RDPreviewController isPreviewActive],@"pending preview is active for quality switching");
    FixtureTask *pending=s.tasks.lastObject;
    [RDPreviewController stopPreview];
    Check(pending.cancelled==1,@"stop cancels pending resolver exactly once");
    [pending finish:NSData.data url:@"https://cdn.example/final.mp4" error:nil]; Pump();
    Check(played.count==0 && errors==0,@"resolver success arriving after stop has no effects");
    if (argc==1) {
    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"A",NO) policy:nil]; a=s.tasks.lastObject;
    [RDPreviewController startPreviewForMedia:Media(@"B",NO) policy:nil]; b=s.tasks.lastObject;
    Check(a.cancelled==1 && b.resumed==1,@"switch cancels old resolver and starts new one");
    [b finish:NSData.data url:@"https://cdn.example/b.mp4" error:nil];
    [a finish:NSData.data url:@"https://cdn.example/a.mp4" error:nil]; Pump();
    Check([played isEqual:@[@"B"]],@"out-of-order resolver completion plays only B");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"old master",YES) policy:nil]; a=s.tasks.lastObject;
    [RDPreviewController stopPreview];
    Check(a.cancelled==1,@"stop cancels pending master exactly once");
    [a finish:nil url:nil error:Error()]; Pump();
    Check(errors==0 && loops==0 && played.count==0,@"late master error after close is invisible");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"master A",YES) policy:nil]; a=s.tasks.lastObject;
    [RDPreviewController startPreviewForMedia:Media(@"master B",YES) policy:nil]; b=s.tasks.lastObject;
    [b finish:Master() url:@"https://cdn.example/master.m3u8" error:nil];
    [a finish:Master() url:@"https://cdn.example/master.m3u8" error:nil]; Pump();
    Check(loops==1 && [played isEqual:@[@"master B"]],@"old master success cannot replace newer playback or loopback");
    Check(a.cancelled==1 && b.cancelled==0,@"only superseded master is cancelled");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"failure",YES) policy:nil];
    [s.tasks.lastObject finish:nil url:nil error:Error()]; Pump();
    Check(errors==1 && ![RDPreviewController isPreviewActive],@"current master error reports exactly once and clears active state");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"fallback",NO) policy:nil];
    [s.tasks.lastObject finish:nil url:nil error:Error()]; Pump();
    Check([played isEqual:@[@"fallback"]] && errors==0,@"current transient resolution failure preserves direct fallback");

    s=Reset();
    s.onResume=^(FixtureTask *task) { [task finish:NSData.data url:@"https://cdn.example/sync.mp4" error:nil]; };
    [RDPreviewController startPreviewForMedia:Media(@"sync",NO) policy:nil];
    Check(played.count==0,@"synchronous transport completion is deferred out of start stack"); Pump();
    Check([played isEqual:@[@"sync"]],@"synchronous completion eventually plays once");
    [RDPreviewController stopPreview];
    Check(s.tasks.lastObject.cancelled==0,@"completed resolver is not retained as pending");

    s=Reset();
    s.onCreate=^{ [RDPreviewController stopPreview]; };
    [RDPreviewController startPreviewForMedia:Media(@"creation reentry",YES) policy:nil];
    Check(s.tasks.lastObject.cancelled==1 && s.tasks.lastObject.resumed==0,@"stop reentry during task creation cancels without resuming");
    [s.tasks.lastObject finish:Master() url:@"https://cdn.example/master.m3u8" error:nil]; Pump();
    Check(played.count==0 && loops==0,@"reentrant stopped task completion cannot start playback");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"cancel old",YES) policy:nil]; a=s.tasks.lastObject;
    a.onCancel=^{ [RDPreviewController startPreviewForMedia:Media(@"reentrant newest",YES) policy:nil]; };
    [RDPreviewController startPreviewForMedia:Media(@"outer superseded",YES) policy:nil];
    Check(s.tasks.count==2,@"new preview started during cancellation wins over outer start");
    [s.tasks.lastObject finish:Master() url:@"https://cdn.example/master.m3u8" error:nil]; Pump();
    Check([played isEqual:@[@"reentrant newest"]],@"cancellation reentry preserves newest preview");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"cancel callback",YES) policy:nil]; a=s.tasks.lastObject;
    __weak FixtureTask *weakA=a;
    a.onCancel=^{ [weakA finish:nil url:nil error:Error()]; };
    [RDPreviewController stopPreview]; Pump();
    Check(errors==0 && played.count==0,@"synchronous cancellation completion has no stale effects");
    a.onCancel=nil;

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"KVO old",NO) policy:nil];
    [s.tasks.lastObject finish:NSData.data url:@"https://cdn.example/old.mp4" error:nil]; Pump();
    NSUInteger oldGeneration=RDPreviewTestPlaybackGeneration();
    [RDPreviewController startPreviewForMedia:Media(@"KVO new",NO) policy:nil];
    RDPreviewTestPlaybackFailure(oldGeneration); Pump();
    Check(errors==0 && s.tasks.lastObject.cancelled==0,@"queued old KVO error cannot stop a newer pending preview");
    [s.tasks.lastObject finish:NSData.data url:@"https://cdn.example/new.mp4" error:nil]; Pump();
    Check([played.lastObject isEqual:@"KVO new"],@"new preview survives old KVO error");
    RDPreviewTestPlaybackFailure(RDPreviewTestPlaybackGeneration());
    Check(errors==1 && ![RDPreviewController isPreviewActive],@"current KVO error still reports and stops");

    s=Reset();
    s.onResume=^(FixtureTask *task) { [task finish:Master() url:@"https://cdn.example/master.m3u8" error:nil]; };
    [RDPreviewController startPreviewForMedia:Media(@"sync master",YES) policy:nil];
    Check(loops==0 && played.count==0,@"synchronous master completion stays out of start stack");
    [RDPreviewController stopPreview]; Pump();
    Check(loops==0 && played.count==0 && errors==0,@"stop before queued master completion suppresses all effects");

    s=Reset();
    __weak FixtureSession *weakSession=s;
    s.onCreate=^{ [weakSession.tasks.lastObject finish:NSData.data url:@"https://cdn.example/early.mp4" error:nil]; };
    [RDPreviewController startPreviewForMedia:Media(@"creation completion",NO) policy:nil]; Pump();
    Check([played isEqual:@[@"creation completion"]],@"completion during task creation is handled after registration");

    s=Reset();
    FixturePolicy *policy=[FixturePolicy new];
    [RDPreviewController startPreviewForMedia:Media(@"denied resolve",NO) policy:(id)policy];
    a=s.tasks.lastObject;
    NSURLRequest *denied=RDPreviewTestRedirect(a,[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://blocked.example/private.mp4"]]);
    Check(denied==nil,@"resolver redirect retains URLPolicy boundary");
    [a finish:NSData.data url:@"https://cdn.example/video.mp4" error:nil]; Pump();
    Check(errors==1 && played.count==0,@"policy-denied resolver never falls back to original player URL");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"denied master",YES) policy:(id)policy];
    a=s.tasks.lastObject;
    denied=RDPreviewTestRedirect(a,[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://blocked.example/master.m3u8"]]);
    [a finish:Master() url:@"https://cdn.example/master.m3u8" error:nil]; Pump();
    Check(denied==nil && errors==1 && played.count==0 && loops==0,@"policy-denied master cannot serve a supplied body");

    s=Reset();
    [RDPreviewController startPreviewForMedia:Media(@"denied final response",NO) policy:(id)policy];
    [s.tasks.lastObject finish:NSData.data url:@"https://blocked.example/video.mp4" error:nil]; Pump();
    Check(errors==1 && played.count==0,@"terminal response URL is rechecked before player handoff");

    s=Reset();
    RDPreviewTestSetBoundaries(^(NSURL *url,NSDictionary *options,NSString *title) { [played addObject:title ?: @""]; lastOptions=options; }, ^BOOL(NSString *body) {
        loops++; [RDPreviewController stopPreview]; return YES;
    });
    [RDPreviewController startPreviewForMedia:Media(@"loopback reentry",YES) policy:nil];
    [s.tasks.lastObject finish:Master() url:@"https://cdn.example/master.m3u8" error:nil]; Pump();
    Check(loops==1 && played.count==0,@"stop reentry at loopback boundary prevents stale player handoff");

    s=Reset();
    [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeOrigin)];
    DetectedMedia *mutableMedia=Media(@"source snapshot",NO);
    [RDPreviewController startPreviewForMedia:mutableMedia policy:nil];
    mutableMedia.sourcePageURL=@"https://changed.example/new?q=changed";
    [s.tasks.lastObject finish:NSData.data url:@"https://cdn.example/final.mp4" error:nil]; Pump();
    Check([lastOptions[@"AVURLAssetHTTPHeaderFieldsKey"][@"Referer"] isEqual:@"https://site.example"],@"asynchronous preview uses source snapshot rather than later-mutated media");
    }
    [RDPreviewController stopPreview]; Pump();
    printf("NO_NETWORK_NO_WINDOWS=YES\nPREVIEW-LIFECYCLE checks=%lu failed=%lu\n",(unsigned long)checks,(unsigned long)failed);
    return failed ? 1 : 0;
} }
