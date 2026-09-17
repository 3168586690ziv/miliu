#import <Cocoa/Cocoa.h>
#import "DetectedMedia.h"

NS_ASSUME_NONNULL_BEGIN

/// 结果列表的行视图：纯视图组合（类型徽章 + 标题 + 元数据行），
/// 不使用 NSTableCellView / NSCell，也不依赖 makeViewWithIdentifier 的裸文本复用。
@interface ResourceResultRowView : NSView
@property (nonatomic, strong) DetectedMedia *media;
- (void)configureWithMedia:(DetectedMedia *)media;
/// durationHint：已知时长（如 "12:34"）时显示在元数据行；nil/空则跳过
- (void)configureWithMedia:(DetectedMedia *)media durationHint:(nullable NSString *)durationHint;
/// sizeHint：已格式化的显式大小文本（如 "100.6 MB"）。
/// 用户为该行选定了某个画质档位时，行摘要必须显示该档位的大小，而不是
/// 发现时的默认档位大小；nil/空则按 media.sizeBytes 自行格式化。
- (void)configureWithMedia:(DetectedMedia *)media
              durationHint:(nullable NSString *)durationHint
                  sizeHint:(nullable NSString *)sizeHint;
@end

NS_ASSUME_NONNULL_END
