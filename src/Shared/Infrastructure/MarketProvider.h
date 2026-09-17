//
//  MarketProvider.h — 模块 08（接口声明，模块 16 接入）
//
#import <Foundation/Foundation.h>
#import "HTTPClient.h"

NS_ASSUME_NONNULL_BEGIN

@protocol MarketProvider <NSObject>
// 拉取美股数据；模块 16 实现。completion 在主线程回调（取消后不回调）。
- (HTTPTask *)fetchMarketDataWithCompletion:(void (^)(HTTPResult *result))completion;
// 解析美股 JSON（模块 16 实现具体解析）
- (nullable id)parseMarketJSON:(NSData *)data error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
