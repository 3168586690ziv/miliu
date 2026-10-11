//
//  RDPreviewEligibility.h — 预览可用性判定（第 35 轮｜预览播放）
//
//  在点「预览」之前回答：这个条目能否用 AVPlayer 直接预览？不能时给出中文
//  可读理由（能力边界对用户可见，文案口径与 RDStreamPlan 的 DRM 提示一致）。
//  纯逻辑：无网络、无文件 IO、无 GUI。
//
//  本头文件刻意不 #import "URLPolicy.h"（它连带 DNSResolver.h，而预览套件
//  preview-playback.sh 编译本组件时不带 Shared/Infrastructure 头路径）；
//  URLPolicy 在签名中仅作指针使用，字段对接见 RDPreviewEligibility.m 顶部
//  的最小接口声明。
//

#import <Foundation/Foundation.h>
#import "DetectedMedia.h"

@class URLPolicy;

typedef NS_ENUM(NSInteger, RDPreviewDecision) {
    RDPreviewDecisionDirectFile,  // 直链渐进式媒体（mp4/m4v/mov/m4a/mp3/aac）→ AVPlayer 直连
    RDPreviewDecisionHLSMaster,   // HLS master playlist（≥2 个声明变体）→ 走环回钉选
    RDPreviewDecisionHLSMedia,    // HLS 媒体清单（无变体，单码率）→ AVPlayer 直连
    RDPreviewDecisionRefused,     // 不可预览
};

NS_ASSUME_NONNULL_BEGIN

@interface RDPreviewVerdict : NSObject
@property (nonatomic, assign, readonly) RDPreviewDecision decision;
/// 仅 RDPreviewDecisionRefused 时非 nil：中文可读理由。
@property (nonatomic, copy, readonly, nullable) NSString *refusalReason;
@end

@interface RDPreviewEligibility : NSObject

/// 预览可用性判定。media 为 nil / 空地址 / 图片 / DRM / 不支持的清单与容器
/// → RDPreviewDecisionRefused 且 refusalReason 给出中文理由；放行时
/// refusalReason 为 nil。直播流（isLive / 清单 isLive / availabilityState）
/// 不因此拒绝：AVPlayer 原生支持直播，与点播走同一格式判定。
+ (RDPreviewVerdict *)verdictForMedia:(nullable DetectedMedia *)media;

/// URLPolicy 事前校验（本组件不做网络）。地址被安全策略拒绝时返回
/// decision = RDPreviewDecisionRefused，refusalReason 原样保留 URLPolicy 的
/// 用户提示；policy 放行（或拿不到决定）返回 nil——nil 表示「无拒绝」。
+ (nullable RDPreviewVerdict *)verdictIfURLAllowed:(NSURL *)url policy:(URLPolicy *)policy;

@end

NS_ASSUME_NONNULL_END
