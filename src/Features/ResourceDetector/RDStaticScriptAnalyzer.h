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
/// Dean Edwards packer 解包（第 47 轮：jav.guru / javclan 类站点的播放器地址
/// 整段被 `eval(function(p,a,c,k,e,d){...}('...',36,525,'...'.split('|')))` 混淆，
/// 不解包则静态腿完全看不到 m3u8 地址）。
/// **纯字符串变换，不执行任何脚本**：只按 packer 的字典替换规则还原文本。
/// 输入不是 packer 形态时原样返回；解包结果长度超过上限时放弃（防解压炸弹）。
/// 处理嵌套：解包结果若仍含 packer，最多再解一层（实测该站点两层足够）。
+ (NSString *)unpackDeanEdwardsPacker:(NSString *)source maxBytes:(NSUInteger)maxBytes;
@end
