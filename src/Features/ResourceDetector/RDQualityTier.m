//
//  RDQualityTier.m — 通用质量档位归一化与候选去重
//
//  所有发现来源（静态 <source size>、srcset、WebKit 动态桥、HLS master、
//  DASH Representation）都必须经由本文件产出最终候选，禁止任何调用方
//  自行生成第二套标签体系。
//

#import "RDQualityTier.h"
#import "RDURLUtilities.h"

// 归一化容差：短边与档位目标的偏差 ≤ 目标×10%。854x480/1280x720/
// 1920x1080 命中；800x800 短边 800 距 720 偏差 80 > 72，不命中。
static const double kRDQualityTierRelativeTolerance = 0.10;

// 通用临时 URL 启发式：参数名意味着地址会过期。只用于"同档多候选"时的稳定性
// 排序与同一资源分组（见 RDURLUtilities 的 RDResourceGroupingIdentity），
// 绝不用于放行/拦截。
static NSArray<NSString *> *RDEphemeralQueryKeys(void) {
    return RDEphemeralQueryKeyNames();
}

@implementation RDQualityCandidate
@end

@implementation RDQualityTier

+ (RDQualityTierLevel)levelForShortSide:(double)shortSide {
    if (!(shortSide > 0) || !isfinite(shortSide)) return RDQualityTierNone;
    static RDQualityTierLevel levels[] = { RDQualityTier480p, RDQualityTier720p, RDQualityTier1080p };
    for (NSUInteger i = 0; i < 3; i++) {
        double target = (double)levels[i];
        if (fabs(shortSide - target) <= target * kRDQualityTierRelativeTolerance) return levels[i];
    }
    return RDQualityTierNone;
}

+ (RDQualityTierLevel)levelForPixelWidth:(double)width height:(double)height {
    if (!(width > 0) || !(height > 0) || !isfinite(width) || !isfinite(height)) return RDQualityTierNone;
    return [self levelForShortSide:MIN(width, height)];
}

+ (RDQualityTierLevel)levelForDeclaredHeight:(double)height {
    return [self levelForShortSide:height];
}

+ (NSString *)labelForLevel:(RDQualityTierLevel)level {
    switch (level) {
        case RDQualityTier480p:  return @"480p";
        case RDQualityTier720p:  return @"720p";
        case RDQualityTier1080p: return @"1080p";
        default:                 return @"";
    }
}

// 声明标签 → (level, 数字高度)。"480"/"480p"/"720P" 可解析；"HD" 不可。
static BOOL RDParseDeclaredHeight(NSString *label, double *outHeight) {
    if (label.length == 0 || label.length > 12) return NO;
    NSString *text = [label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text.lowercaseString hasSuffix:@"p"]) text = [text substringToIndex:text.length - 1];
    if (text.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value <= 0 || value > 100000) return NO;
    if (outHeight) *outHeight = value;
    return YES;
}

// "1280x720" / "1280×720" → 像素
static BOOL RDParseResolution(NSString *text, double *outWidth, double *outHeight) {
    if (text.length == 0 || text.length > 24) return NO;
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"xX×"]];
    if (parts.count != 2) return NO;
    double w = [parts[0] doubleValue], h = [parts[1] doubleValue];
    if (!(w > 0) || !(h > 0) || !isfinite(w) || !isfinite(h)) return NO;
    if (outWidth) *outWidth = w;
    if (outHeight) *outHeight = h;
    return YES;
}

+ (BOOL)parseResolution:(NSString *)text width:(double *)outWidth height:(double *)outHeight {
    return RDParseResolution(text ?: @"", outWidth, outHeight);
}

+ (RDQualityCandidate *)candidateFromDeclaredDict:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSString *url = [dict[@"url"] isKindOfClass:NSString.class] ? dict[@"url"] : nil;
    if (!url.length) return nil;
    RDQualityCandidate *c = [RDQualityCandidate new];
    c.url = url;
    c.pixelWidth = [dict[@"pixelWidth"] doubleValue];
    c.pixelHeight = [dict[@"pixelHeight"] doubleValue];
    c.bandwidth = [dict[@"bandwidth"] longLongValue];
    NSString *label = [dict[@"label"] isKindOfClass:NSString.class] ? dict[@"label"] : nil;
    double w = 0, h = 0;
    if (RDParseResolution(label, &w, &h)) { c.pixelWidth = c.pixelWidth > 0 ? c.pixelWidth : w; c.pixelHeight = c.pixelHeight > 0 ? c.pixelHeight : h; c.declaredLabel = nil; }
    else c.declaredLabel = label;
    return c;
}

+ (RDQualityCandidate *)candidateFromManifestDict:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSString *url = [dict[@"url"] isKindOfClass:NSString.class] ? dict[@"url"] : nil;
    if (!url.length) return nil;
    RDQualityCandidate *c = [RDQualityCandidate new];
    c.url = url;
    c.bandwidth = [dict[@"bandwidth"] longLongValue] ?: [dict[@"BANDWIDTH"] longLongValue];
    double w = [dict[@"width"] doubleValue], h = [dict[@"height"] doubleValue];
    if (!(w > 0) || !(h > 0)) if (RDParseResolution([dict[@"resolution"] description], &w, &h)) { /* resolved below */ }
    if (w > 0 && h > 0) { c.pixelWidth = w; c.pixelHeight = h; }
    NSString *label = [dict[@"label"] isKindOfClass:NSString.class] ? dict[@"label"] : nil;
    double lw = 0, lh = 0;
    if (RDParseResolution(label, &lw, &lh)) { c.pixelWidth = lw; c.pixelHeight = lh; c.declaredLabel = nil; }
    else c.declaredLabel = label;
    c.discoverySource = @"manifest";
    return c;
}

// 候选的最终档位：实测像素优先，其次声明文本（先试 "WxH"，再试纯高度）。
+ (RDQualityTierLevel)levelForCandidate:(RDQualityCandidate *)c {
    if (c.pixelWidth > 0 && c.pixelHeight > 0) return [self levelForPixelWidth:c.pixelWidth height:c.pixelHeight];
    double w = 0, h = 0;
    if (RDParseResolution(c.declaredLabel ?: @"", &w, &h)) return [self levelForPixelWidth:w height:h];
    double declared = 0;
    if (RDParseDeclaredHeight(c.declaredLabel ?: @"", &declared)) return [self levelForDeclaredHeight:declared];
    return RDQualityTierNone;
}

+ (BOOL)candidateHasEphemeralQuery:(RDQualityCandidate *)c {
    NSURLComponents *components = [NSURLComponents componentsWithString:c.url ?: @""];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        for (NSString *key in RDEphemeralQueryKeys()) {
            if ([item.name.lowercaseString isEqualToString:key]) return YES;
        }
    }
    return NO;
}

static NSInteger RDSourceTrustRank(NSString *source) {
    // 数字越小越可信。清单是站点明确声明的档位表；静态 video 标签次之；
    // 懒加载属性最弱。
    if ([source isEqualToString:@"manifest"] || [source isEqualToString:@"static-video-variants"]) return 0;
    if ([source isEqualToString:@"static-video"] || [source isEqualToString:@"dynamic-video"]) return 1;
    if ([source isEqualToString:@"static-video-lazy"] || [source isEqualToString:@"static-video-srcset"] ||
        [source isEqualToString:@"static-video-preload"]) return 2;
    return 3;
}

// 候选择优比较器：可用 > 视频类 > 更接近目标 > 带宽高 > 来源可信 > URL 稳定。
// 返回 NSOrderedDescending 表示 a 应排在 b 之后（b 更优）。
static NSComparisonResult RDCompareCandidates(RDQualityCandidate *a, RDQualityCandidate *b, RDQualityTierLevel level) {
    // 1. 可用性：needsVerification/unresolvedBlob 排后
    BOOL aNeeds = [a.availabilityState isEqualToString:@"needsVerification"] ||
                  [a.availabilityState isEqualToString:@"unresolvedBlob"];
    BOOL bNeeds = [b.availabilityState isEqualToString:@"needsVerification"] ||
                  [b.availabilityState isEqualToString:@"unresolvedBlob"];
    if (aNeeds != bNeeds) return aNeeds ? NSOrderedDescending : NSOrderedAscending;
    // 2. 视频/清单优先于图片
    BOOL aImage = a.kind == RDResourceKindImage, bImage = b.kind == RDResourceKindImage;
    if (aImage != bImage) return aImage ? NSOrderedDescending : NSOrderedAscending;
    // 3. 更接近目标档位
    if (level != RDQualityTierNone) {
        double aSide = MIN(a.pixelWidth > 0 ? a.pixelWidth : DBL_MAX, a.pixelHeight > 0 ? a.pixelHeight : DBL_MAX);
        double bSide = MIN(b.pixelWidth > 0 ? b.pixelWidth : DBL_MAX, b.pixelHeight > 0 ? b.pixelHeight : DBL_MAX);
        BOOL aHasPixels = a.pixelWidth > 0 && a.pixelHeight > 0;
        BOOL bHasPixels = b.pixelWidth > 0 && b.pixelHeight > 0;
        if (aHasPixels && bHasPixels) {
            double aDist = fabs(aSide - (double)level), bDist = fabs(bSide - (double)level);
            if (aDist != bDist) return aDist < bDist ? NSOrderedAscending : NSOrderedDescending;
        }
    }
    // 4. 带宽更高
    if (a.bandwidth != b.bandwidth) return a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending;
    // 5. 来源可信度更高
    NSInteger aTrust = RDSourceTrustRank(a.discoverySource), bTrust = RDSourceTrustRank(b.discoverySource);
    if (aTrust != bTrust) return aTrust < bTrust ? NSOrderedAscending : NSOrderedDescending;
    // 6. URL 稳定（无临时参数）优先
    BOOL aEphemeral = [RDQualityTier candidateHasEphemeralQuery:a];
    BOOL bEphemeral = [RDQualityTier candidateHasEphemeralQuery:b];
    if (aEphemeral != bEphemeral) return aEphemeral ? NSOrderedDescending : NSOrderedAscending;
    // 兜底：URL 字典序，保证输出确定性
    return [a.url compare:b.url];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)normalizedVariantsFromCandidates:(NSArray<RDQualityCandidate *> *)candidates {
    // 第一步：URL 规范化去重（同 URL 静态/动态重复发现合并为一个候选，保留信息更全者）
    NSMutableDictionary<NSString *, RDQualityCandidate *> *byURL = [NSMutableDictionary dictionary];
    for (RDQualityCandidate *c in candidates) {
        if (![c isKindOfClass:RDQualityCandidate.class] || c.url.length == 0) continue;
        NSString *key = RDCanonicalResourceURL([NSURL URLWithString:c.url]);
        RDQualityCandidate *existing = byURL[key];
        if (!existing) { byURL[key] = c; continue; }
        if (c.pixelWidth > 0 && existing.pixelWidth <= 0) { existing.pixelWidth = c.pixelWidth; existing.pixelHeight = c.pixelHeight; }
        if (c.bandwidth > existing.bandwidth) existing.bandwidth = c.bandwidth;
        if (existing.declaredLabel.length == 0 && c.declaredLabel.length) existing.declaredLabel = c.declaredLabel;
    }
    // 第二步：按档位分桶
    NSMutableDictionary<NSNumber *, NSMutableArray<RDQualityCandidate *> *> *buckets = [NSMutableDictionary dictionary];
    for (NSString *key in byURL) {
        RDQualityCandidate *c = byURL[key];
        RDQualityTierLevel level = [self levelForCandidate:c];
        NSNumber *bucket = @(level);
        if (!buckets[bucket]) buckets[bucket] = [NSMutableArray array];
        [buckets[bucket] addObject:c];
    }
    // 第三步：每档择优一个。产品规则：质量选择只提供实际存在的 480p/720p/1080p，
    // 缺档不生成；非标准尺寸（None 档）绝不自动变成额外质量选项——真实像素
    // 保留在详情“分辨率”行，由维度字段呈现，不在这里产生任何标签。
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
    for (NSNumber *levelNumber in [@[@(RDQualityTier480p), @(RDQualityTier720p), @(RDQualityTier1080p)] objectEnumerator]) {
        NSArray<RDQualityCandidate *> *bucket = buckets[levelNumber];
        if (bucket.count == 0) continue; // 缺档不生成
        RDQualityCandidate *best = bucket.firstObject;
        for (RDQualityCandidate *c in bucket) if (RDCompareCandidates(c, best, (RDQualityTierLevel)levelNumber.integerValue) == NSOrderedAscending) best = c;
        NSMutableDictionary *dict = [@{ @"url": best.url,
                                        @"label": [self labelForLevel:(RDQualityTierLevel)levelNumber.integerValue],
                                        @"level": levelNumber,
                                        @"pixelWidth": @((NSInteger)best.pixelWidth),
                                        @"pixelHeight": @((NSInteger)best.pixelHeight),
                                        @"bandwidth": @(best.bandwidth) } mutableCopy];
        if (best.bandwidth > 0) dict[@"bandwidth"] = @(best.bandwidth); else [dict removeObjectForKey:@"bandwidth"];
        [out addObject:dict];
    }
    return [out copy];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)normalizedVariantsByMergingDeclared:(NSArray<NSDictionary *> *)declared
                                                                        manifest:(NSArray<NSDictionary *> *)manifest {
    NSMutableArray<RDQualityCandidate *> *candidates = [NSMutableArray array];
    for (NSDictionary *d in declared ?: @[]) {
        RDQualityCandidate *c = [self candidateFromDeclaredDict:d];
        if (c) [candidates addObject:c];
    }
    for (NSDictionary *d in manifest ?: @[]) {
        RDQualityCandidate *c = [self candidateFromManifestDict:d];
        if (c) [candidates addObject:c];
    }
    return [self normalizedVariantsFromCandidates:candidates];
}

@end
