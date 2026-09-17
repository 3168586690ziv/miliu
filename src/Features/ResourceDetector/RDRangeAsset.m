#import "RDRangeAsset.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
@interface RDRangeAsset ()
@property AVURLAsset *asset;
@property long long length;
@property NSString *etag;
@property (copy) RDRangeRequest request;
@property NSMutableSet<AVAssetResourceLoadingRequest *> *pending;
@property BOOL cancelled;
@end
@implementation RDRangeAsset
- (instancetype)initWithLength:(long long)length etag:(NSString *)etag request:(RDRangeRequest)request {
    if ((self=[super init])) {
        _length=length; _etag=etag; _request=request; _pending=[NSMutableSet set];
        _asset=[AVURLAsset URLAssetWithURL:[NSURL URLWithString:@"rdverified://media/movie.mp4"] options:nil];
        [_asset.resourceLoader setDelegate:self queue:dispatch_get_main_queue()];
    } return self;
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loading {
    if (_cancelled || ![loading.request.URL.absoluteString isEqual:@"rdverified://media/movie.mp4"]) {
        [loading finishLoadingWithError:[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBlocked userInfo:nil]]; return YES;
    }
    [_pending addObject:loading];
    loading.contentInformationRequest.contentType=UTTypeMPEG4Movie.identifier;
    loading.contentInformationRequest.contentLength=_length;
    loading.contentInformationRequest.byteRangeAccessSupported=YES;
    [self fill:loading]; return YES;
}
- (void)fill:(AVAssetResourceLoadingRequest *)loading {
    if (_cancelled || ![_pending containsObject:loading]) return;
    AVAssetResourceLoadingDataRequest *d=loading.dataRequest;
    long long start=MAX(d.currentOffset,d.requestedOffset);
    if (!d || start>=_length || (!d.requestsAllDataToEndOfResource && start-d.requestedOffset>=d.requestedLength)) {
        [_pending removeObject:loading]; [loading finishLoading]; return;
    }
    long long remaining=d.requestsAllDataToEndOfResource?_length-start:MIN(_length-start,d.requestedLength-(start-d.requestedOffset));
    NSUInteger count=(NSUInteger)MIN(remaining,1024*1024);
    if (start<0 || !count) { [_pending removeObject:loading]; [loading finishLoadingWithError:[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBlocked userInfo:nil]]; return; }
    // 与 RDBoundedMovie 一致：不发 If-Match（Hanime CDN 返回 412），用 Content-Range 几何校验。
    NSDictionary *headers=@{@"Range":[NSString stringWithFormat:@"bytes=%lld-%lld",start,start+count-1],@"Accept-Encoding":@"identity"};
    _request(headers,count,^(RDMetadataResponse *r) {
        if (self.cancelled || ![self.pending containsObject:loading]) return;
        NSString *expected=[NSString stringWithFormat:@"bytes %lld-%lld/%lld",start,start+count-1,self.length];
        BOOL valid=!r.error && r.response.statusCode==206 && r.data.length==count && [[r.response valueForHTTPHeaderField:@"Content-Range"] isEqual:expected];
        if (!valid) { [self.pending removeObject:loading]; [loading finishLoadingWithError:r.error?:[NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBlocked userInfo:nil]]; return; }
        [d respondWithData:r.data]; [self fill:loading];
    });
}
- (void)resourceLoader:(AVAssetResourceLoader *)loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loading { [_pending removeObject:loading]; }
- (void)cancel {
    _cancelled=YES;
    for (AVAssetResourceLoadingRequest *r in _pending.allObjects) [r finishLoadingWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    [_pending removeAllObjects]; [_asset cancelLoading];
}
@end
