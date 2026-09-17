//
//  DetectedMedia.m — 模块 17｜媒体结果模型实现
//
#import "DetectedMedia.h"
#import "RDURLUtilities.h"

static const NSUInteger kHeadKeep = 24;   // 标题开头保留字符数
static const NSUInteger kTailKeep = 12;   // 标题结尾保留字符数

@implementation DetectedMedia

+ (NSString *)dedupKeyForURL:(NSString *)urlString {
    return RDCanonicalResourceURL([NSURL URLWithString:urlString ?: @""]);
}

+ (NSString *)groupingKeyForURL:(NSString *)urlString {
    return RDResourceGroupingIdentity([NSURL URLWithString:urlString ?: @""]);
}

// 同一地址的多次发现合并。规则（顺序即优先级）：
//   · 身份：保留 primary 已有的 family；primary 无 family 时采用 secondary 的；
//     两者都有且不同时，采用画质声明更多的一侧（更完整的分组身份）。
//   · 画质声明：取条目更多的一份；数量相同保留 primary（不制造第二套标签）。
//   · 展示/元数据字段：仅在 primary 缺失时用 secondary 补齐。
//   · 资源类型：manifest 优先于 video，video 优先于 other（类型信息只增不减）。
+ (DetectedMedia *)mediaByEnriching:(DetectedMedia *)primary with:(DetectedMedia *)secondary {
    if (!primary) return secondary;
    if (!secondary) return primary;
    if (primary == secondary) return primary;

    if (primary.videoFamilyID.length == 0 && secondary.videoFamilyID.length) {
        primary.videoFamilyID = secondary.videoFamilyID;
    } else if (primary.videoFamilyID.length && secondary.videoFamilyID.length &&
               ![primary.videoFamilyID isEqualToString:secondary.videoFamilyID] &&
               secondary.declaredVariants.count > primary.declaredVariants.count) {
        primary.videoFamilyID = secondary.videoFamilyID;
    }
    if (secondary.declaredVariants.count > primary.declaredVariants.count) {
        primary.declaredVariants = secondary.declaredVariants;
    }
    if (primary.poster.length == 0 && secondary.poster.length) primary.poster = secondary.poster;
    if (primary.title.length == 0 && secondary.title.length) primary.title = secondary.title;
    if (primary.sourcePageURL.length == 0 && secondary.sourcePageURL.length) primary.sourcePageURL = secondary.sourcePageURL;
    if (primary.mimeType.length == 0 && secondary.mimeType.length) primary.mimeType = secondary.mimeType;
    if (primary.contentRange.length == 0 && secondary.contentRange.length) primary.contentRange = secondary.contentRange;
    if (primary.parentMediaURL.length == 0 && secondary.parentMediaURL.length) primary.parentMediaURL = secondary.parentMediaURL;
    if (primary.availabilityState.length == 0 && secondary.availabilityState.length) primary.availabilityState = secondary.availabilityState;
    if (primary.manifestInfo == nil && secondary.manifestInfo != nil) primary.manifestInfo = secondary.manifestInfo;
    if (primary.durationSeconds == nil && secondary.durationSeconds != nil) primary.durationSeconds = secondary.durationSeconds;
    if (primary.pixelWidth <= 0 && secondary.pixelWidth > 0) primary.pixelWidth = secondary.pixelWidth;
    if (primary.pixelHeight <= 0 && secondary.pixelHeight > 0) primary.pixelHeight = secondary.pixelHeight;
    if (primary.sizeBytes <= 0 && secondary.sizeBytes > 0) primary.sizeBytes = secondary.sizeBytes;
    if (primary.quality.length == 0 && secondary.quality.length) {
        primary.quality = secondary.quality;
        primary.qualityDerivedFromPixelHeight = secondary.qualityDerivedFromPixelHeight;
    }
    if (primary.discoveredAt <= 0 && secondary.discoveredAt > 0) primary.discoveredAt = secondary.discoveredAt;
    if (primary.thumbnailStatus == RDThumbnailNone && secondary.thumbnailStatus != RDThumbnailNone) primary.thumbnailStatus = secondary.thumbnailStatus;
    if (primary.drmType == RDDrmNone && secondary.drmType != RDDrmNone) primary.drmType = secondary.drmType;
    if (!primary.isLive && secondary.isLive) primary.isLive = YES;
    // 类型只允许“更具体”：other < image/video < manifest。
    if (primary.resourceKind == RDResourceKindOther && secondary.resourceKind != RDResourceKindOther) {
        primary.resourceKind = secondary.resourceKind;
    } else if (primary.resourceKind != RDResourceKindManifest && secondary.resourceKind == RDResourceKindManifest) {
        primary.resourceKind = RDResourceKindManifest;
    }
    if (!primary.isManifest && secondary.isManifest) primary.isManifest = YES;
    if (primary.format.length == 0 && secondary.format.length) primary.format = secondary.format;
    return primary;
}

- (NSString *)titleSummary {
    NSString *t = self.title;
    if (t == nil) return @"";
    NSMutableArray<NSString *> *graphemes = [NSMutableArray array];
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *part, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        [graphemes addObject:part];
    }];
    if (graphemes.count <= (kHeadKeep + kTailKeep + 1)) return t;
    NSString *head = [[graphemes subarrayWithRange:NSMakeRange(0, kHeadKeep)] componentsJoinedByString:@""];
    NSString *tail = [[graphemes subarrayWithRange:NSMakeRange(graphemes.count - kTailKeep, kTailKeep)] componentsJoinedByString:@""];
    return [NSString stringWithFormat:@"%@…%@", head, tail];
}

+ (NSString *)drmLocalizedHint:(RDDrmType)type {
    switch (type) {
        case RDDrmWidevine:  return @"该内容受 Widevine DRM 保护，当前版本无法直接处理，请使用内容提供方官方客户端。";
        case RDDrmFairPlay:  return @"该内容受 Apple FairPlay DRM 保护，当前版本无法直接处理，请使用内容提供方官方客户端。";
        case RDDrmPlayReady: return @"该内容受 PlayReady DRM 保护，当前版本无法直接处理，请使用内容提供方官方客户端。";
        case RDDrmUnknownProtected: return @"该内容检测到受保护信号，当前版本无法直接处理，请使用内容提供方官方客户端。";
        default: return @"";
    }
}

@end
