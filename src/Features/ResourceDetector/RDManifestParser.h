#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 轻量、离线可测试的 HLS/DASH 结构化摘要。只解析清单元数据，不下载分片，
/// 不尝试绕过 DRM；所有 URL 均按 baseURL 绝对化。
@interface RDManifestParser : NSObject
/// 单次清单正文上限，超过后拒绝解析，避免恶意/失控清单耗尽内存。
+ (NSUInteger)maxManifestBytes;
+ (NSDictionary *)parseManifest:(NSString *)text baseURL:(NSURL *)baseURL;
+ (NSDictionary *)parseManifest:(NSString *)text
                         baseURL:(NSURL *)baseURL
                           error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
