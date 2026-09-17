// Included by the headless ASan harness; never invokes production main/preferences.
#import <ImageIO/ImageIO.h>
#import "WebProbe.h"
// BUG-005/007/008/009 回归测试（定义在文件末尾）
static void WebProbeLazyAttributeBoundaryTests(void);
static void StaticPageDecodingTests(void);
static void ManifestEncodingTests(void);
static void ParallelCancelKeepsCompletedPagesTests(void);
// DASH SegmentTemplate 兼容回归（定义在文件末尾）
static void DASHSegmentTemplateTests(void);
// 质量档位归一化/去重（问题1/2，定义在文件末尾）
static void QualityTierTests(void);
// 元数据服务并发上限与分阶段超时预算（问题3，定义在文件末尾）
static void MetadataConcurrencyTests(void);
static void MetadataTimeoutBudgetTests(NSURL *videoURL);
static void PosterURLSharingTests(void);
// 选中项调度优先级：排队/网络/解析分段计时（问题3，定义在文件末尾）
static void MetadataPriorityTests(void);
// App 详情订阅回调的静态+清单合并集成测试（定义在文件末尾）
static void SnapshotMergeIntegrationTests(void);
@interface RDHTTPFixture : NSURLProtocol
@end
static NSUInteger HTTPStarts, HTTPStops, HTTPChunks;
@implementation RDHTTPFixture
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    HTTPStarts++;
    NSString *path = self.request.URL.path;
    if ([path isEqual:@"/hang"]) return;
    BOOL head = [self.request.HTTPMethod isEqual:@"HEAD"];
    NSInteger status = 200;
    NSDictionary *headers = @{@"Content-Length":@"4"};
    if ([path isEqual:@"/head405"]) { status = head ? 405 : 206; headers = head ? @{} : @{@"Content-Range":@"bytes 0-0/9876",@"Content-Length":@"1"}; }
    if ([path isEqual:@"/badRange"]) { status = head ? 405 : 206; headers = head ? @{} : @{@"Content-Range":@"bytes 2-9/3",@"Content-Length":@"1"}; }
    if ([path isEqual:@"/ignored"]) { status = head ? 405 : 200; headers = head ? @{} : @{@"Content-Length":@"999999"}; }
    NSMutableDictionary *typed = [headers mutableCopy]; typed[@"Content-Type"] = @"image/jpeg"; headers = typed;
    if ([path hasPrefix:@"/falseSize"]) {
        status = [path hasSuffix:@"403"] ? 403 : ([path hasSuffix:@"302"] ? 302 : 200);
        headers = @{@"Content-Length":@"143", @"Content-Type":[path hasSuffix:@"manifest"] ? @"application/vnd.apple.mpegurl" : @"text/html"};
    }
    if ([path isEqual:@"/stream"]) headers = @{};
    if ([path isEqual:@"/binaryMovie"]) {
        BOOL probe = [self.request valueForHTTPHeaderField:@"Range"].length > 0;
        status = probe ? 206 : 200;
        BOOL wide = [[self.request valueForHTTPHeaderField:@"Range"] isEqual:@"bytes=0-31"];
        headers = @{@"Content-Type":@"application/octet-stream",@"Content-Length":probe?(wide?@"32":@"1"):@"130023424",@"Content-Range":wide?@"bytes 0-31/130023424":@"bytes 0-0/130023424"};
    }
    if ([path isEqual:@"/headMismatch"]) {
        status = head ? 200 : 206;
        headers = head ? @{@"Content-Type":@"video/mp4",@"Content-Length":@"143"} : @{@"Content-Type":@"video/mp4",@"Content-Length":@"1",@"Content-Range":@"bytes 0-0/98765432"};
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (!head && [path isEqual:@"/binaryMovie"] && [[self.request valueForHTTPHeaderField:@"Range"] isEqual:@"bytes=0-31"]) {
        NSMutableData *prefix=[NSMutableData dataWithLength:32]; memcpy((uint8_t *)prefix.mutableBytes+4,"ftyp",4);
        [self.client URLProtocol:self didLoadData:prefix]; [self.client URLProtocolDidFinishLoading:self]; return;
    }
    if (!head) {
        NSUInteger chunks = [path isEqual:@"/stream"] ? 16 : 1;
        for (NSUInteger i=0;i<chunks;i++) { HTTPChunks++; [self.client URLProtocol:self didLoadData:[NSMutableData dataWithLength:status == 206 ? 1 : 4]]; }
    }
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { HTTPStops++; }
@end

@interface RDMapTransport : NSObject <RDMetadataTransporting>
@property NSMutableDictionary *map;
@property NSUInteger requests;
@property NSUInteger cancellations;
@property NSTimeInterval delay;
@property NSUInteger transientFailures;
@property NSUInteger transientAttempts;
@property NSMutableArray<NSNumber *> *timeouts; // 每次请求的 timeout 预算（分阶段预算测试用）
@property NSMutableArray<NSString *> *order;   // 请求到达顺序（路径，优先级测试用）
@property NSMutableArray<NSString *> *ranges;  // 每次请求的 Range 头（前缀窗口回归用）
@end
@implementation RDMapTransport
- (instancetype)init { if ((self = [super init])) _map = [NSMutableDictionary dictionary]; _timeouts = [NSMutableArray array]; _order = [NSMutableArray array]; _ranges = [NSMutableArray array]; return self; }
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion {
    self.requests++; [self.timeouts addObject:@(timeout)]; [self.order addObject:request.URL.path];
    [self.ranges addObject:[request valueForHTTPHeaderField:@"Range"] ?: @""]; RDMetadataToken *t = [RDMetadataToken new];
    __weak typeof(self) weak = self; [t addCancellation:^{ weak.cancellations++; }];
    id fixture = self.map[request.URL.path];
    RDMetadataResponse *r = [RDMetadataResponse new];
    NSData *data = [fixture isKindOfClass:NSString.class] ? [fixture dataUsingEncoding:NSUTF8StringEncoding] : fixture;
    if ([fixture isKindOfClass:NSError.class]) { r.error = fixture; data = nil; }
    r.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:data ? 200 : 404 HTTPVersion:@"HTTP/1.1" headerFields:data ? @{@"Content-Length":@(data.length).stringValue,@"Content-Type":([request.URL.path hasSuffix:@"jpg"] ? @"image/jpeg" : @"video/mp4")} : @{}];
    r.data = [request.HTTPMethod isEqual:@"HEAD"] ? NSData.data : data;
    if (!data && !r.error) r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataHTTPFailure userInfo:nil];
    if (r.data.length > budget) r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBudgetExceeded userInfo:nil];
    if ([request.HTTPMethod isEqual:@"GET"] && [request.URL.path isEqual:@"/retry.jpg"] && self.transientAttempts++ < self.transientFailures) r.error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    double delay = [request.URL.path isEqual:@"/slow.mov"] ? .8 : self.delay;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if (!t.cancelled) completion(r); });
    return t;
}
@end
static NSData *ImageFixture(NSInteger orientation, NSUInteger width, NSUInteger height) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL,width,height,8,width*4,space,kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = NSMutableData.data;
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,NULL);
    CGImageDestinationAddImage(destination,image,(__bridge CFDictionaryRef)@{(id)kCGImagePropertyOrientation:@(orientation)});
    Check(CGImageDestinationFinalize(destination),@"offline oriented JPEG generated");
    CFRelease(destination); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(space); return data;
}
static RDMetadataSnapshot *ReadMetadata(RDMetadataService *service, DetectedMedia *media, BOOL reload) {
    __block RDMetadataSnapshot *result;
    [service subscribeMedia:media reload:reload update:^(RDMetadataSnapshot *s) {
        if (s.duration.state != RDMetadataLoading && s.preview.state != RDMetadataLoading && s.size.state != RDMetadataLoading && s.dimensions.state != RDMetadataLoading) result = s;
    }];
    Check(Wait(^BOOL { return result != nil; },10),@"offline metadata terminal callback"); return result;
}
static void MetadataTests(NSURL *videoURL) {
    RDMetadataTransport *transport = [[RDMetadataTransport alloc] initWithResolver:^NSArray *(NSString *host) { return @[@"8.8.8.8"]; } protocolClasses:@[RDHTTPFixture.class]];
    for (NSString *path in @[@"/head",@"/head405",@"/ignored",@"/badRange"]) {
        RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:transport];
        DetectedMedia *m = [DetectedMedia new]; m.mediaURL = [@"https://offline.invalid" stringByAppendingString:path]; m.resourceKind = RDResourceKindImage;
        RDMetadataSnapshot *s = ReadMetadata(service,m,NO);
        if ([path isEqual:@"/head"]) Check(s.size.state == RDMetadataKnown && [s.size.value integerValue] == 4,@"HEAD 200 content length");
        if ([path isEqual:@"/head405"]) Check(s.size.state == RDMetadataKnown && [s.size.value integerValue] == 9876,@"HEAD 405 Range 206 total not partial length");
        if ([path isEqual:@"/ignored"]) Check(s.size.state == RDMetadataKnown && [s.size.value integerValue] == 999999,@"ignored Range uses full response length with bounded cancellation");
        if ([path isEqual:@"/badRange"]) Check(s.size.state != RDMetadataKnown,@"invalid Content-Range never fabricates total");
    }
    for (NSString *path in @[@"/falseSize200",@"/falseSize403",@"/falseSize302",@"/falseSizemanifest"]) {
        RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:transport];
        DetectedMedia *m = [DetectedMedia new]; m.mediaURL = [@"https://offline.invalid" stringByAppendingString:path]; m.resourceKind = RDResourceKindVideo; m.sizeBytes = 143;
        RDMetadataSnapshot *s = ReadMetadata(service,m,NO);
        Check(s.size.state != RDMetadataKnown && !s.size.value,@"143-byte HTML/error/redirect/manifest and stale probe size never become video size");
    }
    {
        RDMetadataService *service=[[RDMetadataService alloc] initWithTransport:transport];
        DetectedMedia *m=[DetectedMedia new]; m.mediaURL=@"https://offline.invalid/binaryMovie"; m.resourceKind=RDResourceKindVideo;
        RDMetadataSnapshot *s=ReadMetadata(service,m,NO);
        Check(s.size.state==RDMetadataKnown && [s.size.value longLongValue]==130023424,@"binary MIME MP4 uses verified prefix and Range total");
    }
    {
        RDMetadataService *service=[[RDMetadataService alloc] initWithTransport:transport];
        DetectedMedia *m=[DetectedMedia new]; m.mediaURL=@"https://offline.invalid/headMismatch"; m.resourceKind=RDResourceKindVideo;
        RDMetadataSnapshot *s=ReadMetadata(service,m,NO);
        // 视频路径已不再串行发 HEAD（大小来自单次前缀探测的 Content-Range），
        // 不存在“HEAD 与媒体响应长度冲突”的来源；仍锁定：媒体 Range 总长
        // 胜出，绝不采用任何冲突的 143 声明。
        Check(s.size.state==RDMetadataKnown && [s.size.value longLongValue]==98765432 && [s.size.source containsString:@"Content-Range"],@"media Range total wins over any conflicting declared length");
    }
    __block RDMetadataResponse *response;
    [transport request:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://offline.invalid/stream"]] budget:5 timeout:1 completion:^(RDMetadataResponse *r) { response = r; }];
    Check(Wait(^BOOL { return response != nil; },2) && response.error.code == RDMetadataBudgetExceeded && response.data == nil,@"stream exceeds budget, cancels and drops body");
    response = nil;
    [transport request:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://offline.invalid/hang"]] budget:5 timeout:.05 completion:^(RDMetadataResponse *r) { response = r; }];
    Check(Wait(^BOOL { return response != nil; },2) && response.error.code == RDMetadataTimedOut,@"wall clock timeout cancels hung transport");
    NSUInteger stops = HTTPStops; __block NSUInteger callbacks = 0;
    RDMetadataToken *cancel = [transport request:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://offline.invalid/hang"]] budget:5 timeout:1 completion:^(RDMetadataResponse *r) { callbacks++; }];
    Wait(^BOOL { return NO; },.05); [cancel cancel]; Wait(^BOOL { return NO; },.1);
    Check(callbacks == 0 && HTTPStops > stops,@"explicit transport cancel stops protocol and suppresses callback");

    RDMapTransport *map = [RDMapTransport new]; RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:map];
    map.map[@"/image.jpg"] = ImageFixture(6,80,40);
    DetectedMedia *m = [DetectedMedia new]; m.resourceKind = RDResourceKindImage; m.mediaURL = @"https://offline.invalid/image.jpg";
    RDMetadataSnapshot *s = ReadMetadata(service,m,NO);
    NSSize size = [(NSValue *)s.dimensions.value sizeValue];
    Check(s.duration.state == RDMetadataUnsupported && [s.duration.source isEqual:@"not-applicable"],@"image duration not applicable");
    Check(size.width == 40 && size.height == 80 && s.preview.state == RDMetadataKnown,@"ImageIO orientation swaps measured dimensions and preview");
    Check(map.requests == 2,@"image size HEAD plus single shared image GET");
    map.map[@"/large.jpg"] = ImageFixture(1,2400,1200); m.mediaURL = @"https://offline.invalid/large.jpg";
    s = ReadMetadata(service,m,NO); NSImage *preview = s.preview.value;
    NSLog(@"large state=%ld pixels=%ld dimensions=%@",(long)s.preview.state,(long)preview.representations.firstObject.pixelsWide,s.dimensions.value);
    Check(s.preview.state == RDMetadataKnown && preview.representations.firstObject.pixelsWide <= 1024 && [(NSValue *)s.dimensions.value sizeValue].width == 2400,@"large image downsampled but true dimensions retained");
    NSMutableData *bomb = [map.map[@"/image.jpg"] mutableCopy];
    uint8_t *jpeg = bomb.mutableBytes;
    for (NSUInteger i=0;i+9<bomb.length;i++) if (jpeg[i]==0xff && (jpeg[i+1]==0xc0 || jpeg[i+1]==0xc2)) { jpeg[i+5]=0xff; jpeg[i+6]=0xff; jpeg[i+7]=0xff; jpeg[i+8]=0xff; break; }
    map.map[@"/bomb.jpg"] = bomb; m.mediaURL = @"https://offline.invalid/bomb.jpg";
    s = ReadMetadata(service,m,NO); Check(s.dimensions.state == RDMetadataUnsupported && s.preview.state == RDMetadataUnsupported,@"declared huge image rejected by pixel budget before decode");
    map.map[@"/over.jpg"] = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBudgetExceeded userInfo:nil]; m.mediaURL = @"https://offline.invalid/over.jpg";
    s = ReadMetadata(service,m,NO); Check(s.preview.state == RDMetadataUnsupported,@"body over budget is explicitly unsupported");
    map.map[@"/bad.jpg"] = [NSData dataWithBytes:"bad" length:3]; m.mediaURL = @"https://offline.invalid/bad.jpg";
    s = ReadMetadata(service,m,NO); Check(s.preview.state == RDMetadataFailed,@"corrupt image explicit failed state");
    map.map[@"/timeout.jpg"] = [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataTimedOut userInfo:nil]; m.mediaURL = @"https://offline.invalid/timeout.jpg";
    s = ReadMetadata(service,m,NO); Check(s.preview.state == RDMetadataTimeout,@"service timeout state preserved");
    map.map[@"/timeout.jpg"] = map.map[@"/image.jpg"]; s = ReadMetadata(service,m,NO); Check(s.preview.state == RDMetadataKnown,@"timeout can retry without reload");

    map.map[@"/master.m3u8"] = @"#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=320x180\nvod.m3u8";
    map.map[@"/vod.m3u8"] = @"#EXTM3U\n#EXTINF:0.5,\na.ts\n#EXTINF:1.25,\nb.ts\n#EXT-X-ENDLIST";
    m.mediaURL = @"https://offline.invalid/master.m3u8"; m.resourceKind = RDResourceKindManifest;
    s = ReadMetadata(service,m,NO); Check(s.duration.state == RDMetadataKnown && [s.duration.value doubleValue] == 1.75 && s.size.state == RDMetadataUnknown && s.preview.state == RDMetadataUnknown,@"master recursion VOD duration, unknown media size and unsafe frame");
    map.map[@"/multi.m3u8"] = @"#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=640x360\nvod.m3u8\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\nvod.m3u8";
    m.mediaURL=@"https://offline.invalid/multi.m3u8";
    s=ReadMetadata(service,m,NO);
    Check(s.variants.count==2,@"master alternatives reach published metadata snapshot");
    map.map[@"/disguised.mp4"]=map.map[@"/vod.m3u8"];
    m.mediaURL=@"https://offline.invalid/disguised.mp4"; m.resourceKind=RDResourceKindVideo;
    NSUInteger oldCount=map.requests;
    s=ReadMetadata(service,m,NO);
    Check(s.duration.state==RDMetadataKnown && fabs([s.duration.value doubleValue]-1.75)<.001,@"disguised MP4 playlist parses fetched body without unsupported error");
    // 视频路径：前缀探测（GET bytes=0-1023）已带回完整小响应体（143B 清单），
    // 直接本地解析——整个 work 仅 1 个请求，且没有 HEAD、没有重复本体 GET
    // （旧实现为前缀探测 + 本体 GET 共 2 个请求）。
    Check(map.requests-oldCount==1,@"disguised playlist parses probe body with a single request (no duplicate complete GET)");
    m.resourceKind=RDResourceKindManifest;
    map.map[@"/loop.m3u8"] = @"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nloop.m3u8"; m.mediaURL = @"https://offline.invalid/loop.m3u8";
    s = ReadMetadata(service,m,NO); Check(s.duration.state == RDMetadataUnsupported,@"manifest recursion cycle rejected");
    map.map[@"/live.m3u8"] = @"#EXTM3U\n#EXTINF:3,\na.ts"; m.mediaURL = @"https://offline.invalid/live.m3u8";
    s = ReadMetadata(service,m,NO); Check(s.duration.state == RDMetadataUnknown && !s.duration.value,@"live duration never reported as total");
    NSDictionary *invalid = [RDManifestParser parseManifest:@"#EXTM3U\n#EXTINF:nan,\na.ts\n#EXT-X-ENDLIST" baseURL:nil];
    Check(!invalid[@"durationSeconds"],@"invalid EXTINF does not silently become zero");

    m.resourceKind = RDResourceKindVideo; m.mediaURL = @"https://offline.invalid/a.mov"; map.map[@"/a.mov"] = [NSData dataWithContentsOfURL:videoURL]; map.delay = .05;
    m.poster = @"https://offline.invalid/image.jpg";
    s = ReadMetadata(service,m,YES); Check(s.preview.state == RDMetadataKnown && [s.preview.source hasPrefix:@"poster"],@"successful poster takes precedence over video frame");
    m.poster = nil;
    __block NSUInteger first = 0, second = 0;
    NSUInteger before = map.requests;
    RDMetadataToken *one = [service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *v) { if (v.preview.state != RDMetadataLoading) first++; }];
    [service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *v) { if (v.preview.state != RDMetadataLoading) second++; }];
    [one cancel];
    // 视频 work 的请求数：前缀探测窗口放大到 1MB 后，共享 mock（RDMapTransport
    // 不做 Range 切片，把整份夹具当完整响应体返回）的探测体落在预算内，生产代码
    // 因此走“响应体已完整 → 本地解码”分支，只需 **1** 个请求（旧窗口 1024B 会
    // 触发 BudgetExceeded，退化成 2 个）。真实网址是 206 分片，走的是有界 moov
    // 读取分支；那里的请求数由请求窗口回归单独锁定（前缀窗口断言见本文件后段）。
    Check(Wait(^BOOL { return second == 1; },10) && first == 0 && map.requests-before == 1,
          @"inflight merge and independent subscriber cancellation（探测体落在预算内时只需 1 个请求）");
    __block NSUInteger stale = 0, current = 0;
    RDMetadataToken *a = [service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *v) { stale++; }]; [a cancel];
    m.mediaURL = @"https://offline.invalid/b.mov"; map.map[@"/b.mov"] = map.map[@"/a.mov"];
    RDMetadataToken *b = [service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *v) { stale++; }]; [b cancel];
    m.mediaURL = @"https://offline.invalid/a.mov";
    [service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *v) { if (v.preview.state != RDMetadataLoading) current++; }];
    Check(Wait(^BOOL { return current == 1; },10) && stale == 0,@"A-B-A cancellation generations do not cross deliver");
    // Exercise the exact production redirect delegate without a real socket (NSURLProtocol
    // on macOS does not support synthetic redirect callbacks reliably).
    for (NSString *target in @[@"https://10.0.0.1/movie",@"file:///tmp/movie",@"https://localhost/movie",@"https://mixed.invalid/movie"]) {
        id<NSURLSessionTaskDelegate> hop = [NSClassFromString(@"RDMetadataTransfer") new];
        NSObject *object = (NSObject *)hop;
        [object setValue:[RDMetadataToken new] forKey:@"token"];
        [object setValue:[RDMetadataResponse new] forKey:@"result"];
        [object setValue:[^NSArray *(NSString *host) { return @[@"8.8.8.8",@"192.168.0.1"]; } copy] forKey:@"resolver"];
        __block BOOL denied = NO;
        NSHTTPURLResponse *redirect = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://public.invalid/movie"] statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        [hop URLSession:nil task:nil willPerformHTTPRedirection:redirect newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:target]] completionHandler:^(NSURLRequest *next) { denied = next == nil; }];
        Check(Wait(^BOOL { return denied; },2),@"production redirect delegate rejects private/file/localhost/mixed DNS");
    }
    map.delay = 0; m.resourceKind = RDResourceKindImage;
    for (NSUInteger i=0;i<65;i++) {
        NSString *path = [NSString stringWithFormat:@"/cache-%lu.jpg",i]; map.map[path] = map.map[@"/image.jpg"]; m.mediaURL = [@"https://offline.invalid" stringByAppendingString:path]; ReadMetadata(service,m,NO);
    }
    NSUInteger cacheRequests = map.requests; m.mediaURL = @"https://offline.invalid/cache-0.jpg";
    ReadMetadata(service,m,NO);
    Check(map.requests == cacheRequests+2,@"success cache evicts oldest beyond 64 entries");
    map.map[@"/retry.jpg"]=map.map[@"/image.jpg"]; m.mediaURL=@"https://offline.invalid/retry.jpg";
    map.transientFailures=2; map.transientAttempts=0;
    s=ReadMetadata(service,m,YES);
    Check(s.preview.state==RDMetadataKnown && map.transientAttempts==3,@"automatic two retries succeed in one subscription");
    map.transientAttempts=0; map.transientFailures=10;
    RDMetadataToken *backoff=[service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *v) {}];
    Check(Wait(^BOOL { return map.transientAttempts==1; },1),@"retry enters backoff");
    [backoff cancel]; NSUInteger cancelledRequests=map.requests; Wait(^BOOL { return NO; },.7);
    Check(map.requests==cancelledRequests,@"cancel during backoff sends no retry");
    map.map[@"/slow.mov"]=map.map[@"/a.mov"]; m.mediaURL=@"https://offline.invalid/slow.mov"; m.resourceKind=RDResourceKindVideo; m.poster=@"https://offline.invalid/image.jpg";
    __block BOOL early=NO; __block BOOL terminal=NO; NSDate *start=NSDate.date;
    [service subscribeMedia:m reload:YES update:^(RDMetadataSnapshot *v) {
        if (v.preview.state==RDMetadataKnown && v.duration.state==RDMetadataLoading) early=YES;
        if (v.preview.state==RDMetadataKnown && v.duration.state==RDMetadataKnown) terminal=YES;
    }];
    Check(Wait(^BOOL { return early; },.5),@"poster publishes before delayed video and size");
    NSLog(@"PERF early poster %.4fs",-[start timeIntervalSinceNow]);
    Check(Wait(^BOOL { return terminal; },3),@"parallel video eventually publishes duration");
    RDScriptBridgeHandler *bridge=[RDScriptBridgeHandler new];
    NSDictionary *event=@{@"action":@"resource",@"url":@"https://offline.invalid/observed.mp4",@"kind":@"video",@"durationSeconds":@1.5,@"pixelWidth":@180,@"pixelHeight":@320,@"poster":@"https://offline.invalid/image.jpg"};
    Check([bridge validateBridgePayload:event reason:nil],@"bridge accepts finite whitelisted metadata");
    NSMutableDictionary *bad=[event mutableCopy]; bad[@"durationSeconds"]=@(NAN);
    Check(![bridge validateBridgePayload:bad reason:nil],@"bridge rejects NaN");
    bad[@"durationSeconds"]=@{}; Check(![bridge validateBridgePayload:bad reason:nil],@"bridge rejects metadata object");
    NSMutableDictionary *later=[event mutableCopy]; later[@"durationSeconds"]=@2.5;
    NSString *html=[[RDBridgeEventSynthesizer syntheticHTMLForEvent:event] stringByAppendingString:[RDBridgeEventSynthesizer syntheticHTMLForEvent:later]];
    RDProbeResult *parsed=[RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://offline.invalid"]];
    Check(parsed.media.count==1 && parsed.media.firstObject.durationSeconds.doubleValue==2.5 && parsed.media.firstObject.pixelHeight==320,@"same URL later bridge metadata survives analyzer dedup");
    DetectedMedia *observed=parsed.media.firstObject; observed.mediaURL=@"https://offline.invalid/missing.mp4"; observed.sizeBytes=1234;
    RDMetadataSnapshot *observedResult=ReadMetadata(service,observed,YES);
    Check(observedResult.duration.state==RDMetadataKnown && [observedResult.duration.value doubleValue]==2.5 && observedResult.dimensions.state==RDMetadataKnown && observedResult.size.state!=RDMetadataKnown,@"known duration and dimensions survive failure but unverified size is rejected");
    RDProbeResult *versions = [RDProbeAnalyzer analyzeHTML:@"<title>Same</title><video poster='a.jpg'><source src='a-480.mp4?token=x' size='480'><source src='a-720.mp4?token=y' size='720'></video><video><source src='b.mp4' size='1080'></video>" baseURL:[NSURL URLWithString:@"https://offline.invalid/page"]];
    NSUInteger grouped=0;
    for (DetectedMedia *item in versions.media) {
        if ([[NSURL URLWithString:item.mediaURL].lastPathComponent hasPrefix:@"a-"]) { Check(item.declaredVariants.count==2,@"same video declarations form two alternatives"); grouped++; }
        if ([[NSURL URLWithString:item.mediaURL].lastPathComponent isEqual:@"b.mp4"]) Check(!item.declaredVariants.count,@"same title different video is not grouped");
    }
    Check(grouped==2,@"signed media URLs retain declared variants");
    for (DetectedMedia *item in versions.media) Check([item.sourcePageURL isEqual:@"https://offline.invalid/page"],@"analyzer preserves page referer for every media resource");
    RDProbeResult *unlabelled=[RDProbeAnalyzer analyzeHTML:@"<video><source src='a.mp4'><source src='b.mp4'></video>" baseURL:[NSURL URLWithString:@"https://offline.invalid/"]];
    for (DetectedMedia *item in unlabelled.media) Check(!item.declaredVariants.count,@"unlabelled sources do not fabricate quality labels");
    WebProbeLazyAttributeBoundaryTests();
    StaticPageDecodingTests();
    ManifestEncodingTests();
    ParallelCancelKeepsCompletedPagesTests();
    DASHSegmentTemplateTests();
    QualityTierTests();
    MetadataConcurrencyTests();
    MetadataTimeoutBudgetTests(videoURL);
    PosterURLSharingTests();
    MetadataPriorityTests();
    SnapshotMergeIntegrationTests();
    NSLog(@"HTTP fixture starts=%lu stops=%lu chunks=%lu",HTTPStarts,HTTPStops,HTTPChunks);
}

// MARK: - BUG-005/007/008/009 回归（懒加载属性边界 / 页面编码 / 清单编码 / 并行取消）

#import <stdarg.h>
#import "MultiPageResourceProbe.h"
#import "ResourceDiscoveryCoordinator.h"
#import "StaticHTMLDiscoveryPageProbe.h"
#import "ResourceURLGate.h"

// 变参版 Check：行为与 ThumbnailTests 的 Check 完全一致（失败打印并退出）
static void CheckF(BOOL ok, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    Check(ok, message);
}

// BUG-005：属性名左边界必须区分 src 与 data-src。
// \bsrc 在 ICU 中会命中 data-src（“-”非单词字符），把懒加载图片误分类为视频。
static void WebProbeLazyAttributeBoundaryTests(void) {
    NSURL *base = [NSURL URLWithString:@"https://page.example.com/watch"];
    RDProbeResult *plain = [RDProbeAnalyzer analyzeHTML:
        @"<video src='https://cdn.example.com/v.mp4'></video>" baseURL:base];
    CheckF(plain.media.count == 1 && plain.media.firstObject.resourceKind == RDResourceKindVideo,
          @"src= 视频仍识别为视频（BUG-005 无回归）");
    CheckF([plain.media.firstObject.discoverySource isEqual:@"static-video"],
          @"src= 视频来自主视频分支而非懒加载分支");

    RDProbeResult *lazyImg = [RDProbeAnalyzer analyzeHTML:
        @"<source data-src='https://cdn.example.com/image.jpg'>" baseURL:base];
    BOOL jpgAsVideo = NO;
    for (DetectedMedia *m in lazyImg.media) {
        if ([m.mediaURL containsString:@"image.jpg"] &&
            (m.resourceKind == RDResourceKindVideo || m.resourceKind == RDResourceKindManifest)) jpgAsVideo = YES;
    }
    CheckF(!jpgAsVideo, @"<source data-src=image.jpg> 绝不被视频分支误识别（BUG-005）");

    RDProbeResult *lazyVid = [RDProbeAnalyzer analyzeHTML:
        @"<video data-src='https://cdn.example.com/lazy.mp4'></video>" baseURL:base];
    BOOL lazyVideoOK = lazyVid.media.count == 1 && lazyVid.media.firstObject.resourceKind == RDResourceKindVideo &&
        [lazyVid.media.firstObject.discoverySource isEqual:@"static-video-lazy"];
    CheckF(lazyVideoOK, @"data-src 视频按懒加载逻辑识别且只产生一条（实际 %lu 条）", (unsigned long)lazyVid.media.count);

    RDProbeResult *srcset = [RDProbeAnalyzer analyzeHTML:
        @"<img src='https://cdn.example.com/a.jpg' srcset='https://cdn.example.com/b.jpg 2x' data-srcset='https://cdn.example.com/c.mp4 2x'>"
        baseURL:base];
    NSUInteger images = 0;
    BOOL hasB = NO, cLeaked = NO;
    for (DetectedMedia *m in srcset.media) {
        if ([m.mediaURL containsString:@"/a.jpg"] && m.resourceKind == RDResourceKindImage) images++;
        if ([m.mediaURL containsString:@"/b.jpg"] && m.resourceKind == RDResourceKindImage) { images++; hasB = YES; }
        if ([m.mediaURL containsString:@"c.mp4"]) cLeaked = YES;
    }
    CheckF(images == 2 && hasB, @"img src + srcset 图片解析正常（实际 %lu 张）", (unsigned long)images);
    CheckF(!cLeaked, @"data-srcset 不会被 srcset/src 误匹配（BUG-005）");
}

// BUG-007：GBK/GB2312 页面按声明解码，Latin-1 兜底不再静默产生乱码标题。
static NSData *MTHTMLPage(NSString *head, NSString *title, NSStringEncoding encoding) {
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<html><head>"];
    [html appendString:head ?: @""];
    [html appendString:@"<title>"];
    [html appendString:title];
    [html appendString:@"</title></head><body>ok</body></html>"];
    return [html dataUsingEncoding:encoding];
}

@interface MTPageFixture : NSURLProtocol
@end
@implementation MTPageFixture
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSString *path = self.request.URL.path;
    NSStringEncoding gbk = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)@"GBK"));
    NSString *title = @"探测中文标题样例";
    NSData *body = nil;
    NSDictionary *headers = @{@"Content-Type": @"text/html"};
    if ([path isEqual:@"/utf8"]) {
        body = MTHTMLPage(@"<meta charset='utf-8'>", title, NSUTF8StringEncoding);
        headers = @{@"Content-Type": @"text/html; charset=utf-8"};
    } else if ([path isEqual:@"/gbk-header"]) {
        body = MTHTMLPage(nil, title, gbk);
        headers = @{@"Content-Type": @"text/html; charset=GBK"};
    } else if ([path isEqual:@"/gbk-meta"]) {
        body = MTHTMLPage(@"<meta http-equiv='Content-Type' content='text/html; charset=gb2312'>", title, gbk);
    } else if ([path isEqual:@"/gbk-nodecl"]) {
        body = MTHTMLPage(nil, title, gbk);
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static NSString *MTLoadPageHTML(StaticHTMLDiscoveryPageProbe *probe, NSString *path) {
    __block NSString *html = nil;
    [probe loadHTMLForURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://page.fixture%@", path]]
               completion:^(NSString *h, NSURL *finalURL, NSError *error) { html = h; }];
    Wait(^BOOL { return html != nil; }, 5);
    return html;
}

static void StaticPageDecodingTests(void) {
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.protocolClasses = @[MTPageFixture.class];
    StaticHTMLDiscoveryPageProbe *probe = [[StaticHTMLDiscoveryPageProbe alloc] initWithPolicy:[URLPolicy new]
                                                                          sessionConfiguration:cfg];
    ResourceURLGate *gate = [probe valueForKey:@"gate"];
    gate.rd_checksEnabled = NO;   // 本地夹具假域名：与其他测试一致关闭安全解析

    NSString *utf8 = MTLoadPageHTML(probe, @"/utf8");
    CheckF([utf8 containsString:@"探测中文标题样例"], @"UTF-8 页面标题保持正确（BUG-007 无回归）");

    NSString *gbkHeader = MTLoadPageHTML(probe, @"/gbk-header");
    CheckF([gbkHeader containsString:@"探测中文标题样例"],
          @"HTTP Content-Type charset=GBK 页面标题正确（BUG-007）");

    NSString *gbkMeta = MTLoadPageHTML(probe, @"/gbk-meta");
    CheckF([gbkMeta containsString:@"探测中文标题样例"],
          @"meta http-equiv charset=gb2312 页面标题正确（BUG-007）");

    NSString *noDecl = MTLoadPageHTML(probe, @"/gbk-nodecl");
    CheckF(noDecl.length > 0, @"无 charset 声明的页面仍能合理解码（兜底不报错、不崩溃）");
}

// BUG-008：清单结构性关键字是 ASCII，非 UTF-8 字节不得让清单被误判“为空”。
static void ManifestEncodingTests(void) {
    RDMapTransport *map = [RDMapTransport new];
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:map];
    NSStringEncoding gbk = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)@"GBK"));

    NSMutableData *body = [NSMutableData data];
    [body appendData:[@"#EXTM3U\n" dataUsingEncoding:NSASCIIStringEncoding]];
    [body appendData:[@"# 注释：中文站名\n" dataUsingEncoding:gbk]];   // 非 UTF-8 字节
    [body appendData:[@"#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n" dataUsingEncoding:NSASCIIStringEncoding]];
    map.map[@"/gbk.m3u8"] = body;
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = @"https://offline.invalid/gbk.m3u8";
    m.resourceKind = RDResourceKindManifest;
    RDMetadataSnapshot *s = ReadMetadata(service, m, NO);
    CheckF(s.duration.state == RDMetadataKnown && fabs([s.duration.value doubleValue] - 4.0) < .001,
          @"含非 UTF-8 字节但结构有效的清单可解析（BUG-008，状态 %ld 来源 %@）",
          (long)s.duration.state, s.duration.source);

    map.map[@"/utf8.m3u8"] = [@"#EXTM3U\n#EXTINF:2.0,\na.ts\n#EXT-X-ENDLIST" dataUsingEncoding:NSUTF8StringEncoding];
    m.mediaURL = @"https://offline.invalid/utf8.m3u8";
    s = ReadMetadata(service, m, YES);
    CheckF(s.duration.state == RDMetadataKnown && fabs([s.duration.value doubleValue] - 2.0) < .001,
          @"UTF-8 m3u8 正常解析不受影响");

    map.map[@"/empty.m3u8"] = [NSData data];
    m.mediaURL = @"https://offline.invalid/empty.m3u8";
    s = ReadMetadata(service, m, YES);
    CheckF(s.duration.state == RDMetadataFailed, @"真正的空清单仍报明确失败（实际 %ld）", (long)s.duration.state);

    map.map[@"/junk.m3u8"] = [@"garbage-not-a-manifest" dataUsingEncoding:NSUTF8StringEncoding];
    m.mediaURL = @"https://offline.invalid/junk.m3u8";
    s = ReadMetadata(service, m, YES);
    CheckF(s.duration.state == RDMetadataFailed, @"损坏清单仍报明确失败（实际 %ld）", (long)s.duration.state);
}

// BUG-009：并行页探测取消时，已完成页面结果保留；在途页 Cancelled；
// 未开始页 NotStarted；completion 恰好一次；迟到结果不得覆盖。
@interface MTProbeToken : NSObject
@property (nonatomic, assign) BOOL cancelled;
@end
@implementation MTProbeToken
@end

@interface MTParallelPageProbe : NSObject <ZZDiscoveryPageProbing>
@property (nonatomic, strong) NSMutableArray<NSURL *> *probedURLs;
@property (nonatomic, strong) NSMutableArray<MTProbeToken *> *tokens;
@property (nonatomic, strong) NSMutableArray<void (^)(NSArray<DetectedMedia *> *, NSError *)> *completions;
@end
@implementation MTParallelPageProbe
- (instancetype)init {
    self = [super init];
    if (self) {
        _probedURLs = [NSMutableArray array];
        _tokens = [NSMutableArray array];
        _completions = [NSMutableArray array];
    }
    return self;
}
- (id)probePageURL:(NSURL *)pageURL completion:(void (^)(NSArray<DetectedMedia *> *, NSError *))completion {
    [self.probedURLs addObject:pageURL];
    MTProbeToken *token = [MTProbeToken new];
    [self.tokens addObject:token];
    [self.completions addObject:[completion copy]];
    return token;
}
- (void)cancelProbe:(id)probeToken {
    if ([probeToken isKindOfClass:[MTProbeToken class]]) ((MTProbeToken *)probeToken).cancelled = YES;
}
@end

@interface MTHTMLProvider : NSObject <ZZDiscoveryHTMLProviding>
@property (nonatomic, copy) NSString *html;
@end
@implementation MTHTMLProvider
- (id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(self.html, url, nil); });
    return [NSObject new];
}
- (void)cancelHTMLRequest:(id)requestToken {}
@end

static void ParallelCancelKeepsCompletedPagesTests(void) {
    MTHTMLProvider *provider = [MTHTMLProvider new];
    provider.html = @"<html><body>"
        @"<a href='https://list.example.com/watch/a'>A</a>"
        @"<a href='https://list.example.com/watch/b'>B</a>"
        @"<a href='https://list.example.com/watch/c'>C</a>"
        @"<a href='https://list.example.com/watch/d'>D</a>"
        @"</body></html>";
    MTParallelPageProbe *pageProbe = [MTParallelPageProbe new];
    ResourceDiscoveryCoordinator *coordinator =
        [[ResourceDiscoveryCoordinator alloc] initWithPageProbe:pageProbe htmlProvider:provider];

    ZZResourceDiscoveryOptions *options = [ZZResourceDiscoveryOptions defaultOptions];
    options.mode = ZZResourceDiscoveryModeSite;
    options.maxConcurrentPageProbes = 2;
    options.maxSubpageCount = 10;
    options.maxRetries = 0;
    options.requestInterval = 0;

    __block NSUInteger completions = 0;
    __block ZZResourceDiscoveryResult *result = nil;
    [coordinator discoverFromURL:[NSURL URLWithString:@"https://list.example.com/index"]
                         options:options
                      completion:^(ZZResourceDiscoveryResult *r) { completions++; result = r; }];

    Wait(^BOOL { return pageProbe.probedURLs.count == 2; }, 5);
    CheckF(pageProbe.probedURLs.count == 2, @"并行探测已启动前两页（实际 %lu）", (unsigned long)pageProbe.probedURLs.count);

    // 第一页完成并发现资源（并发槽位释放后第三页补位启动，第四页仍未开始）
    DetectedMedia *media = [DetectedMedia new];
    media.mediaURL = @"https://cdn.example.com/a.mp4";
    media.resourceKind = RDResourceKindVideo;
    void (^firstDone)(NSArray<DetectedMedia *> *, NSError *) = pageProbe.completions[0];
    firstDone(@[media], nil);
    Wait(^BOOL { return pageProbe.probedURLs.count == 3; }, 5);
    CheckF(pageProbe.probedURLs.count == 3, @"第一页完成后第三页补位启动");

    // 在其他页面仍运行时取消
    [coordinator cancel];
    Wait(^BOOL { return result != nil; }, 5);
    CheckF(completions == 1, @"completion 恰好回调一次（实际 %lu）", (unsigned long)completions);
    CheckF(result.cancelled, @"结果标记为已取消");
    CheckF(result.pageResults.count == 4, @"四页结果都在（实际 %lu）", (unsigned long)result.pageResults.count);

    MultiPageProbePageResult *pa = result.pageResults[0];
    MultiPageProbePageResult *pb = result.pageResults[1];
    MultiPageProbePageResult *pd = result.pageResults[3];
    CheckF(pa.status == MultiPageProbePageStatusSucceeded && pa.media.count == 1,
          @"已完成页保留 Succeeded 与其资源（状态 %ld 媒体 %lu）",
          (long)pa.status, (unsigned long)pa.media.count);
    CheckF(pb.status == MultiPageProbePageStatusCancelled,
          @"在途页标记 Cancelled（实际 %ld）", (long)pb.status);
    CheckF(pd.status == MultiPageProbePageStatusNotStarted,
          @"未开始页保持 NotStarted（实际 %ld）", (long)pd.status);
    BOOL mediaKept = result.allMedia.count == 1 && [result.allMedia.firstObject.mediaURL containsString:@"a.mp4"];
    CheckF(mediaKept, @"已完成页资源进入 allMedia（实际 %lu 个）", (unsigned long)result.allMedia.count);

    // 迟到的旧 generation summary：不得二次回调、不得覆盖结果
    void (^lateDone)(NSArray<DetectedMedia *> *, NSError *) = pageProbe.completions[1];
    lateDone(@[], nil);
    Wait(^BOOL { return NO; }, 0.3);
    CheckF(completions == 1, @"取消后迟到的 summary 不再触发 completion");
    CheckF(result.allMedia.count == 1, @"迟到结果不覆盖已汇总结果");
}

// MARK: - DASH SegmentTemplate 兼容（无 BaseURL / MPD URL 基址 / Timeline / 音视频 / 多 Representation）

#import "RDStreamPlan.h"

// 用户实测的最小无 BaseURL 样本
static NSString * const DASHNoBaseURLMPD =
    @"<MPD type=\"static\" mediaPresentationDuration=\"PT10S\">"
    @"  <Period>"
    @"    <AdaptationSet mimeType=\"video/mp4\">"
    @"      <SegmentTemplate media=\"seg-$Number$.m4s\""
    @"                       initialization=\"init.mp4\""
    @"                       duration=\"2\""
    @"                       timescale=\"1\"/>"
    @"      <Representation id=\"v1\" width=\"640\" height=\"360\"/>"
    @"    </AdaptationSet>"
    @"  </Period>"
    @"</MPD>";

// 多 Representation + 音频轨 + SegmentTemplate 继承/覆盖
static NSString * const DASHMultiRepMPD =
    @"<MPD type=\"static\" mediaPresentationDuration=\"PT10S\">"
    @"  <Period>"
    @"    <AdaptationSet mimeType=\"video/mp4\">"
    @"      <SegmentTemplate media=\"seg-$Number$.m4s\" initialization=\"init-$Bandwidth$.mp4\" duration=\"2\" timescale=\"1\"/>"
    @"      <Representation id=\"low\" bandwidth=\"500000\" width=\"640\" height=\"360\"/>"
    @"      <Representation id=\"high\" bandwidth=\"1500000\" width=\"1280\" height=\"720\">"
    @"        <SegmentTemplate media=\"hi-$Number$.m4s\"/>"
    @"      </Representation>"
    @"    </AdaptationSet>"
    @"    <AdaptationSet mimeType=\"audio/mp4\">"
    @"      <SegmentTemplate media=\"audio-$Number$.m4s\" initialization=\"a-init.mp4\" duration=\"2\" timescale=\"1\"/>"
    @"      <Representation id=\"a1\" bandwidth=\"128000\" audioSamplingRate=\"48000\"/>"
    @"    </AdaptationSet>"
    @"  </Period>"
    @"</MPD>";

// SegmentTemplate + SegmentTimeline
static NSString * const DASHTimelineMPD =
    @"<MPD type=\"static\" mediaPresentationDuration=\"PT8S\">"
    @"  <Period>"
    @"    <AdaptationSet mimeType=\"video/mp4\">"
    @"      <SegmentTemplate media=\"$Time$.m4s\" initialization=\"init.mp4\" timescale=\"1\">"
    @"        <SegmentTimeline><S d=\"2\" r=\"3\"/></SegmentTimeline>"
    @"      </SegmentTemplate>"
    @"      <Representation id=\"v1\" width=\"640\" height=\"360\"/>"
    @"    </AdaptationSet>"
    @"  </Period>"
    @"</MPD>";

static void DASHSegmentTemplateTests(void) {
    NSURL *mpdURL = [NSURL URLWithString:@"https://cdn.example.com/v/master.mpd"];

    // 1) 无 BaseURL：Representation 必须保留 SegmentTemplate 与分片基址（MPD 请求 URL），
    //    与 RDStreamPlan.DASHTracks 的解析语义一致
    NSDictionary *plain = [RDManifestParser parseManifest:DASHNoBaseURLMPD baseURL:mpdURL];
    NSDictionary *v1 = [plain[@"variants"] firstObject];
    CheckF([plain[@"kind"] isEqual:@"dash"] && [plain[@"variants"] count] == 1, @"无 BaseURL MPD 识别为 dash 且得到 1 个 Representation");
    CheckF([v1[@"segmentTemplate"][@"media"] isEqual:@"seg-$Number$.m4s"]
          && [v1[@"segmentTemplate"][@"initialization"] isEqual:@"init.mp4"]
          && [v1[@"segmentTemplate"][@"duration"] isEqual:@"2"],
          @"无 BaseURL 时 Representation 保留 SegmentTemplate 属性（BUG-017/DASH，实际 %@）", v1[@"segmentTemplate"]);
    CheckF([v1[@"segmentBase"] isEqual:mpdURL.absoluteString],
          @"无 BaseURL 时分片基址为 MPD 请求 URL（实际 %@）", v1[@"segmentBase"]);
    CheckF(fabs([plain[@"durationSeconds"] doubleValue] - 10.0) < .001, @"无 BaseURL MPD 时长仍为 10 秒");

    // 2) MPD URL 作为相对分片基址：解析器基址 + 模板 与 RDStreamPlan 生成的分片 URL 一致
    NSArray *videoTracks = [RDStreamPlan DASHTracks:DASHNoBaseURLMPD baseURL:mpdURL error:nil] ?: @[];
    NSArray *planResources = videoTracks.count > 0 ? videoTracks[0][@"resources"] : @[];
    CheckF(videoTracks.count == 1 && [videoTracks[0][@"kind"] isEqual:@"video"],
          @"DASHTracks 对无 BaseURL 样本产出 1 条视频轨（实际 %lu）", (unsigned long)videoTracks.count);
    CheckF(planResources.count == 6, @"DASHTracks 对无 BaseURL 样本产出 init + 5 分片（10s/2s，实际 %lu）",
          (unsigned long)planResources.count);
    NSString *initViaParser = [[NSURL URLWithString:v1[@"segmentTemplate"][@"initialization"]
                                         relativeToURL:[NSURL URLWithString:v1[@"segmentBase"]]] absoluteString];
    NSString *seg1ViaParser = [[NSURL URLWithString:@"seg-1.m4s"
                                         relativeToURL:[NSURL URLWithString:v1[@"segmentBase"]]] absoluteString];
    NSString *planInitURL = planResources.count > 0 ? planResources[0][@"url"] : nil;
    NSString *planSeg1URL = planResources.count > 1 ? planResources[1][@"url"] : nil;
    CheckF([initViaParser isEqual:planInitURL],
          @"解析器 init 基址与 DASHTracks 首分片一致（%@ vs %@）", initViaParser, planInitURL);
    CheckF([seg1ViaParser isEqual:planSeg1URL],
          @"解析器 media 模板基址与 DASHTracks 分片一致（%@ vs %@）", seg1ViaParser, planSeg1URL);

    // 3) SegmentTemplate + SegmentTimeline：timeline 保留进 variant，下载计划行为不变
    NSDictionary *timeline = [RDManifestParser parseManifest:DASHTimelineMPD baseURL:mpdURL];
    NSDictionary *tv = [timeline[@"variants"] firstObject];
    NSArray *entries = tv[@"segmentTemplate"][@"timeline"];
    CheckF(entries.count == 1 && [[entries[0] valueForKey:@"d"] isEqual:@"2"] && [[entries[0] valueForKey:@"r"] isEqual:@"3"],
          @"SegmentTimeline 的 S 条目保留进 Representation（实际 %@）", entries);
    NSArray *timelineTracks = [RDStreamPlan DASHTracks:DASHTimelineMPD baseURL:mpdURL error:nil] ?: @[];
    NSArray *timelineResources = timelineTracks.count > 0 ? timelineTracks[0][@"resources"] : @[];
    CheckF(timelineResources.count == 5, @"Timeline 样本 DASHTracks 产出 init + 4 分片（实际 %lu）",
          (unsigned long)timelineResources.count);
    NSString *tlFirst = timelineResources.count > 1 ? timelineResources[1][@"url"] : nil;
    NSString *tlLast = timelineResources.count > 4 ? timelineResources[4][@"url"] : nil;
    CheckF([tlFirst hasSuffix:@"0.m4s"] && [tlLast hasSuffix:@"6.m4s"],
          @"Timeline $Time$ 模板按 t 递增替换（%@ … %@）", tlFirst, tlLast);

    // 4) 多 Representation + 音频轨：SegmentTemplate 继承与 Representation 级覆盖
    NSDictionary *multi = [RDManifestParser parseManifest:DASHMultiRepMPD baseURL:mpdURL];
    CheckF([multi[@"variants"] count] == 3, @"多 Representation 全部进入 variants（实际 %lu）",
          (unsigned long)[multi[@"variants"] count]);
    NSArray *multiVariants = multi[@"variants"] ?: @[];
    NSDictionary *low = multiVariants.count > 0 ? multiVariants[0] : nil;
    NSDictionary *high = multiVariants.count > 1 ? multiVariants[1] : nil;
    NSDictionary *aud = multiVariants.count > 2 ? multiVariants[2] : nil;
    CheckF([low[@"segmentTemplate"][@"media"] isEqual:@"seg-$Number$.m4s"]
          && [low[@"segmentTemplate"][@"initialization"] isEqual:@"init-$Bandwidth$.mp4"],
          @"AS 级 SegmentTemplate 被无覆盖 Representation 继承");
    CheckF([high[@"segmentTemplate"][@"media"] isEqual:@"hi-$Number$.m4s"]
          && [high[@"segmentTemplate"][@"duration"] isEqual:@"2"]
          && [high[@"segmentTemplate"][@"initialization"] isEqual:@"init-$Bandwidth$.mp4"],
          @"Representation 级 SegmentTemplate 覆盖 media 但继承其余属性（实际 %@）", high[@"segmentTemplate"]);
    CheckF([aud[@"segmentTemplate"][@"media"] isEqual:@"audio-$Number$.m4s"],
          @"音频 AdaptationSet 的 SegmentTemplate 被独立继承");

    // 5) 多 Representation 时元数据维度取分辨率最高的视频轨，绝不盲取 firstObject、不取音频轨
    RDMapTransport *dashTransport = [RDMapTransport new];
    dashTransport.map[@"/dash-master.mpd"] = DASHMultiRepMPD;
    RDMetadataService *dashService = [[RDMetadataService alloc] initWithTransport:dashTransport];
    DetectedMedia *dashMedia = [DetectedMedia new];
    dashMedia.mediaURL = @"https://offline.invalid/dash-master.mpd";
    dashMedia.resourceKind = RDResourceKindManifest;
    RDMetadataSnapshot *dashSnap = ReadMetadata(dashService, dashMedia, NO);
    NSSize dashDims = [(NSValue *)dashSnap.dimensions.value sizeValue];
    CheckF(dashSnap.duration.state == RDMetadataKnown && fabs([dashSnap.duration.value doubleValue] - 10.0) < .001,
          @"多 Representation MPD 时长来自 mediaPresentationDuration（状态 %ld）", (long)dashSnap.duration.state);
    CheckF(dashSnap.dimensions.state == RDMetadataKnown && (int)dashDims.width == 1280 && (int)dashDims.height == 720,
          @"元数据维度取最高分辨率视频 Representation（实际 %.0fx%.0f）", dashDims.width, dashDims.height);
    // DASH 多 Representation 必须识别为 master 并把 Representation 发布为档位，
    // 否则 UI 永远不会出现 DASH 质量选择（静默丢失）。
    CheckF([multi[@"isMaster"] boolValue] == YES, @"多 Representation MPD 识别为 master");
    CheckF(dashSnap.variants.count == 3, @"DASH Representation 进入发布快照（实际 %lu）", (unsigned long)dashSnap.variants.count);

    // 7) HLS master 维度必须取分辨率最高档（HLS 变体只有 RESOLUTION 字符串，
    //    无 width/height 数值键——选择逻辑不得因此退化成"取第一条"）
    RDMapTransport *hlsTransport = [RDMapTransport new];
    hlsTransport.map[@"/hls-master.m3u8"] =
        @"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nv360.m3u8\n"
        @"#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\nv1080.m3u8";
    hlsTransport.map[@"/v1080.m3u8"] = @"#EXTM3U\n#EXTINF:6.0,\na.ts\n#EXT-X-ENDLIST";
    RDMetadataService *hlsService = [[RDMetadataService alloc] initWithTransport:hlsTransport];
    DetectedMedia *hlsMedia = [DetectedMedia new];
    hlsMedia.mediaURL = @"https://offline.invalid/hls-master.m3u8";
    hlsMedia.resourceKind = RDResourceKindManifest;
    RDMetadataSnapshot *hlsSnap = ReadMetadata(hlsService, hlsMedia, NO);
    NSSize hlsDims = [(NSValue *)hlsSnap.dimensions.value sizeValue];
    CheckF(hlsSnap.dimensions.state == RDMetadataKnown && (int)hlsDims.width == 1920 && (int)hlsDims.height == 1080,
          @"HLS master 维度取 RESOLUTION 最高档 1920x1080（实际 %.0fx%.0f）", hlsDims.width, hlsDims.height);
    CheckF(fabs([hlsSnap.duration.value doubleValue] - 6.0) < .001, @"HLS master 递归 VOD 时长正常（实际 %@）", hlsSnap.duration.value);

    // 6) RDStreamPlan 对多 Representation 样本仍选出最高码率视频轨 + 音频轨（锁定既有行为）
    NSArray *multiTracks = [RDStreamPlan DASHTracks:DASHMultiRepMPD baseURL:mpdURL error:nil] ?: @[];
    NSArray *kinds = [multiTracks valueForKey:@"kind"];
    CheckF(kinds.count == 2 && [kinds containsObject:@"video"] && [kinds containsObject:@"audio"],
          @"DASHTracks 对多 Representation 样本产出 video+audio 两条轨（实际 %@）", kinds);
}

// MARK: - RDQualityTier：质量档位归一化 + 跨来源去重（问题1/2 回归）

#import "RDQualityTier.h"

static RDQualityCandidate *MTQualityCandidate(NSString *url, NSString *label, double w, double h, long long bandwidth, NSString *source) {
    RDQualityCandidate *c = [RDQualityCandidate new];
    c.url = url; c.declaredLabel = label; c.pixelWidth = w; c.pixelHeight = h;
    c.bandwidth = bandwidth; c.discoverySource = source; c.kind = RDResourceKindVideo;
    return c;
}

static void QualityTierTests(void) {
    // 1) 档位归一化：短边 ±10% 容差（规则锁定）
    CheckF([RDQualityTier levelForPixelWidth:800 height:800] == RDQualityTierNone,
          @"800x800 方形不伪装成 480p/720p/1080p");
    CheckF([RDQualityTier levelForPixelWidth:854 height:480] == RDQualityTier480p, @"854x480 → 480p");
    CheckF([RDQualityTier levelForPixelWidth:1280 height:720] == RDQualityTier720p, @"1280x720 → 720p");
    CheckF([RDQualityTier levelForPixelWidth:1920 height:1080] == RDQualityTier1080p, @"1920x1080 → 1080p");
    CheckF([RDQualityTier levelForPixelWidth:1928 height:1084] == RDQualityTier1080p, @"1080±10% 容差内仍归 1080p");
    CheckF([RDQualityTier levelForPixelWidth:720 height:1280] == RDQualityTier720p, @"竖屏 720x1280 按短边归 720p");
    CheckF([RDQualityTier levelForPixelWidth:600 height:800] == RDQualityTierNone, @"600x800 短边 600 不命中任何标准档");
    CheckF([RDQualityTier levelForPixelWidth:0 height:0] == RDQualityTierNone, @"未知尺寸不归档");
    CheckF([RDQualityTier levelForDeclaredHeight:480] == RDQualityTier480p &&
           [RDQualityTier levelForDeclaredHeight:720] == RDQualityTier720p &&
           [RDQualityTier levelForDeclaredHeight:1080] == RDQualityTier1080p,
          @"源站声明高度按同一容差规则归档");
    CheckF([[RDQualityTier labelForLevel:RDQualityTier720p] isEqual:@"720p"], @"档位标签为 720p");

    // 2) 800x800 + 854x480 + 1280x720 + 1920x1080：只有标准三档进入质量选项，
    //    非标准尺寸（800x800）绝不自动变成额外质量选项（真实像素由详情维度呈现）
    NSArray *mixed = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/square.mp4", nil, 800, 800, 0, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/a-480.mp4", @"480", 854, 480, 0, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/a-720.mp4", @"720", 1280, 720, 0, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/a-1080.mp4", @"1080", 1920, 1080, 0, @"static-video"),
    ]];
    CheckF(mixed.count == 3, @"质量选项只含标准三档（实际 %lu）", (unsigned long)mixed.count);
    NSMutableDictionary *byURL = [NSMutableDictionary dictionary];
    for (NSDictionary *v in mixed) byURL[v[@"url"]] = v;
    CheckF(byURL[@"https://cdn.example.com/square.mp4"] == nil,
          @"800x800 不作为可选质量档出现");
    CheckF([byURL[@"https://cdn.example.com/a-480.mp4"][@"label"] isEqual:@"480p"] &&
           [byURL[@"https://cdn.example.com/a-480.mp4"][@"level"] integerValue] == RDQualityTier480p,
          @"854x480 归入 480p 档");
    CheckF([byURL[@"https://cdn.example.com/a-720.mp4"][@"pixelWidth"] integerValue] == 1280 &&
           [byURL[@"https://cdn.example.com/a-720.mp4"][@"pixelHeight"] integerValue] == 720,
          @"标准档候选保留真实像素（720p → 1280x720）");
    // 只有非标准尺寸：不生成任何质量选项（没有就没有，不近似）
    NSArray *onlySquare = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/sq.mp4", nil, 800, 800, 0, @"static-video"),
    ]];
    CheckF(onlySquare.count == 0, @"仅 800x800 时质量选项为空（实际 %lu）", (unsigned long)onlySquare.count);

    // 3) 同档多候选只保留一个：带宽高者优先
    NSArray *duplicateTier = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/low-720.mp4", @"720", 1280, 720, 500000, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/high-720.mp4", @"720", 1280, 720, 2500000, @"static-video"),
    ]];
    CheckF(duplicateTier.count == 1 && [duplicateTier.firstObject[@"url"] isEqual:@"https://cdn.example.com/high-720.mp4"] &&
           [duplicateTier.firstObject[@"label"] isEqual:@"720p"],
          @"两个 720p 候选只保留带宽高的一个（实际 %lu：%@）",
          (unsigned long)duplicateTier.count, [duplicateTier.firstObject[@"url"] description]);

    // 4) 同一 URL 静态+动态重复发现只保留一个（声明带像素与清单带像素合并）
    NSArray *dedup = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/v.mp4", @"720", 1280, 720, 0, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/v.mp4?token=expiring", @"720p", 1280, 720, 1500000, @"hls-manifest"),
    ]];
    CheckF(dedup.count == 1, @"同 URL 去重为一个候选（实际 %lu）", (unsigned long)dedup.count);

    // 5) URL 仅临时参数不同时视为重复，保留更稳定（无 token）的候选
    NSArray *stable = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/v.mp4?expires=999", @"720", 1280, 720, 900000, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/v.mp4", @"720", 1280, 720, 900000, @"static-video"),
    ]];
    CheckF(stable.count == 1 && [stable.firstObject[@"url"] isEqual:@"https://cdn.example.com/v.mp4"],
          @"带临时参数的 URL 让位于稳定 URL（实际 %@）", [stable.firstObject[@"url"] description]);

    // 6) 缺档不生成：只有 480 → 只有 480p
    NSArray *only480 = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/only-480.mp4", @"480", 854, 480, 0, @"static-video"),
    ]];
    CheckF(only480.count == 1 && [only480.firstObject[@"label"] isEqual:@"480p"],
          @"缺失档位不生成（只有 480p）");

    // 6b) 声明文本为 "WxH" 形式（<source size="854x480">）→ 归 480p
    NSArray *declaredWxH = [RDQualityTier normalizedVariantsFromCandidates:@[
        MTQualityCandidate(@"https://cdn.example.com/wxh-480.mp4", @"854x480", 0, 0, 0, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/wxh-720.mp4", @"1280x720", 0, 0, 0, @"static-video"),
        MTQualityCandidate(@"https://cdn.example.com/wxh-1080.mp4", @"1920x1080", 0, 0, 0, @"static-video"),
    ]];
    CheckF(declaredWxH.count == 3 &&
           [declaredWxH[0][@"label"] isEqual:@"480p"] && [declaredWxH[1][@"label"] isEqual:@"720p"] && [declaredWxH[2][@"label"] isEqual:@"1080p"],
          @"size=\"854x480/1280x720/1920x1080\" 声明归入对应档位（实际 %@）",
          [[declaredWxH valueForKey:@"label"] description]);

    // 7) 静态声明 + 清单 Representation 合并：同档取带宽高者、同 URL 去重
    NSArray *merged = [RDQualityTier normalizedVariantsByMergingDeclared:@[
        @{ @"url": @"https://cdn.example.com/v-720.mp4", @"label": @"720" },
    ] manifest:@[
        @{ @"url": @"https://cdn.example.com/v-720.mp4", @"resolution": @"1280x720", @"bandwidth": @"3000000" },
        @{ @"url": @"https://cdn.example.com/v-360.mp4", @"resolution": @"640x360", @"bandwidth": @"800000" },
    ]];
    CheckF(merged.count == 1, @"静态+清单合并后仅保留标准档（360p 不作可选档，实际 %lu）", (unsigned long)merged.count);
    CheckF([merged.firstObject[@"label"] isEqual:@"720p"] &&
           [merged.firstObject[@"bandwidth"] longLongValue] == 3000000,
          @"合并后 720p 保留清单带宽信息");
    CheckF([merged.firstObject[@"pixelWidth"] integerValue] == 1280,
          @"合并候选保留真实像素（1280x720）");

    // 8) 同档多 URL（生产解析器形态）：两个媒体都挂归一化后的分组，
    //    App.visibleMedia 依赖它把同视频折叠为一行（防“重复结果”回归）
    RDProbeResult *sameTier = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video><source src='https://cdn.invalid/sd-a.mp4' size='720'>"
        @"<source src='https://cdn.invalid/sd-b.mp4' size='720'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://page.invalid/watch"]];
    CheckF(sameTier.media.count == 2, @"同档双候选仍发现两个媒体 URL（实际 %lu）", (unsigned long)sameTier.media.count);
    for (DetectedMedia *item in sameTier.media) {
        CheckF(item.declaredVariants.count == 1 &&
               [item.declaredVariants.firstObject[@"label"] isEqual:@"720p"],
              @"%@ 挂同档分组信息（count=%lu）", item.mediaURL.lastPathComponent, (unsigned long)item.declaredVariants.count);
    }
    // 误合并防护：不同视频（不同块、不同档）不得被并成一组
    RDProbeResult *distinct = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video><source src='https://cdn.invalid/x-720.mp4' size='720'></video>"
        @"<video><source src='https://cdn.invalid/y-1080.mp4' size='1080'></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://page.invalid/watch"]];
    CheckF(distinct.media.count == 2, @"两个不同视频各自成行（实际 %lu 条媒体）", (unsigned long)distinct.media.count);
    CheckF(distinct.media.firstObject.declaredVariants.count == 0 && distinct.media.lastObject.declaredVariants.count == 0,
          @"单视频无同族候选时不写回分组（不误合并）");
}

// MARK: - 元数据服务并发上限（问题3：不允许一次对大量候选同时拉取）

static void MetadataConcurrencyTests(void) {
    RDMapTransport *map = [RDMapTransport new]; map.delay = 0.25;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:map];
    NSData *fixture = ImageFixture(6, 80, 40);
    NSMutableArray<RDMetadataToken *> *tokens = [NSMutableArray array];
    for (NSUInteger i = 0; i < 8; i++) {
        NSString *path = [NSString stringWithFormat:@"/conc-%lu.jpg", (unsigned long)i];
        map.map[path] = fixture;
        DetectedMedia *m = [DetectedMedia new];
        m.mediaURL = [@"https://offline.invalid" stringByAppendingString:path];
        m.resourceKind = RDResourceKindImage;
        [tokens addObject:[service subscribeMedia:m reload:NO update:^(RDMetadataSnapshot *s) {}]];
    }
    Wait(^BOOL { return NO; }, 0.15);
    // 每个 image work 恰好 2 个请求（HEAD+GET，既有测试锁定）。并发上限 4 →
    // 首批最多 4 个 work、8 个请求；8 个 work 全部并发则是 16 个请求。
    CheckF(map.requests <= 8, @"并发 work 数不超过明确上限（首批请求 %lu ≤ 8）", (unsigned long)map.requests);
    CheckF(map.requests >= 2, @"首批至少启动 1 个 work（请求 %lu）", (unsigned long)map.requests);
    // 取消仍在排队的订阅者：其底层请求不得启动。
    for (NSUInteger i = 4; i < 8; i++) [tokens[i] cancel];
    NSUInteger afterCancel = map.requests;
    Wait(^BOOL { return NO; }, 0.9); // 首批 4 个完成（各 HEAD+GET+0.25s delay）
    CheckF(map.requests == afterCancel, @"排队取消后不启动被取消者的底层请求（%lu == %lu）",
           (unsigned long)map.requests, (unsigned long)afterCancel);
    for (RDMetadataToken *t in tokens) [t cancel];
    Wait(^BOOL { return NO; }, 0.3);
}

// MARK: - 同一海报 URL 只取一次（同一影片的多个画质共用一张海报）

// 真实网址实测：同一张 408160h.jpg 在 480p/720p 之间被取 2 次——预览通道按
// 媒体身份缓存，而两个画质是不同的媒体身份。按海报 URL 共享后只取一次。
static void PosterURLSharingTests(void) {
    RDMapTransport *map = [RDMapTransport new]; map.delay = 0.05;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:map];
    map.map[@"/poster.jpg"] = ImageFixture(1, 80, 40);
    map.map[@"/a.jpg"] = ImageFixture(1, 40, 20);
    map.map[@"/b.jpg"] = ImageFixture(1, 40, 20);

    DetectedMedia *a = [DetectedMedia new];
    a.mediaURL = @"https://offline.invalid/a.jpg";
    a.poster = @"https://offline.invalid/poster.jpg";
    a.resourceKind = RDResourceKindImage;
    RDMetadataSnapshot *snapA = ReadMetadata(service, a, NO);
    CheckF(snapA.preview.state == RDMetadataKnown, @"第一个画质取到海报（state=%ld）", (long)snapA.preview.state);
    NSUInteger posterAfterFirst = 0;
    for (NSString *path in map.order) if ([path isEqualToString:@"/poster.jpg"]) posterAfterFirst++;

    DetectedMedia *b = [DetectedMedia new];
    b.mediaURL = @"https://offline.invalid/b.jpg";
    b.poster = a.poster;   // 同一张海报
    b.resourceKind = RDResourceKindImage;
    RDMetadataSnapshot *snapB = ReadMetadata(service, b, NO);
    CheckF(snapB.preview.state == RDMetadataKnown, @"第二个画质同样得到海报（state=%ld）", (long)snapB.preview.state);
    NSUInteger posterAfterSecond = 0;
    for (NSString *path in map.order) if ([path isEqualToString:@"/poster.jpg"]) posterAfterSecond++;

    CheckF(posterAfterFirst == 1, @"第一个画质恰好取一次海报（实际 %lu）", (unsigned long)posterAfterFirst);
    CheckF(posterAfterSecond == posterAfterFirst,
           @"第二个画质复用同一海报、不再重复下载（%lu → %lu 次）",
           (unsigned long)posterAfterFirst, (unsigned long)posterAfterSecond);
}

// MARK: - 分阶段超时预算（问题3：HEAD/探测/清单/大块传输不同预算）

static void MetadataTimeoutBudgetTests(NSURL *videoURL) {
    CheckF([RDMetadataService requestTimeoutForMethod:@"HEAD" budget:0] == 3.0,
          @"HEAD 预算 3 秒（实际 %.2f）", [RDMetadataService requestTimeoutForMethod:@"HEAD" budget:0]);
    // ≤2MB 的 Range 读取按 64KB/s 保守吞吐外推：1KB 探测仍 10s，1MB 约 16s，
    // 2MB 封顶 30s（真实网址 981KB moov 需要 6–12s，固定 10s 会误判超时并整段重传）。
    NSTimeInterval oneKB = [RDMetadataService requestTimeoutForMethod:@"GET" budget:1024];
    NSTimeInterval oneMB = [RDMetadataService requestTimeoutForMethod:@"GET" budget:1024 * 1024];
    CheckF(oneKB == 10.0, @"1KB 探测预算 10 秒（实际 %.2f）", oneKB);
    CheckF(oneMB >= 15.0 && oneMB <= 17.0, @"1MB Range 读取预算约 16 秒（实际 %.2f）", oneMB);
    CheckF([RDMetadataService requestTimeoutForMethod:@"GET" budget:2 * 1024 * 1024] == 30.0,
          @"2MB 上限读取预算封顶 30 秒（实际 %.2f）", [RDMetadataService requestTimeoutForMethod:@"GET" budget:2 * 1024 * 1024]);
    NSTimeInterval moovBudget = [RDMetadataService requestTimeoutForMethod:@"GET" budget:4 * 1024 * 1024];
    CheckF(moovBudget >= 15.0 && moovBudget <= 30.0,
          @"4MB moov 大块预算按吞吐外推且封顶 30 秒（实际 %.2f）", moovBudget);
    CheckF([RDMetadataService requestTimeoutForMethod:@"GET" budget:512 * 1024 * 1024] <= 30.0,
          @"超大预算封顶 30 秒（全局看门狗一致）");

    // 实际请求序列验证：视频 work = 前缀探测 GET(bytes=0-1048575，16s) +
    // 2MB 本体 GET(30s)。HEAD 不再位于视频路径（其 3s 预算仍服务图片）。
    // 为什么探测窗口必须是 1MB 而不是 1KB：真实网址实测（2026-09-10）详情腿是
    // 2–4 次**严格串行** Range 往返之和（4.39/6.52/8.67s），每次 1.4–3.5s；
    // 本站 faststart 文件 moov 在偏移 1024、约 318KB–1.44MB，1KB 窗口只能覆盖
    // 头部，盒遍历还要为 1KB 的 box 头、moov 主体各发一次请求。取 1MB 让
    // ftyp+moov 一次到手（RDBoundedMovie 把探测头当初始窗口复用，不再补请求）。
    RDMapTransport *map = [RDMapTransport new];
    RDMetadataService *service = [[RDMetadataService alloc]initWithTransport:map];
    map.map[@"/budget.mov"] = [NSData dataWithContentsOfURL:videoURL];
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = @"https://offline.invalid/budget.mov";
    m.resourceKind = RDResourceKindVideo;
    ReadMetadata(service, m, NO);
    // 只锁定「第一个请求就是放大后的 1MB 前缀窗口、且用 16s 预算」；不锁定请求
    // 总条数——共享 mock 不切 Range，整份夹具落在预算内时会走本地解码分支（1 个请求）。
    CheckF(map.timeouts.count >= 1 && [map.timeouts[0] doubleValue] == 16.0,
           @"前缀探测预算 = 16s（1MB ÷ 64KB/s 外推；实际 %@）", [map.timeouts description]);
    CheckF(map.ranges.count >= 1 && [map.ranges[0] isEqual:@"bytes=0-1048575"],
           @"前缀探测窗口放大到 1MB，一次覆盖 ftyp+moov（实际首个 Range=%@）", map.ranges.count ? map.ranges[0] : @"(无)");

    // 二进制 MIME MP4（video/mp4 响应头，体仅 96B）：前缀探测一次拿到完整
    // 小文件与 Content-Length 总长；本体 GET 走本地解码——整个 work 2 个请求
    // （旧实现为 HEAD + bytes=0-31 + 本体共 3 个）。
    map = [RDMapTransport new];
    service = [[RDMetadataService alloc]initWithTransport:map];
    NSMutableData *binary = [NSMutableData dataWithLength:32];
    memcpy((uint8_t *)binary.mutableBytes + 4, "ftyp", 4);
    [binary appendData:[NSMutableData dataWithLength:64]];
    map.map[@"/binary-short.mp4"] = binary;
    m = [DetectedMedia new];
    m.mediaURL = @"https://offline.invalid/binary-short.mp4";
    m.resourceKind = RDResourceKindVideo;
    RDMetadataSnapshot *binarySnap = ReadMetadata(service, m, NO);
    CheckF(binarySnap.size.state == RDMetadataKnown && [binarySnap.size.value longLongValue] == 96,
          @"二进制 MP4 经单次前缀探测取得签名与总长（实际 %ld/%@）", (long)binarySnap.size.state, binarySnap.size.value);
    CheckF(map.requests == 1, @"二进制 MP4 整个 work 仅 1 个请求（探测即完整响应体，不再重发本体 GET；旧实现 2 个）");

    // 图像 work = HEAD(3s) + 12MB 完整读取 GET(30s)：资源本体读取预算封顶
    map = [RDMapTransport new];
    service = [[RDMetadataService alloc] initWithTransport:map];
    map.map[@"/budget.jpg"] = ImageFixture(6, 80, 40);
    m = [DetectedMedia new];
    m.mediaURL = @"https://offline.invalid/budget.jpg";
    m.resourceKind = RDResourceKindImage;
    ReadMetadata(service, m, NO);
    CheckF(map.timeouts.count == 2 && [map.timeouts[0] doubleValue] == 3.0 && [map.timeouts[1] doubleValue] == 30.0,
          @"image work HEAD=3s、完整读取 GET=30s（实际 %@）", [map.timeouts description]);
}

// MARK: - 选中项调度优先级：占满并发槽 + 排队预取后点击后排结果，
// 记录点击→请求开始（排队）、请求开始→响应（网络）、响应→终态（解析）。

static void MetadataPriorityTests(void) {
    RDMapTransport *map = [RDMapTransport new]; map.delay = 0.4;
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:map];
    NSData *fixture = ImageFixture(6, 80, 40);
    DetectedMedia *(^media)(NSString *) = ^(NSString *name) {
        map.map[[NSString stringWithFormat:@"/p-%@.jpg", name]] = fixture;
        DetectedMedia *m = [DetectedMedia new];
        m.mediaURL = [NSString stringWithFormat:@"https://offline.invalid/p-%@.jpg", name];
        m.resourceKind = RDResourceKindImage;
        return m;
    };
    __block NSDate *clickedAt = nil;
    __block NSDate *clickedFirstRequestAt = nil;
    __block NSDate *clickedTerminalAt = nil;
    NSMutableArray<RDMetadataToken *> *tokens = [NSMutableArray array];
    // 1) 占满 4 个并发槽
    for (NSUInteger i = 0; i < 4; i++) {
        [tokens addObject:[service subscribeMedia:media([NSString stringWithFormat:@"bg%lu", (unsigned long)i]) reload:NO update:^(RDMetadataSnapshot *s) {}]];
    }
    Wait(^BOOL { return map.requests >= 8; }, 5); // 4 work × (HEAD+GET) 全部在途
    // 2) 排入两个后台预取（FIFO：q1 在前、q2 在后）
    [tokens addObject:[service subscribeMedia:media(@"q1") reload:NO update:^(RDMetadataSnapshot *s) {}]];
    [tokens addObject:[service subscribeMedia:media(@"q2") reload:NO update:^(RDMetadataSnapshot *s) {}]];
    Wait(^BOOL { return NO; }, 0.15);
    NSUInteger beforeClick = map.requests;
    CheckF(beforeClick == 8, @"排队者未启动任何请求（实际 %lu）", (unsigned long)beforeClick);
    // 3) 用户点击排在其后的 q2：应插队到 q1 之前
    clickedAt = NSDate.date;
    RDMetadataToken *clicked = [service subscribeMedia:media(@"q2") reload:NO update:^(RDMetadataSnapshot *s) {
        if (s.preview.state != RDMetadataLoading) clickedTerminalAt = NSDate.date;
    }];
    [tokens addObject:clicked];
    [service prioritizeMedia:media(@"q2")];
    Wait(^BOOL { return map.requests > beforeClick; }, 8);
    clickedFirstRequestAt = NSDate.date;
    double queueWait = [clickedFirstRequestAt timeIntervalSinceDate:clickedAt];
    NSLog(@"PERF priority: 排队等待=%.3fs（点击→首个底层请求）", queueWait);
    // 先开始的是被点击项，而不是排在前面的 q1
    CheckF([map.order[beforeClick] isEqual:@"/p-q2.jpg"],
          @"点击项插队：首个获得槽位的是 q2（实际 %@）", map.order[beforeClick]);
    // 4) 等全部完成，记录网络/解析分段
    CheckF(Wait(^BOOL { return clickedTerminalAt != nil; }, 10), @"点击项到达终态");
    for (RDMetadataToken *t in tokens) [t cancel];
    double network = 0.8; // 两次受控响应（HEAD+GET）各 0.4s
    double parse = [clickedTerminalAt timeIntervalSinceDate:clickedFirstRequestAt] - network;
    NSLog(@"PERF priority: 网络≈%.2fs（受控 2 响应×0.4s） 解析≈%.3fs（含回调派发）",
          network, MAX(0, parse));
    CheckF(queueWait < 1.6, @"点击项排队等待 < 4 个槽中最快释放周期（实际 %.3fs）", queueWait);
}

// MARK: - App 详情订阅回调的静态+清单合并（集成：真实 subscribeMetadataForMedia 路径）
// 修复前该路径把 RDQualityCandidate 数组传入 manifest:（NSArray<NSDictionary*>），
// 运行时 NSInvalidArgumentException: objectForKeyedSubscript: —— 此测试防回归。

static void SnapshotMergeIntegrationTests(void) {
    RDMapTransport *map = [RDMapTransport new];
    map.map[@"/merge.m3u8"] =
        @"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nmerge-v360.m3u8\n"
        @"#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\nmerge-v1080.m3u8";
    map.map[@"/merge-v360.m3u8"] = @"#EXTM3U\n#EXTINF:3.0,\na.ts\n#EXT-X-ENDLIST";
    map.map[@"/merge-v1080.m3u8"] = @"#EXTM3U\n#EXTINF:3.0,\na.ts\n#EXT-X-ENDLIST";
    RDMetadataService *service = [[RDMetadataService alloc] initWithTransport:map];
    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = @"https://offline.invalid/merge.m3u8";
    m.resourceKind = RDResourceKindManifest;
    // 静态档位已存在（模拟 WebProbe 已写回同族分组：720p）
    m.declaredVariants = @[ @{ @"url": m.mediaURL, @"label": @"720p", @"level": @720,
                               @"pixelWidth": @1280, @"pixelHeight": @720 } ];
    // 走 App 实际详情订阅回调（真实 subscribeMetadataForMedia 与 update 块）
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.metadataService = service;
    app.durationCache = [NSMutableDictionary dictionary];
    app.results = [NSMutableArray arrayWithObject:m];
    app.detailMedia = m;
    app.detailGeneration = 0;
    app.table = (NSTableView *)[RDTestTable new];
    ((RDTestTable *)app.table).row = [RDTestRow new];
    app.variantPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 20) pullsDown:NO];
    [app subscribeMetadataForMedia:m reload:NO];
    CheckF(Wait(^BOOL { return m.declaredVariants.count == 2; }, 10),
          @"静态 720p + 清单 1080p 合并完成且不抛异常（实际 %lu）", (unsigned long)m.declaredVariants.count);
    NSArray *labels = [m.declaredVariants valueForKey:@"label"];
    CheckF([labels containsObject:@"720p"] && [labels containsObject:@"1080p"],
          @"合并后选项为 720p/1080p（实际 %@）", labels);
    CheckF(![labels containsObject:@"360p"], @"清单 360p 非标准档不进入选项");
    CheckF(app.variantPicker.numberOfItems == 2, @"选择器共 2 项（实际 %lu）", (unsigned long)app.variantPicker.numberOfItems);
    CheckF([app.variantPicker.selectedItem.representedObject[@"url"] isEqual:m.mediaURL],
          @"当前选择保持（选中项 URL = 媒体自身 URL）");
    CheckF([app.detailMedia.mediaURL isEqual:m.mediaURL],
          @"详情与下载对象不变（%@）", app.detailMedia.mediaURL);
}
