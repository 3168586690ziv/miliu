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
/// 性能模式即时切换（2026-10-02 第18轮）：立即把窗口与上限设为新档位值——
/// 降档立即收缩（空闲槽位不再分配），升档立即放开。调用方传入
/// PerformancePolicy 当前档位的连接数（省电 2 / 标准 20）。
- (void)applyModeWindow:(NSInteger)window maximum:(NSInteger)maximum;
@end
NS_ASSUME_NONNULL_END
