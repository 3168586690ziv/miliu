//
//  SubpageLinkExtractor.m — 第 2 阶段｜总站探测·子页面链接提取器实现
//
//  纯 Foundation 实现：无 UI、无 WebKit、无网络请求、无全局可变状态。
//
//  复用说明（第 1 阶段报告第 11 节的实现边界）：
//  · 相对→绝对 URL 解析复用 NSURL URLWithString:relativeToURL:
//    （与 WebProbe.m:91 / SevenZZToolbox.m:7897 使用同一系统 API）；
//  · 同源比较为 scheme + host + 有效端口（显式默认端口视同缺省）。
//    Shared/HTTPPrivacyPolicy 的 originForURL: 只返回 scheme://host、不含端口，
//    无法区分 example.com 与 example.com:8443；DetectedMedia 的 dedupKeyForURL:
//    基于 NSURL.host（不含端口）构造 key，会丢失端口信息——两者均不适合直接
//    复用于“带端口语义的同源判断/去重”，故在本模块内实现最小逻辑，
//    不修改任何既有安全策略模块。
//

#import "SubpageLinkExtractor.h"
#import <stdlib.h>

static NSURL *SLEURLByStrippingFragment(NSURL *u);

#pragma mark - HTML 基本实体解码（单遍替换，避免二次解码）

// 仅解码属性值中最常见的基本实体：&amp; &lt; &gt; &quot; &apos; 与数字实体。
// 单遍处理保证 "&amp;lt;" 解码为 "&lt;"（字面），而不是错误的 "<"。
static NSString *SLEDecodeBasicEntities(NSString *s) {
    if (s.length == 0) return s;
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"&(amp|lt|gt|quot|apos|nbsp|#x[0-9a-fA-F]+|#[0-9]+);"
                             options:0
                               error:nil];
    if (!re) return s;
    NSArray<NSTextCheckingResult *> *matches =
        [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    if (matches.count == 0) return s;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *m in matches) {
        if (m.range.location > cursor) {
            [out appendString:[s substringWithRange:NSMakeRange(cursor, m.range.location - cursor)]];
        }
        NSString *name = [s substringWithRange:[m rangeAtIndex:1]];
        NSString *replacement = nil;
        if ([name isEqualToString:@"amp"]) {
            replacement = @"&";
        } else if ([name isEqualToString:@"lt"]) {
            replacement = @"<";
        } else if ([name isEqualToString:@"gt"]) {
            replacement = @">";
        } else if ([name isEqualToString:@"quot"]) {
            replacement = @"\"";
        } else if ([name isEqualToString:@"apos"]) {
            replacement = @"'";
        } else if ([name isEqualToString:@"nbsp"]) {
            replacement = @" ";
        } else if ([name hasPrefix:@"#x"]) {
            unsigned long v = strtoul([name substringFromIndex:2].UTF8String, NULL, 16);
            if (v > 0 && v <= 0xFFFF) {
                replacement = [NSString stringWithCharacters:(const unichar[]){(unichar)v} length:1];
            }
        } else if (name.length > 1) {
            unsigned long v = strtoul([name substringFromIndex:1].UTF8String, NULL, 10);
            if (v > 0 && v <= 0xFFFF) {
                replacement = [NSString stringWithCharacters:(const unichar[]){(unichar)v} length:1];
            }
        }
        [out appendString:(replacement ?: [s substringWithRange:m.range])];
        cursor = m.range.location + m.range.length;
    }
    if (cursor < s.length) {
        [out appendString:[s substringFromIndex:cursor]];
    }
    return out;
}

static NSString *SLEVisibleAnchorTitle(NSString *innerHTML) {
    if (innerHTML.length == 0) return @"";
    // 列表卡片常把时长、点赞和播放量也放在同一个 <a> 内。优先读取
    // class token 恰为 "title" 的元素，避免把这些统计文字混进视频标题。
    NSRegularExpression *classElementRe = [NSRegularExpression
        regularExpressionWithPattern:@"<([A-Za-z][A-Za-z0-9:-]*)\\b[^>]*\\bclass\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</\\1\\s*>"
                             options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                               error:nil];
    for (NSTextCheckingResult *match in
         [classElementRe matchesInString:innerHTML options:0 range:NSMakeRange(0, innerHTML.length)]) {
        if (match.numberOfRanges < 4) continue;
        NSString *classes = [innerHTML substringWithRange:[match rangeAtIndex:2]];
        NSArray<NSString *> *tokens = [classes componentsSeparatedByCharactersInSet:
                                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![tokens containsObject:@"title"]) continue;
        innerHTML = [innerHTML substringWithRange:[match rangeAtIndex:3]];
        break;
    }
    NSRegularExpression *hiddenRe = [NSRegularExpression
        regularExpressionWithPattern:@"<(script|style)\\b[^>]*>.*?</\\1\\s*>"
                             options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                               error:nil];
    NSString *visible = [hiddenRe stringByReplacingMatchesInString:innerHTML
                                                            options:0
                                                              range:NSMakeRange(0, innerHTML.length)
                                                       withTemplate:@" "];
    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>"
                                                                              options:0
                                                                                error:nil];
    visible = [tagRe stringByReplacingMatchesInString:visible
                                               options:0
                                                 range:NSMakeRange(0, visible.length)
                                          withTemplate:@" "];
    visible = SLEDecodeBasicEntities(visible);
    NSArray<NSString *> *parts = [visible componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in parts) if (part.length) [words addObject:part];
    return [words componentsJoinedByString:@" "];
}

static NSString *SLEAttributeValue(NSString *tag, NSString *attribute) {
    if (tag.length == 0 || attribute.length == 0) return nil;
    NSString *pattern = [NSString stringWithFormat:
        @"(?:^|\\s)%@\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
        [NSRegularExpression escapedPatternForString:attribute]];
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:pattern
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match) return nil;
    NSRange valueRange = [match rangeAtIndex:1];
    if (valueRange.location == NSNotFound) valueRange = [match rangeAtIndex:2];
    if (valueRange.location == NSNotFound) return nil;
    return SLEDecodeBasicEntities([tag substringWithRange:valueRange]);
}

// srcset/data-srcset 值可能带有 1x/2x 或宽度描述符。封面只需要一个
// 可读取的候选地址；按文档顺序取第一个 URL，避免把描述符拼进地址。
static NSString *SLEFirstImageURLToken(NSString *raw, NSString *attribute) {
    NSString *value=SLEDecodeBasicEntities(raw ?: @"");
    if (![attribute.lowercaseString containsString:@"srcset"]) return value;
    for (NSString *candidate in [value componentsSeparatedByString:@","]) {
        NSString *trim=[candidate stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!trim.length) continue;
        NSArray<NSString *> *parts=[trim componentsSeparatedByCharactersInSet:
                                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (parts.firstObject.length) return parts.firstObject;
    }
    return @"";
}

static NSURL *SLESafePreviewURL(NSString *raw, NSURL *baseURL) {
    if (raw.length == 0) return nil;
    NSURL *url = SLEURLByStrippingFragment([NSURL URLWithString:raw relativeToURL:baseURL]);
    NSString *scheme = url.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
        url.host.length == 0 || url.user.length > 0 || url.password.length > 0) {
        return nil;
    }
    return url;
}

static NSString *SLEWatchVideoIdentifier(NSURL *pageURL) {
    if (!pageURL) return @"";
    NSURLComponents *components = [NSURLComponents componentsWithURL:pageURL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (![item.name.lowercaseString isEqualToString:@"v"]) continue;
        NSString *value = item.value ?: @"";
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if (value.length > 0 && value.length <= 12 && [value rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            return value;
        }
    }
    return @"";
}

static NSString *SLECoverVideoIdentifier(NSURL *imageURL) {
    NSString *path = imageURL.path ?: @"";
    if (path.length == 0) return @"";
    static NSRegularExpression *coverIDRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        coverIDRe = [NSRegularExpression regularExpressionWithPattern:@"(?:^|/)image/cover/([0-9]{1,12})(?:\\.[A-Za-z0-9]+|/|$)"
                                                          options:NSRegularExpressionCaseInsensitive
                                                            error:nil];
    });
    NSTextCheckingResult *match = [coverIDRe firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
    if (!match || match.numberOfRanges < 2) return @"";
    return [path substringWithRange:[match rangeAtIndex:1]];
}

#pragma mark - 同源比较（scheme + host + 有效端口）

// 有效端口：显式端口优先；缺省时 https=443、http=80。
// 显式 443 与缺省视为同一端口（RFC 6454 同源语义）。
static NSInteger SLEEffectivePort(NSURL *u) {
    if (u.port) return u.port.integerValue;
    if ([u.scheme.lowercaseString isEqualToString:@"https"]) return 443;
    return 80;
}

static BOOL SLEIsSameOrigin(NSURL *a, NSURL *b) {
    if (!a || !b) return NO;
    NSString *sa = a.scheme.lowercaseString ?: @"";
    NSString *sb = b.scheme.lowercaseString ?: @"";
    if (![sa isEqualToString:sb]) return NO;
    NSString *ha = a.host.lowercaseString ?: @"";
    NSString *hb = b.host.lowercaseString ?: @"";
    if (![ha isEqualToString:hb]) return NO;
    return SLEEffectivePort(a) == SLEEffectivePort(b);
}

#pragma mark - fragment 去除与去重 key

// URL 语法中首个 '#' 即 fragment 起点（query 内的 '#' 必须编码为 %23）。
static NSURL *SLEURLByStrippingFragment(NSURL *u) {
    if (!u) return nil;
    NSString *abs = u.absoluteString;
    if (abs.length == 0) return u;
    NSRange r = [abs rangeOfString:@"#"];
    if (r.location == NSNotFound) return u;
    return [NSURL URLWithString:[abs substringToIndex:r.location]];
}

// 去重 key：scheme/host 强制小写 + 显式端口 + percent-encoded 路径 + 查询。
// 路径与查询保持原样（不重排 query、不动尾部斜杠、不解码 %XX），
// 避免 NSURL path/query 解码导致 "%2F" 与 "/" 错误合并。
static NSString *SLEDedupKeyForURL(NSURL *u) {
    if (!u) return @"";
    NSString *abs = u.absoluteString;
    if (abs.length == 0) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithString:abs];
    if (!c || c.scheme.length == 0 || c.host.length == 0) {
        return abs;  // 解析退化：以原串为 key（保守可用，不崩溃）
    }
    NSMutableString *key = [NSMutableString
        stringWithFormat:@"%@://%@", c.scheme.lowercaseString, c.host.lowercaseString];
    if (c.port) [key appendFormat:@":%@", c.port];
    if (c.percentEncodedPath.length > 0) [key appendString:c.percentEncodedPath];
    if (c.percentEncodedQuery.length > 0) [key appendFormat:@"?%@", c.percentEncodedQuery];
    return key;
}

#pragma mark - 无关链接排除

// 静态资源与媒体清单扩展名（对齐项目 resourceKindForURL 的媒体分类，
// 媒体资源不是候选子页面）。基于 URL 路径最后一段的扩展名，大小写不敏感。
static BOOL SLEPathHasExcludedExtension(NSString *path, NSSet<NSString *> *exts) {
    if (path.length == 0) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    return ext.length > 0 && [exts containsObject:ext];
}

// 操作页路径段排除：login/register/…。逐段（小写）比较，
// 页面脚本扩展名（.html/.php 等）剥离后再比较，避免过度排除普通页面
// （如 /blog/login-tips 不被排除）。
static BOOL SLEPathHasExcludedSegment(NSString *path,
                                      NSSet<NSString *> *tokens,
                                      NSSet<NSString *> *pageExts) {
    if (path.length == 0) return NO;
    for (NSString *seg in [path componentsSeparatedByString:@"/"]) {
        if (seg.length == 0) continue;
        NSString *s = seg.lowercaseString;
        NSString *ext = s.pathExtension;
        if (ext.length > 0 && [pageExts containsObject:ext]) {
            s = [s stringByDeletingPathExtension];
        }
        if ([tokens containsObject:s]) return YES;
    }
    return NO;
}

#pragma mark - 提取主流程

@implementation SubpageLinkExtractor

+ (NSArray<NSURL *> *)extractSubpageLinksFromHTML:(NSString *)html
                                         baseURL:(NSURL *)baseURL
                                         maxCount:(NSUInteger)maxCount {
    if (maxCount == 0) return @[];
    if (html.length == 0) return @[];
    // baseURL 必须是可解析的 http/https 页面地址，否则无法做相对解析与同源过滤
    NSString *baseScheme = baseURL.scheme.lowercaseString;
    if (![baseScheme isEqualToString:@"http"] && ![baseScheme isEqualToString:@"https"]) return @[];
    if (baseURL.host.length == 0) return @[];

    // 排除集合（每次调用重建，不使用全局缓存）
    NSSet<NSString *> *excludedSegments = [NSSet setWithArray:@[
        @"login", @"signin", @"signup", @"register", @"logout",
        @"search", @"comment", @"comments", @"share", @"rss", @"feed",
    ]];
    NSSet<NSString *> *staticExts = [NSSet setWithArray:@[
        @"css", @"js", @"png", @"jpg", @"jpeg", @"gif", @"webp", @"svg", @"ico", @"avif",
        @"mp4", @"m4v", @"mov", @"webm", @"avi", @"ts", @"flv",
        @"m3u8", @"mpd",
        @"mp3", @"m4a", @"aac", @"wav", @"ogg",
    ]];
    NSSet<NSString *> *pageExts = [NSSet setWithArray:@[
        @"html", @"htm", @"php", @"aspx", @"jsp", @"asp", @"do", @"action",
    ]];

    // 仅提取引号包裹的 href；"\s+href" 要求 href 前有空白，
    // 防止误匹配 data-href 等属性名的一部分。支持单/双引号与属性空格。
    NSRegularExpression *hrefRe = [NSRegularExpression
        regularExpressionWithPattern:@"<a\\b[^>]*?\\s+href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    if (!hrefRe) return @[];

    // 种子页自身的规范化 key（种子页不是候选子页面）
    NSURL *seedURL = SLEURLByStrippingFragment(baseURL);
    NSString *seedKey = SLEDedupKeyForURL(seedURL);

    NSMutableOrderedSet<NSURL *> *results = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];

    [hrefRe enumerateMatchesInString:html
                              options:0
                                range:NSMakeRange(0, html.length)
                           usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        if (results.count >= maxCount) {
            *stop = YES;  // 达到上限立即停止
            return;
        }
        NSRange valueRange = [match rangeAtIndex:1];
        if (valueRange.location == NSNotFound) valueRange = [match rangeAtIndex:2];
        if (valueRange.location == NSNotFound) return;
        NSString *raw = [html substringWithRange:valueRange];
        NSString *candidate = SLEDecodeBasicEntities(raw);
        if (candidate.length == 0) return;

        // 相对→绝对解析；解析失败视为格式错误，跳过
        NSURL *resolved = [NSURL URLWithString:candidate relativeToURL:baseURL];
        if (!resolved) return;
        NSString *scheme = resolved.scheme.lowercaseString;
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return;
        if (resolved.host.length == 0) return;
        // 不输出包含用户名/密码等凭据的 URL
        if (resolved.user.length > 0 || resolved.password.length > 0) return;

        // 去除 fragment
        NSURL *normalized = SLEURLByStrippingFragment(resolved);
        if (!normalized) return;

        // 同源过滤（scheme + host + 有效端口）
        if (!SLEIsSameOrigin(normalized, baseURL)) return;
        // 静态资源 / 媒体清单扩展名排除
        if (SLEPathHasExcludedExtension(normalized.path, staticExts)) return;
        // 登录/注册/搜索等操作页路径段排除
        if (SLEPathHasExcludedSegment(normalized.path, excludedSegments, pageExts)) return;

        // 去重（种子页自身排除）
        NSString *key = SLEDedupKeyForURL(normalized);
        if (key.length == 0) return;
        if ([key isEqualToString:seedKey]) return;
        if ([seenKeys containsObject:key]) return;

        [seenKeys addObject:key];
        [results addObject:normalized];
    }];

    return [results array];
}

+ (NSDictionary<NSString *,NSString *> *)extractSubpageTitlesFromHTML:(NSString *)html
                                                               baseURL:(NSURL *)baseURL
                                                               maxCount:(NSUInteger)maxCount {
    NSArray<NSURL *> *links = [self extractSubpageLinksFromHTML:html baseURL:baseURL maxCount:maxCount];
    if (links.count == 0 || html.length == 0) return @{};

    NSMutableSet<NSString *> *allowed = [NSMutableSet setWithCapacity:links.count];
    for (NSURL *url in links) if (url.absoluteString.length) [allowed addObject:url.absoluteString];

    NSRegularExpression *anchorRe = [NSRegularExpression
        regularExpressionWithPattern:@"<a\\b[^>]*?\\s+href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')[^>]*>(.*?)</a\\s*>"
                             options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                               error:nil];
    if (!anchorRe) return @{};
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary dictionary];
    [anchorRe enumerateMatchesInString:html
                                options:0
                                  range:NSMakeRange(0, html.length)
                             usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSRange hrefRange = [match rangeAtIndex:1];
        if (hrefRange.location == NSNotFound) hrefRange = [match rangeAtIndex:2];
        if (hrefRange.location == NSNotFound) return;
        NSURL *resolved = [NSURL URLWithString:SLEDecodeBasicEntities([html substringWithRange:hrefRange])
                                 relativeToURL:baseURL];
        NSURL *normalized = SLEURLByStrippingFragment(resolved);
        NSString *key = normalized.absoluteString;
        if (![allowed containsObject:key] || titles[key] != nil) return;
        NSRange bodyRange = [match rangeAtIndex:3];
        NSString *title = bodyRange.location == NSNotFound ? @"" :
            SLEVisibleAnchorTitle([html substringWithRange:bodyRange]);
        if (title.length) titles[key] = title;
    }];
    return [titles copy];
}

+ (NSDictionary<NSString *,NSString *> *)extractSubpagePreviewImagesFromHTML:(NSString *)html
                                                                      baseURL:(NSURL *)baseURL
                                                                     maxCount:(NSUInteger)maxCount {
    NSArray<NSURL *> *links = [self extractSubpageLinksFromHTML:html baseURL:baseURL maxCount:maxCount];
    if (links.count == 0 || html.length == 0) return @{};

    NSMutableSet<NSString *> *allowed = [NSMutableSet setWithCapacity:links.count];
    for (NSURL *url in links) if (url.absoluteString.length) [allowed addObject:url.absoluteString];

    NSRegularExpression *anchorRe = [NSRegularExpression
        regularExpressionWithPattern:@"<a\\b[^>]*?\\s+href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')[^>]*>(.*?)</a\\s*>"
                             options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                               error:nil];
    NSRegularExpression *imageRe = [NSRegularExpression
        regularExpressionWithPattern:@"<(?:img|source)\\b[^>]*>"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    if (!anchorRe || !imageRe) return @{};

    NSArray<NSString *> *attributes = @[@"src", @"data-src", @"data-original",
                                        @"data-lazy-src", @"data-original-src", @"data-url",
                                        @"srcset", @"data-srcset"];
    NSMutableDictionary<NSString *, NSString *> *images = [NSMutableDictionary dictionary];
    [anchorRe enumerateMatchesInString:html
                                options:0
                                  range:NSMakeRange(0, html.length)
                             usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSRange hrefRange = [match rangeAtIndex:1];
        if (hrefRange.location == NSNotFound) hrefRange = [match rangeAtIndex:2];
        if (hrefRange.location == NSNotFound) return;
        NSURL *pageURL = [NSURL URLWithString:SLEDecodeBasicEntities([html substringWithRange:hrefRange])
                                relativeToURL:baseURL];
        NSString *pageKey = SLEURLByStrippingFragment(pageURL).absoluteString;
        if (![allowed containsObject:pageKey] || images[pageKey] != nil) return;

        NSRange bodyRange = [match rangeAtIndex:3];
        if (bodyRange.location == NSNotFound) return;
        NSString *body = [html substringWithRange:bodyRange];
        NSTextCheckingResult *imageMatch = [imageRe firstMatchInString:body
                                                               options:0
                                                                 range:NSMakeRange(0, body.length)];
        if (!imageMatch) return;
        NSString *imageTag = [body substringWithRange:imageMatch.range];
        for (NSString *attribute in attributes) {
            NSString *raw = SLEFirstImageURLToken(SLEAttributeValue(imageTag, attribute), attribute);
            if (raw.length == 0) continue;
            NSURL *imageURL = SLESafePreviewURL(raw, baseURL);
            if (imageURL) {
                images[pageKey] = imageURL.absoluteString;
                break;
            }
        }
    }];

    // Some real listing pages render the cover beside, rather than inside, the
    // detail anchor. Their image URL carries the same stable id as watch?v=.
    // Preserve the stricter same-anchor result above and only fill missing keys.
    NSMutableDictionary<NSString *, NSString *> *pageKeyByVideoID = [NSMutableDictionary dictionary];
    for (NSString *pageKey in allowed) {
        NSString *videoID = SLEWatchVideoIdentifier([NSURL URLWithString:pageKey]);
        if (videoID.length && pageKeyByVideoID[videoID] == nil) pageKeyByVideoID[videoID] = pageKey;
    }
    if (pageKeyByVideoID.count) {
        [imageRe enumerateMatchesInString:html
                                   options:0
                                     range:NSMakeRange(0, html.length)
                                usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            NSString *imageTag = [html substringWithRange:match.range];
            for (NSString *attribute in attributes) {
                NSURL *imageURL = SLESafePreviewURL(SLEFirstImageURLToken(SLEAttributeValue(imageTag, attribute), attribute), baseURL);
                NSString *videoID = SLECoverVideoIdentifier(imageURL);
                NSString *pageKey = videoID.length ? pageKeyByVideoID[videoID] : nil;
                if (pageKey.length && images[pageKey] == nil) {
                    images[pageKey] = imageURL.absoluteString;
                    break;
                }
            }
        }];
    }
    return [images copy];
}

@end
