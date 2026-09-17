#import <AVFoundation/AVFoundation.h>
#import "RDBoundedMovie.h"

@interface RDRangeAsset : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, readonly) AVURLAsset *asset;
- (instancetype)initWithLength:(long long)length etag:(NSString *)etag request:(RDRangeRequest)request;
- (void)cancel;
@end
