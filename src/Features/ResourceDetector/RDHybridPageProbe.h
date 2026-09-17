#import "ResourceDiscoveryCoordinator.h"
#import "URLPolicy.h"
#import "WebProbe.h"
@interface RDHybridPageProbe : NSObject <ZZDiscoveryPageProbing, ZZDiscoveryHTMLProviding>
- (instancetype)initWithPolicy:(URLPolicy *)policy;
// Independent loaders per page keep simultaneous scans and refreshes isolated.
@property (nonatomic,copy) id<RDProbeLoader> (^loaderFactory)(void);
@end
