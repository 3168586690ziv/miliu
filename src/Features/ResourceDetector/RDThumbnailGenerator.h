//
//  RDThumbnailGenerator.h — 模块 17｜异步缩略图生成
//
//  仅使用 AVAssetImageGenerator 的异步 API（generateCGImageAsynchronouslyForTime:），
//  不调用已弃用的同步 copyCGImageAtTime:actualTime:error:，并支持取消保护，
//  避免旧结果回调到已失效的 UI。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>
#import "AppError.h"

NS_ASSUME_NONNULL_BEGIN

@interface RDThumbnailGenerator : NSObject
// 可复用；新请求自动取代旧请求。成功/失败在主队列回调，取消/被取代的请求不回调。
// 成功回调获得 +1 CGImage，调用方必须 CGImageRelease（可在回调返回后使用）。
// completion 可重入 cancel/生成新请求；不要在其中同步等待其他线程调用本对象。
- (void)generateThumbnailForURL:(NSURL *)url
                          atTime:(CMTime)time
                      completion:(void (^)(CGImageRef _Nullable image, AppError * _Nullable error))completion;
// 带来源页 Referer 的变体：防盗链站点必须带 Referer 才能加载视频帧
- (void)generateThumbnailForURL:(NSURL *)url
                          atTime:(CMTime)time
                         referer:(nullable NSString *)referer
                      completion:(void (^)(CGImageRef _Nullable image, AppError * _Nullable error))completion;
- (void)cancel;  // 取消进行中的生成；已失效的回调不再触发完成
@end

NS_ASSUME_NONNULL_END
