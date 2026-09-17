//
//  DetectedMedia.h — 模块 17｜探测到的媒体结果模型
//
//  保存 URL、标题、格式、质量、大小、缩略图状态与 DRM 状态。
//  提供 URL 去重 key（规范化）与标题首尾摘要。纯模型，无 GUI。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RDThumbnailStatus) {
    RDThumbnailNone = 0,    // 无缩略图（如纯音频/无图）
    RDThumbnailPending,     // 生成中
    RDThumbnailReady,       // 已生成
    RDThumbnailFailed,      // 生成失败（仍保留元数据与标题摘要）
};

typedef NS_ENUM(NSInteger, RDDrmType) {
    RDDrmNone = 0,
    RDDrmWidevine,
    RDDrmFairPlay,
    RDDrmPlayReady,
    RDDrmUnknownProtected,  // 检测到受保护信号但无法精确识别
};

typedef NS_ENUM(NSInteger, RDResourceKind) {
    RDResourceKindVideo = 0,
    RDResourceKindImage,
    RDResourceKindManifest,
    RDResourceKindOther,
};

@interface DetectedMedia : NSObject
@property (nonatomic, copy) NSString *mediaURL;
/// Explicit alternatives within one video element, not measured pixel dimensions.
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *declaredVariants;
/// Stable identity for resources discovered from the same explicit video element.
@property (nonatomic, copy, nullable) NSString *videoFamilyID;
@property (nonatomic, copy, nullable) NSString *sourcePageURL;
@property (nonatomic, copy, nullable) NSString *mimeType;
/// HTTP 响应的 Content-Range（若可获得），用于解释分段/清单资源。
@property (nonatomic, copy, nullable) NSString *contentRange;
/// 清单变体或播放器线索所关联的父媒体 URL。
@property (nonatomic, copy, nullable) NSString *parentMediaURL;
/// HLS/DASH 解析出的结构化摘要；为空表示尚未读取清单正文。
@property (nonatomic, copy, nullable) NSDictionary *manifestInfo;
/// 可解释状态：downloadable / needsVerification / unresolvedBlob 等。
@property (nonatomic, copy, nullable) NSString *availabilityState;
/// 发现时间（单调性由调用方保证；仅用于同一会话内排序/诊断）。
@property (nonatomic, assign) NSTimeInterval discoveredAt;
@property (nonatomic, assign) RDResourceKind resourceKind;
@property (nonatomic, copy, nullable) NSString *discoverySource;
@property (nonatomic, assign) NSInteger pixelWidth;
@property (nonatomic, assign) NSInteger pixelHeight;
/// Nil means unknown; only finite, nonnegative observed values are accepted.
@property (nonatomic, copy, nullable) NSNumber *durationSeconds;
@property (nonatomic, assign) BOOL isLive;
@property (nonatomic, assign) BOOL isManifest;
@property (nonatomic, copy, nullable) NSString *poster;   // video.poster，或与详情页直接关联的列表卡片封面
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *format;      // mp4 / webm / hls / dash ...
@property (nonatomic, copy) NSString *quality;     // 720p / 1080p / auto ...
@property (nonatomic, assign) BOOL qualityDerivedFromPixelHeight; // 本地测量，不是源站质量等级
@property (nonatomic, assign) long long sizeBytes;
@property (nonatomic, assign) RDThumbnailStatus thumbnailStatus;
@property (nonatomic, assign) RDDrmType drmType;

// 规范化去重 key：去 fragment、host 小写、路径统一、去除常见追踪 query（保留核心）
+ (NSString *)dedupKeyForURL:(NSString *)urlString;

// 发现/展示层“同一资源”身份：在规范化基础上再忽略签名/过期类参数
// （secure/token/expires/...）。同一文件经静态取页与动态取页会拿到不同签名，
// 只按 dedupKey 去重会让同一部影片显示成两个视频选项。
// 下载身份仍使用 dedupKeyForURL，不受此影响。
+ (NSString *)groupingKeyForURL:(NSString *)urlString;

// 同一 URL 经不同发现路径（静态 HTML / 动态 WebKit 桥 / 清单）得到多条记录时的
// 合并：以 primary 为主，缺失的身份、画质声明与展示字段由 secondary 补齐。
// 绝不产生第二套标签，也不改变已确认的字段值（同一字段都有值时保留 primary）。
// 返回 nil 仅当两者都为 nil。
+ (nullable DetectedMedia *)mediaByEnriching:(nullable DetectedMedia *)primary
                                        with:(nullable DetectedMedia *)secondary;

// 标题摘要：保留开头与结尾，中间以省略号替代（截断时）。
- (NSString *)titleSummary;

+ (NSString *)drmLocalizedHint:(RDDrmType)type; // 不可直接处理的准确提示
@end

NS_ASSUME_NONNULL_END
