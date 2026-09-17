#import <Foundation/Foundation.h>
#import "DetectedMedia.h"
#import "ResourceDiscoveryCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface RDResourceModeFilter : NSObject
+ (BOOL)allowsMedia:(DetectedMedia *)media mode:(ZZResourceDiscoveryMode)mode;
+ (NSArray<DetectedMedia *> *)allowedMedia:(NSArray<DetectedMedia *> *)media
                                      mode:(ZZResourceDiscoveryMode)mode;
@end

NS_ASSUME_NONNULL_END
