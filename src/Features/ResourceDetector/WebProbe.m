//
//  WebProbe.m — 模块 17｜网页探测核心实现
//
#import "WebProbe.h"
#import "RDLog.h"
#import "RDManualVerification.h"   // 共享会话存储（探测 WebView 与验证窗口同一实例）
#import "RDURLUtilities.h"
#import "RDQualityTier.h"
#import "URLPolicy.h"
#import "DetectedMedia.h"
#import "AppError.h"
#import "HTTPClient.h"
#import "RequestGeneration.h"
#import "DNSResolver.h"
#import <WebKit/WebKit.h>
#import <stdatomic.h>
#import <math.h>

static BOOL RDIsHTTPURL(NSString *value) { NSURL *url=[NSURL URLWithString:value ?: @""]; NSString *scheme=url.scheme.lowercaseString; return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]; }

#pragma mark - RDProbeResult

@implementation RDProbeResult

- (RDResourceDisplayMetadata *)bestDisplayMetadataForSourcePageURL:(NSURL *)sourcePageURL {
    NSString *title = self.ogTitle.length ? self.ogTitle : self.pageTitle;
    if (!title.length) {
        // 退而求其次：取第一个 DetectedMedia 的 title（通常已用 pageTitle 填充）。
        for (DetectedMedia *m in self.media) {
            if (m.title.length) { title = m.title; break; }
        }
    }

    NSString *poster = nil;
    if (self.ogImageURL.length) {
        poster = self.ogImageURL;
    } else {
        for (DetectedMedia *m in self.media) {
            if (m.poster.length) { poster = m.poster; break; }
        }
    }

    RDDisplayMetadataConfidence confidence = RDDisplayMetadataConfidenceNone;
    if (title.length && poster.length) confidence = RDDisplayMetadataConfidenceMedium;
    else if (title.length || poster.length) confidence = RDDisplayMetadataConfidenceLow;

    return [RDResourceDisplayMetadata metadataWithTitle:title
                                        posterURLString:poster
                                    sourcePageURLString:sourcePageURL.absoluteString
                                             confidence:confidence];
}

@end

#pragma mark - RDProbeAnalyzer（纯函数）

@implementation RDProbeAnalyzer

+ (NSString *)absolutePosterURLString:(NSString *)poster baseURL:(NSURL *)baseURL {
    if (poster.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:[self absoluteURLString:poster baseURL:baseURL] ?: @""];
    return url.absoluteURL.absoluteString;
}

+ (NSString *)formatFromURL:(NSString *)url {
    NSString *ext = [NSURL URLWithString:url].pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4v"]) return @"mp4";
    if ([ext isEqualToString:@"webm"]) return @"webm";
    if ([ext isEqualToString:@"m3u8"]) return @"hls";
    if ([ext isEqualToString:@"mpd"]) return @"dash";
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"jpg";
    if ([ext isEqualToString:@"png"]) return @"png";
    if ([ext isEqualToString:@"gif"]) return @"gif";
    if ([ext isEqualToString:@"webp"]) return @"webp";
    if ([ext isEqualToString:@"avif"]) return @"avif";
    return @"unknown";
}

+ (NSString *)absoluteURLString:(NSString *)raw baseURL:(NSURL *)baseURL {
    if (!raw.length) return nil;
    NSString *value = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Bridge 合成标签会按 HTML 属性规则转义 &；在 URL 解析前还原一次，
    // 避免带 query/signature 的动态媒体被错误改成含有字面量 "&amp;" 的 URL。
    value = RDDecodeHTMLAttribute(value);
    if ([value hasPrefix:@"//"]) {
        value = [NSString stringWithFormat:@"%@:%@", baseURL.scheme.length ? baseURL.scheme : @"https", value];
    }
    NSURL *url = baseURL ? [NSURL URLWithString:value relativeToURL:baseURL] : [NSURL URLWithString:value];
    NSString *absolute = url.absoluteURL.absoluteString;
    if (!RDIsHTTPURL(absolute)) return nil;
    return absolute;
}

+ (NSString *)attributeValue:(NSString *)tag name:(NSString *)name {
    // 属性名左边界不能用 \b：ICU 中 “-” 是非单词字符，\bsrc 会命中
    // data-src（懒加载页常见写法），把图片/懒加载地址误提取为 src。
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        [NSString stringWithFormat:@"(?:^|[\\s\\\"'<])%@\\s*=\\s*(?:[\\\"']([^\\\"']+)[\\\"']|([^\\s\\\"'=<>`]+))", name]
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match || match.numberOfRanges < 3) return nil;
    NSRange range = [match rangeAtIndex:1];
    if (range.location == NSNotFound) range = [match rangeAtIndex:2];
    return range.location == NSNotFound ? nil : [tag substringWithRange:range];
}

+ (NSArray<NSString *> *)URLsFromSrcset:(NSString *)srcset baseURL:(NSURL *)baseURL {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (NSString *entry in [srcset componentsSeparatedByString:@","]) {
        NSString *raw = [[entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject;
        NSString *absolute = [self absoluteURLString:raw baseURL:baseURL];
        if (absolute.length) [urls addObject:absolute];
    }
    return urls;
}

+ (DetectedMedia *)imageMediaForURL:(NSString *)url result:(RDProbeResult *)result source:(NSString *)source {
    DetectedMedia *media = [DetectedMedia new];
    media.mediaURL = url;
    media.resourceKind = RDResourceKindImage;
    media.discoverySource = source;
    media.sourcePageURL = nil;
    media.title = result.pageTitle.length ? result.pageTitle : url.lastPathComponent;
    media.format = [self formatFromURL:url];
    media.thumbnailStatus = RDThumbnailNone;
    return media;
}

+ (void)applyBridgeMetadataFromTag:(NSString *)tag toMedia:(DetectedMedia *)media {
    for (NSString *key in @[@"durationSeconds",@"pixelWidth",@"pixelHeight"]) {
        NSString *text = [self attributeValue:tag name:[@"data-rd-" stringByAppendingString:key]];
        NSScanner *scanner = [NSScanner scannerWithString:text ?: @""]; double value = NAN;
        if ([scanner scanDouble:&value] && scanner.isAtEnd && isfinite(value) && value >= 0 && value <= 2147483647) {
            if ([key isEqual:@"durationSeconds"]) media.durationSeconds = @(value);
            else if (value > 0 && floor(value) == value && value <= 100000) [media setValue:@(value) forKey:key];
        }
    }
    NSString *poster = [self attributeValue:tag name:@"data-rd-poster"];
    if (poster.length) { NSString *url = [self absoluteURLString:poster baseURL:nil]; if (url) media.poster = url; }
    if (!tag.length || !media) return;
    NSString *mime = [self attributeValue:tag name:@"data-rd-mime"];
    if (mime.length) media.mimeType = mime;
    NSString *range = [self attributeValue:tag name:@"data-rd-range"];
    if (range.length) media.contentRange = range;
    NSString *size = [self attributeValue:tag name:@"data-rd-size"];
    if (size.length) media.sizeBytes = MAX(0, size.longLongValue);
    NSString *parent = [self attributeValue:tag name:@"data-rd-parent"];
    if (parent.length) media.parentMediaURL = parent;
    NSString *source = [self attributeValue:tag name:@"data-rd-source"];
    if (source.length) media.discoverySource = source;
    NSString *live = [self attributeValue:tag name:@"data-rd-live"];
    if (live.length) media.isLive = [live boolValue] || [live isEqualToString:@"1"];
    NSString *encrypted = [self attributeValue:tag name:@"data-rd-encrypted"];
    if (encrypted.length && ([encrypted boolValue] || [encrypted isEqualToString:@"1"])) {
        media.availabilityState = @"needsVerification";
        if (media.drmType == RDDrmNone) media.drmType = RDDrmUnknownProtected;
    }
    if (!media.availabilityState.length) media.availabilityState = @"downloadable";
}

+ (RDProbeResult *)analyzeHTML:(NSString * _Nullable)html baseURL:(NSURL * _Nullable)baseURL {
    RDProbeResult *r = [RDProbeResult new];
    r.media = @[];
    r.mediaClues = @[];
    if (html == nil || html.length == 0) {
        r.isBadPage = YES;       // 坏页面/无内容
        return r;
    }
    NSURL *sourcePageURL = baseURL;
    NSRegularExpression *baseRE = [NSRegularExpression regularExpressionWithPattern:@"<base\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *match in [baseRE matchesInString:html options:0 range:NSMakeRange(0,html.length)]) {
        NSString *href = [self attributeValue:[html substringWithRange:match.range] name:@"href"];
        if (href != nil) { NSString *resolved = [self absoluteURLString:href baseURL:baseURL]; if (resolved.length) baseURL = [NSURL URLWithString:resolved]; break; }
    }
    NSString *lower = [html lowercaseString];

    // 标题：优先 og:title，其次 <title>。og:title 通常已去掉站点后缀。
    // meta 属性顺序不固定（property/content 可以互换），逐标签读取属性。
    NSRegularExpression *metaTagRe = [NSRegularExpression regularExpressionWithPattern:@"<meta\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSString *(^metaAttr)(NSString *, NSString *) = ^NSString *(NSString *tag, NSString *name) {
        NSString *p = [NSString stringWithFormat:@"(?:^|[\\s\\\"'<])%@\\s*=\\s*(?:[\\\"']([^\\\"']+)[\\\"']|([^\\s\\\"'=<>`]+))", name];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
        if (!m || m.numberOfRanges < 3) return nil;
        NSRange a = [m rangeAtIndex:1]; if (a.location == NSNotFound) a = [m rangeAtIndex:2];
        return a.location == NSNotFound ? nil : [tag substringWithRange:a];
    };
    for (NSTextCheckingResult *mt in [metaTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:mt.range];
        NSString *property = [metaAttr(tag, @"property") lowercaseString];
        NSString *content = metaAttr(tag, @"content");
        if ([property isEqualToString:@"og:title"] && content.length && !r.ogTitle.length)
            r.ogTitle = [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([property isEqualToString:@"og:image"] && content.length && !r.ogImageURL.length)
            r.ogImageURL = [self absolutePosterURLString:content baseURL:baseURL];
    }

    NSRegularExpression *titleRe = [NSRegularExpression
        regularExpressionWithPattern:@"<title[^>]*>(.*?)</title>"
                             options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive
                               error:nil];
    NSTextCheckingResult *tm = [titleRe firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (tm && tm.numberOfRanges >= 2) {
        r.pageTitle = [html substringWithRange:[tm rangeAtIndex:1]];
    }


    // DRM 识别（不误报可下载）
    RDDrmType drm = RDDrmNone;
    if ([lower containsString:@"widevine"]) drm = RDDrmWidevine;
    else if ([lower containsString:@"fairplay"]) drm = RDDrmFairPlay;
    else if ([lower containsString:@"playready"]) drm = RDDrmPlayReady;
    r.drmType = drm;

    // 视频源：<video>/<source> 的 src
    NSMutableArray<DetectedMedia *> *found = [NSMutableArray array];
    NSRegularExpression *srcRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?:<(?:video|source)\\b[^>]*?[\\s\"']src\\s*=\\s*(?:[\"']([^\"']+)[\"']|([^\\s\"'=<>`]+)))"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSArray<NSTextCheckingResult *> *ms = [srcRe matchesInString:html options:0 range:NSMakeRange(0, html.length)];

    // <source type="image/*">（picture 下的图片源）不是视频候选：它在下方图片
    // 解析路径按 IMG 处理。这里先收集其 src 集合，视频主循环跳过，避免图片
    // URL 被按“无视频扩展名”误判为未知格式视频（kind 语义错误）。
    NSRegularExpression *sourceTagRe = [NSRegularExpression
        regularExpressionWithPattern:@"<source\\b[^>]*>"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSMutableSet<NSString *> *imageTypeSourceURLs = [NSMutableSet set];
    for (NSTextCheckingResult *st in [sourceTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *sourceTag = [html substringWithRange:st.range];
        NSString *sourceType = [self attributeValue:sourceTag name:@"type"].lowercaseString;
        if (![sourceType hasPrefix:@"image/"]) continue;
        NSString *raw = [self attributeValue:sourceTag name:@"src"];
        NSString *abs = [self absoluteURLString:raw baseURL:baseURL];
        if (abs.length) [imageTypeSourceURLs addObject:abs];
    }

    // 先扫描 <video> 开标签，建立 src -> poster 映射（poster 仅来自该 video 标签）
    NSMutableDictionary<NSString *, NSString *> *videoPosterBySrc = [NSMutableDictionary dictionary];
    NSRegularExpression *videoTagRe = [NSRegularExpression
        regularExpressionWithPattern:@"<video\\b[^>]*>"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    for (NSTextCheckingResult *vt in [videoTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:vt.range];
        NSString *(^attr)(NSString *) = ^NSString *(NSString *name){
            NSRegularExpression *ar = [NSRegularExpression regularExpressionWithPattern:
                [NSString stringWithFormat:@"(?:^|[\\s\\\"'<])%@\\s*=\\s*(?:[\\\"']([^\\\"']+)[\\\"']|([^\\s\\\"'=<>`]+))", name]
                                                                               options:NSRegularExpressionCaseInsensitive error:nil];
            NSTextCheckingResult *am = [ar firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
            if (!am || am.numberOfRanges < 3) return nil;
            NSRange valueRange = [am rangeAtIndex:1];
            if (valueRange.location == NSNotFound) valueRange = [am rangeAtIndex:2];
            return valueRange.location == NSNotFound ? nil : [tag substringWithRange:valueRange];
        };
        NSString *vsrc = attr(@"src");
        NSString *poster = attr(@"poster");
        if (vsrc.length && poster.length) {
            NSURL *abs = [NSURL URLWithString:[self absoluteURLString:vsrc baseURL:baseURL] ?: @""];
            NSString *key = abs.absoluteString;
            NSString *absolutePoster = [self absolutePosterURLString:poster baseURL:baseURL];
            if (key.length && absolutePoster.length) videoPosterBySrc[key] = absolutePoster;
        }
    }
    // 常见结构是 <video poster="..."><source ...><source ...></video>，
    // video 本身没有 src。把该 video 块内的所有 source 映射到同一 poster。
    NSRegularExpression *videoBlockRe=[NSRegularExpression
        regularExpressionWithPattern:@"<video\\b([^>]*)>(.*?)</video>"
                             options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators
                               error:nil];
    NSRegularExpression *posterRe=[NSRegularExpression
        regularExpressionWithPattern:@"(?:^|[\\s\\\"'<])poster\\s*=\\s*[\"']([^\"']+)[\"']"
                             options:NSRegularExpressionCaseInsensitive error:nil];
    for(NSTextCheckingResult *blockMatch in [videoBlockRe matchesInString:html options:0 range:NSMakeRange(0,html.length)]){
        NSString *block=[html substringWithRange:blockMatch.range];
        NSTextCheckingResult *posterMatch=[posterRe firstMatchInString:block options:0 range:NSMakeRange(0,block.length)];
        if(!posterMatch||posterMatch.numberOfRanges<2)continue;
        NSString *poster=[block substringWithRange:[posterMatch rangeAtIndex:1]];
        NSString *absolutePoster=[self absolutePosterURLString:poster baseURL:baseURL];
        if(!absolutePoster.length)continue;
        for(NSTextCheckingResult *sourceMatch in [srcRe matchesInString:block options:0 range:NSMakeRange(0,block.length)]){
            if(sourceMatch.numberOfRanges<3)continue;
            NSRange rawRange=[sourceMatch rangeAtIndex:1];
            if(rawRange.location==NSNotFound)rawRange=[sourceMatch rangeAtIndex:2];
            if(rawRange.location==NSNotFound)continue;
            NSString *raw=[block substringWithRange:rawRange];
            NSURL *abs=[NSURL URLWithString:[self absoluteURLString:raw baseURL:baseURL] ?: @""];
            if(abs.absoluteString.length)videoPosterBySrc[abs.absoluteString]=absolutePoster;
        }
    }

    for (NSTextCheckingResult *m in ms) {
        if (m.numberOfRanges < 3) continue;
        NSRange rawRange = [m rangeAtIndex:1]; if (rawRange.location == NSNotFound) rawRange = [m rangeAtIndex:2];
        if (rawRange.location == NSNotFound) continue;
        NSString *raw = [html substringWithRange:rawRange];
        NSURL *abs = [NSURL URLWithString:[self absoluteURLString:raw baseURL:baseURL] ?: @""];
        NSString *u = abs.absoluteString;
        if (u == nil || !RDIsHTTPURL(u)) continue;  // 仅 http/https
        if ([imageTypeSourceURLs containsObject:u]) continue;  // 图片型 source 走图片解析
        DetectedMedia *dm = [DetectedMedia new];
        dm.mediaURL = u;
        NSString *dmFormat = [self formatFromURL:u];
        dm.resourceKind = ([dmFormat isEqualToString:@"hls"] || [dmFormat isEqualToString:@"dash"]) ? RDResourceKindManifest : RDResourceKindVideo;
        dm.isManifest = (dm.resourceKind == RDResourceKindManifest);
        dm.discoverySource = @"static-video";
        dm.poster = videoPosterBySrc[u];  // 仅当该 video 标签自带 poster 时才附上
        dm.title = (r.pageTitle.length ? r.pageTitle : u.lastPathComponent);
        dm.format = dmFormat;
        dm.drmType = drm;
        dm.thumbnailStatus = RDThumbnailNone;
        [found addObject:dm];
    }

    // 补充现代网页常见的懒加载/预加载写法。许多站点不会把真实地址放在
    // video.src，而是放在 data-src、data-video、srcset 或 link[preload] 中。
    // 这些候选仍经过同一套绝对化与去重流程，不改变安全边界。
    NSRegularExpression *attrRe = [NSRegularExpression regularExpressionWithPattern:
        @"\\b(?:data-(?:src|video|file|url)|video-src)\\s*=\\s*(?:[\\\"']([^\\\"']+)[\\\"']|([^\\s\\\"'=<>`]+))"
        options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *match in [attrRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSRange valueRange = [match rangeAtIndex:1];
        if (valueRange.location == NSNotFound) valueRange = [match rangeAtIndex:2];
        if (valueRange.location == NSNotFound) continue;
        NSString *raw = [html substringWithRange:valueRange];
        NSURL *absolute = [NSURL URLWithString:[self absoluteURLString:raw baseURL:baseURL] ?: @""];
        NSString *u = absolute.absoluteString;
        if (!u.length || !RDIsHTTPURL(u)) continue;
        NSString *format = [self formatFromURL:u];
        if (![@[@"mp4",@"webm",@"hls",@"dash"] containsObject:format]) continue;
        DetectedMedia *dm = [DetectedMedia new]; dm.mediaURL = u;
        dm.resourceKind = ([format isEqualToString:@"hls"] || [format isEqualToString:@"dash"]) ? RDResourceKindManifest : RDResourceKindVideo;
        dm.isManifest = (dm.resourceKind == RDResourceKindManifest);
        dm.discoverySource = @"static-video-lazy";
        dm.title = r.pageTitle.length ? r.pageTitle : u.lastPathComponent;
        dm.format = format; dm.drmType = drm; dm.thumbnailStatus = RDThumbnailNone;
        [found addObject:dm];
    }

    NSRegularExpression *srcsetRe = [NSRegularExpression regularExpressionWithPattern:
        // 与 attributeValue 同理：\b 无法排除 data-srcset，改用属性名左边界。
        @"(?:^|[\\s\\\"'<])srcset\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *match in [srcsetRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *value = [html substringWithRange:[match rangeAtIndex:1]];
        for (NSString *candidate in [value componentsSeparatedByString:@","]) {
            // The HTML srcset grammar permits any ASCII whitespace between a
            // URL and its descriptor (tabs/newlines are common in generated
            // markup). Splitting on a literal space treated a tab-prefixed
            // descriptor as part of the URL and silently dropped the source.
            NSArray *parts = [candidate componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *raw = nil;
            for (NSString *part in parts) {
                if (part.length) { raw = part; break; }
            }
            NSURL *absolute = [NSURL URLWithString:[self absoluteURLString:raw baseURL:baseURL] ?: @""];
            NSString *u = absolute.absoluteString;
            if (!u.length || !RDIsHTTPURL(u)) continue;
            NSString *format = [self formatFromURL:u];
            if (![@[@"mp4",@"webm",@"hls",@"dash"] containsObject:format]) continue;
            DetectedMedia *dm = [DetectedMedia new]; dm.mediaURL = u;
            dm.resourceKind = ([format isEqualToString:@"hls"] || [format isEqualToString:@"dash"]) ? RDResourceKindManifest : RDResourceKindVideo;
            dm.isManifest = (dm.resourceKind == RDResourceKindManifest);
            dm.discoverySource = @"static-video-srcset";
            dm.title = r.pageTitle.length ? r.pageTitle : u.lastPathComponent;
            dm.format = format; dm.drmType = drm; dm.thumbnailStatus = RDThumbnailNone;
            [found addObject:dm];
        }
    }

    // Attribute order is not significant in HTML. Parse each link tag and
    // then inspect rel/href independently so generated markup with href
    // before rel (or mixed quoting) is handled exactly like the conventional
    // order.
    NSRegularExpression *preloadTagRe = [NSRegularExpression regularExpressionWithPattern:
        @"<link\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *match in [preloadTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:match.range];
        NSString *rel = [self attributeValue:tag name:@"rel"];
        NSArray *relTokens = [rel.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![relTokens containsObject:@"preload"]) continue;
        NSString *raw = [self attributeValue:tag name:@"href"];
        if (!raw.length) continue;
        NSURL *absolute = [NSURL URLWithString:[self absoluteURLString:raw baseURL:baseURL] ?: @""];
        NSString *u = absolute.absoluteString;
        NSString *format = [self formatFromURL:u];
        if (!u.length || ![@[@"mp4",@"webm",@"hls",@"dash"] containsObject:format] || !RDIsHTTPURL(u)) continue;
        DetectedMedia *dm = [DetectedMedia new]; dm.mediaURL = u; dm.title = r.pageTitle.length ? r.pageTitle : u.lastPathComponent;
        dm.resourceKind = ([format isEqualToString:@"hls"] || [format isEqualToString:@"dash"]) ? RDResourceKindManifest : RDResourceKindVideo;
        dm.isManifest = (dm.resourceKind == RDResourceKindManifest);
        dm.discoverySource = @"static-video-preload";
        dm.format = format; dm.drmType = drm; dm.thumbnailStatus = RDThumbnailNone; [found addObject:dm];
    }

    // 图片来源：img/source srcset、懒加载属性以及社交元数据。所有候选先绝对化，
    // 再走统一 dedup；未知扩展名也保留，交由后续响应信息补充类型。
    NSRegularExpression *imageTagRe = [NSRegularExpression regularExpressionWithPattern:@"<(?:img|source)\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *match in [imageTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:match.range];
        NSString *tagName = [[tag componentsSeparatedByString:@" "].firstObject.lowercaseString stringByReplacingOccurrencesOfString:@"<" withString:@""];
        BOOL isImageSource = [tagName isEqualToString:@"source"] && [[self attributeValue:tag name:@"type"].lowercaseString hasPrefix:@"image/"];
        NSString *src = [self attributeValue:tag name:@"src"];
        if (src.length) {
            NSString *absolute = [self absoluteURLString:src baseURL:baseURL];
            if (absolute.length && ([tagName isEqualToString:@"img"] || isImageSource)) [found addObject:[self imageMediaForURL:absolute result:r source:@"static-img"]];
        }
        NSString *srcset = [self attributeValue:tag name:@"srcset"];
        for (NSString *absolute in [self URLsFromSrcset:srcset baseURL:baseURL]) {
            if ([tagName isEqualToString:@"img"] || isImageSource) [found addObject:[self imageMediaForURL:absolute result:r source:@"static-srcset"]];
        }
        for (NSString *name in @[@"data-src", @"data-lazy-src", @"data-original", @"data-url", @"data-original-src", @"data-image"]) {
            NSString *lazy = [self attributeValue:tag name:name];
            NSString *absolute = [self absoluteURLString:lazy baseURL:baseURL];
            if (absolute.length && [tagName isEqualToString:@"img"]) [found addObject:[self imageMediaForURL:absolute result:r source:@"static-lazy-img"]];
        }
    }
    for (NSTextCheckingResult *match in [metaTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:match.range];
        NSString *property = [self attributeValue:tag name:@"property"] ?: [self attributeValue:tag name:@"name"];
        NSString *content = [self attributeValue:tag name:@"content"];
        if (([property.lowercaseString isEqualToString:@"og:image"] || [property.lowercaseString isEqualToString:@"twitter:image"]) && content.length) {
            NSString *absolute = [self absoluteURLString:content baseURL:baseURL];
            if (absolute.length) [found addObject:[self imageMediaForURL:absolute result:r source:@"meta-image"]];
        }
    }
    NSRegularExpression *imageLinkRe = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *match in [imageLinkRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:match.range];
        if ([[self attributeValue:tag name:@"rel"].lowercaseString containsString:@"image_src"]) {
            NSString *absolute = [self absoluteURLString:[self attributeValue:tag name:@"href"] baseURL:baseURL];
            if (absolute.length) [found addObject:[self imageMediaForURL:absolute result:r source:@"link-image"]];
        }
    }

    // 去重
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<DetectedMedia *> *ordered = [NSMutableArray arrayWithCapacity:found.count];
    for (DetectedMedia *dm in found) {
        NSString *k = [DetectedMedia dedupKeyForURL:dm.mediaURL];
        if (k.length && ![seen containsObject:k]) { [seen addObject:k]; [ordered addObject:dm]; }
    }
    // 动态桥接事件以 data-rd-* 属性附带响应元数据。把这些元数据回填到
    // 已去重的统一模型，不让动态路径绕过静态分析器。
    // 同时收集"同一播放器身份"（data-rd-player）与该播放器的画质声明：
    // 静态 <video> 块与动态事件必须走同一套归组/档位归一化。
    NSMutableDictionary<NSString *, NSMutableArray<DetectedMedia *> *> *playerMembers = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<RDQualityCandidate *> *> *playerCandidates = [NSMutableDictionary dictionary];
    NSRegularExpression *bridgeTagRe = [NSRegularExpression regularExpressionWithPattern:@"<(?:video|img)\\b[^>]*>"
                                                                                     options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *bt in [bridgeTagRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:bt.range];
        NSString *raw = [self attributeValue:tag name:@"src"];
        NSString *absolute = [self absoluteURLString:raw baseURL:baseURL];
        if (!absolute.length) continue;
        NSString *key = [DetectedMedia dedupKeyForURL:absolute];
        DetectedMedia *matched = nil;
        for (DetectedMedia *dm in ordered) {
            if ([[DetectedMedia dedupKeyForURL:dm.mediaURL] isEqualToString:key]) {
                [self applyBridgeMetadataFromTag:tag toMedia:dm];
                matched = dm;
                break;
            }
        }
        NSString *player = [self attributeValue:tag name:@"data-rd-player"];
        if (!player.length || player.length > 32) continue;
        if (matched && matched.resourceKind != RDResourceKindImage) {
            if (!playerMembers[player]) playerMembers[player] = [NSMutableArray array];
            if (![playerMembers[player] containsObject:matched]) [playerMembers[player] addObject:matched];
        }
        NSString *declared = [self attributeValue:tag name:@"data-rd-quality"];
        if (declared.length > 32) declared = nil;
        double declaredWidth = [self attributeValue:tag name:@"data-rd-width"].doubleValue;
        double declaredHeight = [self attributeValue:tag name:@"data-rd-height"].doubleValue;
        if (!declared.length && !(declaredWidth > 0 && declaredHeight > 0)) continue;
        RDQualityCandidate *candidate = [RDQualityCandidate new];
        candidate.url = absolute;
        candidate.declaredLabel = declared;
        candidate.pixelWidth = declaredWidth;
        candidate.pixelHeight = declaredHeight;
        candidate.kind = RDResourceKindVideo;
        candidate.discoverySource = @"dynamic-video";
        if (!playerCandidates[player]) playerCandidates[player] = [NSMutableArray array];
        [playerCandidates[player] addObject:candidate];
    }
    for (NSTextCheckingResult *match in [videoBlockRe matchesInString:html options:0 range:NSMakeRange(0,html.length)]) {
        NSString *block = [html substringWithRange:match.range];
        NSString *familyID = [NSUUID UUID].UUIDString;
        NSMutableArray<RDQualityCandidate *> *candidates = [NSMutableArray array];
        // 同一播放器的全部成员地址：video 自身 src + 块内所有 source 的 src。
        // “属于同一播放器”与“是否声明标准画质”分开处理：缺声明的成员照样
        // 获得同组身份（否则 video.src / 无 size 的 source 会以独立行重复出现），
        // 但不参与档位归一化，也绝不伪造档位。
        NSMutableSet<NSString *> *memberURLs = [NSMutableSet set];
        NSTextCheckingResult *openTag = [videoTagRe firstMatchInString:block options:0 range:NSMakeRange(0,block.length)];
        if (openTag) {
            NSString *videoSrc = [self absoluteURLString:[self attributeValue:[block substringWithRange:openTag.range] name:@"src"] baseURL:baseURL];
            if (videoSrc.length && [@[@"http",@"https"] containsObject:[NSURL URLWithString:videoSrc].scheme.lowercaseString])
                [memberURLs addObject:videoSrc];
        }
        for (NSTextCheckingResult *source in [sourceTagRe matchesInString:block options:0 range:NSMakeRange(0,block.length)]) {
            NSString *tag = [block substringWithRange:source.range];
            NSString *url = [self absoluteURLString:[self attributeValue:tag name:@"src"] baseURL:baseURL];
            if (!url.length) continue;
            if (![@[@"http",@"https"] containsObject:[NSURL URLWithString:url].scheme.lowercaseString]) continue;
            // 地址身份与画质声明分开处理：同一 URL 只作为一个播放器成员参与分组，
            // 但该 URL 在 video.src / 其它 source 中再次出现时，仍必须读取并合并
            // size/label/width/height 声明。绝不能因为地址已经是成员就 continue
            // 跳过整个标签——否则 video.src 与某 source 同址时，该档位会被静默
            // 丢弃（用户实测：页面提供 480p+720p，却只剩 720p）。
            [memberURLs addObject:url];
            // 声明三来源：size/label 文本、width/height 数值属性。缺声明且无像素的
            // source 不虚构档位，跳过归一化；重复/冲突声明由 RDQualityTier 按
            // 同一 URL 去重（首次声明确定档位，缺失像素信息补全），确定性处理。
            RDQualityCandidate *candidate = [RDQualityCandidate new];
            candidate.url = url;
            candidate.declaredLabel = [self attributeValue:tag name:@"size"] ?: [self attributeValue:tag name:@"label"];
            if (candidate.declaredLabel.length > 32) candidate.declaredLabel = nil;
            candidate.pixelWidth = [self attributeValue:tag name:@"width"].doubleValue;
            candidate.pixelHeight = [self attributeValue:tag name:@"height"].doubleValue;
            if (!candidate.declaredLabel.length && !(candidate.pixelWidth > 0 && candidate.pixelHeight > 0)) continue;
            candidate.kind = RDResourceKindVideo;
            candidate.discoverySource = @"static-video";
            [candidates addObject:candidate];
        }
        // 统一归一化：静态声明与 HLS/DASH 清单共用同一套档位规则与去重，
        // 输出 label 只有标准三档，绝不私造第二套标签。
        // 成员数 ≥2 即构成同一播放器分组：全部成员写入稳定身份；存在标准档位
        // 时全部成员（含未声明画质的成员）共享同一份 declaredVariants——它们
        // 是同一影片的候选地址，不再是独立行，缺画质也不成为重复显示的理由。
        // 单成员块不写回分组/档位：它没有同族候选，写回会让"不同视频各自成行"
        // 的既有约定失效；单成员的动态同族由 data-rd-player 分组补齐。
        if (memberURLs.count >= 2) {
            NSArray *variants = candidates.count ? [RDQualityTier normalizedVariantsFromCandidates:candidates] : @[];
            for (DetectedMedia *media in ordered) {
                if (media.resourceKind == RDResourceKindImage || ![memberURLs containsObject:media.mediaURL]) continue;
                // 同一地址被多个播放器块共享时保持首次分组身份：后出现的块不得
                // 改写它的 family/variants，否则会把前一块的其他成员留在错误
                // 分组，或让后一块的独有成员被折叠吞掉。
                if (media.videoFamilyID.length) continue;
                media.videoFamilyID = familyID;
                if (variants.count >= 1) media.declaredVariants = variants;
            }
        }
    }
    // 动态播放器身份收尾：同一 <video> 元素（含其全部 <source>）的成员共享一个
    // 页面内稳定身份；若其中任一成员已由静态 <video> 块取得 family，则整组采用
    // 该 family（静态与动态不产生两组）；否则使用页面 + 播放器序号构造的身份。
    // 不同播放器身份互不相干，绝不把不同视频并成一行。
    if (playerMembers.count) {
        NSString *pageKey = [DetectedMedia dedupKeyForURL:baseURL.absoluteString ?: @""];
        for (NSString *player in playerMembers) {
            NSMutableArray<DetectedMedia *> *members = playerMembers[player];
            NSString *family = nil;
            for (DetectedMedia *m in members) if (m.videoFamilyID.length) { family = m.videoFamilyID; break; }
            if (!family.length) family = [NSString stringWithFormat:@"%@#player:%@", pageKey.length ? pageKey : @"page", player];
            NSArray<NSDictionary *> *variants = nil;
            if (playerCandidates[player].count) variants = [RDQualityTier normalizedVariantsFromCandidates:playerCandidates[player]];
            for (DetectedMedia *m in members) {
                if (!m.videoFamilyID.length) m.videoFamilyID = family;
                if (variants.count >= 1 && variants.count > m.declaredVariants.count) m.declaredVariants = variants;
            }
        }
    }
    // Blob/MediaSource 只能证明播放器已经产生了播放线索，不能伪造一个可下载 URL。
    // 生产桥把它编码成 meta，结果仍然可解释且不会进入下载列表。
    NSRegularExpression *clueRe = [NSRegularExpression regularExpressionWithPattern:@"<meta\\b[^>]*\\bname\\s*=\\s*[\\\"']rd-unresolved-clue[\\\"'][^>]*>"
                                                                                  options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableArray *clues = [NSMutableArray array];
    for (NSTextCheckingResult *cm in [clueRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:cm.range];
        NSString *value = [self attributeValue:tag name:@"content"] ?: @"unresolved-media";
        [clues addObject:@{@"type": value}];
    }
    r.mediaClues = [clues copy];
    r.unresolvedMediaClueCount = clues.count;
    for (DetectedMedia *media in ordered) media.sourcePageURL = sourcePageURL.absoluteString;
    r.media = [ordered copy];
    r.hasVideo = (r.media.count > 0) || ([lower containsString:@"<video"]);
    return r;
}

@end

#pragma mark - RDBridgeEventSynthesizer

@implementation RDBridgeEventSynthesizer

+ (NSString *)syntheticHTMLForEvent:(NSDictionary *)event {
    if (![event isKindOfClass:[NSDictionary class]]) return @"";
    NSString *action = [event[@"action"] isKindOfClass:[NSString class]] ? event[@"action"] : @"";
    if ([action isEqualToString:@"clue"]) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : @"unresolved-media";
        NSString *message = [event[@"message"] isKindOfClass:[NSString class]] ? event[@"message"] : kind;
        NSString *safe = [message stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
        safe = [safe stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
        safe = [safe stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        safe = [safe stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        return [NSString stringWithFormat:@"<meta name=\"rd-unresolved-clue\" content=\"%@\">", safe];
    }
    if (![action isEqualToString:@"resource"]) return @"";
    NSString *u = [event[@"url"] isKindOfClass:[NSString class]] ? event[@"url"] : @"";
    NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : @"video";
    if (u.length == 0) return @"";
    if (!([kind isEqualToString:@"image"] || [kind isEqualToString:@"video"] || [kind isEqualToString:@"manifest"])) return @"";
    // 与 JS 侧 / RDProbeAnalyzer 的双重 http(s) 约束保持一致；blob URL 只能作为 clue，
    // 不允许伪造成可下载资源。本地回环/IP 字面量
    // 由下游 URLPolicy/ResourceURLGate 语义过滤，此处仅收敛到合法 scheme。
    if (!RDIsHTTPURL(u)) return @"";
    NSString *tag = [kind isEqualToString:@"image"] ? @"img" : @"video";
    NSString *escaped = [u stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    NSString *source = [event[@"source"] isKindOfClass:[NSString class]] ? event[@"source"] : @"";
    if (source.length) {
        source = [source stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
        source = [source stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    }
    NSMutableArray *attrs = [NSMutableArray array];
    if (source.length) [attrs addObject:[NSString stringWithFormat:@"data-rd-source=\"%@\"", source]];
    NSDictionary *fields = @{@"mimeType": @"data-rd-mime", @"contentRange": @"data-rd-range",
                             @"contentLength": @"data-rd-size", @"parentURL": @"data-rd-parent",
                             @"live": @"data-rd-live", @"encrypted": @"data-rd-encrypted",
                             @"durationSeconds": @"data-rd-durationSeconds", @"pixelWidth": @"data-rd-pixelWidth",
                             @"pixelHeight": @"data-rd-pixelHeight", @"poster": @"data-rd-poster",
                             // 同一播放器身份与源站画质声明：让动态发现与静态 <video> 块
                             // 走同一套归组/档位归一化（同一播放器一行、不同播放器不合并）。
                             @"player": @"data-rd-player", @"size": @"data-rd-quality",
                             @"width": @"data-rd-width", @"height": @"data-rd-height"};
    for (NSString *key in fields) {
        id value = event[key];
        if ([value isKindOfClass:[NSNumber class]]) value = [value stringValue];
        if (![value isKindOfClass:[NSString class]] || ![(NSString *)value length]) continue;
        NSString *v = [(NSString *)value stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
        v = [v stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
        [attrs addObject:[NSString stringWithFormat:@"%@=\"%@\"", fields[key], v]];
    }
    NSString *suffix = attrs.count ? [NSString stringWithFormat:@" %@", [attrs componentsJoinedByString:@" "]] : @"";
    return [NSString stringWithFormat:@"<%@ src=\"%@\" data-rd-kind=\"%@\"%@></%@>", tag, escaped, kind, suffix, tag];
}

@end

#pragma mark - RDScriptBridgeHandler

@implementation RDScriptBridgeHandler

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxStringLength = 2048;
        _maxItems = 64;
        _maxTotalBytes = 64 * 1024;
        _acceptedCount = 0;
        _rejectedCount = 0;
    }
    return self;
}

- (NSSet<NSString *> *)allowedKeys {
    // 固定字段集合，超出即拒绝
    return [NSSet setWithArray:@[@"action", @"media", @"title", @"quality", @"url", @"kind", @"source",
                                 @"mimeType", @"contentLength", @"contentRange", @"status", @"live",
                                 @"encrypted", @"parentURL", @"blobURL", @"message", @"durationSeconds", @"pixelWidth", @"pixelHeight", @"poster",
                                 // 同一播放器身份（p1、p2…）与源站画质声明（size/label/width/height）
                                 @"player", @"size", @"width", @"height"]];
}

- (BOOL)validateBridgePayload:(id)body reason:(NSString * _Nullable * _Nullable)reason {
    if (![body isKindOfClass:[NSDictionary class]]) {
        if (reason) *reason = @"body 必须是字典";
        return NO;
    }
    NSDictionary *d = (NSDictionary *)body;
    if (d.count > self.maxItems) {
        if (reason) *reason = @"条目数超限";
        return NO;
    }
    NSSet *allowed = [self allowedKeys];
    NSUInteger total = 0;
    for (NSString *key in d) {
        if (![allowed containsObject:key]) {
            if (reason) *reason = [NSString stringWithFormat:@"未知键: %@", key];
            return NO;
        }
        id val = d[key];
        if ([@[@"durationSeconds",@"pixelWidth",@"pixelHeight",@"width",@"height"] containsObject:key]) {
            if (![val isKindOfClass:NSNumber.class] || !isfinite([val doubleValue]) || [val doubleValue] < 0 || [val doubleValue] > INT_MAX) return NO;
            if (![key isEqual:@"durationSeconds"] && (floor([val doubleValue]) != [val doubleValue] || [val doubleValue] > 100000)) return NO;
        }
        // 播放器身份与画质声明是页面文本：限长后按字符串处理（数值由分析器再校验）。
        if ([@[@"player",@"size"] containsObject:key]) {
            if (![val isKindOfClass:[NSString class]] || [(NSString *)val length] > 32) {
                if (reason) *reason = @"播放器身份/画质声明非法";
                return NO;
            }
        }
        if ([val isKindOfClass:NSNumber.class]) { if (!isfinite([val doubleValue])) return NO; total += 32; }
        else if ([val isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)val;
            if (s.length > self.maxStringLength) { if (reason) *reason = @"字符串超长"; return NO; }
            total += [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        } else if ([val isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)val) {
                if (![item isKindOfClass:[NSString class]]) { if (reason) *reason = @"数组元素类型非法"; return NO; }
                NSString *s = (NSString *)item;
                if (s.length > self.maxStringLength) { if (reason) *reason = @"数组字符串超长"; return NO; }
                total += [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            }
        }
        else { if (reason) *reason = @"非法字段类型"; return NO; }
        if (total > self.maxTotalBytes) { if (reason) *reason = @"总负载超长"; return NO; }
    }
    return YES;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSString *reason = nil;
    if ([self validateBridgePayload:message.body reason:&reason]) {
        self.acceptedCount++;
        if (self.eventHandler) self.eventHandler((NSDictionary *)message.body);
    } else {
        self.rejectedCount++;
        // 拒绝：丢弃，不传递给业务
    }
}

@end

#pragma mark - GUI 取页器（WKWebView，仅 App 内使用）

static NSString * const RDProbeBridgeName = @"rdBridge";

static NSString *RDProbeRequestCaptureScript(void) {
    NSString *script = @"(function(){if(window.__zzRDRequestInstalled)return;window.__zzRDRequestInstalled=true;var seen=new Set(),maxSeen=4000;function post(u,kind,source,extra){try{u=new URL(u,location.href).href;}catch(e){return;}if(!/^https?:/i.test(u)||seen.size>=maxSeen||seen.has(kind+'|'+u))return;seen.add(kind+'|'+u);try{var p={action:'resource',url:u,kind:kind,source:source||'dynamic-request'};if(extra)Object.keys(extra).forEach(function(k){p[k]=extra[k];});window.webkit.messageHandlers.rdBridge.postMessage(p);}catch(e){}}function classify(u,ct){ct=(ct||'').toLowerCase();if(ct.indexOf('mpegurl')>=0||ct.indexOf('dash')>=0||/\\.(m3u8|mpd)(?:[?#]|$)/i.test(u))return 'manifest';if(ct.indexOf('video/')===0||/\\.(mp4|mov|m4v|webm|avi)(?:[?#]|$)/i.test(u))return 'video';if(ct.indexOf('image/')===0||/\\.(jpg|jpeg|png|webp|gif|avif|heic|heif)(?:[?#]|$)/i.test(u))return 'image';return '';};function meta(res,source){var h=res&&res.headers,ct=h&&h.get?h.get('content-type'):'';var k=classify(res.url,ct);if(k)post(res.url,k,source,{mimeType:ct||'',contentLength:h&&h.get?h.get('content-length')||'': '',contentRange:h&&h.get?h.get('content-range')||'':''});}var of=window.fetch;if(of)window.fetch=function(){var a=arguments;return of.apply(this,a).then(function(res){meta(res,'fetch');return res;});};var O=XMLHttpRequest.prototype.open,S=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(m,u){this.__zzURL=u;return O.apply(this,arguments);};XMLHttpRequest.prototype.send=function(){this.addEventListener('load',function(){var u=this.responseURL||this.__zzURL,ct=this.getResponseHeader&&this.getResponseHeader('content-type')||'',k=classify(u,ct);if(k)post(u,k,'xhr',{mimeType:ct||'',contentLength:this.getResponseHeader&&this.getResponseHeader('content-length')||'',contentRange:this.getResponseHeader&&this.getResponseHeader('content-range')||'',status:String(this.status||'')});});return S.apply(this,arguments);};function perf(){try{performance.getEntriesByType('resource').forEach(function(e){var k=classify(e.name,'');if(k)post(e.name,k,'performance');});}catch(e){}}try{if(window.PerformanceObserver){new PerformanceObserver(function(list){list.getEntries().forEach(function(e){var k=classify(e.name,'');if(k)post(e.name,k,'performance');});}).observe({type:'resource',buffered:true});}}catch(e){}perf();function clue(message){try{window.webkit.messageHandlers.rdBridge.postMessage({action:'clue',kind:'blob',source:'media-source',message:message||'blob/media-source 无法还原原始 URL'});}catch(e){}}try{var cu=URL.createObjectURL;URL.createObjectURL=function(o){var u=cu.apply(this,arguments);if(o&&((window.MediaSource&&o instanceof MediaSource)||String(o).indexOf('MediaSource')>=0))clue('MediaSource/Blob 播放线索已发现，但无法还原原始媒体 URL');return u;};}catch(e){}try{if(window.MediaSource&&MediaSource.prototype.addSourceBuffer){var asb=MediaSource.prototype.addSourceBuffer;MediaSource.prototype.addSourceBuffer=function(m){clue('MediaSource sourceBuffer MIME: '+String(m||''));return asb.apply(this,arguments);};}}catch(e){}function scanPlayers(){try{var list=[];if(window.videojs)list.push(window.videojs);if(window.jwplayer)list.push(window.jwplayer());if(window.Plyr)list.push(window.Plyr);if(window.dplayer)list.push(window.dplayer);if(window.art)list.push(window.art);list.forEach(function(p){var v=p&&p.el?p.el():p&&p.video?p.video:p&&p.media?p.media:p;if(v&&v.currentSrc)post(v.currentSrc,'video','player');if(v&&v.src)post(v.src,'video','player');});}catch(e){}}scanPlayers();['click','scroll','play'].forEach(function(ev){document.addEventListener(ev,function(){setTimeout(function(){perf();scanPlayers();},0);},true);});function scanRoot(root){try{root.querySelectorAll&&root.querySelectorAll('img,video,source').forEach(function(e){var u=e.currentSrc||e.getAttribute('src')||e.getAttribute('data-src');if(u){var k=classify(u,e.type);if(k)post(u,k,'shadow-dom');}});}catch(e){}}var aa=Element.prototype.attachShadow;if(aa)Element.prototype.attachShadow=function(o){var r=aa.call(this,o);scanRoot(r);try{new MutationObserver(function(){scanRoot(r);}).observe(r,{subtree:true,childList:true,attributes:true,attributeFilter:['src','srcset','data-src','data-lazy-src','data-original']});}catch(e){}return r;};document.addEventListener('load',function(e){var f=e.target;if(f&&f.tagName==='IFRAME'){try{var d=f.contentDocument;if(d)scanRoot(d);}catch(x){}}},true);})();";
    return script;
}

static NSString *RDProbeDynamicCaptureScript(void) {
    // 注意：本脚本被生产代码按子串打补丁（见 beginSessionWithContext），
    // 以下两段必须原样保留：observe(document.documentElement 与
    // emitSet(el,'image','dynamic-image-srcset');return;
    return @"(function(){if(window.__zzRDInstalled)return;window.__zzRDInstalled=true;"
            "const seen=new Set();const observed=new WeakMap();const playerIds=new WeakMap();let nextPlayerId=1;let frameToken='';"
            // 同一 <video> 元素的稳定身份：video.src 与其内部全部 source.src 共享；
            // 不同 <video> 元素绝不共享，保证同片归组、不同片不误合并。
            // 播放器身份必须按"帧"隔离：广告/内嵌 iframe 各自有独立 JS 上下文，
            // 序号都从 1 开始；只用序号会让主片与广告片共享同一身份（真实网址实测
            // 广告视频继承了主片画质声明）。用本帧 URL 的短哈希做前缀。
            "function frameKey(){if(!frameToken){let h=0,s=String(location.href||'');for(let i=0;i<s.length;i++){h=(h*31+s.charCodeAt(i))|0;}frameToken=(h>>>0).toString(36);}return frameToken;}"
            "function playerId(el){if(!el||!el.tagName)return '';let host=el.tagName.toLowerCase()==='source'?el.parentElement:el;"
            "if(!host||!host.tagName||host.tagName.toLowerCase()!=='video')return '';let id=playerIds.get(host);"
            "if(!id){id=frameKey()+'.p'+(nextPlayerId++);playerIds.set(host,id);}return id;}"
            "function metadata(e){if(!e||e.tagName!=='VIDEO'||!e.currentSrc)return;const u=e.currentSrc;if(!/^https?:/i.test(u))return;"
            "const p={action:'resource',url:u,kind:'video',source:'dom-metadata',player:playerId(e)};"
            "if(Number.isFinite(e.duration)&&e.duration>=0)p.durationSeconds=e.duration;"
            "if(Number.isInteger(e.videoWidth)&&e.videoWidth>0)p.pixelWidth=e.videoWidth;"
            "if(Number.isInteger(e.videoHeight)&&e.videoHeight>0)p.pixelHeight=e.videoHeight;"
            "if(e.poster){try{const poster=new URL(e.poster,document.baseURI).href;if(/^https?:/i.test(poster))p.poster=poster;}catch(x){}}"
            "const signature=JSON.stringify(p);if(observed.get(e)===signature)return;observed.set(e,signature);"
            "window.webkit.messageHandlers.rdBridge.postMessage(p);}"
            "['loadedmetadata','durationchange','resize'].forEach(ev=>document.addEventListener(ev,e=>metadata(e.target),true));"
            "const lazy=['data-src','data-lazy-src','data-original','data-url','data-original-src','data-image'];"
            "function abs(u){try{return new URL(u,document.baseURI).href}catch(e){return ''}}"
            "function emit(kind,u,source,extra){u=abs(u);if(!u||!/^https?:/i.test(u)||seen.has(kind+'|'+u))return;seen.add(kind+'|'+u);"
            "const p={action:'resource',media:[u],kind:kind,url:u,source:source||'dynamic-dom'};"
            "if(extra)Object.keys(extra).forEach(function(k){const v=extra[k];if(v!==undefined&&v!==null&&v!=='')p[k]=v;});"
            "window.webkit.messageHandlers.rdBridge.postMessage(p);}"
            "function value(el){if(!el)return '';return el.getAttribute('src')||el.currentSrc||lazy.map(a=>el.getAttribute(a)).find(Boolean)||'';}"
            "function isPictureSource(el){return el&&el.tagName&&el.tagName.toLowerCase()==='source'&&el.parentElement&&el.parentElement.tagName.toLowerCase()==='picture';}"
            "function emitSet(el,kind,source,extra){let set=el.getAttribute('srcset')||el.getAttribute('data-srcset')||'';"
            "set.split(',').forEach(x=>{let u=x.trim().split(/\\s+/)[0];if(u)emit(kind,u,source,extra);});}"
            // 源站声明（size/label 文本、width/height 数值）随事件上报，交给统一的
            // RDQualityTier 归一化；缺失声明不伪造档位。
            "function sourceDecl(el){const out={};if(!el||!el.getAttribute)return out;"
            "const size=el.getAttribute('size')||el.getAttribute('label');if(size&&size.length<=32)out.size=size;"
            "const w=parseInt(el.getAttribute('width'),10),h=parseInt(el.getAttribute('height'),10);"
            "if(Number.isFinite(w)&&w>0&&w<=100000)out.width=w;if(Number.isFinite(h)&&h>0&&h<=100000)out.height=h;return out;}"
            "function scan(el){if(!el||!el.tagName)return;let t=el.tagName.toLowerCase(),picture=isPictureSource(el),"
            "type=(el.getAttribute('type')||'').toLowerCase(),u=value(el);"
            "if(t==='img'||(t==='source'&&picture)){if(u)emit('image',u,t==='img'?'dynamic-img':'dynamic-picture-source');"
            "emitSet(el,'image','dynamic-image-srcset');return;}"
            "if(t==='video'){metadata(el);const pid=playerId(el);if(u){"
            "if(/\\.(m3u8|mpd)(?:$|[?#])/i.test(u))emit('manifest',u,'dynamic-video',{player:pid});"
            "else emit('video',u,'dynamic-video',{player:pid});}"
            "emitSet(el,'video','dynamic-video-srcset',{player:pid});"
            "lazy.forEach(a=>{let v=el.getAttribute(a);if(v){"
            "if(/\\.(m3u8|mpd)(?:$|[?#])/i.test(v))emit('manifest',v,'dynamic-video-lazy',{player:pid});"
            "else emit('video',v,'dynamic-video-lazy',{player:pid});}});return;}"
            "if(t==='source'){const pid=playerId(el),decl=sourceDecl(el);if(u){"
            "let manifest=type.indexOf('mpegurl')>=0||type.indexOf('dash')>=0||/\\.(m3u8|mpd)(?:$|[?#])/i.test(u);"
            "const extra=Object.assign({player:pid},decl);"
            "if(manifest)emit('manifest',u,'dynamic-video-source',extra);else emit('video',u,'dynamic-video-source',extra);}"
            "emitSet(el,'video','dynamic-video-srcset',Object.assign({player:pid},decl));}}"
            "function scanTree(n){if(n.nodeType!==1)return;scan(n);n.querySelectorAll&&n.querySelectorAll('img,video,source').forEach(scan);}"
            "scanTree(document.documentElement);"
            "new MutationObserver(ms=>ms.forEach(m=>{if(m.type==='childList')m.addedNodes.forEach(scanTree);"
            "else if(m.type==='attributes')scan(m.target);})).observe(document.documentElement,{subtree:true,childList:true,attributes:true,"
            "attributeFilter:['src','srcset','data-srcset','data-src','data-lazy-src','data-original','data-url','data-original-src','data-image','type','size','label','width','height']});})();";
}

// 任务 ID 唯一来源：原子递增，任意线程分配均无数据竞争。
static NSUInteger RDProbeNextTaskID(void) {
    static _Atomic(unsigned long) counter = 0;
    return (NSUInteger)atomic_fetch_add_explicit(&counter, 1, memory_order_relaxed) + 1;
}

// 默认工厂：主线程创建离屏 WKWebView（loadRequest: 返回值按协议约定忽略）。
@implementation RDDefaultWebViewFactory
- (id<RDProbeWebView>)makeWebViewWithConfiguration:(WKWebViewConfiguration *)configuration {
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    return (id<RDProbeWebView>)webView;
}
@end

// 任务上下文（不可变快照）：绑定 URL / policy / completion / 任务 token /
// HTML 上限。init 之后只读，因此可安全地在任意线程构造并异步传给主线程；
// 取消状态由会话对象在主线程维护（cancelled）。
@interface RDWebProbeTaskContext : NSObject
- (instancetype)initWithTaskID:(NSUInteger)taskID
                           url:(NSURL *)url
                        policy:(URLPolicy *)policy
                  maxHTMLBytes:(NSUInteger)maxHTMLBytes
                    completion:(void (^)(NSString * _Nullable, AppError * _Nullable))completion;
@property (nonatomic, readonly) NSUInteger taskID;             // 任务 token（唯一凭据）
@property (nonatomic, readonly, copy) NSURL *url;
@property (nonatomic, readonly, strong) URLPolicy *policy;
@property (nonatomic, readonly, assign) NSUInteger maxHTMLBytes;
@property (nonatomic, copy, readonly, nullable) void (^completion)(NSString * _Nullable, AppError * _Nullable);
@end

@implementation RDWebProbeTaskContext

- (instancetype)initWithTaskID:(NSUInteger)taskID
                           url:(NSURL *)url
                        policy:(URLPolicy *)policy
                  maxHTMLBytes:(NSUInteger)maxHTMLBytes
                    completion:(void (^)(NSString * _Nullable, AppError * _Nullable))completion {
    self = [super init];
    if (self) {
        _taskID = taskID;
        _url = [url copy];
        _policy = policy;
        _maxHTMLBytes = maxHTMLBytes;
        _completion = [completion copy];
    }
    return self;
}

@end

// 主线程会话：一次 loadPageAtURL 的全部 WebKit 对象与完成状态宿主。
// 除 init 外所有属性读写都发生在主线程（由 loader 统一调度），
// 因此 WebKit 主线程回调与本类之间不存在跨线程数据竞争。
@interface RDWebProbeSession : NSObject
- (instancetype)initWithContext:(RDWebProbeTaskContext *)context;
@property (nonatomic, strong, readonly) RDWebProbeTaskContext *context;
@property (nonatomic, strong, nullable) id<RDProbeWebView> webView;                 // 本会话专属
@property (nonatomic, strong, nullable) WKUserContentController *userContentController;
@property (nonatomic, strong, nullable) RDScriptBridgeHandler *bridge;
@property (nonatomic, strong) NSMutableString *dynamicHTML;
@property (nonatomic, copy) NSURL *navigationURL;
@property (nonatomic, assign) BOOL cancelled;   // 被顶替/取消/detach：迟到回调一律丢弃
@property (nonatomic, assign, readonly) BOOL completionDelivered;
// completion 恰好一次投递；仅主线程调用。返回是否真正投递（已取消/已完成 → NO）。
- (BOOL)deliverCompletionWithHTML:(NSString * _Nullable)html error:(AppError * _Nullable)error;
@end

@implementation RDWebProbeSession {
    // 主线程专用的待投递 completion（init 时从不可变上下文复制）；
    // 投递一次后置空，保证每任务恰好一次。
    void (^_pending)(NSString * _Nullable, AppError * _Nullable);
}

- (instancetype)initWithContext:(RDWebProbeTaskContext *)context {
    self = [super init];
    if (self) {
        _context = context;
        _navigationURL = context.url;
        _pending = [context.completion copy];
        _dynamicHTML = [NSMutableString string];
    }
    return self;
}

- (BOOL)deliverCompletionWithHTML:(NSString *)html error:(AppError *)error {

    if (error) RDLogWrite(@"probe", @"页面探测失败 type=%ld 文案=%@", (long)error.type, error.message ?: @"");
    else RDLogWrite(@"probe", @"页面探测成功 html=%lu 字节", (unsigned long)html.length);
    NSAssert([NSThread isMainThread], @"RDWebProbeSession 投递必须在主线程");
    if (_cancelled || _pending == nil) return NO;
    void (^cb)(NSString * _Nullable, AppError * _Nullable) = _pending;
    _pending = nil;   // 恰好一次：先摘除再调用，迟到的重复触发直接失效
    cb(html, error);
    return YES;
}

- (BOOL)completionDelivered {
    return _pending == nil;
}

@end

@interface RDWebViewProbeLoader () <WKNavigationDelegate>
// 以下状态仅在主线程读写：
@property (nonatomic, strong) id<RDProbeWebViewFactory> factory;
@property (nonatomic, strong, nullable) RDWebProbeSession *session;   // 当前在途会话
@property (nonatomic, assign) BOOL detached;                          // 已拆除（可复活）
@end

@implementation RDWebViewProbeLoader

+ (NSString *)dynamicCaptureScriptForTesting { return RDProbeDynamicCaptureScript(); }
+ (NSString *)requestCaptureScriptForTesting { return RDProbeRequestCaptureScript(); }

- (instancetype)init {
    return [self initWithWebViewFactory:[RDDefaultWebViewFactory new]];
}

- (instancetype)initWithWebViewFactory:(id<RDProbeWebViewFactory>)factory {
    self = [super init];
    if (self) {
        _factory = factory ?: [RDDefaultWebViewFactory new];
        _maxHTMLBytes = 8 * 1024 * 1024;
    }
    return self;
}

#pragma mark 取页入口（任意线程）

- (nullable HTTPTask *)loadPageAtURL:(NSURL *)url
                              policy:(URLPolicy *)policy
                          completion:(void (^)(NSString * _Nullable, AppError * _Nullable))completion {
    return [self loadPageAtURL:url policy:policy maxHTMLBytes:self.maxHTMLBytes completion:completion];
}

- (nullable HTTPTask *)loadPageAtURL:(NSURL *)url
                              policy:(URLPolicy *)policy
                         maxHTMLBytes:(NSUInteger)maxHTMLBytes
                          completion:(void (^)(NSString * _Nullable, AppError * _Nullable))completion {
    if (url == nil || completion == nil) return nil;
    // 独立任务上下文：在本线程构造不可变快照（含本次 HTML 上限与任务 token），
    // 随后只通过异步消息交给主线程；本方法不触碰任何主线程状态。
    RDWebProbeTaskContext *ctx = [[RDWebProbeTaskContext alloc]
        initWithTaskID:RDProbeNextTaskID()
                   url:url
                policy:policy ?: [URLPolicy new]
          maxHTMLBytes:MAX(maxHTMLBytes, 1)
            completion:completion];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self beginSessionWithContext:ctx];
    });
    return nil;  // 取消由 WebProbe generation + cancelActiveLoad/detach 统一驱动
}

#pragma mark 会话生命周期（仅主线程）

- (void)beginSessionWithContext:(RDWebProbeTaskContext *)ctx {

    RDLogWrite(@"probe", @"WebKit 会话开始 url=%@", ctx.url.absoluteString ?: @"(nil)");
    NSAssert([NSThread isMainThread], @"WKWebView 会话只能在主线程创建");
    // 复用规则：detach 只是“已拆除”，新任务到来即重建会话（loader 保持可复用）；
    // 旧会话先作废——其迟到导航/JS 回调将因 cancelled 或身份不匹配被丢弃，
    // 绝不可能触碰新任务上下文或启动新页面。
    [self invalidateActiveSessionOnMainThread];
    self.detached = NO;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];   // 主线程
    // 会话延续（第 13 轮）：这里原来用 nonPersistentDataStore 做会话隔离，
    // 结果是每次探测都是全新访客，用户手动完成人机验证拿到的通行证也无法用于真正的
    // 资源探测。现改为 App 容器内的持久化存储，并与手动验证窗口共用同一实例
    // （既让同源会话自然延续，也保证探测与验证窗口确实看到同一个会话）。
    // 边界与隐私不变：只用 App 自己的存储，不共享/不读取 Safari 数据；
    // Cookie 只由 WebKit 自己保管，本代码不读取、不打印、不导出。
    cfg.websiteDataStore = [RDManualVerificationController sharedSessionDataStore];
    RDScriptBridgeHandler *bridge = [RDScriptBridgeHandler new];
    RDWebProbeSession *session = [[RDWebProbeSession alloc] initWithContext:ctx];
    __weak RDWebProbeSession *weakSession = session;
    bridge.eventHandler = ^(NSDictionary *event) {
        RDWebProbeSession *s = weakSession;
        if (!s || s.cancelled) return;
        NSString *html = [RDBridgeEventSynthesizer syntheticHTMLForEvent:event];
        if (html.length && [s.dynamicHTML lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [html lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < s.context.maxHTMLBytes) [s.dynamicHTML appendString:html];
    };
    [cfg.userContentController addScriptMessageHandler:bridge name:RDProbeBridgeName];   // 主线程

    session.bridge = bridge;
    NSString *dynamicScript=[RDProbeDynamicCaptureScript() stringByReplacingOccurrencesOfString:@"observe(document.documentElement" withString:@"observe(document"];
    dynamicScript=[dynamicScript stringByAppendingString:RDProbeRequestCaptureScript()];
    dynamicScript=[dynamicScript stringByReplacingOccurrencesOfString:@"emitSet(el,'image','dynamic-image-srcset');return;" withString:@"lazy.forEach(a=>{let v=el.getAttribute(a);if(v)emit('image',v,'dynamic-lazy-img');});emitSet(el,'image','dynamic-image-srcset');return;"];
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:dynamicScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    session.userContentController = cfg.userContentController;
    session.webView = [self.factory makeWebViewWithConfiguration:cfg];     // 主线程创建
    session.webView.navigationDelegate = self;                             // 主线程设置
    self.session = session;
    [session.webView loadRequest:[NSURLRequest requestWithURL:ctx.url]];   // 主线程发起
}

// 作废当前会话并安全清理其 WebKit 对象（仅主线程）。
- (void)invalidateActiveSessionOnMainThread {
    NSAssert([NSThread isMainThread], @"stopLoading/removeScriptMessageHandlerForName 只允许在主线程调用");
    RDWebProbeSession *old = self.session;
    self.session = nil;
    if (!old || old.cancelled) return;
    old.cancelled = YES;              // 迟到的导航/JS 回调全部失效，不再投递任何结果
    id<RDProbeWebView> webView = old.webView;
    WKUserContentController *ucc = old.userContentController;
    old.webView = nil;
    old.userContentController = nil;
    old.bridge = nil;
    if (!webView) return;
    webView.navigationDelegate = nil;                       // 断开 delegate 强引用环
    [webView stopLoading];                                  // 主线程
    [ucc removeScriptMessageHandlerForName:RDProbeBridgeName];   // 主线程
}

- (void)cancelActiveLoad {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self invalidateActiveSessionOnMainThread];
    });
}

// 页面离开：拆除当前 WebKit 会话；loader 不进入永久不可复用状态
// （下一次 loadPageAtURL 会自动重建）。
- (void)detach {
    void (^teardown)(void) = ^{
        [self invalidateActiveSessionOnMainThread];
        self.detached = YES;
    };
    if ([NSThread isMainThread]) teardown();
    else dispatch_async(dispatch_get_main_queue(), teardown);
}

#pragma mark WKNavigationDelegate（WebKit 保证主线程回调）

// 页面提交后快速检查 DOM，用于跳过广告/图片/预载的尾部等待。
//
// 两个前提（2026-09-09 真实网址回归后收紧）：
//   1) 文档必须已解析完成（readyState = interactive/complete）。流式页面在
//      传输过程中也能查到 preload/og:image 两条媒体；此时投递得到的是只有
//      <head> 前缀的半个文档，同一影片会因缺少 <video> 块而丢掉 family/
//      画质声明/poster，进而在左侧显示成第二行、详情退化为视频抽帧。
//   2) DOM 里必须已经出现可归组的播放器结构（非图片媒体带 family）。没有播放器
//      的页面继续等 didFinish，避免图片懒加载事件被提前截断。
// 检查分两步：先做廉价的 readyState/播放器探测，只有确认可投递时才序列化整个
// DOM（500KB 级页面的 outerHTML 序列化本身不便宜）。
- (void)captureEarlyMediaHTMLForSession:(RDWebProbeSession *)session
                                webView:(WKWebView *)webView {
    if (!session || session.cancelled || session.completionDelivered || self.session != session ||
        session.webView != (id<RDProbeWebView>)webView) return;
    __weak typeof(self) wself = self;
    __weak RDWebProbeSession *wsession = session;
    [webView evaluateJavaScript:@"document.readyState+'|'+(document.querySelector('video')?'1':'0')"
              completionHandler:^(id _Nullable value, NSError * _Nullable error) {
        __strong typeof(wself) s = wself;
        RDWebProbeSession *mine = wsession;
        if (!s || !mine || mine.cancelled || mine.completionDelivered || s.session != mine || error ||
            ![value isKindOfClass:NSString.class]) return;
        NSString *probe = (NSString *)value;
        NSRange separator = [probe rangeOfString:@"|"];
        if (separator.location == NSNotFound) return;
        NSString *readyState = [probe substringToIndex:separator.location];
        BOOL parsed = [readyState isEqualToString:@"interactive"] || [readyState isEqualToString:@"complete"];
        BOOL hasPlayer = [[probe substringFromIndex:separator.location + 1] isEqualToString:@"1"];
        if (!parsed || !hasPlayer) return;
        [webView evaluateJavaScript:@"document.documentElement.outerHTML"
                  completionHandler:^(id _Nullable html, NSError * _Nullable htmlError) {
            __strong typeof(wself) s2 = wself;
            RDWebProbeSession *mine2 = wsession;
            if (!s2 || !mine2 || mine2.cancelled || mine2.completionDelivered || s2.session != mine2 ||
                htmlError || ![html isKindOfClass:NSString.class]) return;
            NSString *out = [NSString stringWithFormat:@"%@%@", (NSString *)html, mine2.dynamicHTML ?: @""];
            if (out.length == 0 || [out lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > mine2.context.maxHTMLBytes) return;
            RDProbeResult *preview = [RDProbeAnalyzer analyzeHTML:out baseURL:mine2.context.url];
            BOOL grouped = NO;
            for (DetectedMedia *m in preview.media) {
                if (m.resourceKind != RDResourceKindImage && m.videoFamilyID.length) { grouped = YES; break; }
            }
            if (!grouped) return;   // 播放器结构尚未成形：交给 didFinish 路径
            [mine2 deliverCompletionWithHTML:out error:nil];
        }];
    }];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    RDWebProbeSession *session = self.session;
    if (!session || session.cancelled || session.webView != (id<RDProbeWebView>)webView) return;
    __weak typeof(self) wself = self;
    __weak RDWebProbeSession *wsession = session;
    // 轮询到 20s（硬超时之下）：文档一解析完就投递，不再空等 didFinish。
    // 每次检查只做一次廉价的 readyState/querySelector 求值。
    for (int i = 0; i <= 40; i++) {
        double delay = 0.35 + 0.5 * (double)i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(wself) s = wself;
            RDWebProbeSession *mine = wsession;
            if (!s || !mine || mine.cancelled || mine.completionDelivered || s.session != mine) return;
            [s captureEarlyMediaHTMLForSession:mine webView:webView];
        });
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                                                          decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    RDWebProbeSession *sess = self.session;   // 主线程读
    // 身份检查：旧页面的迟到导航决策不得影响新任务
    if (!sess || sess.cancelled || sess.webView != (id<RDProbeWebView>)webView) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    NSURL *target = navigationAction.request.URL;
    // 安全边界：主框架与子框架均执行 URLPolicy + DNS 校验。广告/内嵌 iframe
    // 常会访问被策略拒绝的地址；这类拒绝只取消该 iframe，不影响主页面结果。
    // WebKit 内部空白文档 about:blank（navigationType==Other）不访问网络，
    //    不是用户输入的网址，放行；
    // 主框架 http/https 导航（含重定向）仍逐跳经 URLPolicy 严格校验。

    if ([target.scheme.lowercaseString isEqualToString:@"about"] &&
        [target.absoluteString.lowercaseString isEqualToString:@"about:blank"] &&
        navigationAction.navigationType == WKNavigationTypeOther) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // 每次导航（含重定向与 DNS 解析后）都重新校验目标 URL
    URLPolicyDecision *d = [sess.context.policy evaluateRedirect:target fromURL:sess.navigationURL];
    if (!d.allowed) {
        if(navigationAction.targetFrame.isMainFrame) [sess deliverCompletionWithHTML:nil
                                  error:[AppError errorWithType:AppErrorPermission message:d.userMessage]];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    URLPolicy *policy = sess.context.policy;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        DNSResolutionStatus status=DNSResolutionSucceeded;
        NSArray<NSString *> *ips = [DNSResolver resolveIPsForHost:target.host ?: @"" status:&status];
        URLPolicyDecision *resolved = [policy evaluateResolvedURL:target resolvedIPs:ips resolutionStatus:status];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            RDWebProbeSession *current = self.session;
            if (!self || current != sess || sess.cancelled) {
                decisionHandler(WKNavigationActionPolicyCancel);
            } else {
                if (!resolved.allowed) {
                    // 子框架被拒绝时只取消该框架；主框架则必须结束本次探测，
                    // 并把 DNS/地址策略原因传给调用方，避免静默等待到超时。
                    if (navigationAction.targetFrame.isMainFrame) {
                        [sess deliverCompletionWithHTML:nil
                                                  error:[AppError errorWithType:AppErrorPermission
                                                                          message:resolved.userMessage]];
                    }
                    decisionHandler(WKNavigationActionPolicyCancel);
                    return;
                }
                if (navigationAction.targetFrame.isMainFrame) sess.navigationURL = target;
                decisionHandler(WKNavigationActionPolicyAllow);
            }
        });
    });
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    RDWebProbeSession *session=self.session;
    if(!session||session.cancelled||session.webView!=(id<RDProbeWebView>)webView){decisionHandler(WKNavigationResponsePolicyCancel);return;}
    NSHTTPURLResponse *http=[response.response isKindOfClass:NSHTTPURLResponse.class]?(id)response.response:nil;
    // An HTTP error document is a read failure, not a successfully parsed empty
    // page. Do not let the dynamic leg hide the static leg's HTTP failure.
    if(response.isForMainFrame && http.statusCode>=400){
        [session deliverCompletionWithHTML:nil error:[AppError errorWithType:AppErrorHTTP httpStatusCode:http.statusCode
            message:[NSString stringWithFormat:@"页面读取失败：HTTP %ld",(long)http.statusCode]]];
        decisionHandler(WKNavigationResponsePolicyCancel);return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    RDWebProbeSession *sess = self.session;   // 主线程读
    // 旧页面完成回调：丢弃。旧页面绝不触发任何新动作/新页面/新 completion。
    if (!sess || sess.cancelled || sess.completionDelivered || sess.webView != (id<RDProbeWebView>)webView) return;
    __weak typeof(self) wself = self;
    __weak RDWebProbeSession *wsess = sess;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    if(sess.cancelled || sess.completionDelivered || self.session != sess)return;
    [webView evaluateJavaScript:@"document.documentElement.outerHTML"
              completionHandler:^(id _Nullable html, NSError * _Nullable err) {
        __strong typeof(wself) s = wself;
        if (!s) return;
        RDWebProbeSession *cur = s.session;      // 主线程读：当前会话
        RDWebProbeSession *mine = wsess;
        // 迟到的 evaluateJavaScript 回调必须被丢弃：会话已被顶替/作废则静默返回
        if (!mine || !cur || cur != mine || mine.cancelled) return;
        if (err || ![html isKindOfClass:[NSString class]]) {
            [mine deliverCompletionWithHTML:nil
                                      error:[AppError errorWithType:AppErrorParse message:@"页面解析失败"]];
        } else {
            NSString *out = [NSString stringWithFormat:@"%@%@", (NSString *)html, sess.dynamicHTML ?: @""];
            if ([out lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > mine.context.maxHTMLBytes) {
                // 资源耗尽防护：超大 HTML 停止解析，不进入业务
                [mine deliverCompletionWithHTML:nil
                                          error:[AppError errorWithType:AppErrorFile message:@"页面过大，已停止解析"]];
            } else {
                [mine deliverCompletionWithHTML:out error:nil];
            }
        }
    }];
    });
}

#pragma mark 导航失败（网络级失败 → 立即终态，不再一律退化成「探测超时」）

// NSURLError → AppError：按真实原因分类，供用户与调用方区分
// 「域名不存在」/「连接被拒」/「TLS 失败」/「无网络」/「超时」。
// 说明：WKNavigation 只代表主框架导航，因此以下回调只会收到主框架的失败；
// 子框架（广告/内嵌 iframe）的失败不产生 WKNavigation，不会走到这里。
static AppError *RDWebProbeErrorFromNavigationError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) {
        return [AppError errorWithType:AppErrorOffline
                               message:[NSString stringWithFormat:@"页面读取失败：%@",
                                        error.localizedDescription ?: @"未知网络错误"]];
    }
    switch (error.code) {
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
            return [AppError errorWithType:AppErrorOffline message:@"DNS 解析失败：找不到该主机"];
        case NSURLErrorCannotConnectToHost:
            return [AppError errorWithType:AppErrorOffline message:@"连接失败：目标主机拒绝连接或不可达"];
        case NSURLErrorNotConnectedToInternet:
            return [AppError errorWithType:AppErrorOffline message:@"网络不可用：本机当前没有网络连接"];
        case NSURLErrorNetworkConnectionLost:
            return [AppError errorWithType:AppErrorOffline message:@"连接中断：网络连接已断开"];
        case NSURLErrorTimedOut:
            return [AppError errorWithType:AppErrorTimeout message:@"探测超时：目标在限定时间内没有响应"];
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
        case NSURLErrorClientCertificateRejected:
        case NSURLErrorClientCertificateRequired:
            return [AppError errorWithType:AppErrorPermission
                                   message:@"TLS 失败：无法建立安全连接（证书不受信任或握手失败）"];
        default:
            return [AppError errorWithType:AppErrorOffline
                                   message:[NSString stringWithFormat:@"页面读取失败：%@",
                                            error.localizedDescription ?: @"网络错误"]];
    }
}

// 供应期失败（DNS 失败、连接被拒、TLS 错误）：立即进入终态。
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    RDWebProbeSession *sess = self.session;
    if (!sess || sess.cancelled || sess.completionDelivered || sess.webView != (id<RDProbeWebView>)webView) return;
    // 主动取消不是失败：策略拒绝与会话作废都会取消导航，必须静默丢弃，
    // 否则会污染既有取消语义与双腿收尾行为。
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    [sess deliverCompletionWithHTML:nil error:RDWebProbeErrorFromNavigationError(error)];
}

// 提交之后的失败（连接中途断开等）：同样立即终态。
// 若早投递路径已交付结果，completionDelivered 守卫保证不会二次投递。
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    RDWebProbeSession *sess = self.session;
    if (!sess || sess.cancelled || sess.completionDelivered || sess.webView != (id<RDProbeWebView>)webView) return;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    [sess deliverCompletionWithHTML:nil error:RDWebProbeErrorFromNavigationError(error)];
}

@end

#pragma mark - WebProbe（generation + 取消 + 硬超时）

@interface WebProbe ()
@property (nonatomic, strong) RequestGeneration *gen;
@property (nonatomic, strong, nullable) HTTPTask *inFlight;
@property (nonatomic, strong, nullable) dispatch_source_t timeoutTimer;
@property (nonatomic, assign) NSUInteger currentGen;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@end

@implementation WebProbe

- (instancetype)initWithPolicy:(URLPolicy *)policy {
    self = [super init];
    if (self) {
        _policy = policy ?: [URLPolicy new];
        _gen = [RequestGeneration new];
        _hardTimeout = 30.0;
        _maxHTMLBytes = 8 * 1024 * 1024;
        _syncQueue = dispatch_queue_create("rd.webprobe", DISPATCH_QUEUE_SERIAL);
        _loader = [RDWebViewProbeLoader new];  // GUI 默认；测试注入 mock
    }
    return self;
}

- (void)dealloc {
    [self cancelTimer];
}

- (void)cancelTimer {
    if (self.timeoutTimer) {
        dispatch_source_cancel(self.timeoutTimer);
        self.timeoutTimer = nil;
    }
}

- (void)armTimerForGen:(NSUInteger)g completion:(void (^)(RDProbeResult *, AppError *, NSUInteger))completion {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.syncQueue);
    self.timeoutTimer = t;
    int64_t ns = (int64_t)(self.hardTimeout * NSEC_PER_SEC);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, ns), DISPATCH_TIME_FOREVER, 0);
    __weak typeof(self) w = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(w) s = w;
        if (!s) return;
        if (g != s.currentGen || s.finished) return;
        s.finished = YES;
        [s cancelTimer];
        s.currentGen = [s.gen nextGeneration];     // 使迟到的真实回调失效
        [s.inFlight cancel];
        // 真实 WebView loader：同步让在途会话失效（异步到主线程停止加载）
        id<RDProbeLoader> loader = s.loader;
        if ([loader respondsToSelector:@selector(cancelActiveLoad)]) {
            [(id)loader cancelActiveLoad];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [AppError errorWithType:AppErrorTimeout message:@"探测超时"], g);
            });
        }
    });
    dispatch_resume(t);
}

- (NSUInteger)probeURL:(NSString *)urlString
            completion:(void (^)(RDProbeResult * _Nullable, AppError * _Nullable, NSUInteger))completion {
    __block NSUInteger g;
    dispatch_sync(self.syncQueue, ^{
    [self cancelOnStateQueue];
    g = self.currentGen;
    self.finished = NO;

    // 时机 1：文本阶段策略校验
    URLPolicyDecision *d = [self.policy evaluateTextURL:urlString];
    if (!d.allowed) {
        self.finished = YES;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [AppError errorWithType:AppErrorPermission message:d.userMessage], g);
        });
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) {
        self.finished = YES;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [AppError errorWithType:AppErrorParse message:@"URL 无效"], g);
        });
        return;
    }
    [self cancelTimer];
    __weak typeof(self) w = self;
    // 资源耗尽防护：HTML 上限随任务上下文逐次传入 loader，
    // 不再跨线程写 loader 属性（旧实现存在后台写 / 主线程读的竞争）。
    id<RDProbeLoader> loader = self.loader;
    void (^onHTML)(NSString * _Nullable, AppError * _Nullable) = ^(NSString *html, AppError *error) {
        __strong typeof(w) s = w;
        if (!s) return;
        // Always enqueue, including synchronous loaders. Timer setup finishes
        // before accepting HTML; one serial terminal gate handles every race.
        dispatch_async(s.syncQueue, ^{
            if (g != s.currentGen || s.finished) return;
            s.finished = YES;
            [s cancelTimer];
            s.inFlight = nil;
            RDProbeResult *r = error ? nil : [RDProbeAnalyzer analyzeHTML:html baseURL:url];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(r, error, g); });
        });
    };
    HTTPTask *task = nil;
    if ([loader respondsToSelector:@selector(loadPageAtURL:policy:maxHTMLBytes:completion:)]) {
        task = [(id)loader loadPageAtURL:url
                                  policy:self.policy
                            maxHTMLBytes:self.maxHTMLBytes
                              completion:onHTML];
    } else {
        task = [loader loadPageAtURL:url policy:self.policy completion:onHTML];
    }
    self.inFlight = task;
    [self armTimerForGen:g completion:completion];
    });
    return g;
}

- (void)cancelAll {
    dispatch_sync(self.syncQueue, ^{ [self cancelOnStateQueue]; });
}

- (void)cancelOnStateQueue {
    // Invalidate before calling a loader that may synchronously report cancellation.
    self.finished = YES;
    self.currentGen = [self.gen nextGeneration];
    [self.inFlight cancel];
    self.inFlight = nil;
    // 真实 WebView loader：让在途会话立即失效（异步主线程，不阻塞、不触发其 completion）
    id<RDProbeLoader> loader = self.loader;
    if ([loader respondsToSelector:@selector(cancelActiveLoad)]) {
        [(id)loader cancelActiveLoad];
    }
    [self cancelTimer];
}

- (void)detachWebView {
    if ([self.loader isKindOfClass:[RDWebViewProbeLoader class]]) {
        [(RDWebViewProbeLoader *)self.loader detach];
    }
}

@end
