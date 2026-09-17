#import <Foundation/Foundation.h>
#import "StaticHTMLDiscoveryPageProbe.h"
#import "ResourceURLGate.h"
#import "RDHybridPageProbe.h"
static NSDictionary *bodies;
static NSMutableArray *requests;
static int failures;
static NSError *lastError;
@interface ScriptDynamicLoader : NSObject <RDProbeLoader> @end
@implementation ScriptDynamicLoader
- (HTTPTask *)loadPageAtURL:(NSURL *)url policy:(URLPolicy *)policy completion:(void (^)(NSString *,AppError *))done {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.2*NSEC_PER_SEC),dispatch_get_main_queue(),^{done(@"<video src='https://cdn.example.com/dynamic-only.mp4'></video>",nil);});return nil;
}
@end
@interface ScriptGate : ResourceURLGate @end
@implementation ScriptGate
- (void)verifyURLAsync:(NSURL *)url completion:(void (^)(URLPolicyDecision *))done {
    URLPolicyDecision *d = [self.policy evaluateTextURL:url.absoluteString];
    dispatch_async(dispatch_get_main_queue(), ^{ done(d); });
}
@end
@interface ScriptProtocol : NSURLProtocol @end
@implementation ScriptProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    @synchronized(requests) { [requests addObject:self.request.URL.absoluteString]; }
    id body = bodies[self.request.URL.path];
    if ([body isEqual:@"HANG"]) return;
    if (!body) { [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]]; return; }
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length":@(data.length).stringValue}];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static void pump(double seconds) { NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds]; while(end.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]]; }
static void check(BOOL ok, NSString *message) { printf("%s %s\n",ok?"PASS":"FAIL",message.UTF8String); if(!ok)failures++; }
static NSArray *run(NSDictionary *fixture, BOOL cancel) {
    bodies=fixture; requests=[NSMutableArray array];lastError=nil;
    NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration; cfg.protocolClasses=@[ScriptProtocol.class];
    StaticHTMLDiscoveryPageProbe *p=[[StaticHTMLDiscoveryPageProbe alloc]initWithPolicy:[URLPolicy new] sessionConfiguration:cfg];
    [p setValue:[ScriptGate new] forKey:@"gate"];
    __block NSArray *media; __block int count=0;
    id token=[p probePageURL:[NSURL URLWithString:@"https://example.com/page"] completion:^(NSArray *m,NSError *e){media=m;lastError=e;count++;}];
    if(cancel){pump(.05);[p cancelProbe:token];}
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!count && end.timeIntervalSinceNow>0 && !cancel)pump(.01);
    if(cancel)pump(.2);
    check(cancel ? count==0 : count==1, cancel?@"cancel suppresses final completion":@"exactly one final completion");
    return media;
}
int main(void){@autoreleasepool{
    NSArray *ignored=run(@{@"/page":@"<!-- <script src='/comment.js'></script> --><script data-src='/lazy.js'></script><script>const sample=\"<script src='/literal.js'>\";</script><video src='/keep.mp4'></video>"},NO);
    check(requests.count==1&&ignored.count==1,@"comments, data-src and inline quoted markup do not trigger script requests");
    NSArray *m=run(@{@"/page":@"<script src='/js/player.js'></script><script src='https://cdn.example.com/other.js'></script>",@"/js/player.js":@"var config={file:'../video.mp4',source:'https:\\/\\/cdn.example.com\\/film.m3u8'};",@"/other.js":@"var file='https://example.com/video.mp4';"},NO);
    check(m.count==2,@"relative/absolute scripts and escaped media; duplicates removed");
    BOOL source=YES; for(DetectedMedia *x in m)source &= [x.sourcePageURL isEqual:@"https://example.com/page"];
    check(source&&m.count>0,@"original source page retained");
    m=run(@{@"/page":@"<script src='/js/player.js'></script>",@"/js/player.js":@"document.body.innerHTML='<video src=\\\"movie.mp4\\\"></video>';"},NO);
    DetectedMedia *scriptInserted = m.count ? (DetectedMedia *)m.firstObject : nil;
    check(m.count==1&&[scriptInserted.mediaURL isEqual:@"https://example.com/movie.mp4"],@"script-inserted relative media resolves against document URL, not script directory");
    m=run(@{@"/page":@"<script src='/runtime.js'></script>",@"/runtime.js":@"var src='https://cdn.example.com/' + 'computed.mp4';"},NO);
    check(m.count==1&&[[(DetectedMedia *)m.firstObject mediaURL] isEqual:@"https://cdn.example.com/computed.mp4"],@"literal URL concatenation is recognized without evaluating variables");
    m=run(@{@"/page":@"<script src='/config.js'></script>",@"/config.js":@"var player='{""file"":""/json/movie.m3u8"",""poster"":""/cover.jpg""}';"},NO);
    check(m.count==1&&[[(DetectedMedia *)m.firstObject mediaURL] isEqual:@"https://example.com/json/movie.m3u8"],@"JSON player config string exposes media URL while ignoring poster");
    m=run(@{@"/page":@"<video src='/keep.mp4'></video><script src='/missing.js'></script>"},NO);
    check(m.count==1,@"failed script retains HTML media");
    m=run(@{@"/page":@"<video src='/keep.mp4'></video><script src='/big.js'></script>",@"/big.js":[@"var file='oversized.mp4';" stringByPaddingToLength:300000 withString:@" " startingAtIndex:0]},NO);
    check(m.count==1,@"oversized script rejected without losing HTML media");
    NSMutableString *html=[NSMutableString string];NSMutableDictionary *fixture=[NSMutableDictionary dictionary];
    for(int i=0;i<20;i++){[html appendFormat:@"<script src='/p%d.js'></script>",i];fixture[[NSString stringWithFormat:@"/p%d.js",i]]=@"var file='same.mp4';";}fixture[@"/page"]=html;
    m=run(fixture,NO);check(requests.count<=7&&requests.count>1,@"at most six scripts requested");
    NSMutableDictionary *large=[NSMutableDictionary dictionary];NSMutableString *largeHTML=[NSMutableString string];
    for(int i=0;i<6;i++){NSString *path=[NSString stringWithFormat:@"/large%d.js",i];[largeHTML appendFormat:@"<script src='%@'></script>",path];large[path]=[[NSString stringWithFormat:@"var file='large%d.mp4';",i]stringByPaddingToLength:250000 withString:@" " startingAtIndex:0];}large[@"/page"]=largeHTML;
    m=run(large,NO);check(m.count==4,@"combined script body budget rejects fifth/sixth large script without dropping four earlier resources");
    m=run(@{@"/page":@"<video src='/keep.mp4'></video><script src='/slow.js'></script>",@"/slow.js":@"HANG"},NO);
    check(m.count==1,@"script timeout preserves HTML media");
    run(@{@"/page":@"<script src='/slow.js'></script><script src='/never.js'></script>",@"/slow.js":@"HANG"},YES);
    check(![requests containsObject:@"https://example.com/never.js"],@"cancellation prevents later scripts");
    bodies=@{@"/page":@"<script src='/slow.js'></script><script src='/never.js'></script>",@"/slow.js":@"HANG"};requests=[NSMutableArray array];
    NSURLSessionConfiguration *lateCfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;lateCfg.protocolClasses=@[ScriptProtocol.class];
    StaticHTMLDiscoveryPageProbe *lateProbe=[[StaticHTMLDiscoveryPageProbe alloc]initWithPolicy:[URLPolicy new] sessionConfiguration:lateCfg];[lateProbe setValue:[ScriptGate new] forKey:@"gate"];
    __block int lateCompletions=0;
    id lateToken=[lateProbe probePageURL:[NSURL URLWithString:@"https://example.com/page"] completion:^(NSArray *items,NSError *e){lateCompletions++;}];pump(.08);
    NSURLSessionDataTask *lateTask=[[lateToken valueForKey:@"scriptToken"]valueForKey:@"task"];
    [lateProbe cancelProbe:lateToken];pump(.02);
    [(id<NSURLSessionDataDelegate>)lateProbe URLSession:NSURLSession.sharedSession dataTask:lateTask didReceiveData:[@"var file='late.mp4';" dataUsingEncoding:NSUTF8StringEncoding]];
    [(id<NSURLSessionTaskDelegate>)lateProbe URLSession:NSURLSession.sharedSession task:lateTask didCompleteWithError:nil];pump(.05);
    check(lateTask&&lateCompletions==0&&requests.count==2,@"late script data/completion after cancel cannot publish or start another script");
    m=run(@{@"/page":@"<video src='/keep.mp4'></video><script src='http://127.0.0.1/blocked.js'></script>"},NO);
    check(requests.count==1&&m.count==1,@"dangerous script rejected before request");
    for(NSString *target in @[@"http://other.example.com/p.js",@"https://user:pass@example.com/p.js",@"https://127.0.0.1/p.js",@"https://cdn.example.com/p.js"]){
        bodies=@{@"/page":@"<script src='/slow.js'></script>",@"/slow.js":@"HANG"};requests=[NSMutableArray array];
        NSURLSessionConfiguration *redirectCfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;redirectCfg.protocolClasses=@[ScriptProtocol.class];
        StaticHTMLDiscoveryPageProbe *probe=[[StaticHTMLDiscoveryPageProbe alloc]initWithPolicy:[URLPolicy new] sessionConfiguration:redirectCfg];[probe setValue:[ScriptGate new] forKey:@"gate"];
        id token=[probe probePageURL:[NSURL URLWithString:@"https://example.com/page"] completion:^(NSArray *items,NSError *e){}];pump(.08);
        NSURLSessionTask *task=[[token valueForKey:@"scriptToken"]valueForKey:@"task"];
        __block BOOL decided=NO,allowed=NO;
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:[NSURL URLWithString:@"https://example.com/slow.js"] statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        [(id<NSURLSessionTaskDelegate>)probe URLSession:NSURLSession.sharedSession task:task willPerformHTTPRedirection:response newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:target]] completionHandler:^(NSURLRequest *next){decided=YES;allowed=next!=nil;}];pump(.05);
        check(task&&decided&&allowed==[target isEqual:@"https://cdn.example.com/p.js"],[@"production script redirect policy: " stringByAppendingString:target]);
        [probe cancelProbe:token];pump(.02);
    }
    run(@{@"/page":@""},NO);check(lastError.code==ZZResourceDiscoveryErrorUnrecognizedPage,@"empty unreadable content preserves unrecognized-page reason");
    run(@{@"/page":@"<html><body><form>Login</form></body></html>"},NO);check(!lastError,@"login form alone remains normal empty page");
    bodies=@{@"/page":@"<script src='/p.js'></script>",@"/p.js":@"var file='static-only.mp4';"};requests=[NSMutableArray array];
    NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;cfg.protocolClasses=@[ScriptProtocol.class];
    StaticHTMLDiscoveryPageProbe *statik=[[StaticHTMLDiscoveryPageProbe alloc]initWithPolicy:[URLPolicy new] sessionConfiguration:cfg];[statik setValue:[ScriptGate new] forKey:@"gate"];
    RDHybridPageProbe *hybrid=[[RDHybridPageProbe alloc]initWithPolicy:[URLPolicy new]];[hybrid setValue:statik forKey:@"statik"];
    hybrid.loaderFactory=^id<RDProbeLoader>{return [ScriptDynamicLoader new];};
    __block int finals=0,interims=0;__block NSArray *merged;
    [hybrid probePageURL:[NSURL URLWithString:@"https://93.184.216.34/page"] incrementalCompletion:^(NSArray *items,NSError *e,BOOL final){if(final){finals++;merged=items;}else interims++;}];
    pump(.8);check(finals==1&&interims==1&&merged.count==2,@"actual external-script static leg merges with delayed dynamic-only media; interim is not final");
    __block int oneShot=0;__block NSUInteger oneShotCount=0;
    [hybrid probePageURL:[NSURL URLWithString:@"https://93.184.216.34/page"] completion:^(NSArray *items,NSError *e){oneShot++;oneShotCount=items.count;}];
    pump(.8);check(oneShot==1&&oneShotCount==2,@"one-shot Hybrid waits for complete static+dynamic result");
    printf("FAILURES=%d\n",failures);return failures?1:0;
}}
