#import <Foundation/Foundation.h>
#import "URLPolicy.h"
NS_ASSUME_NONNULL_BEGIN
@interface ZZDownloadCapability : NSObject
@property(nonatomic,strong) NSURL *finalURL;
@property(nonatomic) NSInteger statusCode;
@property(nonatomic) int64_t contentLength;
@property(nonatomic) BOOL rangeSupported;
@property(nonatomic) BOOL bodyResponsive;
@property(nonatomic) NSTimeInterval firstByteLatency;
@property(nonatomic,copy) NSString *etag;
@property(nonatomic,copy) NSString *lastModified;
@property(nonatomic,copy) NSString *failureReason;
@end
@interface DownloadCapabilityProbe : NSObject
@property(nonatomic,strong) URLPolicy *urlPolicy;
- (void)probeURL:(NSURL *)url referer:(nullable NSString *)referer completion:(void (^)(ZZDownloadCapability * _Nullable capability))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
