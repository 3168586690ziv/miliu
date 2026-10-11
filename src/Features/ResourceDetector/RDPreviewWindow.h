//
//  RDPreviewWindow.h — 视频预览播放窗口：探测命中后不下载、直接 AVPlayer 预览（第 35 轮）
//

#import <Foundation/Foundation.h>
@class AVPlayer;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RDPreviewWindowDidCloseNotification;

@interface RDPreviewWindow : NSObject
/// 显示播放窗口并挂上 AVPlayer（attachPlayer 与 showError 互斥：先调哪个显示哪个）
+ (void)attachPlayer:(AVPlayer *)player title:(nullable NSString *)title;
/// 显示错误态（可读理由文案，居中显示；不带播放器）
+ (void)showError:(NSString *)message title:(nullable NSString *)title;
/// 若窗口开着则关闭（主智能体在切换条目时调用）
+ (void)close;
@end

NS_ASSUME_NONNULL_END
