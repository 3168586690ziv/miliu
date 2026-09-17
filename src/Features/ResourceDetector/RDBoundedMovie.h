#import <Foundation/Foundation.h>
#import "RDMetadataTransport.h"
NS_ASSUME_NONNULL_BEGIN
// Every byte goes through the caller's policy-enforcing transport. No AV remote URL.
typedef void (^RDRangeRequest)(NSDictionary *headers, NSUInteger budget, void (^done)(RDMetadataResponse *));
@interface RDBoundedMovie : NSObject
+ (void)readWithRequest:(RDRangeRequest)request completion:(void (^)(NSDictionary * _Nullable metadata, NSError * _Nullable error))completion;
// 以服务层前缀探测带回的已校验头部数据（bytes=0-… 前缀）与 Content-Range
// 总长为初始缓冲：窗口内结构本地解析，缺口才发 Range 请求，不重复取头部。
+ (void)readWithHeadData:(NSData * _Nullable)head total:(uint64_t)total etag:(NSString * _Nullable)etag request:(RDRangeRequest)request completion:(void (^)(NSDictionary * _Nullable metadata, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
