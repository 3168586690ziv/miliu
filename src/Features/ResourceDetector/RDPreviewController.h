//
//  RDPreviewController.h — 视频预览播放编排：不下载、直接流式预览（第 35 轮）
//
//  实测定案（第 35 轮 Spike，本地夹具+服务器日志实证）：
//  - AVPlayer 直连 http(s)：mp4 与 HLS（含 AES-128）可播，AVURLAssetHTTPHeaderFieldsKey
//    的 Referer 作用于全部子请求（清单/分片/key）；
//  - resource loader 路线不可行（播放管线由系统 daemon 拉流，loader 数据进不去）；
//  - 档位钉选 = 本地环回服务器返回「只含所选变体的改写 master」（分片 URL 为远程绝对地址，
//    AVPlayer 直连拉取）。
//

#import <Foundation/Foundation.h>

@class DetectedMedia;
@class URLPolicy;

NS_ASSUME_NONNULL_BEGIN

@interface RDPreviewController : NSObject

/// 主线程调用。判定 → URLPolicy 事前校验 →（HLS 钉选场景：拉取 master、改写、环回 serve）
/// → AVPlayer → 预览窗口。拒绝与失败都以可读文案显示在预览窗口内，不静默失败。
+ (void)startPreviewForMedia:(nullable DetectedMedia *)media policy:(nullable URLPolicy *)policy;

/// 停止播放、回收环回服务器与 KVO（关窗动作由 RDPreviewWindow 负责）。
+ (void)stopPreview;

/// 预览是否在进行中（供档位切换联动：active 时切档应重启预览）。
+ (BOOL)isPreviewActive;

@end

NS_ASSUME_NONNULL_END
