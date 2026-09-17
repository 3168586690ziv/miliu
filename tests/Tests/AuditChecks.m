#define main RDUnusedExistingTestsMain
#import "DownloadIntegrityTests.m"
#undef main
#define main RDUnusedAuditAppMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "WebProbe.h"
#import "RDManifestParser.h"
#import "StaticHTMLDiscoveryPageProbe.h"
#import "ResourceURLGate.h"

static int auditReproduced=0;
static void Evidence(NSString *name, BOOL reproduces, id observed) {
    printf("AUDIT %s | %s | %s\n", reproduces?"REPRODUCED":"NOT_REPRODUCED",name.UTF8String,[[observed description] UTF8String]);
    fflush(stdout); if(reproduces) auditReproduced++;
}
static TestContext *AuditContext(void) { return MakeContext(); }
static DownloadManager *Restore(TestContext *c) {
    return [[DownloadManager alloc] initWithBackend:c.backend tempRoot:c.tmpRoot store:[[DownloadStore alloc] initWithUserDefaults:c.ud]];
}
@interface AuditText : NSObject
@property NSString *string;
@property NSString *stringValue;
@end
@implementation AuditText
@end


static NSUInteger auditPageRequests=0;
@interface AuditPageProtocol : NSURLProtocol
@end
@implementation AuditPageProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    auditPageRequests++;
    NSString *text=[self.request.URL.path hasSuffix:@"app.js"] ? @"document.body.innerHTML='<video src=\"https://example.com/dynamic.mp4\"></video>';" : @"<html><body><script src='/app.js'></script></body></html>";
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"text/html",@"Content-Length":@(data.length).stringValue}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
@interface AuditImageTransport : NSObject<RDMetadataTransporting>
@property NSData *data;
@property NSUInteger requests;
@end
@implementation AuditImageTransport
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion {
    self.requests++; RDMetadataToken *t=[RDMetadataToken new]; RDMetadataResponse *r=[RDMetadataResponse new];
    r.data=[request.HTTPMethod isEqual:@"HEAD"] ? NSData.data : self.data;
    r.response=[[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"image/png",@"Content-Length":@(self.data.length).stringValue}];
    dispatch_async(dispatch_get_main_queue(),^{if(!t.cancelled)completion(r);});return t;
}
@end

int main(int argc,const char **argv) { @autoreleasepool {
    gContextSeq=900000+arc4random_uniform(100000);
    NSURL *base=[NSURL URLWithString:@"https://example.com/watch/index.html"];
    RDProbeResult *signedMedia=[RDProbeAnalyzer analyzeHTML:@"<video src='https://cdn.example.com/movie.m3u8?token=A&amp;expires=9'></video>" baseURL:base];
    DetectedMedia *sm=signedMedia.media.firstObject;
    Evidence(@"Signed HLS format becomes unknown/video",sm && sm.resourceKind!=RDResourceKindManifest,@{@"url":sm.mediaURL?:@"",@"format":sm.format?:@"",@"kind":@(sm.resourceKind)});
    Evidence(@"Video src retains literal amp entity",[sm.mediaURL containsString:@"&amp;"],sm.mediaURL);
    RDProbeResult *relative=[RDProbeAnalyzer analyzeHTML:@"<base href='https://cdn.example.com/assets/'><video src='a.mp4'></video>" baseURL:base];
    Evidence(@"HTML base href ignored",![relative.media.firstObject.mediaURL isEqual:@"https://cdn.example.com/assets/a.mp4"],relative.media.firstObject.mediaURL);
    NSString *p1=[DetectedMedia dedupKeyForURL:@"https://example.com:8443/a.mp4"], *p2=[DetectedMedia dedupKeyForURL:@"https://example.com:9443/a.mp4"];
    Evidence(@"Discovery dedup drops port",[p1 isEqual:p2],@[p1,p2]);
    NSString *q1=[DownloadManager sourceIdentityForURL:[NSURL URLWithString:@"https://example.com/api/video?token=VIDEO_A"]];
    NSString *q2=[DownloadManager sourceIdentityForURL:[NSURL URLWithString:@"https://example.com/api/video?token=VIDEO_B"]];
    Evidence(@"Download identity merges token-identified videos",[q1 isEqual:q2],@[q1,q2]);
    Evidence(@"Title numeric suffix suppresses media extension",[[DownloadJob fileNameByEnsuringMediaExtension:@"Episode.01" fallbackExtension:@"mp4"] isEqual:@"Episode.01"],[DownloadJob fileNameByEnsuringMediaExtension:@"Episode.01" fallbackExtension:@"mp4"]);
    NSString *longName=[DownloadJob fileNameByEnsuringMediaExtension:[@"a" stringByPaddingToLength:260 withString:@"a" startingAtIndex:0] fallbackExtension:@"mp4"];
    TestContext *longContext=AuditContext(); NSError *nameError=nil;
    BOOL wrote=[[@"fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[longContext.destFolder URLByAppendingPathComponent:longName] options:NSDataWritingAtomic error:&nameError];
    Evidence(@"Long title exceeds filesystem component limit",!wrote,@{@"length":@(longName.length),@"error":nameError.localizedDescription?:@""});
    NSData *png=[[NSData alloc] initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=" options:0];
    TestContext *img=AuditContext(); img.backend.script=^MockScript *(NSURLRequest *r,NSInteger n){return [MockScript response:200 headers:@{@"Content-Type":@"application/octet-stream",@"Content-Length":@(png.length).stringValue} body:png];};
    DownloadJob *ij=[img.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://example.com/a.png"] folder:img.destFolder preferredName:@"a.png" sourcePageURL:nil resourceKind:DownloadResourceImage expectedLength:png.length];
    Wait(^BOOL{return ij.state==DownloadJobStateFailed||ij.state==DownloadJobStateCompleted;},3);
    Evidence(@"Valid PNG with octet-stream MIME rejected",ij.state==DownloadJobStateFailed,ij.errorText?:@"completed");
    TestContext *hls=AuditContext(); NSData *list=[@"#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n" dataUsingEncoding:NSUTF8StringEncoding];
    hls.backend.script=^MockScript *(NSURLRequest *r,NSInteger n){return [MockScript response:200 headers:@{@"Content-Type":@"application/vnd.apple.mpegurl",@"Content-Length":@(list.length).stringValue} body:list];};
    DownloadJob *hj=[hls.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://example.com/a.m3u8"] folder:hls.destFolder preferredName:@"a.hls" sourcePageURL:nil resourceKind:DownloadResourceManifest expectedLength:0];
    Wait(^BOOL{return hj.state==DownloadJobStateFailed||hj.state==DownloadJobStateCompleted;},3);
    Evidence(@"Manifest completion saves only playlist",hj.state==DownloadJobStateCompleted&&hls.backend.requests.count==1,@{@"requests":@(hls.backend.requests.count),@"bytes":@(FileSize(hj.destinationURL)),@"file":hj.fileName,@"state":@(hj.state)});
    DownloadManager *restored=Restore(hls); DownloadJob *rj=restored.allJobs.firstObject;
    Evidence(@"Completed history restores as zero percent",rj.state==DownloadJobStateCompleted&&rj.progress==0,@{@"state":@(rj.state),@"progress":@(rj.progress),@"transferred":@(rj.transferredBytes)});
    TestContext *interrupted=AuditContext(); [interrupted.manager beginBatchEnqueue];
    DownloadJob *intj=[interrupted.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://example.com/interrupted.mp4"] folder:interrupted.destFolder preferredName:@"interrupted.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:5000];
    [interrupted.manager markInterruptedOnTerminate]; DownloadManager *rm=Restore(interrupted);
    ResourceDetectorAppDelegate *delegate=[ResourceDetectorAppDelegate new]; delegate.downloadManager=rm;
    AuditText *status=[AuditText new]; delegate.statusNote=(id)status;
    [delegate refreshDownloadsList]; [delegate toggleDownloadPauseResume:nil];
    Evidence(@"Interrupted task cannot resume through UI action",rm.allJobs.firstObject.state==DownloadJobStateInterrupted,@{@"status":status.stringValue?:@""});
    [rm cancelJob:intj.identifier];
    Evidence(@"Cancel interrupted task leaves state interrupted",rm.allJobs.firstObject.state==DownloadJobStateInterrupted,@(rm.allJobs.firstObject.state));
    TestContext *rejected=AuditContext();
    DownloadJob *bad=[rejected.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"http://127.0.0.1/x.mp4"] folder:rejected.destFolder preferredName:@"x.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:0];
    DownloadManager *rr=Restore(rejected);
    Evidence(@"Admission rejection disappears after restart",bad.state==DownloadJobStateFailed&&rr.allJobs.count==0,@{@"persisted":@(rejected.manager.store.finishedJobRecords.count),@"restored":@(rr.allJobs.count)});
    NSDictionary *mpd=[RDManifestParser parseManifest:@"<MPD mediaPresentationDuration='PT4S'><Period><AdaptationSet mimeType='video/mp4'><Representation id='1' width='640' height='360'><BaseURL>small.mp4</BaseURL></Representation><Representation id='2' width='1280' height='720'><BaseURL>large.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>" baseURL:base];
    Evidence(@"DASH Representation BaseURL not parsed",[mpd[@"variants"] count]==2&&!mpd[@"variants"][0][@"url"],mpd[@"variants"]);
    NSDictionary *hlsAttrs=[RDManifestParser parseManifest:@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS=\"avc1.42e01e,mp4a.40.2\",RESOLUTION=640x360\na.m3u8\n" baseURL:base];
    Evidence(@"HLS quoted comma truncates CODECS",![hlsAttrs[@"variants"][0][@"codecs"] isEqual:@"avc1.42e01e,mp4a.40.2"],hlsAttrs[@"variants"]);
    TestContext *dns=AuditContext(); DownloadManager *dm=Restore(dns); __block int calls=0;
    dm.rd_resolver=^NSArray *(NSString *host){calls++;return @[@"127.0.0.1"];}; [dm beginBatchEnqueue];
    DownloadJob *dj=[dm enqueueItemWithSourceURL:[NSURL URLWithString:@"https://internal.example.com/a.mp4"] folder:dns.destFolder preferredName:@"dns.mp4" sourcePageURL:nil resourceKind:DownloadResourceVideo expectedLength:0];
    Evidence(@"Production default skips download endpoint DNS verification",!dm.rd_enableEndpointResolution&&calls==0&&dj.state!=DownloadJobStateFailed,@{@"enabled":@(dm.rd_enableEndpointResolution),@"resolverCalls":@(calls),@"state":@(dj.state)});

    RDProbeResult *lazy=[RDProbeAnalyzer analyzeHTML:@"<img data-src='https://example.com/a.webp'><img srcset='https://example.com/b.png 2x'>" baseURL:base];
    NSUInteger fakeVideos=0;for(DetectedMedia *m in lazy.media)if(m.resourceKind==RDResourceKindVideo)fakeVideos++;
    Evidence(@"Lazy images and img srcset misclassified as videos",fakeVideos==2,@(fakeVideos));
    NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;cfg.protocolClasses=@[AuditPageProtocol.class];
    StaticHTMLDiscoveryPageProbe *pageProbe=[[StaticHTMLDiscoveryPageProbe alloc] initWithPolicy:[URLPolicy new] sessionConfiguration:cfg];
    ResourceURLGate *gate=[pageProbe valueForKey:@"gate"];gate.rd_checksEnabled=NO;
    __block BOOL pageDone=NO;__block NSArray *pageMedia=nil;
    [pageProbe probePageURL:base completion:^(NSArray *m,NSError *e){pageMedia=m;pageDone=YES;}];
    Wait(^BOOL{return pageDone;},3);
    Evidence(@"Default static probe never loads external player script",pageDone&&auditPageRequests==1&&pageMedia.count==0,@{@"requests":@(auditPageRequests),@"media":@(pageMedia.count)});
    AuditImageTransport *imt=[AuditImageTransport new];imt.data=png;
    RDMetadataService *ms=[[RDMetadataService alloc] initWithTransport:imt];
    DetectedMedia *cm=[DetectedMedia new];cm.mediaURL=@"https://example.com/cache.png";cm.resourceKind=RDResourceKindImage;
    __block RDMetadataSnapshot *cs=nil;
    RDMetadataToken *ct=[ms subscribeMedia:cm reload:NO update:^(RDMetadataSnapshot *snap){cs=snap;}];
    BOOL imageKnown=Wait(^BOOL{return cs && cs.preview.state==RDMetadataKnown&&cs.size.state==RDMetadataKnown&&cs.dimensions.state==RDMetadataKnown;},4);
    NSUInteger before=imt.requests;
    if(imageKnown){NSSize dims=[(NSValue *)cs.dimensions.value sizeValue];cm.pixelWidth=lround(dims.width);cm.pixelHeight=lround(dims.height);cm.sizeBytes=[cs.size.value longLongValue];}
    [ct cancel];cs=nil;
    RDMetadataToken *ct2=[ms subscribeMedia:cm reload:NO update:^(RDMetadataSnapshot *snap){cs=snap;}];
    Wait(^BOOL{return cs&&cs.preview.state!=RDMetadataLoading;},4);
    Evidence(@"App metadata writeback changes cache key and refetches",imageKnown&&imt.requests>before,@{@"firstRequests":@(before),@"afterSecondSelection":@(imt.requests)});[ct2 cancel];
    if(argc>1){
        TestContext *native=AuditContext();id<RDDownloadBackend> backend=[NSClassFromString(@"SessionDownloadBackend") new];
        DownloadManager *nm=[[DownloadManager alloc] initWithBackend:backend tempRoot:native.tmpRoot store:[[DownloadStore alloc]initWithUserDefaults:native.ud]];
        DownloadJob *nj=[nm enqueueItemWithSourceURL:[NSURL URLWithString:@"https://www.w3schools.com/html/mov_bbb.mp4"] folder:native.destFolder preferredName:@"public-test.mp4" sourcePageURL:@"https://www.w3schools.com/html/html5_video.asp" resourceKind:DownloadResourceVideo expectedLength:788493];
        Wait(^BOOL{return nj.state==DownloadJobStateCompleted||nj.state==DownloadJobStateFailed;},45);
        printf("NATIVE PUBLIC DOWNLOAD state=%ld bytes=%lld path=%s error=%s\n",(long)nj.state,FileSize(nj.destinationURL),nj.destinationURL.path.UTF8String,(nj.errorText?:@"").UTF8String);
    }
    printf("AUDIT SUMMARY %d reproduced cases\n",auditReproduced);
    return 0;
}}
