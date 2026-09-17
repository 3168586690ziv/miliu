#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// All public operations and completions are main-queue confined. Cancel suppresses delivery.
@interface RDMetadataToken : NSObject
@property (nonatomic, readonly) BOOL cancelled;
- (void)cancel;
- (void)addCancellation:(dispatch_block_t)block;
@end

@interface RDMetadataResponse : NSObject
@property (nonatomic, strong, nullable) NSData *data;
@property (nonatomic, strong, nullable) NSHTTPURLResponse *response;
@property (nonatomic, strong, nullable) NSError *error;
@end

typedef NSArray<NSString *> *_Nullable (^RDMetadataResolver)(NSString *host);
@protocol RDMetadataTransporting <NSObject>
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion;
@end

// Ephemeral, no cookies/cache/credentials. Every URL and redirect is validated with URLPolicy
// and ALL DNS answers before starting/following it. protocolClasses is for offline tests only.
@interface RDMetadataTransport : NSObject <RDMetadataTransporting>
- (instancetype)initWithResolver:(nullable RDMetadataResolver)resolver
                protocolClasses:(nullable NSArray<Class> *)classes;
@end

FOUNDATION_EXPORT NSString * const RDMetadataErrorDomain;
/// 对冲请求延迟（公开给性能回归测试，避免把连接级卡顿预算写死在测试中）。
FOUNDATION_EXPORT NSTimeInterval RDMetadataHedgeDelay(void);
typedef NS_ENUM(NSInteger, RDMetadataError) {
    RDMetadataBlocked = 1, RDMetadataBudgetExceeded, RDMetadataTimedOut, RDMetadataHTTPFailure
};

NS_ASSUME_NONNULL_END
