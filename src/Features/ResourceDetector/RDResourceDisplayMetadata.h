//
//  RDResourceDisplayMetadata.h
//  7zz
//
//  资源卡片的“展示元数据”模型：标题 + 封面 + 可信级别。
//  与下载 URL 身份解耦，按规范化 sourcePage URL 稳定保存，避免 token 刷新后
//  标题/封面退化。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RDDisplayMetadataConfidence) {
    RDDisplayMetadataConfidenceNone = 0,
    RDDisplayMetadataConfidenceLow,     // 仅 title 或仅 poster
    RDDisplayMetadataConfidenceMedium,  // title + poster 来自同一页，但未严格校验作品 ID
    RDDisplayMetadataConfidenceHigh,    // title + poster 且身份可证明（同作品 ID）
};

@interface RDResourceDisplayMetadata : NSObject <NSCopying>
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *posterURLString;
@property (nonatomic, copy, nullable) NSString *sourcePageURLString;
@property (nonatomic, assign) RDDisplayMetadataConfidence confidence;

+ (instancetype)metadataWithTitle:(nullable NSString *)title
                  posterURLString:(nullable NSString *)posterURLString
              sourcePageURLString:(nullable NSString *)sourcePageURLString
                       confidence:(RDDisplayMetadataConfidence)confidence;

/// 去掉站点后缀、分辨率尾缀等常见噪声，保留作品标题。
- (NSString *)cleanedTitle;

/// 标题是否像数字文件名（如 407460-sc-480p.mp4）。
- (BOOL)titleLooksLikeOpaqueFilename;

/// 校验当前 preview/thumbnail URL 与来源页作品 ID 是否一致（如 407460 对应 407460h.jpg）。
/// 仅用于“当前新请求来源页”的受限兜底，不放宽历史缩略图规则。
- (BOOL)posterURLProvesSameWorkForSourcePageURL:(nullable NSString *)sourcePageURL;

@end

NS_ASSUME_NONNULL_END
