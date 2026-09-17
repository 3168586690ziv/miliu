#import <Foundation/Foundation.h>
@interface RDStreamPlan : NSObject
// Each track contains a list of approved-to-be-validated remote resource descriptors.
+ (NSArray<NSDictionary *> *)DASHTracks:(NSString *)manifest baseURL:(NSURL *)base error:(NSError **)error;
+ (NSDictionary *)HLSPlaylist:(NSString *)manifest baseURL:(NSURL *)base error:(NSError **)error;
@end
