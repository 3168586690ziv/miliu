#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import <CoreVideo/CoreVideo.h>
#import "RDThumbnailGenerator.h"
#import "RDMetadataService.h"
#import "RDManifestParser.h"

@interface RDVariantTestApp : ResourceDetectorAppDelegate
@property DetectedMedia *configured;
@end
@implementation RDVariantTestApp
- (void)configureDetailForMedia:(DetectedMedia *)m { self.configured=m; self.detailMedia=m; }
@end
@interface RDVariantPickerStub : NSObject
@property NSMenuItem *selectedItem;
@end
@implementation RDVariantPickerStub
@end

static void Check(BOOL ok, NSString *message) {
    if (!ok) { NSLog(@"FAIL: %@", message); exit(1); }
    NSLog(@"PASS: %@", message);
}
static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
static void FixtureWithOptions(NSURL *url, int frames, BOOL rotated) {
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeQuickTimeMovie error:&error];
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
        outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264, AVVideoWidthKey:@320, AVVideoHeightKey:@180}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:
        @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32ARGB), (id)kCVPixelBufferWidthKey:@320,
          (id)kCVPixelBufferHeightKey:@180}];
    if (rotated) input.transform = CGAffineTransformMake(0,1,-1,0,180,0);
    [writer addInput:input];
    Check([writer startWriting], @"AVAssetWriter starts local fixture");
    [writer startSessionAtSourceTime:kCMTimeZero];
    for (int frame = 0; frame < frames; frame++) {
        Check(Wait(^BOOL { return input.readyForMoreMediaData || writer.status == AVAssetWriterStatusFailed; }, 5)
              && writer.status != AVAssetWriterStatusFailed, @"fixture input ready");
        CVPixelBufferRef buffer = NULL;
        CVReturn result = CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer);
        if (result != kCVReturnSuccess) exit(1);
        CVPixelBufferLockBaseAddress(buffer, 0);
        memset(CVPixelBufferGetBaseAddress(buffer), 0x90, CVPixelBufferGetBytesPerRow(buffer) * 180);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        if (![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame, 30)]) exit(1);
        CVPixelBufferRelease(buffer);
    }
    [input markAsFinished];
    __block BOOL finished = NO;
    [writer finishWritingWithCompletionHandler:^{ finished = YES; }];
    Check(Wait(^BOOL { return finished; }, 10) && writer.status == AVAssetWriterStatusCompleted, @"local 320x180 two-second fixture written");
}

// Headless spies exercise production metadata methods without creating an application/window.
@interface RDTestRow : NSObject
@property NSUInteger updates;
@end
@implementation RDTestRow
- (BOOL)isKindOfClass:(Class)cls { return cls == ResourceResultRowView.class || [super isKindOfClass:cls]; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint { self.updates++; }
- (void)configureWithMedia:(DetectedMedia *)m durationHint:(NSString *)hint sizeHint:(NSString *)sizeHint { self.updates++; }
@end
@interface RDTestTable : NSObject
@property RDTestRow *row;
@property NSUInteger reloads;
@property NSInteger selectedRow;
@end
@implementation RDTestTable
- (id)viewAtColumn:(NSInteger)c row:(NSInteger)r makeIfNecessary:(BOOL)make { return self.row; }
- (void)reloadData { self.reloads++; self.selectedRow = -1; }
@end

@interface RDOfflineTransport : NSObject <RDMetadataTransporting>
@property NSData *video;
@property NSUInteger requests;
@property BOOL fail;
@end
@implementation RDOfflineTransport
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion {
    self.requests++;
    RDMetadataToken *token = [RDMetadataToken new];
    RDMetadataResponse *r = [RDMetadataResponse new];
    BOOL poster = [request.URL.path containsString:@"poster"];
    r.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:poster ? 404 : 200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length":@(self.video.length).stringValue,@"Content-Type":@"video/mp4"}];
    r.data = [request.HTTPMethod isEqual:@"HEAD"] ? NSData.data : self.video;
    if (poster || self.fail) r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataHTTPFailure userInfo:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) completion(r); });
    return token;
}
@end

#import "MetadataTests.m"
#import "RangeMetadataTests.m"

// Hanime 类站点隔离夹具：防盗链（Referer/410）、HTML 错误页、慢 poster。
@interface RDHanimeTransport : NSObject <RDMetadataTransporting>
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *routes; // path → status/headers/data
@property (nonatomic, assign) NSUInteger mediaRequests;
@property (nonatomic, assign) NSUInteger posterRequests;
@property (nonatomic, copy, nullable) NSString *lastMediaReferer;
@property (nonatomic, copy, nullable) NSString *lastMediaRange;
@end
@implementation RDHanimeTransport
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion {
    RDMetadataToken *token = [RDMetadataToken new];
    NSString *path = request.URL.path;
    if ([path containsString:@"poster"]) self.posterRequests++;
    else {
        self.mediaRequests++;
        self.lastMediaReferer = [request valueForHTTPHeaderField:@"Referer"];
        self.lastMediaRange = [request valueForHTTPHeaderField:@"Range"];
    }
    NSDictionary *route = self.routes[path];
    RDMetadataResponse *r = [RDMetadataResponse new];
    if (route) {
        if (route[@"error"]) {
            r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:[route[@"error"] integerValue] userInfo:nil];
        } else {
            NSInteger status = [route[@"status"] integerValue];
            r.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:route[@"headers"] ?: @{}];
            r.data = route[@"data"];
            if (status >= 400) r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataHTTPFailure userInfo:nil];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (!token.cancelled) completion(r); });
    return token;
}
@end

int main(int argc, const char **argv) { @autoreleasepool {
    Check(RDMetadataHedgeDelay() <= 0.8,
          [NSString stringWithFormat:@"性能回归：元数据对冲延迟不超过 0.8s（当前 %.3fs）", RDMetadataHedgeDelay()]);
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    FixtureWithOptions(url,60,NO);
    RDThumbnailGenerator *generator = [RDThumbnailGenerator new];
    __block NSUInteger count = 0;
    __block CGImageRef held = NULL;
    void (^success)(CGImageRef, AppError *) = ^(CGImageRef image, AppError *error) {
        Check(NSThread.isMainThread && image && !error, @"success delivered on main queue");
        held = image; count++;
    };
    void (^checkOwned)(NSUInteger) = ^(NSUInteger expected) {
        Check(Wait(^BOOL { return count == expected; }, 10), @"request completes");
        // Read and draw AFTER the AVFoundation callback returned, then release our +1.
        Check(CGImageGetWidth(held) == 320 && CGImageGetHeight(held) == 180, @"owned image survives callback return");
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, 320, 180, 8, 1280, space, kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, 320, 180), held);
        CGContextRelease(ctx); CGColorSpaceRelease(space); CGImageRelease(held); held = NULL;
    };
    [generator generateThumbnailForURL:url atTime:CMTimeMake(1, 1) completion:success];
    checkOwned(1); Check(YES, @"first request");
    [generator cancel]; [generator cancel];
    [generator generateThumbnailForURL:url atTime:CMTimeMake(1, 1) referer:@"https://example.invalid/page" completion:success];
    checkOwned(2); Check(YES, @"cancel then reuse, referer overload");
    __block NSUInteger stale = 0;
    for (int i = 0; i < 30; i++) {
        [generator generateThumbnailForURL:url atTime:CMTimeMake(1, 1) completion:^(CGImageRef image, AppError *error) {
            stale++; if (image) CGImageRelease(image);
        }];
        if (i % 2 == 0) [generator cancel];
    }
    [generator generateThumbnailForURL:url atTime:CMTimeMake(1, 1) completion:success];
    checkOwned(3);
    Wait(^BOOL { return NO; }, 0.5);
    Check(stale == 0, @"30 rapid replacements discard old callbacks without cancelling newest");
    __block BOOL failed = NO;
    [generator generateThumbnailForURL:[url URLByAppendingPathExtension:@"missing"] atTime:kCMTimeZero
        completion:^(CGImageRef image, AppError *error) { failed = image == NULL && error != nil; }];
    Check(Wait(^BOOL { return failed; }, 10), @"missing video failure");
    [generator generateThumbnailForURL:url atTime:kCMTimeZero completion:^(CGImageRef image, AppError *error) {
        Check(image && !error, @"retry after failure"); CGImageRelease(image);
        [generator cancel];
        [generator generateThumbnailForURL:url atTime:kCMTimeZero completion:success];
    }];
    checkOwned(4); Check(YES, @"completion reentrantly cancels and starts a successful request");
    failed = NO;
    [generator generateThumbnailForURL:(NSURL * _Nonnull)nil atTime:kCMTimeZero completion:^(CGImageRef image, AppError *error) {
        failed = !image && error != nil;
    }];
    Check(Wait(^BOOL { return failed; }, 2), @"invalid URL failure");
    [generator generateThumbnailForURL:url atTime:kCMTimeZero completion:^(CGImageRef image, AppError *error) {
        stale++; if (image) CGImageRelease(image);
    }];
    [generator cancel]; Wait(^BOOL { return NO; }, 0.5);
    Check(stale == 0, @"cancel without replacement suppresses completion");

    Check([RDFormatDurationSeconds(NAN) isEqual:@"—"] && [RDFormatDurationSeconds(INFINITY) isEqual:@"—"]
          && [RDFormatDurationSeconds(-INFINITY) isEqual:@"—"] && [RDFormatDurationSeconds(1e100) isEqual:@"—"]
          && [RDFormatDurationSeconds(65) isEqual:@"01:05"], @"finite duration formatting and overflow guard");
    RDOfflineTransport *transport = [RDOfflineTransport new]; transport.video = [NSData dataWithContentsOfURL:url];
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:transport];
    DetectedMedia *media = [DetectedMedia new]; media.mediaURL = @"https://media.invalid/clip.mov"; media.resourceKind = RDResourceKindVideo; media.poster = @"https://media.invalid/poster.jpg";
    __block RDMetadataSnapshot *snapshot = nil;
    [service subscribeMedia:media reload:NO update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },10), @"production service completes bounded local decoding");
    Check(snapshot.duration.state == RDMetadataKnown && fabs([snapshot.duration.value doubleValue]-2) < .1, @"service actual duration");
    Check(snapshot.dimensions.state == RDMetadataKnown && [(NSValue *)snapshot.dimensions.value sizeValue].width == 320, @"service actual dimensions");
    Check(snapshot.preview.state == RDMetadataKnown && [snapshot.preview.source containsString:@"frame"], @"poster failure falls back to local video frame");
    NSUInteger requests = transport.requests; snapshot = nil;
    [service subscribeMedia:media reload:NO update:^(RDMetadataSnapshot *s) { snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },2) && requests == transport.requests, @"bounded successful cache avoids network");
    __block NSUInteger deliveries = 0; snapshot = nil;
    RDMetadataToken *cancelled = [service subscribeMedia:media reload:YES update:^(RDMetadataSnapshot *s) { deliveries++; }];
    [cancelled cancel]; Wait(^BOOL { return NO; },.1);
    Check(deliveries == 0, @"cancel before start suppresses all callbacks");
    transport.fail = YES;
    [service subscribeMedia:media reload:YES update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },3) && snapshot.duration.state == RDMetadataFailed, @"failure has explicit state");
    transport.fail = NO; snapshot = nil;
    [service subscribeMedia:media reload:NO update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },10) && snapshot.duration.state == RDMetadataKnown, @"failed request is retryable without cache eviction");

    // ── Hanime 类站点隔离测试：防盗链 Referer、410/HTML 错误页、慢 poster 不阻塞回退 ──
    NSData *fixtureBytes = [NSData dataWithContentsOfURL:url];
    RDHanimeTransport *hanime = [RDHanimeTransport new];
    RDMetadataService *hanimeService = [[RDMetadataService alloc] initWithTransport:hanime];
    DetectedMedia *hanimeMedia = [DetectedMedia new];
    hanimeMedia.mediaURL = @"https://cdn.invalid/jmpres/12258-480p.mp4?secure=abc";
    hanimeMedia.poster = @"https://img.invalid/poster.jpg";
    hanimeMedia.sourcePageURL = @"https://www.hanime2.org/watch?v=12258";
    hanimeMedia.resourceKind = RDResourceKindVideo;
    hanime.routes = @{@"/jmpres/12258-480p.mp4": @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4", @"Content-Length": @(fixtureBytes.length).stringValue}, @"data": fixtureBytes},
                      @"/poster.jpg": @{@"error": @(RDMetadataTimedOut)}};
    snapshot = nil;
    [hanimeService subscribeMedia:hanimeMedia reload:NO update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },10), @"hanime-shaped media completes with terminal states");
    Check([hanime.lastMediaReferer isEqual:hanimeMedia.sourcePageURL], @"media requests carry the page Referer for hotlink protection");
    Check(snapshot.preview.state == RDMetadataKnown && [snapshot.preview.source containsString:@"frame"], @"poster failure still falls back to video frame");
    NSUInteger posterAttempts = hanime.posterRequests;
    NSUInteger mediaAttempts = hanime.mediaRequests;
    snapshot = nil;
    [hanimeService subscribeMedia:hanimeMedia reload:YES update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },10), @"reload re-probes hanime media");
    Check(hanime.posterRequests == posterAttempts + 1, @"poster timeout/failure retries at most once per work (fast fallback)");

    // 410 Gone（站点下发过期 secure token 时实测的响应）
    NSData *gonePage = [@"<html><center>410 Gone</center></html>" dataUsingEncoding:NSUTF8StringEncoding];
    hanime.routes = @{@"/jmpres/12258-480p.mp4": @{@"status": @410, @"headers": @{@"Content-Type": @"text/html"}, @"data": gonePage},
                      @"/poster.jpg": @{@"status": @404, @"headers": @{@"Content-Type": @"text/html"}}};
    snapshot = nil;
    [hanimeService subscribeMedia:hanimeMedia reload:YES update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },15), @"410 page reaches explicit terminal states");
    Check(snapshot.preview.state == RDMetadataFailed && snapshot.duration.state == RDMetadataFailed && snapshot.size.state == RDMetadataFailed,
          [NSString stringWithFormat:@"expired-token 410 is a visible failure, never a decodable frame (preview=%ld duration=%ld size=%ld dimensions=%ld sources: %@ | %@ | %@)",
           (long)snapshot.preview.state, (long)snapshot.duration.state, (long)snapshot.size.state, (long)snapshot.dimensions.state,
           snapshot.preview.source, snapshot.duration.source, snapshot.size.source]);

    // 200 但内容是 HTML（错误页伪装成 video/mp4）
    NSData *htmlPage = [@"<html><body>challenge page</body></html>" dataUsingEncoding:NSUTF8StringEncoding];
    hanime.routes = @{@"/jmpres/12258-480p.mp4": @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4", @"Content-Length": @(htmlPage.length).stringValue}, @"data": htmlPage},
                      @"/poster.jpg": @{@"status": @200, @"headers": @{@"Content-Type": @"image/jpeg", @"Content-Length": @(fixtureBytes.length).stringValue}, @"data": fixtureBytes}};
    snapshot = nil;
    [hanimeService subscribeMedia:hanimeMedia reload:YES update:^(RDMetadataSnapshot *s) { if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) snapshot = s; }];
    Check(Wait(^BOOL { return snapshot != nil; },10), @"HTML body pretending to be video completes");
    Check(snapshot.preview.state == RDMetadataUnsupported && snapshot.duration.state == RDMetadataUnsupported, @"HTML masquerading as mp4 is rejected, poster does not override failure path order");

    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.metadataService = service; app.durationCache = [NSMutableDictionary dictionary]; app.results = [NSMutableArray arrayWithObject:media]; app.detailMedia = media;
    RDTestTable *table = [RDTestTable new]; table.row = [RDTestRow alloc]; table.selectedRow = 0; app.table = (NSTableView *)table;
    [app subscribeMetadataForMedia:media reload:NO];
    Check(Wait(^BOOL { return media.pixelHeight == 180; },3), @"App subscribes to production service");
    Check(table.reloads == 0 && table.selectedRow == 0 && table.row.updates > 0, @"metadata updates existing row without selection loss/reload");
    NSDictionary *hls = [RDManifestParser parseManifest:@"#EXTM3U\n#EXTINF:0.25,\na.ts\n#EXTINF:1.5,\nb.ts\n#EXT-X-ENDLIST" baseURL:[NSURL URLWithString:media.mediaURL]];
    Check(fabs([hls[@"durationSeconds"] doubleValue]-1.75)<.001 && ![hls[@"isLive"] boolValue], @"HLS VOD sums real EXTINF");
    NSDictionary *master = [RDManifestParser parseManifest:@"#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=640x360\nchild.m3u8" baseURL:[NSURL URLWithString:media.mediaURL]];
    Check([master[@"isMaster"] boolValue] && ![master[@"isLive"] boolValue] && !master[@"durationSeconds"], @"master not misclassified live");
    NSDictionary *dash = [RDManifestParser parseManifest:@"<MPD mediaPresentationDuration='PT1M2.5S'><Period><AdaptationSet width='320' height='180'><Representation id='a'/></AdaptationSet></Period></MPD>" baseURL:[NSURL URLWithString:media.mediaURL]];
    Check(fabs([dash[@"durationSeconds"] doubleValue]-62.5)<.001 && [[dash[@"variants"] firstObject][@"width"] integerValue] == 320, @"DASH XML duration and inherited dimensions");
    RDMetadataTransport *safe = [[RDMetadataTransport alloc] initWithResolver:^NSArray *(NSString *host) { return @[@"8.8.8.8",@"127.0.0.1"]; } protocolClasses:nil];
    for (NSString *blocked in @[@"file:///tmp/movie.mov",@"https://localhost/movie",@"https://mixed.invalid/movie"]) {
        __block BOOL rejected = NO;
        [safe request:[NSURLRequest requestWithURL:[NSURL URLWithString:blocked]] budget:1024 timeout:1 completion:^(RDMetadataResponse *r) { rejected = r.error.code == RDMetadataBlocked; }];
        Check(Wait(^BOOL { return rejected; },2), @"transport rejects file/localhost/mixed DNS without HTTP");
    }
    RDVariantTestApp *variantApp=[RDVariantTestApp new];
    DetectedMedia *low=[DetectedMedia new], *high=[DetectedMedia new];
    low.mediaURL=@"https://offline.invalid/480.mp4"; high.mediaURL=@"https://offline.invalid/720.mp4";
    variantApp.results=[NSMutableArray arrayWithObjects:low,high,nil]; variantApp.detailMedia=low;
    RDVariantPickerStub *picker=[RDVariantPickerStub new]; picker.selectedItem=[NSMenuItem new];
    picker.selectedItem.representedObject=@{@"url":high.mediaURL,@"label":@"720p"}; variantApp.variantPicker=(id)picker;
    NSArray *declared=@[@{@"url":low.mediaURL,@"label":@"480p"},@{@"url":high.mediaURL,@"label":@"720p"}];
    low.declaredVariants=declared; high.declaredVariants=declared;
    Check(variantApp.visibleMedia.count==1,@"same video variants collapse into one visible row");
    [variantApp selectDeclaredVariant:nil];
    Check(variantApp.configured==high && variantApp.detailMedia==high,@"variant action binds detail to target URL without changing list names");
    // 同档多候选（复查2 回归）：生产解析器 → 分组写回 → 列表折叠为一行，
    // 代表行=归一化择优 URL（详情与下载对象一致），且不误合并不同视频。
    RDProbeResult *sameTier = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video><source src='https://offline.invalid/sd-a.mp4' size='720'>"
        @"<source src='https://offline.invalid/sd-b.mp4' size='720'>"
        @"<source src='https://offline.invalid/sd-c.mp4' size='720'>"
        @"<source src='https://offline.invalid/sd-d.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://offline.invalid/watch"]];
    Check(sameTier.media.count==4 && sameTier.media.firstObject.declaredVariants.count==1
          && [sameTier.media.firstObject.declaredVariants.firstObject[@"label"] isEqual:@"720p"],
          @"analyzer keeps same-tier grouping on all 4 media (720p)");
    NSString *bestURL = sameTier.media.firstObject.declaredVariants.firstObject[@"url"];
    Check([bestURL isEqual:@"https://offline.invalid/sd-a.mp4"], @"normalized best URL is sd-a.mp4 (stable order)");
    // 2/3/4 个同组候选 × 择优最先/中间/最后出现：每组恰好一行，代表=择优 URL
    NSArray<NSArray<NSString *> *> *orders = @[
        @[@"sd-a.mp4", @"sd-b.mp4", @"sd-c.mp4", @"sd-d.mp4"],   // 择优最先
        @[@"sd-b.mp4", @"sd-c.mp4", @"sd-d.mp4", @"sd-a.mp4"],   // 择优最后
        @[@"sd-c.mp4", @"sd-a.mp4", @"sd-b.mp4", @"sd-d.mp4"],   // 择优中间（4 候选）
        @[@"sd-c.mp4", @"sd-b.mp4", @"sd-a.mp4"],                // 择优最后（3 候选）
        @[@"sd-b.mp4", @"sd-a.mp4"],                             // 择优最后（2 候选）
    ];
    for (NSArray<NSString *> *order in orders) {
        NSMutableArray *rowsSource = [NSMutableArray array];
        for (NSString *name in order)
            for (DetectedMedia *m in sameTier.media)
                if ([m.mediaURL hasSuffix:name]) [rowsSource addObject:m];
        RDVariantTestApp *orderApp=[RDVariantTestApp new];
        orderApp.results=rowsSource;
        NSArray<DetectedMedia *> *visible = orderApp.visibleMedia;
        NSString *rowURLs = [[visible valueForKey:@"mediaURL"] componentsJoinedByString:@","];
        CheckF(visible.count==1 && [visible.firstObject.mediaURL hasSuffix:@"sd-a.mp4"],
              @"order %@ → 1 row, representative=sd-a.mp4 (got %lu rows: %@" ")",
              order, (unsigned long)visible.count, rowURLs);
    }
    // 择优项不在结果里：首个占位行作为确定性回退（b 是结果顺序中第一个）
    {
        NSMutableArray *noBest = [NSMutableArray array];
        for (NSString *name in @[@"sd-d.mp4", @"sd-c.mp4", @"sd-b.mp4"])
            for (DetectedMedia *m in sameTier.media)
                if ([m.mediaURL hasSuffix:name]) [noBest addObject:m];
        RDVariantTestApp *fallbackApp=[RDVariantTestApp new];
        fallbackApp.results=noBest;
        NSArray<DetectedMedia *> *visible = fallbackApp.visibleMedia;
        NSString *rowURLs = [[visible valueForKey:@"mediaURL"] componentsJoinedByString:@","];
        CheckF(visible.count==1 && [visible.firstObject.mediaURL hasSuffix:@"sd-d.mp4"],
              @"best missing → deterministic fallback to first placeholder (got %lu rows: %@" ")",
              (unsigned long)visible.count, rowURLs);
        Check([visible.firstObject.declaredVariants.firstObject[@"url"] isEqual:bestURL],
              @"fallback row still carries the group's declared best URL (detail/download target)");
    }
    RDProbeResult *distinctVideos = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video><source src='https://offline.invalid/x-720.mp4' size='720'></video>"
        @"<video><source src='https://offline.invalid/y-1080.mp4' size='1080'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://offline.invalid/watch"]];
    RDVariantTestApp *distinctApp=[RDVariantTestApp new];
    distinctApp.results=[NSMutableArray arrayWithArray:distinctVideos.media];
    Check(distinctApp.visibleMedia.count==2,@"two distinct videos are NOT merged");
    MetadataTests(url);
    NSURL *shortURL = [url URLByAppendingPathExtension:@"short.mov"];
    FixtureWithOptions(shortURL,3,YES);
    RDMapTransport *shortTransport = [RDMapTransport new]; shortTransport.map[@"/short.mov"] = [NSData dataWithContentsOfURL:shortURL];
    RDMetadataService *shortService = [[RDMetadataService alloc] initWithTransport:shortTransport];
    DetectedMedia *shortMedia = [DetectedMedia new]; shortMedia.mediaURL = @"https://offline.invalid/short.mov"; shortMedia.resourceKind = RDResourceKindVideo;
    RDMetadataSnapshot *shortResult = ReadMetadata(shortService,shortMedia,NO);
    NSSize shortSize = [(NSValue *)shortResult.dimensions.value sizeValue];
    Check(shortResult.preview.state == RDMetadataKnown && [shortResult.duration.value doubleValue] < .2 && shortSize.width == 180 && shortSize.height == 320,@"short rotated video real duration dimensions and first-frame fallback");
    RangeMetadataTests([url URLByDeletingLastPathComponent]);
    [ImageFixture(6,80,40) writeToURL:[[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"oriented.jpg"] atomically:YES];
    NSLog(@"PASS: ALL FOCUSED TESTS");
    return 0;
} }
