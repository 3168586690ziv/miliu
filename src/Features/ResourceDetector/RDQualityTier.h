//
//  RDQualityTier.h — 通用质量档位归一化与候选去重
//
//  产品只认 480p/720p/1080p 三个标准档位；静态 HTML（<source size>）、
//  WebKit 动态事件、HLS master、DASH Representation 全部经由同一个
//  归一化入口，禁止任何来源私造一套候选。
//

#import <Foundation/Foundation.h>
#import "DetectedMedia.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RDQualityTierLevel) {
    RDQualityTierNone = 0,    // 无法归入标准档位（如 800×800 方形）——绝不伪装
    RDQualityTier480p = 480,
    RDQualityTier720p = 720,
    RDQualityTier1080p = 1080,
};

@interface RDQualityCandidate : NSObject
@property (nonatomic, copy) NSString *url;
/// 源站/清单声明（size="480"、"480p"、"1280x720"）；可空。
@property (nonatomic, copy, nullable) NSString *declaredLabel;
@property (nonatomic, assign) double pixelWidth;
@property (nonatomic, assign) double pixelHeight;
@property (nonatomic, assign) long long bandwidth;
@property (nonatomic, copy, nullable) NSString *discoverySource;
@property (nonatomic, copy, nullable) NSString *availabilityState;
@property (nonatomic, assign) RDResourceKind kind;
@end

@interface RDQualityTier : NSObject

// 归一化规则（测试锁定）：取宽高中较短的一边为档位基准；短边与档位目标的
// 偏差 ≤ 目标×10% 才归档。854x480/1280x720/1920x1080 命中；800x800 短边
// 800 距 720 偏差 80 > 72，不命中、返回 None。竖屏 720x1280 短边 720 → 720p。
+ (RDQualityTierLevel)levelForPixelWidth:(double)width height:(double)height;

// 源站声明值（如 <source size="480">）按同一容差规则归档。
+ (RDQualityTierLevel)levelForDeclaredHeight:(double)height;

+ (NSString *)labelForLevel:(RDQualityTierLevel)level;

// "1280x720" / "1280×720" → 像素（供清单 RESOLUTION 属性使用）。
+ (BOOL)parseResolution:(nullable NSString *)text width:(double *)outWidth height:(double *)outHeight;

// 归一化输出 dict 键：url / label / level / pixelWidth / pixelHeight / bandwidth。
// 规则：
//   1. 同一 URL（RDCanonicalResourceURL 规范化）只出现一次；
//   2. 同一标准档位只保留一个候选，优先级依次为：
//      可用（无 needsVerification/DRM）> 视频/清单而非图片 > 声明或实测
//      分辨率更接近目标 > 带宽更高 > 来源可信度更高 > URL 更稳定
//      （无 expires/token/secure/signature 类临时参数）；
//   3. 无法归档的候选保留原始像素或声明标签，不参与档位去重；
//   4. 输出按档位升序排列，None 档位在最后。
+ (NSArray<NSDictionary<NSString *, id> *> *)normalizedVariantsFromCandidates:(NSArray<RDQualityCandidate *> *)candidates;

// 静态声明 dict（url/label/pixelWidth/pixelHeight）与清单 dict
// （url/resolution/width/height/bandwidth/BANDWIDTH/label）合并后统一归一化——
// 静态与动态路径必须产出同一套候选。
+ (NSArray<NSDictionary<NSString *, id> *> *)normalizedVariantsByMergingDeclared:(NSArray<NSDictionary *> *)declared
                                                                        manifest:(NSArray<NSDictionary *> *)manifest;

NS_ASSUME_NONNULL_END

@end
