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
/// JSON-LD（application/ld+json）正文里的媒体地址字符串提取：只做 JSON 解析与
/// URL 形状过滤，不执行任何脚本。用于 VideoObject 的 contentUrl/embedUrl。
+ (NSArray<NSString *> *)mediaURLStringsInJSONText:(NSString *)text;
@end
