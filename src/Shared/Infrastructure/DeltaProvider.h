//
//  DeltaProvider.h — 模块 08（接口声明，模块 14 接入）
//
#import <Foundation/Foundation.h>
#import "HTTPClient.h"

NS_ASSUME_NONNULL_BEGIN

@protocol DeltaProvider <NSObject>
// 拉取三角洲情报；模块 14 实现。completion 在主线程回调（取消后不回调）。
- (HTTPTask *)fetchDeltaPayloadWithCompletion:(void (^)(HTTPResult *result))completion;
// 缓存新鲜度判断（业务日期）
- (BOOL)isCacheFresh:(HTTPResult *)cached maxAge:(NSTimeInterval)maxAge;
@end

NS_ASSUME_NONNULL_END
