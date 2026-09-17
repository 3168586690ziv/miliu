//
//  HTTPRequest.h — 模块 08
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HTTPRequest : NSObject
@property (nonatomic, copy) NSURL *url;
@property (nonatomic, copy) NSString *method;       // 默认 GET
@property (nonatomic, assign) NSTimeInterval timeout; // 默认 30
@property (nonatomic, assign) NSInteger maxBodyBytes; // 默认 5MB
@property (nonatomic, assign) BOOL idempotent;       // 仅幂等 GET 可重试
@property (nonatomic, assign) NSInteger retryLimit;   // 默认 2
- (instancetype)initWithURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
