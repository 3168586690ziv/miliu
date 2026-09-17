#import "StaticHTMLDiscoveryPageProbe.h"
#import "ResourceURLGate.h"
#import "WebProbe.h"
#import "RDStaticScriptAnalyzer.h"

NSString *const ZZStaticHTMLPageProbeErrorDomain = @"ZZStaticHTMLPageProbeErrorDomain";

// 按 HTTP Content-Type / <meta charset> 声明解码；无声明或声明解码失败时
// 维持原 UTF-8 → Latin-1 兜底。中文资源站的 GB2312/GBK 页面若无此嗅探，
// 会被 Latin-1 兜底解码成整体乱码并被静默采纳入库。
static NSString *SHPEncodingNameFromContentType(NSString *contentType) {
    if (contentType.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"charset\\s*=\\s*\"?([A-Za-z0-9_\\-]+)\"?" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:contentType options:0 range:NSMakeRange(0, contentType.length)];
    return m ? [contentType substringWithRange:[m rangeAtIndex:1]] : nil;
}

// ── 直链媒体 / 流清单分流（2026-09-18 新增）──
// 背景：用户可能把「媒体文件」或「流清单」的地址直接粘进输入框。此前这类请求也
// 一律当 HTML 解析，实测两个后果：① 超过 2MB 的视频文件被「页面内容超过 2 MB
// 安全上限」挡掉，一个资源都探不到；② 白白把整个媒体文件下载完再当 HTML 丢弃。
// 判定顺序：先看 HTTP MIME；只有 MIME 不明确（空 / octet-stream）时才回退看扩展名。
// 只要 MIME 明确是 text/html，无论扩展名像不像媒体，都走原 HTML 解析路径 ——
// 「伪装成 .mp4 的 HTML 页」不会被误判成媒体。
static DetectedMedia *SHPDetectedMediaForDirectResponse(NSHTTPURLResponse *http, NSURL *url) {
    if (!http || !url) return nil;
    NSString *mime = [http.MIMEType lowercaseString] ?: @"";
    NSString *ext = url.pathExtension.lowercaseString ?: @"";
    BOOL mimeGeneric = (mime.length == 0
                        || [mime isEqualToString:@"application/octet-stream"]
                        || [mime isEqualToString:@"binary/octet-stream"]);
    BOOL manifest = [mime containsString:@"mpegurl"]
                 || [mime isEqualToString:@"application/dash+xml"]
                 || (mimeGeneric && ([ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"mpd"]));
    static NSSet<NSString *> *videoExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        videoExts = [NSSet setWithArray:@[@"mp4",@"m4v",@"mov",@"webm",@"mkv",@"avi",
                                          @"ts",@"m2ts",@"flv",@"ogv"]];
    });
    BOOL video = [mime hasPrefix:@"video/"] || (mimeGeneric && [videoExts containsObject:ext]);
    if (!manifest && !video) return nil;

    DetectedMedia *m = [DetectedMedia new];
    m.mediaURL = url.absoluteString;
    if (mime.length) m.mimeType = mime;
    m.resourceKind = manifest ? RDResourceKindManifest : RDResourceKindVideo;
    m.isManifest = manifest;
    m.discoverySource = @"direct-url";
    m.sourcePageURL = url.absoluteString;   // 直链本身就是来源页
    NSString *name = url.lastPathComponent.stringByRemovingPercentEncoding ?: url.lastPathComponent;
    m.title = name.length ? name : url.absoluteString;
    if (manifest) {
        BOOL dash = [ext isEqualToString:@"mpd"] || [mime isEqualToString:@"application/dash+xml"];
        m.format = dash ? @"dash" : @"hls";
        m.thumbnailStatus = RDThumbnailNone;
    } else {
        m.format = ext.length ? ext : @"mp4";
        m.thumbnailStatus = RDThumbnailPending;
    }
    // 响应是 200 且 MIME 明确为媒体，可用性有据可依；该字段只参与排序，不控制显隐。
    m.availabilityState = @"downloadable";
    m.discoveredAt = [NSDate date].timeIntervalSince1970;
    if (http.expectedContentLength > 0) m.sizeBytes = http.expectedContentLength;
    return m;
}

static NSString *SHPDecodeHTML(NSData *data, NSURLResponse *response, NSString *metaSnippet) {
    NSMutableArray<NSString *> *declared = [NSMutableArray array];
    NSString *fromHeader = SHPEncodingNameFromContentType(
        ((NSHTTPURLResponse *)response).allHeaderFields[@"Content-Type"] ?: @"");
    if (fromHeader.length) [declared addObject:fromHeader];
    if (metaSnippet.length) {
        NSString *fromMeta = SHPEncodingNameFromContentType(metaSnippet);
        if (fromMeta.length) [declared addObject:fromMeta];
    }
    for (NSString *name in declared) {
        CFStringEncoding cfEnc = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)name);
        if (cfEnc == kCFStringEncodingInvalidId) continue;
        NSStringEncoding nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc);
        if (nsEnc == NSProprietaryStringEncoding) continue;
        NSString *html = [[NSString alloc] initWithData:data encoding:nsEnc];
        if (html) return html;
    }
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return html;
}

@interface ZZStaticHTMLProbeContext : NSObject
@property (nonatomic, strong) NSURL *originalURL;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, copy, nullable) void (^mediaCompletion)(NSArray<DetectedMedia *> *, NSError *);
@property (nonatomic, copy, nullable) ZZDiscoveryHTMLCompletion htmlCompletion;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL bodyLimitExceeded;
@property (nonatomic) NSUInteger byteLimit;
@property (nonatomic) NSUInteger receivedBytes;
@property (nonatomic) NSUInteger redirectCount;
@property (nonatomic, strong) ZZStaticHTMLProbeContext *scriptToken;
@property (nonatomic, copy) NSArray<NSURL *> *scriptURLs;
@property (nonatomic, strong) NSMutableArray<DetectedMedia *> *collectedMedia;
@property (nonatomic, strong, nullable) NSURL *documentBaseURL;
@property (nonatomic) NSUInteger scriptIndex;
@property (nonatomic) NSUInteger scriptBytes;
@property (nonatomic) BOOL scriptsDone;
@property (nonatomic, strong, nullable) NSError *redirectError;
@property (nonatomic, strong, nullable) NSError *pageError;
@end
@implementation ZZStaticHTMLProbeContext
@end

@interface StaticHTMLDiscoveryPageProbe () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong) URLPolicy *policy;
@property (nonatomic, strong) ResourceURLGate *gate;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ZZStaticHTMLProbeContext *> *contexts;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@end

@implementation StaticHTMLDiscoveryPageProbe

- (instancetype)initWithPolicy:(URLPolicy *)policy {
    return [self initWithPolicy:policy sessionConfiguration:nil];
}

- (instancetype)initWithPolicy:(URLPolicy *)policy
           sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self=[super init];
    if(self){
        _policy=policy ?: [URLPolicy new];
        _gate=[ResourceURLGate new];
        _gate.policy=_policy;
        // 上限对齐（2026-09-18）：原先这里写死 2 MB，而同一项目的另外两条网页读取路径
        // 都是 8 MB（WebProbe.m 的 _maxHTMLBytes、ProductionDiscoveryHTMLProvider 的
        // kHTMLMaxBytes）。三处做同一件事却两套上限属实现不一致，且实测有真实站点因此
        // 被整页拒绝（coverr.co：HTML 约 9.7 MB，报「页面内容超过 2 MB 安全上限」、
        // 一个资源都探不到）。这里对齐为 8 MB；超过 8 MB 的页面仍按原策略拒绝。
        _maxHTMLBytes=8*1024*1024;
        _requestTimeout=12.0;
        _contexts=[NSMutableDictionary dictionary];
        _stateQueue=dispatch_queue_create("zz.static-html-probe.state",DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg=configuration ? [configuration copy]
                                                     : NSURLSessionConfiguration.ephemeralSessionConfiguration;
        // The session is shared by all detail probes.  Keep it aligned with
        // the controller's bounded probe concurrency so one origin is not
        // flooded when a listing has many entries.
        cfg.HTTPMaximumConnectionsPerHost=8;
        cfg.timeoutIntervalForRequest=_requestTimeout;
        cfg.timeoutIntervalForResource=_requestTimeout;
        cfg.URLCache=nil;
        cfg.HTTPCookieStorage=nil; cfg.URLCredentialStorage=nil; cfg.HTTPShouldSetCookies=NO;
        _session=[NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    return self;
}

- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(void (^)(NSArray<DetectedMedia *> *, NSError *))completion {
    return [self startURL:pageURL mediaCompletion:completion htmlCompletion:nil];
}

- (nullable id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    return [self startURL:url mediaCompletion:nil htmlCompletion:completion];
}

- (nullable id)startURL:(NSURL *)pageURL
        mediaCompletion:(void (^)(NSArray<DetectedMedia *> *, NSError *))mediaCompletion
         htmlCompletion:(ZZDiscoveryHTMLCompletion)htmlCompletion {
    return [self startURL:pageURL mediaCompletion:mediaCompletion htmlCompletion:htmlCompletion byteLimit:self.maxHTMLBytes];
}

- (id)startURL:(NSURL *)pageURL mediaCompletion:(void (^)(NSArray<DetectedMedia *> *, NSError *))mediaCompletion
 htmlCompletion:(ZZDiscoveryHTMLCompletion)htmlCompletion byteLimit:(NSUInteger)byteLimit {
    ZZStaticHTMLProbeContext *ctx=[ZZStaticHTMLProbeContext new];
    ctx.originalURL=pageURL;
    ctx.byteLimit=byteLimit;
    ctx.data=[NSMutableData data];
    ctx.mediaCompletion=[mediaCompletion copy];
    ctx.htmlCompletion=[htmlCompletion copy];
    if(!pageURL||![self.gate isTextAllowed:pageURL]){
        NSError *error=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                           code:ZZResourceDiscoveryErrorInvalidURL
                                       userInfo:@{NSLocalizedDescriptionKey:@"页面地址未通过安全校验"}];
        dispatch_async(dispatch_get_main_queue(),^{
            if(ctx.cancelled)return;
            if(mediaCompletion)mediaCompletion(@[],error);
            if(htmlCompletion)htmlCompletion(nil,nil,error);
        });
        return ctx;
    }
    __weak typeof(self) w=self;
    [self.gate verifyURLAsync:pageURL completion:^(URLPolicyDecision *decision) {
        __strong typeof(w) s=w;
        if(!s||ctx.cancelled)return;
        if(!decision.allowed){
            [s finishContext:ctx media:@[]
                       error:[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                                code:ZZResourceDiscoveryErrorPermissionDenied
                                            userInfo:@{NSLocalizedDescriptionKey:decision.userMessage ?: @"页面地址被安全策略拒绝"}]];
            return;
        }
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:pageURL
                                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                         timeoutInterval:s.requestTimeout];
        [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15"
       forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"text/html,application/xhtml+xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
        // HTML 必须完整读取；固定 Range 会让服务器只返回前 128KB，
        // 从而漏掉详情页后部的 source/清晰度。
        NSURLSessionDataTask *task=[s.session dataTaskWithRequest:request];
        ctx.task=task;
        dispatch_sync(s.stateQueue,^{ s.contexts[@(task.taskIdentifier)]=ctx; });
        [task resume];
    }];
    return ctx;
}

- (void)cancelProbe:(id)probeToken {
    ZZStaticHTMLProbeContext *ctx=[probeToken isKindOfClass:ZZStaticHTMLProbeContext.class]?probeToken:nil;
    if(!ctx)return;
    ctx.cancelled=YES;
    [self cancelProbe:ctx.scriptToken];
    ctx.scriptToken=nil;
    ctx.mediaCompletion=nil;
    ctx.htmlCompletion=nil;
    [ctx.task cancel];
    if(ctx.task)dispatch_async(self.stateQueue,^{ [self.contexts removeObjectForKey:@(ctx.task.taskIdentifier)]; });
}

- (void)cancelHTMLRequest:(id)requestToken {
    [self cancelProbe:requestToken];
}

- (ZZStaticHTMLProbeContext *)contextForTask:(NSURLSessionTask *)task {
    __block ZZStaticHTMLProbeContext *ctx=nil;
    dispatch_sync(self.stateQueue,^{ ctx=self.contexts[@(task.taskIdentifier)]; });
    return ctx;
}

- (void)finishContext:(ZZStaticHTMLProbeContext *)ctx
                 media:(NSArray<DetectedMedia *> *)media
                  error:(NSError *)error {
    @synchronized(ctx){
        if(ctx.finished||ctx.cancelled)return;
        ctx.finished=YES;
    }
    if(ctx.task)dispatch_async(self.stateQueue,^{ [self.contexts removeObjectForKey:@(ctx.task.taskIdentifier)]; });
    void (^mediaCompletion)(NSArray<DetectedMedia *> *,NSError *)=ctx.mediaCompletion;
    ZZDiscoveryHTMLCompletion htmlCompletion=ctx.htmlCompletion;
    ctx.mediaCompletion=nil;
    ctx.htmlCompletion=nil;
    NSError *finalError = error ?: (media.count ? nil : ctx.pageError);
    if(mediaCompletion)dispatch_async(dispatch_get_main_queue(),^{ if(!ctx.cancelled)mediaCompletion(media ?: @[],finalError); });
    if(htmlCompletion)dispatch_async(dispatch_get_main_queue(),^{ if(!ctx.cancelled)htmlCompletion(nil,nil,error); });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:task];
    NSURL *target=request.URL;
    if(!ctx||ctx.cancelled||ctx.finished||!target){ completionHandler(nil); return; }
    if(++ctx.redirectCount>5){completionHandler(nil);[task cancel];return;}
    URLPolicyDecision *text=[self.policy evaluateRedirect:target fromURL:response.URL ?: task.currentRequest.URL];
    if(!text.allowed){
        ctx.redirectError=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                              code:ZZResourceDiscoveryErrorPermissionDenied
                                          userInfo:@{NSLocalizedDescriptionKey:text.userMessage ?: @"重定向被安全策略拒绝"}];
        completionHandler(nil);
        [task cancel];
        return;
    }
    [self.gate verifyURLAsync:target completion:^(URLPolicyDecision *decision) {
        if(ctx.cancelled){ completionHandler(nil); return; }
        if(!decision.allowed){
            ctx.redirectError=[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                                  code:ZZResourceDiscoveryErrorPermissionDenied
                                              userInfo:@{NSLocalizedDescriptionKey:decision.userMessage ?: @"重定向地址被安全策略拒绝"}];
            completionHandler(nil);
            [task cancel];
            return;
        }
        completionHandler(request);
    }];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:dataTask];
    if(!ctx||ctx.cancelled){ completionHandler(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)response:nil;
    if(http.statusCode<200||http.statusCode>=300){
        completionHandler(NSURLSessionResponseCancel);
        [self finishContext:ctx media:@[]
                     error:[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                              code:http.statusCode
                                          userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HTTP %ld",(long)http.statusCode]}]];
        return;
    }
    // 直链媒体/流清单：不下载正文，直接由 URL 生成一条媒体条目（见上方分流函数注释）。
    // 用重定向之后的有效地址：直链媒体常跳转到 CDN，那个才是真正可下载的地址。
    DetectedMedia *directMedia = SHPDetectedMediaForDirectResponse(http, http.URL ?: ctx.originalURL);
    if (directMedia) {
        completionHandler(NSURLSessionResponseCancel);
        [dataTask cancel];
        [self finishContext:ctx media:@[directMedia] error:nil];
        return;
    }
    if(response.expectedContentLength>(long long)ctx.byteLimit){
        ctx.bodyLimitExceeded=YES;
        completionHandler(NSURLSessionResponseCancel);
        [dataTask cancel];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:dataTask];
    if(!ctx||ctx.cancelled)return;
    // Charge even rejected chunks, so oversized/failed scripts cannot reset
    // the page-wide budget. NSURLSession may deliver one in-flight excess chunk.
    ctx.receivedBytes=MIN(ctx.receivedBytes,NSUIntegerMax-data.length)+data.length;
    if(data.length>ctx.byteLimit-ctx.data.length){
        ctx.bodyLimitExceeded=YES;
        [dataTask cancel];
        return;
    }
    [ctx.data appendData:data];
    // 媒体标签可能位于页面尾部；等待完整响应后统一解析，确保所有清晰度/格式都进入结果。
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    ZZStaticHTMLProbeContext *ctx=[self contextForTask:task];
    if(!ctx||ctx.cancelled)return;
    if(ctx.redirectError){ [self finishContext:ctx media:@[] error:ctx.redirectError]; return; }
    if(ctx.bodyLimitExceeded){
        [self finishContext:ctx media:@[]
                     error:[NSError errorWithDomain:ZZStaticHTMLPageProbeErrorDomain
                                              code:NSURLErrorDataLengthExceedsMaximum
                                          userInfo:@{NSLocalizedDescriptionKey:@"页面内容超过 2 MB 安全上限"}]];
        return;
    }
    if(error){
        [self finishContext:ctx media:@[] error:error];
        return;
    }
    // 编码嗅探：Latin-1 兜底对任意字节恒成功，必须在兜底之前先按声明解码。
    NSString *metaSnippet = [[NSString alloc] initWithData:[ctx.data subdataWithRange:NSMakeRange(0, MIN(ctx.data.length, (NSUInteger)2048))] encoding:NSISOLatin1StringEncoding] ?: @"";
    NSString *html = SHPDecodeHTML(ctx.data, task.response, metaSnippet);
    if(ctx.htmlCompletion){
        ZZDiscoveryHTMLCompletion completion=ctx.htmlCompletion;
        ctx.htmlCompletion=nil;
        ctx.finished=YES;
        dispatch_async(self.stateQueue,^{ [self.contexts removeObjectForKey:@(task.taskIdentifier)]; });
        dispatch_async(dispatch_get_main_queue(),^{ if(!ctx.cancelled)completion(html,task.currentRequest.URL ?: ctx.originalURL,nil); });
        return;
    }
    RDProbeResult *result=[RDProbeAnalyzer analyzeHTML:html baseURL:task.currentRequest.URL ?: ctx.originalURL];
    if(result.isBadPage)ctx.pageError=[NSError errorWithDomain:ZZResourceDiscoveryErrorDomain code:ZZResourceDiscoveryErrorUnrecognizedPage
        userInfo:@{NSLocalizedDescriptionKey:@"页面无法识别，请检查页面内容或稍后重试"}];
    dispatch_async(dispatch_get_main_queue(), ^{
        if(ctx.cancelled||ctx.finished)return;
        NSURL *finalPageURL=task.currentRequest.URL ?: ctx.originalURL;
        ctx.documentBaseURL=[RDStaticScriptAnalyzer documentBaseURLInHTML:html baseURL:finalPageURL];
        ctx.collectedMedia=[(result.media ?: @[]) mutableCopy];
        ctx.scriptURLs=[RDStaticScriptAnalyzer scriptURLsInHTML:html ?: @"" baseURL:task.currentRequest.URL ?: ctx.originalURL limit:6];
        // Sequential, one-level enrichment: <=6 files, 256 KiB/file, 1 MiB
        // combined bodies, four seconds total. HTML results survive every failure.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            [self finishScripts:ctx];
        });
        [self nextScript:ctx];
    });
}

- (void)finishScripts:(ZZStaticHTMLProbeContext *)ctx {
    if(ctx.cancelled||ctx.finished||ctx.scriptsDone)return;
    ctx.scriptsDone=YES;
    [self cancelProbe:ctx.scriptToken];ctx.scriptToken=nil;
    NSMutableArray *unique=[NSMutableArray array];NSMutableSet *keys=[NSMutableSet set];
    for(DetectedMedia *media in ctx.collectedMedia){
        NSString *key=[DetectedMedia dedupKeyForURL:media.mediaURL];
        if(!key.length||[keys containsObject:key])continue;
        [keys addObject:key];media.sourcePageURL=ctx.originalURL.absoluteString;[unique addObject:media];
    }
    [self verifyMediaCandidates:unique context:ctx];
}

- (void)nextScript:(ZZStaticHTMLProbeContext *)ctx {
    if(ctx.cancelled||ctx.finished||ctx.scriptsDone)return;
    if(ctx.scriptIndex>=ctx.scriptURLs.count||ctx.scriptBytes>=1024*1024||ctx.collectedMedia.count>=500){[self finishScripts:ctx];return;}
    NSURL *scriptURL=ctx.scriptURLs[ctx.scriptIndex++];
    __block ZZStaticHTMLProbeContext *child;
    child=[self startURL:scriptURL mediaCompletion:nil htmlCompletion:^(NSString *text,NSURL *finalURL,NSError *error){
        if(ctx.cancelled||ctx.finished||ctx.scriptsDone)return;
        ctx.scriptBytes=MIN(ctx.scriptBytes,NSUIntegerMax-child.receivedBytes)+child.receivedBytes;
        if(!error&&text.length){
            NSArray *found=[RDStaticScriptAnalyzer mediaInScript:text
                                                       scriptURL:finalURL ?: scriptURL
                                                     sourcePage:ctx.originalURL
                                               documentBaseURL:ctx.documentBaseURL ?: (ctx.originalURL ?: scriptURL)];
            [ctx.collectedMedia addObjectsFromArray:[found subarrayWithRange:NSMakeRange(0,MIN(found.count,500-ctx.collectedMedia.count))]];
        }
        ctx.scriptToken=nil;
        [self nextScript:ctx];
    } byteLimit:MIN((NSUInteger)256*1024,(NSUInteger)1024*1024-ctx.scriptBytes)];
    ctx.scriptToken=child;
}

// 页面发现的媒体候选与页面地址执行同一安全标准（URLPolicy）：
// 文本阶段同步校验（scheme/localhost/IP 字面量/私网字样），通过者再逐一
// 异步 DNS 解析并逐 IP 预校验（不是实际 peer-IP 绑定）；拒绝即剔除该候选，
// 全部拒绝时以空结果完成（不透传被策略拒绝的 URL）。
- (void)verifyMediaCandidates:(NSArray<DetectedMedia *> *)media
                      context:(ZZStaticHTMLProbeContext *)ctx {
    if (!media.count) {
        [self finishContext:ctx media:@[] error:nil];
        return;
    }
    NSMutableArray<DetectedMedia *> *pending = [NSMutableArray array];
    for (DetectedMedia *m in media) {
        NSURL *u = [NSURL URLWithString:m.mediaURL ?: @""];
        if (u && [self.gate textDecisionForURL:u].allowed && u.host.length) {
            [pending addObject:m];
        }
    }
    if (!pending.count) {
        [self finishContext:ctx media:@[] error:nil];
        return;
    }
    NSMutableArray<DetectedMedia *> *approved = [NSMutableArray array];
    __block NSUInteger remaining = pending.count;
    __weak typeof(self) w = self;
    for (DetectedMedia *m in pending) {
        [self.gate verifyURLAsync:[NSURL URLWithString:m.mediaURL]
                       completion:^(URLPolicyDecision *decision) {
            __strong typeof(w) s = w;
            if (!s) return;
            if (ctx.cancelled) return;   // 校验期间被取消：finishContext 已作废
            if (decision.allowed) [approved addObject:m];
            remaining -= 1;
            if (remaining == 0 && !ctx.finished) {
                [s finishContext:ctx media:[approved copy] error:nil];
            }
        }];
    }
}

@end
