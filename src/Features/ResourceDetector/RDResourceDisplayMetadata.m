//
//  RDResourceDisplayMetadata.m
//  7zz
//

#import "RDResourceDisplayMetadata.h"
#import <AppKit/AppKit.h> // cleanedTitle 使用 NSAttributedString HTML 解码（AppKit 文档属性常量）

@implementation RDResourceDisplayMetadata

+ (instancetype)metadataWithTitle:(NSString *)title
                  posterURLString:(NSString *)posterURLString
              sourcePageURLString:(NSString *)sourcePageURLString
                       confidence:(RDDisplayMetadataConfidence)confidence {
    RDResourceDisplayMetadata *m = [[self alloc] init];
    m.title = title;
    m.posterURLString = posterURLString;
    m.sourcePageURLString = sourcePageURLString;
    m.confidence = confidence;
    return m;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return [RDResourceDisplayMetadata metadataWithTitle:self.title
                                        posterURLString:self.posterURLString
                                    sourcePageURLString:self.sourcePageURLString
                                             confidence:self.confidence];
}

- (NSString *)cleanedTitle {
    NSString *raw = self.title ?: @"";
    if (!raw.length) return @"";

    // HTML entity 解码（与 App 层 cleanResourceDiscoveryTitle: 的第一步对齐）。
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    NSAttributedString *decoded = data ? [[NSAttributedString alloc] initWithData:data
                                                                            options:@{NSDocumentTypeDocumentAttribute:NSHTMLTextDocumentType,
                                                                                      NSCharacterEncodingDocumentAttribute:@(NSUTF8StringEncoding)}
                                                                 documentAttributes:nil error:nil] : nil;
    NSString *plain = decoded.string.length ? decoded.string : raw;

    // 去掉常见站点后缀（大小写不敏感、从末尾匹配）。
    NSArray *suffixes = @[
        @" - H動漫/裏番/線上看 - hanime2.org",
        @" - H动漫/里番/线上看 - hanime2.org",
        @" - hanime2.org",
        @" - hanime2.net",
        @" | hanime2.org",
        @" | hanime",
    ];
    for (NSString *suffix in suffixes) {
        NSRange r = [plain rangeOfString:suffix options:NSCaseInsensitiveSearch | NSBackwardsSearch];
        if (r.location != NSNotFound) {
            plain = [plain substringToIndex:r.location];
            break;
        }
    }

    // 去掉常见的“[中文字幕]”“[无修]”等标签末尾站点名；只去掉已知的站点构造。
    plain = [plain stringByReplacingOccurrencesOfString:@" - hanime" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, plain.length)];

    // 规范化空白。
    NSArray *parts = [plain componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [words addObject:p];
    return [words componentsJoinedByString:@" "];
}

- (BOOL)titleLooksLikeOpaqueFilename {
    NSString *raw = self.title ?: @"";
    if (!raw.length) return NO;
    // 形如 407460-sc-480p.mp4、407460.mp4、123456-1080p.mkv。
    NSString *pattern = @"^\\d{5,}(?:[-_.][A-Za-z0-9]+)?(?:[-_.]\\d{3,4}p)?(\\.[A-Za-z0-9]{2,4})?$";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
    return [re firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)] != nil;
}

- (BOOL)posterURLProvesSameWorkForSourcePageURL:(NSString *)sourcePageURL {
    if (!self.posterURLString.length || !sourcePageURL.length) return NO;
    NSURL *posterURL = [NSURL URLWithString:self.posterURLString];
    NSURL *pageURL = [NSURL URLWithString:sourcePageURL];
    if (!posterURL || !pageURL) return NO;

    // 从来源页 query 中提取作品 ID，例如 watch?v=407460。
    NSURLComponents *pageComponents = [NSURLComponents componentsWithURL:pageURL resolvingAgainstBaseURL:NO];
    NSString *workID = nil;
    for (NSURLQueryItem *item in pageComponents.queryItems ?: @[]) {
        if ([item.name isEqualToString:@"v"] && item.value.length) {
            workID = item.value;
            break;
        }
    }
    if (!workID.length) return NO;

    // 图片路径中必须包含同一作品 ID，且后跟 h/l/数字/下划线等预览图后缀。
    NSString *path = posterURL.path ?: @"";
    NSString *pattern = [NSString stringWithFormat:@"/%@[hl\\d_]?\\.(jpg|jpeg|png|webp|gif|avif)",
                         [NSRegularExpression escapedPatternForString:workID]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
    return [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)] != nil;
}

@end
