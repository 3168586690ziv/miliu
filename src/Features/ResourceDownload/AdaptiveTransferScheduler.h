#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Pure, stateful transfer-window controller. It never bypasses server errors;
/// it only grows after stable samples and shrinks on throttling/failure.
@interface AdaptiveTransferScheduler : NSObject
@property(nonatomic,readonly) NSInteger window;
- (instancetype)initWithInitialWindow:(NSInteger)initial maximumWindow:(NSInteger)maximum;
- (NSInteger)recordThroughput:(double)bytesPerSecond error:(BOOL)error throttled:(BOOL)throttled;
/// BUG-044: rates are reduced per active stream before adapting the shared window.
- (NSInteger)recordThroughput:(double)bytesPerSecond error:(BOOL)error
                    throttled:(BOOL)throttled streamIdentifier:(nullable NSString *)identifier;
- (void)removeStreamIdentifier:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
