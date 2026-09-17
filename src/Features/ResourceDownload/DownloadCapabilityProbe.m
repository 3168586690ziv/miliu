#import "DownloadCapabilityProbe.h"
#import "RDNetworkValidation.h"
#import "HTTPPrivacyPolicy.h"
@interface ZZCapabilityDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic,copy) void (^completion)(ZZDownloadCapability *);
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) ZZDownloadCapability *capability;
@property(nonatomic) BOOL finished;
@property(nonatomic,strong) NSDate *startedAt;
@property(nonatomic) BOOL receivedHeaders;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) URLPolicy *policy;
@end
@implementation ZZDownloadCapability
@end
@implementation ZZCapabilityDelegate
- (void)finish:(ZZDownloadCapability *)cap { if(self.finished)return; self.finished=YES; if(self.completion)self.completion(cap); self.completion=nil; [self.session invalidateAndCancel]; self.session=nil; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    URLPolicyDecision *redirect = [self.policy evaluateRedirect:request.URL fromURL:response.URL];
    if (!redirect.allowed) {
        handler(nil);
        ZZDownloadCapability *c = [ZZDownloadCapability new]; c.failureReason = redirect.userMessage;
        [self finish:c]; return;
    }
    RDValidateNetworkURL(request.URL,self.policy,nil,^(URLPolicyDecision *decision) {
        if (self.finished) { handler(nil); return; }
        if (!decision.allowed) { handler(nil); ZZDownloadCapability *c=[ZZDownloadCapability new]; c.failureReason=decision.userMessage; [self finish:c]; return; }
        NSMutableURLRequest *next=[request mutableCopy];
        for (NSString *header in @[@"Range",@"Accept-Encoding",@"User-Agent"]) [next setValue:[task.originalRequest valueForHTTPHeaderField:header] forHTTPHeaderField:header];
        NSMutableURLRequest *previous = [task.currentRequest mutableCopy]; previous.URL = response.URL;
        [HTTPPrivacyPolicy sanitizeRedirectRequest:next fromRequest:previous];
        handler(next);
    });
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    NSHTTPURLResponse *h=[response isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)response:nil;
    ZZDownloadCapability *c=[ZZDownloadCapability new]; c.finalURL=response.URL?:task.currentRequest.URL; c.statusCode=h.statusCode;
    c.contentLength=response.expectedContentLength>0?response.expectedContentLength:0;
    NSString *cr=[h valueForHTTPHeaderField:@"Content-Range"]?:@""; NSRange slash=[cr rangeOfString:@"/"];
    if(slash.location!=NSNotFound&&slash.location+1<cr.length){int64_t n=[[cr substringFromIndex:slash.location+1]longLongValue];if(n>0)c.contentLength=n;}
    // 错误页/网页响应不是媒体：绝不把它的 Content-Length 当成视频大小回填任务，
    // 否则一个 143 字节的 HTML 错误页会让任务带着 143 字节的“预期长度”进入下载，
    // 50MB 预期被抹掉、短文件校验随之失效。
    NSString *ctype=[[h valueForHTTPHeaderField:@"Content-Type"]lowercaseString]?:@"";
    BOOL looksLikeMedia=[ctype hasPrefix:@"video/"]||[ctype isEqualToString:@"application/octet-stream"]
        ||[ctype hasPrefix:@"image/"]||[ctype hasPrefix:@"audio/"]||[ctype containsString:@"mpegurl"]||ctype.length==0;
    if(h.statusCode<200||h.statusCode>=300||!looksLikeMedia){
        c.contentLength=0; c.rangeSupported=NO; c.etag=@""; c.lastModified=@"";
        c.failureReason=[NSString stringWithFormat:@"能力探测返回 %ld（非媒体响应）",(long)h.statusCode];
    }
    NSString *ar=[[h valueForHTTPHeaderField:@"Accept-Ranges"]lowercaseString]?:@"";
    c.rangeSupported=(looksLikeMedia && h.statusCode==206&&(cr.length>0||[ar containsString:@"bytes"]));
    if (looksLikeMedia && h.statusCode >= 200 && h.statusCode < 300) {
        c.etag=[h valueForHTTPHeaderField:@"ETag"]?:@"";
        c.lastModified=[h valueForHTTPHeaderField:@"Last-Modified"]?:@"";
    } else {
        c.etag=@"";
        c.lastModified=@"";
    }
    self.capability=c; self.receivedHeaders=YES; handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.finished || !data.length) return;
    ZZDownloadCapability *c=self.capability ?: [ZZDownloadCapability new];
    c.bodyResponsive=YES;
    c.firstByteLatency=self.startedAt ? -[self.startedAt timeIntervalSinceNow] : 0;
    self.capability=c; [task cancel]; [self finish:c];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { if(self.finished)return; ZZDownloadCapability *c=self.capability?:[ZZDownloadCapability new]; c.failureReason=error.localizedDescription?:@"能力探测失败"; [self finish:c]; }
@end
@interface DownloadCapabilityProbe () @property(nonatomic,strong) NSMutableArray<ZZCapabilityDelegate *> *delegates; @end
@implementation DownloadCapabilityProbe
- (instancetype)init { if((self=[super init])){_delegates=[NSMutableArray array];_urlPolicy=[URLPolicy new];} return self; }
- (void)probeURL:(NSURL *)url referer:(NSString *)referer completion:(void (^)(ZZDownloadCapability * _Nullable))completion {
    if(!url||!url.scheme.length||!url.host.length){if(completion)completion(nil);return;}
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10]; r.HTTPMethod=@"GET"; [r setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"]; [r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"]; [r setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"]; if(referer.length)[r setValue:referer forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    ZZCapabilityDelegate *d=[ZZCapabilityDelegate new]; d.startedAt=[NSDate date]; __weak typeof(self) w=self; __weak ZZCapabilityDelegate *weakD=d; d.completion=^(ZZDownloadCapability *c){dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(c);}); ZZCapabilityDelegate *strongD=weakD; if(strongD)[w.delegates removeObject:strongD];}; [self.delegates addObject:d];
    NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration; cfg.URLCache=nil; cfg.HTTPMaximumConnectionsPerHost=2; cfg.timeoutIntervalForRequest=10; cfg.HTTPCookieStorage=nil;cfg.URLCredentialStorage=nil;cfg.HTTPShouldSetCookies=NO;
    d.policy=self.urlPolicy;
    NSURLSession *s=[NSURLSession sessionWithConfiguration:cfg delegate:d delegateQueue:[NSOperationQueue mainQueue]]; d.session=s; d.task=[s dataTaskWithRequest:r];
    RDValidateNetworkURL(url,d.policy,nil,^(URLPolicyDecision *decision) {
        if(d.finished)return;
        if(!decision.allowed){ZZDownloadCapability *c=[ZZDownloadCapability new];c.failureReason=decision.userMessage;[d finish:c];return;}
        [d.task resume];
    });
    __weak ZZCapabilityDelegate *wd=d;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZZCapabilityDelegate *sd=wd; if (!sd || sd.finished) return;
        ZZDownloadCapability *c=sd.capability ?: [ZZDownloadCapability new]; c.bodyResponsive=NO; c.firstByteLatency=10.0; c.rangeSupported=NO;
        c.failureReason=sd.receivedHeaders ? @"服务器响应头已到达，但首字节超时" : @"能力探测超时";
        [sd.task cancel]; [sd finish:c];
    });
}
- (void)cancel { for(ZZCapabilityDelegate *d in [self.delegates copy]){ d.completion=nil; [d finish:[ZZDownloadCapability new]]; } [self.delegates removeAllObjects]; }
@end
