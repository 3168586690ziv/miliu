#import <Foundation/Foundation.h>
#import "DetectedMedia.h"
// Deliberately not a JavaScript interpreter. One-level external scripts only.
@interface RDStaticScriptAnalyzer : NSObject
+ (NSString *)decodeLiteral:(NSString *)literal;
+ (NSArray<NSURL *> *)scriptURLsInHTML:(NSString *)html baseURL:(NSURL *)base limit:(NSUInteger)limit;
+ (NSURL *)documentBaseURLInHTML:(NSString *)html baseURL:(NSURL *)base;
+ (NSArray<DetectedMedia *> *)mediaInScript:(NSString *)script
                                  scriptURL:(NSURL *)url
                                sourcePage:(NSURL *)page;
+ (NSArray<DetectedMedia *> *)mediaInScript:(NSString *)script
                                  scriptURL:(NSURL *)url
                                sourcePage:(NSURL *)page
                          documentBaseURL:(NSURL *)documentBaseURL;
@end
