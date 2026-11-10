#import <Cocoa/Cocoa.h>
#import "ResourceTitleTranslator.h"
static NSUInteger checks,failed,requests;
static BOOL holdRequests;
static NSMutableArray *held;
static NSMutableArray<NSURLRequest *> *captured;
static void Check(BOOL ok,NSString *name){checks++;if(!ok)failed++;printf("%s: %s\n",ok?"PASS":"FAIL",name.UTF8String);}
static void Pump(double seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];}
@interface TitleProtocol:NSURLProtocol @end
@implementation TitleProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r{return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r{return r;}
- (void)startLoading { dispatch_async(dispatch_get_main_queue(), ^{ requests++;[captured addObject:self.request]; if(holdRequests){[held addObject:self];return;} [self reply]; }); }
- (void)reply {
 NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"responseData":@{@"translatedText":@"夹具译文"},@"responseStatus":@200} options:0 error:nil];
 [self.client URLProtocol:self didReceiveResponse:[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}] cacheStoragePolicy:NSURLCacheStorageNotAllowed];
 [self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
// Runtime dispatch permits behavioral red against the old API, not a compile-error red.
@interface ResourceTitleTranslator(Permission)
- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)c allowsNetworkTranslation:(BOOL)allowed;
@end
static NSURLSessionConfiguration *Configuration(void){
 NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.protocolClasses=@[TitleProtocol.class];return c;
}
static ResourceTitleTranslator *Translator(BOOL allowed){
 NSURLSessionConfiguration *c=Configuration();
 if([ResourceTitleTranslator instancesRespondToSelector:@selector(initWithSessionConfiguration:allowsNetworkTranslation:)])return [[ResourceTitleTranslator alloc]initWithSessionConfiguration:c allowsNetworkTranslation:allowed];
 return [[ResourceTitleTranslator alloc]initWithSessionConfiguration:c];
}
// Controlled session boundary: completions can arrive synchronously at task
// creation or long after invalidation. This exercises production request guards,
// independent of NSURLSession rejecting late NSURLProtocol events internally.
@interface FixtureTask:NSObject
@property(nonatomic,copy) void (^deliver)(void);
@property(nonatomic) BOOL completeOnResume;
@end
@implementation FixtureTask
- (void)resume { if(self.completeOnResume)self.deliver(); }
@end
@interface FixtureSession:NSObject
@property(nonatomic,strong) NSMutableArray<FixtureTask *> *tasks;
@property(nonatomic) BOOL completeOnCreate;
@property(nonatomic) BOOL completeOnResume;
@property(nonatomic) BOOL replyOnInvalidate;
@property(nonatomic) NSUInteger invalidations;
@property(nonatomic,copy) void (^onCreate)(void);
@property(nonatomic,copy) NSString *responseText;
@end
@implementation FixtureSession
- (instancetype)init {if((self=[super init]))_tasks=[NSMutableArray array];return self;}
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))completion {
 requests++;[captured addObject:request];FixtureTask *task=[FixtureTask new];
 task.completeOnResume=self.completeOnResume;
 NSString *responseText=self.responseText?:@"同步夹具译文";
 task.deliver=^{
  NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"responseData":@{@"translatedText":responseText},@"responseStatus":@200} options:0 error:nil];
  completion(data,[[NSHTTPURLResponse alloc]initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil],nil);
 };
 [self.tasks addObject:task];void (^onCreate)(void)=self.onCreate;self.onCreate=nil;if(onCreate)onCreate();if(self.completeOnCreate)task.deliver();return task;
}
- (void)invalidateAndCancel {self.invalidations++;if(self.replyOnInvalidate)for(FixtureTask *task in [self.tasks copy])task.deliver();}
@end
static void TestControlledCompletions(void){
 ResourceTitleTranslator *t=Translator(YES);FixtureSession *session=[FixtureSession new];
 session.completeOnCreate=YES;[t setValue:session forKey:@"session"];
 __block NSUInteger count=0;[t translateTitle:@"Creation Sync Fixture" completion:^(NSString *s){count++;Check(NSThread.isMainThread&&s.length>0,@"sync creation completion on main");}];
 Check(count==0,@"synchronous task creation cannot inline user completion");Pump(.1);Check(count==1,@"synchronous task creation completes once");
 session.completeOnCreate=NO;session.completeOnResume=YES;count=0;
 [t translateTitle:@"Resume Sync Fixture" completion:^(NSString *s){count++;}];Pump(.1);Check(count==1,@"synchronous resume completes once");
 session.completeOnResume=NO;NSUInteger duplicateBefore=requests;__block NSUInteger first=0,second=0;
 [t translateTitle:@"  Normalized   Fixture  " completion:^(NSString *s){first++;Check(s.length>0,@"first successful duplicate receives result");}];
 [t translateTitle:@"Normalized Fixture" completion:^(NSString *s){second++;Check(s.length>0,@"second successful duplicate receives result");}];
 Check(requests==duplicateBefore+1,@"whitespace-normalized duplicate uses one task");session.tasks.lastObject.deliver();Pump(.1);
 Check(first==1&&second==1,@"successful subscribers each complete once");
 session.replyOnInvalidate=YES;session.responseText=@"";NSUInteger before=requests;count=0;
 [t translateTitle:@"Late Segment / Another Fragment" completion:^(NSString *s){count++;Check(NSThread.isMainThread&&s.length==0,@"cancel completion main and empty");}];
 FixtureTask *late=session.tasks.lastObject;[t cancelAll];late.deliver();Pump(.1);
 Check(count==1&&requests==before+1,@"forced synchronous invalidate and late completion cannot restart segments or complete twice");
 Check(session.invalidations==1,@"cancel invalidates only old session");
 FixtureSession *fresh=[FixtureSession new];fresh.completeOnResume=YES;[t setValue:fresh forKey:@"session"];count=0;
 // Deliver while replacement is registered and creating its task. This avoids
 // HTML normalization's nested main run loop draining stale events too early.
 fresh.onCreate=^{late.deliver();};
 [t translateTitle:@"Late Segment / Another Fragment" completion:^(NSString *s){count++;}];Pump(.1);
 Check(count==1&&requests==before+2,@"old same-key identity cannot finish new operation or start fallback");[t cancelAll];
}
int main(){@autoreleasepool{
 held=[NSMutableArray array];captured=[NSMutableArray array];
 ResourceTitleTranslator *local=Translator(NO);__block NSUInteger count=0;__block NSString *result=nil;
 [local translateTitle:@"Xylophone Quasar" completion:^(NSString *t){count++;result=t;Check(NSThread.isMainThread,@"local completion main");}];Pump(.3);
 Check(requests==0,@"default permission emits zero requests");Check(count==1&&result.length==0,@"local miss completes empty once (coordinator preserves source)");
 count=0;[local translateTitle:@"girl story" completion:^(NSString *t){count++;result=t;}];Pump(.3);
 Check(requests==0,@"local dictionary never requests network");Check(count==1&&[result isEqual:@"女孩故事"],@"existing local dictionary used");
 count=0;[local translateTitle:@"中文标题" completion:^(NSString *t){count++;result=t;}];Pump(.2);
 Check(requests==0&&count==1&&result.length==0,@"Chinese short circuit zero network");[local cancelAll];
 ResourceTitleTranslator *network=Translator(YES);NSUInteger before=requests;count=0;
 [network translateTitle:@"Xylophone Quasar" completion:^(NSString *t){count++;result=t;Check(NSThread.isMainThread,@"network completion main");}];Pump(.4);
 Check(requests==before+1&&count==1&&[result isEqual:@"夹具译文"],@"explicit permission allows one fake network request");
 NSURLComponents *parts=[NSURLComponents componentsWithURL:captured.lastObject.URL resolvingAgainstBaseURL:NO];NSMutableDictionary *q=[NSMutableDictionary dictionary];for(NSURLQueryItem *i in parts.queryItems)q[i.name]=i.value;
 Check([parts.host isEqual:@"api.mymemory.translated.net"]&&[q[@"q"] isEqual:@"Xylophone Quasar"]&&[q[@"langpair"] isEqual:@"en|zh-CN"],@"explicit request fields accurate");
 holdRequests=YES;before=requests;__block NSUInteger a=0,b=0;
 [network translateTitle:@"Duplicate Fixture" completion:^(NSString *t){a++;Check(t.length==0,@"cancel first callback empty");}];
 [network translateTitle:@"Duplicate Fixture" completion:^(NSString *t){b++;Check(t.length==0,@"cancel duplicate callback empty");}];Pump(.2);
 Check(requests==before+1,@"simultaneous normalized duplicate merged");
 [network cancelAll];Pump(.2);Check(a==1&&b==1,@"cancel drains every subscriber exactly once");
 // Force a late response on the canceled protocol object. NSURLSession may reject it;
 // regardless, it must not restart translation or complete any subscriber twice.
 NSArray *old=[held copy];[held removeAllObjects];for(TitleProtocol *p in old){@try{[p reply];}@catch(NSException *e){}}
 Pump(.2);Check(a==1&&b==1&&requests==before+1,@"late canceled response cannot callback or start fallback");
 holdRequests=NO;before=requests;count=0;@try{[network translateTitle:@"Reusable Fixture" completion:^(NSString *t){count++;result=t;}];}@catch(NSException *e){Check(NO,@"reuse must not throw on invalidated session");}Pump(.4);
 Check(requests==before+1&&count==1&&result.length>0,@"same translator reusable after cancel");
 // Cancel callback reenters translation: the old cancel must not invalidate new session.
 holdRequests=YES;__block NSUInteger canceled=0,reentered=0;@try{[network translateTitle:@"Reentrant Fixture" completion:^(NSString *t){canceled++;holdRequests=NO;@try{[network translateTitle:@"New Generation" completion:^(NSString *s){reentered++;}];}@catch(NSException *e){Check(NO,@"cancel callback reentry must not throw");}}];}@catch(NSException *e){Check(NO,@"reentry setup must not throw");}Pump(.2);[network cancelAll];Pump(.4);
 Check(canceled==1&&reentered==1,@"cancel callback reentry preserves new generation");
 [network cancelAll];
 // Compatibility initializer is local too, not just the new explicit-NO API.
 ResourceTitleTranslator *legacy=[[ResourceTitleTranslator alloc]initWithSessionConfiguration:Configuration()];before=requests;count=0;
 [legacy translateTitle:@"Unknown Catalogue" completion:^(NSString *s){count++;Check(NSThread.isMainThread&&s.length==0,@"legacy initializer local miss main empty");}];Pump(.1);
 Check(requests==before&&count==1,@"compatibility initializer defaults local");
 ResourceTitleTranslator *plain=[ResourceTitleTranslator new];count=0;
 [plain translateTitle:@"girl story" completion:^(NSString *s){count++;Check([s isEqual:@"女孩故事"],@"plain init uses local map");}];Pump(.1);
 Check(count==1,@"plain init completes once");[plain cancelAll];
 count=0;[legacy translateTitle:@"girl story" completion:^(NSString *s){count++;Check(s.length==0,@"canceled pending local callback empty");}];[legacy cancelAll];Pump(.1);
 Check(count==1,@"pending local cancellation completes exactly once");
 count=0;dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{[legacy translateTitle:@"girl story" completion:^(NSString *s){count++;Check(NSThread.isMainThread&&[s isEqual:@"女孩故事"],@"background caller routed to main local completion");}];});Pump(.2);
 Check(count==1,@"background caller completes once");[legacy cancelAll];
 TestControlledCompletions();
 // All test transports are protocol fixtures, including unexpected destinations.
 printf("TITLE-PRIVACY checks=%lu failed=%lu FAKE_TRANSPORT_ONLY=YES\n",(unsigned long)checks,(unsigned long)failed);return failed?1:0;
}}
