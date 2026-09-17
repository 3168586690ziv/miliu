#define main RDUnusedOriginalDownloadTestsMain
#import "DownloadIntegrityTests.m"
#undef main
#define main RDUnusedRepairedAppMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "RDStreamPlan.h"
#import "RDManifestParser.h"
#import "RDURLUtilities.h"

@interface RepairText : NSObject
@property NSString *string;
@property NSString *stringValue;
@end
@implementation RepairText
@end
@interface RepairPolicy : URLPolicy
@end
@implementation RepairPolicy
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray *)ips { return [URLPolicyDecision allow]; }
@end
@interface RepairStaticProbe : NSObject
@end
@implementation RepairStaticProbe
- (id)probePageURL:(NSURL *)url completion:(void (^)(NSArray *,NSError *))done {dispatch_async(dispatch_get_main_queue(),^{done(@[],nil);});return self;}
- (void)cancelProbe:(id)token {}
@end
@interface RepairDynamicLoader : NSObject<RDProbeLoader>
@end
@implementation RepairDynamicLoader
- (HTTPTask *)loadPageAtURL:(NSURL *)url policy:(URLPolicy *)policy completion:(void (^)(NSString *,AppError *))done {dispatch_async(dispatch_get_main_queue(),^{done(@"<video src='https://example.com/dynamic.mp4'></video>",nil);});return nil;}
@end
@interface RepairImageTransport : NSObject<RDMetadataTransporting>
@property NSData *data;
@property NSUInteger requests;
@end
@implementation RepairImageTransport
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))done {
    self.requests++;RDMetadataToken *token=[RDMetadataToken new];RDMetadataResponse *r=[RDMetadataResponse new];r.data=[request.HTTPMethod isEqual:@"HEAD"]?NSData.data:self.data;r.response=[[NSHTTPURLResponse alloc]initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"image/png",@"Content-Length":@(self.data.length).stringValue}];dispatch_async(dispatch_get_main_queue(),^{if(!token.cancelled)done(r);});return token;
}
@end
static DownloadManager *Reopen(TestContext *c){DownloadManager *m=[[DownloadManager alloc]initWithBackend:c.backend tempRoot:c.tmpRoot store:[[DownloadStore alloc]initWithUserDefaults:c.ud]];m.rd_enableEndpointResolution=NO;return m;}
int main(int argc,const char **argv){@autoreleasepool{
    gContextSeq=1000000+arc4random_uniform(100000);
    NSURL *base=[NSURL URLWithString:@"https://example.com/watch/index.html"];
    RDProbeResult *signedURL=[RDProbeAnalyzer analyzeHTML:@"<video src='https://cdn.example.com/movie.m3u8?token=A&amp;expires=9'></video>" baseURL:base];
    Check(signedURL.media.count==1 && signedURL.media.firstObject.resourceKind==RDResourceKindManifest && [signedURL.media.firstObject.format isEqual:@"hls"],@"RD-03 signed manifest classified as HLS");
    Check([signedURL.media.firstObject.mediaURL isEqual:@"https://cdn.example.com/movie.m3u8?token=A&expires=9"],@"RD-04 media HTML entities decode exactly once");
    Check([RDDecodeHTMLAttribute(@"a&#38;b&#x26;c&amp;amp;d") isEqual:@"a&b&c&amp;d"],@"RD-04 numeric and nested entity boundaries");
    RDProbeResult *lazy=[RDProbeAnalyzer analyzeHTML:@"<img data-src='https://example.com/a.webp'><img srcset='https://example.com/b.png 2x'>" baseURL:base];
    Check(lazy.media.count==2,@"RD-05 lazy images retained");for(DetectedMedia *m in lazy.media)Check(m.resourceKind==RDResourceKindImage,@"RD-05 images never enter video download pipeline");
    RDProbeResult *relative=[RDProbeAnalyzer analyzeHTML:@"<base href='https://cdn.example.com/assets/'><video src='a.mp4'></video>" baseURL:base];
    Check([relative.media.firstObject.mediaURL isEqual:@"https://cdn.example.com/assets/a.mp4"] && [relative.media.firstObject.sourcePageURL isEqual:base.absoluteString],@"RD-14 base href resolves media without changing source page");
    RDProbeResult *modernMarkup=[RDProbeAnalyzer analyzeHTML:@"<img srcset='poster-1x.mp4\t1x, poster-2x.mp4\n2x'><link href='/preloaded.m3u8' as='video' rel='preload'>" baseURL:base];
    NSMutableSet *modernURLs=[NSMutableSet set]; for (DetectedMedia *item in modernMarkup.media) [modernURLs addObject:item.mediaURL ?: @""];
    Check([modernURLs containsObject:@"https://example.com/watch/poster-1x.mp4"] && [modernURLs containsObject:@"https://example.com/watch/poster-2x.mp4"] && [modernURLs containsObject:@"https://example.com/preloaded.m3u8"], @"RD-24 srcset ASCII whitespace and href-before-rel preload are discovered");
    Check(![[DetectedMedia dedupKeyForURL:@"https://example.com:8443/a.mp4"] isEqual:[DetectedMedia dedupKeyForURL:@"https://example.com:9443/a.mp4"]],@"RD-13 non-default ports remain distinct");
    Check(![[DetectedMedia dedupKeyForURL:@"https://example.com/a%2Fb.mp4"] isEqual:[DetectedMedia dedupKeyForURL:@"https://example.com/a/b.mp4"]],@"RD-13 encoded path separators retain identity");
    Check(![[DownloadManager sourceIdentityForURL:[NSURL URLWithString:@"https://example.com/api/video?token=A"]] isEqual:[DownloadManager sourceIdentityForURL:[NSURL URLWithString:@"https://example.com/api/video?token=B"]]],@"RD-08 content tokens are not discarded");
    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"Episode.01" fallbackExtension:@"mp4"] isEqual:@"Episode.01.mp4"],@"RD-16 numeric suffix gets media extension");
    NSString *longName=[DownloadJob fileNameByEnsuringMediaExtension:[@"视" stringByPaddingToLength:300 withString:@"视" startingAtIndex:0] fallbackExtension:@"mp4"];TestContext *longC=MakeContext();NSError *writeError=nil;
    Check([longName hasSuffix:@".mp4"] && [longName lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=230 && [NSData.data writeToURL:[longC.destFolder URLByAppendingPathComponent:longName] options:NSDataWritingAtomic error:&writeError],@"RD-17 Unicode long filename fits filesystem and preserves extension");
    NSData *png=[[NSData alloc]initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=" options:0];
    TestContext *image=MakeContext();image.backend.script=^MockScript *(NSURLRequest *r,NSInteger n){return [MockScript response:200 headers:@{@"Content-Type":@"application/octet-stream",@"Content-Length":@(png.length).stringValue} body:png];};
    DownloadJob *ij=[image.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://example.com/a.png"] folder:image.destFolder preferredName:@"a.png" sourcePageURL:nil resourceKind:DownloadResourceImage expectedLength:png.length];
    Check(Wait(^BOOL{return ij.state==DownloadJobStateCompleted;},3) && FileSize(ij.destinationURL)==png.length,@"RD-15 octet-stream PNG is saved intact");
    DownloadManager *restored=Reopen(image);DownloadJob *rj=restored.allJobs.firstObject;
    Check(rj.state==DownloadJobStateCompleted && rj.progress==1 && rj.transferredBytes==png.length,@"RD-18 completed history restores 100 percent and byte count");
    TestContext *interrupted=MakeContext();[interrupted.manager beginBatchEnqueue];DownloadJob *intj=EnqueueVideo(interrupted,@"/paused.mp4",nil,1000);[interrupted.manager markInterruptedOnTerminate];DownloadManager *rm=Reopen(interrupted);
    // Keep resumed mock transfer pending until cancellation to examine UI/state transitions.
    interrupted.backend.script=^MockScript *(NSURLRequest *r,NSInteger n){return [MockScript response:200 headers:@{@"Content-Type":@"video/mp4"} body:MP4Body(1000)];};
    ResourceDetectorAppDelegate *app=[ResourceDetectorAppDelegate new];app.downloadManager=rm;RepairText *status=[RepairText new];app.statusNote=(id)status;
    [app refreshDownloadsList];Check(rm.allJobs.firstObject.state==DownloadJobStateInterrupted,@"RD-07 interrupted history is labeled accurately");[app toggleDownloadPauseResume:nil];Check(rm.allJobs.firstObject.state==DownloadJobStateRunning||rm.allJobs.firstObject.state==DownloadJobStateQueued,@"RD-07 app continue action reaches restored interrupted job");
    [rm markInterruptedOnTerminate];[rm cancelJob:intj.identifier];Check(rm.allJobs.firstObject.state==DownloadJobStateCancelled && rm.store.interruptedRecords.count==0,@"RD-19 cancelling interrupted job reaches terminal state and clears record");
    TestContext *rejected=MakeContext();DownloadJob *bad=[rejected.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"http://127.0.0.1/x.mp4"] folder:rejected.destFolder preferredName:@"x.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:0];DownloadManager *rr=Reopen(rejected);
    Check(bad.state==DownloadJobStateFailed && rr.allJobs.count==1 && rr.allJobs.firstObject.errorText.length,@"RD-20 pre-admission failures survive restart without destination");
    NSDictionary *mpd=[RDManifestParser parseManifest:@"<MPD mediaPresentationDuration='PT4S'><Period><AdaptationSet mimeType='video/mp4'><BaseURL>tracks/</BaseURL><Representation id='1' width='640' height='360'><BaseURL>small.mp4</BaseURL></Representation><Representation id='2' width='1280' height='720'><BaseURL>large.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>" baseURL:base];
    Check([mpd[@"variants"] count]==2 && [mpd[@"variants"][0][@"url"] isEqual:@"https://example.com/watch/tracks/small.mp4"],@"RD-21 DASH BaseURL inherits and resolves per representation");
    NSDictionary *hls=[RDManifestParser parseManifest:@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"avc1.42e01e,mp4a.40.2\",RESOLUTION=640x360\na.m3u8\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"English, stereo\",URI=\"audio.m3u8?q=1,2\"\n" baseURL:base];
    Check([hls[@"variants"][0][@"codecs"] isEqual:@"avc1.42e01e,mp4a.40.2"] && [hls[@"audioTracks"][0][@"name"] isEqual:@"English, stereo"],@"RD-22 HLS quoted commas preserved in all attribute lists");
    TestContext *dns=MakeContext();DownloadManager *secure=[[DownloadManager alloc]initWithBackend:dns.backend tempRoot:dns.tmpRoot store:dns.manager.store];__block NSUInteger calls=0;secure.rd_resolver=^NSArray *(NSString *h){calls++;return @[@"127.0.0.1"];};
    DownloadJob *denied=[secure enqueueItemWithSourceURL:[NSURL URLWithString:@"https://internal.example.com/a.mp4"] folder:dns.destFolder preferredName:@"a.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:0];
    Check(secure.rd_enableEndpointResolution && Wait(^BOOL{return denied.state==DownloadJobStateFailed;},3) && calls==1 && dns.backend.requests.count==0,@"RD-02 default asynchronous DNS gate blocks before backend request");
    RDHybridPageProbe *hybrid=[[RDHybridPageProbe alloc]initWithPolicy:[RepairPolicy new]];[hybrid setValue:[RepairStaticProbe new] forKey:@"statik"];__block NSUInteger loaders=0;hybrid.loaderFactory=^id<RDProbeLoader>{loaders++;return [RepairDynamicLoader new];};__block BOOL dynamicDone=NO;__block NSArray *dynamicMedia=nil;
    [hybrid probePageURL:base completion:^(NSArray *m,NSError *e){dynamicMedia=m;dynamicDone=YES;}];
    Check(Wait(^BOOL{return dynamicDone;},4) && loaders==1 && [[(DetectedMedia *)dynamicMedia.firstObject mediaURL] isEqual:@"https://example.com/dynamic.mp4"],@"RD-06 hybrid production adapter executes dynamic provider and returns its media");
    app.results=[NSMutableArray array];ZZResourceDiscoveryResult *failed=[ZZResourceDiscoveryResult new];failed.error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotFindHost userInfo:@{NSLocalizedDescriptionKey:@"找不到服务器"}];[app finishScanWithResult:failed];Check([status.stringValue containsString:@"探测失败"] && [status.stringValue containsString:@"找不到服务器"],@"RD-10 failed probe preserves error and never reports empty success");
    app.settingsPage=[[NSView alloc]initWithFrame:NSMakeRect(0,0,980,700)];[app buildSettingsPage];app.settingsPage.frame=NSMakeRect(0,0,760,438);for(NSView *v in app.settingsPage.subviews)Check(NSContainsRect(app.settingsPage.bounds,v.frame),@"RD-11 all settings controls fit smallest content bounds");
    RepairImageTransport *transport=[RepairImageTransport new];transport.data=png;RDMetadataService *ms=[[RDMetadataService alloc]initWithTransport:transport];DetectedMedia *m=[DetectedMedia new];m.mediaURL=@"https://example.com/cache.png";m.resourceKind=RDResourceKindImage;__block RDMetadataSnapshot *snap=nil;RDMetadataToken *t=[ms subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s){snap=s;}];
    Check(Wait(^BOOL{return snap&&snap.preview.state==RDMetadataKnown&&snap.size.state==RDMetadataKnown&&snap.dimensions.state==RDMetadataKnown;},4),@"RD-23 initial image metadata finishes");NSUInteger before=transport.requests;NSSize sz=[(NSValue *)snap.dimensions.value sizeValue];m.pixelWidth=sz.width;m.pixelHeight=sz.height;m.sizeBytes=[snap.size.value longLongValue];[t cancel];snap=nil;[ms subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s){snap=s;}];
    Check(Wait(^BOOL{return snap!=nil;},2) && transport.requests==before,@"RD-23 App writeback no longer invalidates cache");
    Check([RDRedactedURL([NSURL URLWithString:@"https://user:secret@example.com/private?token=SECRET#s"]) isEqual:@"https://example.com/[redacted]"],@"RD-09 URL log redaction excludes credentials, path, query and fragment");
    NSLog(@"REPAIR-CORE-PASSED checks=%d",gChecks);return 0;
}}
