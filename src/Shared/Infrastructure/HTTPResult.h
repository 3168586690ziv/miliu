//
//  HTTPResult.h — 模块 08
//
#import <Foundation/Foundation.h>
#import "AppError.h"

NS_ASSUME_NONNULL_BEGIN

@interface HTTPResult : NSObject
@property (nonatomic, strong, nullable) NSData *data;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong, nullable) AppError *error;
@property (nonatomic, copy) NSString *source;        // @"cache" / @"live"
@property (nonatomic, copy) NSDate *fetchedAt;
@property (nonatomic, assign) BOOL isExpired;          // 缓存过期
@property (nonatomic, copy, nullable) NSString *contentType;
- (BOOL)isSuccess;
@end

NS_ASSUME_NONNULL_END
