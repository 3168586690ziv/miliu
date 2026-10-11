//
//  RDPreviewEligibility.m — 预览可用性判定实现（第 35 轮｜预览播放）
//
//  判定只依赖条目自带字段（format / resourceKind / drmType / manifestInfo /
//  declaredVariants / mediaURL），不发起网络与 IO。DRM 与加密结论沿用
//  RDManifestParser 的结构化输出（isDrmProtected / isSoftwareDecryptable /
//  isEncrypted / encryptionMethod），与 RDStreamPlan 的拒绝口径同一事实来源：
//  AES-128（含 identity KEYFORMAT）由 AVPlayer 原生解密，不按 DRM 拒。
//

#import "RDPreviewEligibility.h"

// URLPolicy.h 连带 DNSResolver.h，而预览套件（preview-playback.sh）编译本组件
// 时不带 Shared/Infrastructure 头路径，故按 URLPolicy.h 的真实字段名复述判定
// 所需的最小接口（evaluateTextURL: / allowed / userMessage）。运行时链接的是
// URLPolicy.m 的真实类，消息按 selector 分发，两处声明天然一致。
@interface URLPolicyDecision : NSObject
@property (nonatomic, assign) BOOL allowed;
@property (nonatomic, copy) NSString *userMessage;
@end

@interface URLPolicy : NSObject
- (URLPolicyDecision *)evaluateTextURL:(NSString *)urlString;
@end

// AVPlayer 原生 demux + 解码的渐进式媒体白名单（预览直连放行）。
static NSArray<NSString *> *RDDirectPreviewFormats(void) {
    return @[@"mp4", @"m4v", @"mov", @"m4a", @"mp3", @"aac"];
}

// 探测器认识（formatFromURL 口径）但不在预览白名单内的媒体格式：具名拒绝，
// 但不下「系统解码器限制」的结论（wav/3gp 等系统其实能解，只是本版未放行）。
static NSArray<NSString *> *RDNamedUnsupportedFormats(void) {
    return @[@"flac", @"ogg", @"opus", @"wav", @"ogv", @"3gp"];
}

static NSString *RDManifestEncryptionMethod(NSDictionary *manifest) {
    id value = manifest[@"encryptionMethod"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

@interface RDPreviewVerdict ()
@property (nonatomic, assign, readwrite) RDPreviewDecision decision;
@property (nonatomic, copy, readwrite, nullable) NSString *refusalReason;
@end

@implementation RDPreviewVerdict
@end

@implementation RDPreviewEligibility

+ (RDPreviewVerdict *)verdictWithDecision:(RDPreviewDecision)decision reason:(nullable NSString *)reason {
    RDPreviewVerdict *verdict = [[RDPreviewVerdict alloc] init];
    verdict.decision = decision;
    verdict.refusalReason = reason;
    return verdict;
}

+ (RDPreviewVerdict *)refusedWithReason:(NSString *)reason {
    return [self verdictWithDecision:RDPreviewDecisionRefused reason:reason];
}

+ (RDPreviewVerdict *)verdictForMedia:(nullable DetectedMedia *)media {
    if (media == nil) return [self refusedWithReason:@"未找到可预览的媒体条目"];
    if (media.mediaURL.length == 0) return [self refusedWithReason:@"该条目没有可播放的媒体地址"];
    if (media.resourceKind == RDResourceKindImage) return [self refusedWithReason:@"图片内容不支持预览播放"];

    // 条目级 DRM 标记（WebKit 侧信号）优先于清单与格式判断。
    switch (media.drmType) {
        case RDDrmWidevine:         return [self refusedWithReason:@"该流受 Widevine 保护，无法预览；需要授权才能解码"];
        case RDDrmFairPlay:         return [self refusedWithReason:@"该流受 FairPlay 保护，无法预览；需要授权才能解码"];
        case RDDrmPlayReady:        return [self refusedWithReason:@"该流受 PlayReady 保护，无法预览；需要授权才能解码"];
        case RDDrmUnknownProtected: return [self refusedWithReason:@"该站点标记了受保护内容信号，无法预览"];
        case RDDrmNone: break;
    }

    // 清单自述加密（RDManifestParser 结构化输出）。
    NSDictionary *manifest = media.manifestInfo;
    if (manifest.count > 0) {
        NSString *method = RDManifestEncryptionMethod(manifest);
        // AES-128 + identity 软件可解：AVPlayer 原生解密，即便清单带 DRM 标记也
        // 不拒（与 RDStreamPlan 对 AES-128 的放行口径一致）。
        if ([manifest[@"isDrmProtected"] boolValue] && ![manifest[@"isSoftwareDecryptable"] boolValue]) {
            NSString *detail = method.length > 0 ? [NSString stringWithFormat:@"（%@）", method] : @"";
            return [self refusedWithReason:[NSString stringWithFormat:@"该流受 DRM 保护%@，无法预览；需要授权才能解码", detail]];
        }
        // isEncrypted 但未判 DRM：仅非 AES-128/NONE 的加密方式拒（SAMPLE-AES 等）。
        if ([manifest[@"isEncrypted"] boolValue] && method.length > 0 &&
            ![method isEqualToString:@"AES-128"] && ![method isEqualToString:@"NONE"]) {
            return [self refusedWithReason:[NSString stringWithFormat:@"该流使用 %@ 加密，暂不支持预览（AVPlayer 仅支持 AES-128 普通加密）", method]];
        }
    }

    // 直播流不参与拒绝：isLive / 清单 isLive / availabilityState 只作展示状态，
    // AVPlayer 原生支持直播，与点播走同一格式判定。
    NSString *format = (media.format ?: @"").lowercaseString;
    if ([format isEqualToString:@"hls"]) {
        RDPreviewDecision decision = media.declaredVariants.count >= 2 ? RDPreviewDecisionHLSMaster : RDPreviewDecisionHLSMedia;
        return [self verdictWithDecision:decision reason:nil];
    }
    if ([format isEqualToString:@"dash"]) return [self refusedWithReason:@"DASH 清单暂不支持预览（AVPlayer 无 DASH 支持），可下载后观看"];
    if ([format isEqualToString:@"webm"]) return [self refusedWithReason:@"WebM 格式暂不支持预览（系统解码器限制），可下载后观看"];
    if ([format isEqualToString:@"mkv"])  return [self refusedWithReason:@"MKV 容器暂不支持预览（系统解码器限制）"];
    if ([format isEqualToString:@"ts"] || [format isEqualToString:@"m2ts"]) return [self refusedWithReason:@"TS 直链暂不支持预览，可下载后观看"];
    if ([format isEqualToString:@"flv"])  return [self refusedWithReason:@"FLV 容器暂不支持预览（系统解码器限制），可下载后观看"];
    if ([format isEqualToString:@"avi"])  return [self refusedWithReason:@"AVI 容器暂不支持预览（系统解码器限制），可下载后观看"];
    if ([RDDirectPreviewFormats() containsObject:format]) return [self verdictWithDecision:RDPreviewDecisionDirectFile reason:nil];
    if ([RDNamedUnsupportedFormats() containsObject:format]) {
        return [self refusedWithReason:[NSString stringWithFormat:@"%@ 格式暂不支持预览，可下载后观看", media.format]];
    }

    // 未知/空白 format：按地址扩展名兜底；仍不命中则如实说明未识别。
    NSString *extension = [[NSURL URLWithString:media.mediaURL] pathExtension].lowercaseString;
    if (extension.length > 0 && [RDDirectPreviewFormats() containsObject:extension]) {
        return [self verdictWithDecision:RDPreviewDecisionDirectFile reason:nil];
    }
    return [self refusedWithReason:@"未识别的媒体格式，暂不支持预览"];
}

+ (nullable RDPreviewVerdict *)verdictIfURLAllowed:(NSURL *)url policy:(URLPolicy *)policy {
    // policy 为 nil 时向 nil 发消息得到 nil 决定，同样落入「无拒绝」分支。
    URLPolicyDecision *decision = [policy evaluateTextURL:url.absoluteString ?: @""];
    if (decision == nil || decision.allowed) return nil;
    return [self refusedWithReason:decision.userMessage.length > 0 ? decision.userMessage : @"该地址未通过安全策略校验，无法预览"];
}

@end
