// RDPreviewPlaylistRewrite.m — HLS master 钉选改写（第 35 轮预览播放）：把 master 清单改写为仅含目标变体的单变体清单；逐行处理保留原文语义；纯函数，无 IO、无网络。

#import "RDPreviewPlaylistRewrite.h"

#pragma mark - 结果对象

@interface RDPreviewPlaylistResult ()
@property (nonatomic, copy, readwrite) NSString *rewrittenPlaylist;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *remoteURLs;
@property (nonatomic, assign, readwrite) BOOL succeeded;
- (instancetype)initWithPlaylist:(NSString *)playlist URLs:(NSArray<NSString *> *)urls succeeded:(BOOL)succeeded;
@end

@implementation RDPreviewPlaylistResult
- (instancetype)initWithPlaylist:(NSString *)playlist URLs:(NSArray<NSString *> *)urls succeeded:(BOOL)succeeded {
    if (self = [super init]) {
        _rewrittenPlaylist = [playlist copy];
        _remoteURLs = [urls copy] ?: @[];
        _succeeded = succeeded;
    }
    return self;
}
@end

#pragma mark - 私有工具

static BOOL RDIsHTTPScheme(NSURL *u) {
    if (!u) return NO;
    NSString *s = [u.scheme lowercaseString];
    return [s isEqualToString:@"http"] || [s isEqualToString:@"https"];
}

// URL 绝对化结果：Keep＝原样保留（空值或已带 scheme 的绝对 URL，协议不限）；
// Rewritten＝相对路径已基于 base 绝对化；Failed＝相对路径无法绝对化（base 缺失或解析失败）。
typedef NS_ENUM(int, RDAbsState) {
    RDAbsKeep = 0,
    RDAbsRewritten = 1,
    RDAbsFailed = 2,
};

// 解析出将写入输出的 URL 文本。已带 scheme 的原样保留；相对路径基于 base 解析且必须落在
// http(s) 上，否则判 Failed——改写结果经本地环回交给 AVPlayer，任何相对 URL 都会指向环回而失效。
static RDAbsState RDAbsoluteURLForOutput(NSString *raw, NSURL *base, NSString **outAbs) {
    *outAbs = raw;
    if (raw.length == 0) return RDAbsKeep;
    NSURL *parsed = [NSURL URLWithString:raw];
    if (parsed && parsed.scheme.length > 0) return RDAbsKeep;
    if (!base) return RDAbsFailed;
    NSURL *resolved = [NSURL URLWithString:raw relativeToURL:base];
    if (!resolved) return RDAbsFailed;
    NSURL *abs = resolved.absoluteURL;
    if (!RDIsHTTPScheme(abs)) return RDAbsFailed;
    NSString *s = abs.absoluteString;
    if (s.length == 0) return RDAbsFailed;
    *outAbs = s;
    return RDAbsRewritten;
}

// 匹配用：把变体行换算成可与 pinned 比对的形态（pinned 通常已是归一化绝对 URL，master 内可能是相对路径）。
static NSString *RDResolveForMatch(NSString *raw, NSURL *base) {
    if (raw.length == 0) return raw;
    NSURL *parsed = [NSURL URLWithString:raw];
    if (parsed && parsed.scheme.length > 0) return raw;
    if (!base) return nil;
    NSURL *resolved = [NSURL URLWithString:raw relativeToURL:base];
    return resolved.absoluteURL.absoluteString;
}

static BOOL RDMatchesPinned(NSString *raw, NSURL *base, NSString *pinned) {
    if (pinned.length == 0 || raw.length == 0) return NO;
    if ([raw isEqualToString:pinned]) return YES;
    NSString *abs = RDResolveForMatch(raw, base);
    if (abs.length > 0 && [abs isEqualToString:pinned]) return YES;
    NSURL *a = abs.length > 0 ? [NSURL URLWithString:abs] : nil;
    NSURL *p = [NSURL URLWithString:pinned];
    return a && p && [a isEqual:p];
}

// 在属性串的一段（引号外按逗号切分）里定位 URI 属性引号内值的 range；找不到返回 {NSNotFound,0}。
static NSRange RDURIValueInRange(NSString *attrs, NSRange seg) {
    NSRange none = NSMakeRange(NSNotFound, 0);
    if (seg.location == NSNotFound || seg.location + seg.length > attrs.length) return none;
    NSString *part = [attrs substringWithRange:seg];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSUInteger p = 0, plen = part.length;
    while (p < plen && [ws characterIsMember:[part characterAtIndex:p]]) p++;
    if (plen - p < 6) return none;  // 最短形态 URI=""（6 字符，空值放行给调用方处理）
    NSString *rest = [part substringFromIndex:p];
    if ([[rest substringToIndex:4] caseInsensitiveCompare:@"URI="] != NSOrderedSame) return none;
    if ([rest characterAtIndex:4] != '"') return none;
    NSRange q2 = [rest rangeOfString:@"\"" options:NSLiteralSearch range:NSMakeRange(5, rest.length - 5)];
    if (q2.location == NSNotFound) return none;
    return NSMakeRange(seg.location + p + 5, q2.location - 5);  // 引号内值在 attrs 中的绝对 range
}

// 在属性行中定位顶层 URI 属性（引号内逗号不参与切分）。
static NSRange RDFindQuotedURIValueRange(NSString *attrs) {
    NSUInteger len = attrs.length;
    NSUInteger segStart = 0;
    BOOL inQuote = NO;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [attrs characterAtIndex:i];
        if (inQuote) {
            if (c == '"') inQuote = NO;
        } else if (c == '"') {
            inQuote = YES;
        } else if (c == ',') {
            NSRange found = RDURIValueInRange(attrs, NSMakeRange(segStart, i - segStart));
            if (found.location != NSNotFound) return found;
            segStart = i + 1;
        }
    }
    return RDURIValueInRange(attrs, NSMakeRange(segStart, len - segStart));
}

// 把 #EXT-X-MEDIA / #EXT-X-SESSION-KEY 行内的 URI 属性值绝对化。
// *status：Keep＝行内无 URI 或 URI 已绝对（原样返回）；Rewritten＝已改写并收集；Failed＝相对且无法绝对化（整体失败）。
static NSString *RDAbsolutizeTagURI(NSString *line, NSString *tagPrefix, NSURL *base,
                                    NSMutableArray<NSString *> *collected, RDAbsState *status) {
    *status = RDAbsKeep;
    NSUInteger attrsOffset = tagPrefix.length;
    if (line.length <= attrsOffset) return line;
    NSRange attrsRange = NSMakeRange(attrsOffset, line.length - attrsOffset);
    NSString *attrs = [line substringWithRange:attrsRange];
    NSRange valueRange = RDFindQuotedURIValueRange(attrs);
    if (valueRange.location == NSNotFound) return line;
    NSString *raw = [attrs substringWithRange:valueRange];
    if (raw.length == 0) return line;
    NSString *abs = nil;
    RDAbsState st = RDAbsoluteURLForOutput(raw, base, &abs);
    if (st == RDAbsFailed) {
        *status = RDAbsFailed;
        return line;
    }
    if (st == RDAbsKeep) {
        if (RDIsHTTPScheme([NSURL URLWithString:raw]) && ![collected containsObject:raw]) [collected addObject:raw];
        return line;
    }
    *status = RDAbsRewritten;
    if (![collected containsObject:abs]) [collected addObject:abs];
    return [line stringByReplacingCharactersInRange:NSMakeRange(attrsRange.location + valueRange.location, valueRange.length)
                                          withString:abs];
}

// 兜底收集：从输出行提取全部绝对 http(s) URL（# 行扫引号内值，URL 行取整行），
// 保证 remoteURLs 覆盖改写后清单里出现的每一个 http(s) 地址。
static void RDSweepURLsFromLine(NSString *t, NSMutableArray<NSString *> *collected) {
    if (t.length == 0) return;
    if ([t hasPrefix:@"#"]) {
        NSUInteger start = 0;
        while (start < t.length) {
            NSRange q1 = [t rangeOfString:@"\"" options:NSLiteralSearch range:NSMakeRange(start, t.length - start)];
            if (q1.location == NSNotFound) break;
            NSRange q2 = [t rangeOfString:@"\"" options:NSLiteralSearch range:NSMakeRange(q1.location + 1, t.length - q1.location - 1)];
            if (q2.location == NSNotFound) break;
            NSString *val = [t substringWithRange:NSMakeRange(q1.location + 1, q2.location - q1.location - 1)];
            if (RDIsHTTPScheme([NSURL URLWithString:val]) && ![collected containsObject:val]) [collected addObject:val];
            start = q2.location + 1;
        }
    } else {
        if (RDIsHTTPScheme([NSURL URLWithString:t]) && ![collected containsObject:t]) [collected addObject:t];
    }
}

static RDPreviewPlaylistResult *RDFail(NSString *original) {
    return [[RDPreviewPlaylistResult alloc] initWithPlaylist:(original ?: @"") URLs:@[] succeeded:NO];
}

#pragma mark - 改写主流程

@implementation RDPreviewPlaylistRewrite

+ (RDPreviewPlaylistResult *)rewriteMaster:(NSString *)masterText
                                   baseURL:(NSString *)baseURL
                        pinnedVariantURL:(NSString *)pinnedVariantURL {
    if (masterText.length == 0) return RDFail(masterText);
    if (![masterText containsString:@"#EXT-X-STREAM-INF"]) {
        // 媒体清单（无变体声明）直通：调用方直连播放它，不改写、不收集。
        return [[RDPreviewPlaylistResult alloc] initWithPlaylist:masterText URLs:@[] succeeded:NO];
    }
    if (pinnedVariantURL.length == 0) return RDFail(masterText);
    NSURL *base = baseURL.length > 0 ? [NSURL URLWithString:baseURL] : nil;

    NSString *normalized = [masterText stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];

    NSMutableArray<NSString *> *emitted = [NSMutableArray array];
    NSMutableArray<NSString *> *collected = [NSMutableArray array];
    NSString *extm3uLine = nil, *versionLine = nil, *pendingINF = nil;
    BOOL matched = NO;

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;  // 空行丢弃
        if ([line hasPrefix:@"#"]) {
            if ([line hasPrefix:@"#EXTM3U"]) {
                if (!extm3uLine) extm3uLine = line;
            } else if ([line hasPrefix:@"#EXT-X-VERSION:"]) {
                if (!versionLine) versionLine = line;
            } else if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
                pendingINF = line;  // 与下一 URL 行配对；上一个未等到 URL 的声明作废
            } else if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
                RDAbsState st = RDAbsKeep;
                NSString *out = RDAbsolutizeTagURI(line, @"#EXT-X-MEDIA:", base, collected, &st);
                if (st == RDAbsFailed) return RDFail(masterText);
                [emitted addObject:out];  // 音轨声明统一保留（含未选中变体引用的组，防误删共享音轨）
            } else if ([line hasPrefix:@"#EXT-X-SESSION-KEY:"]) {
                RDAbsState st = RDAbsKeep;
                NSString *out = RDAbsolutizeTagURI(line, @"#EXT-X-SESSION-KEY:", base, collected, &st);
                if (st == RDAbsFailed) return RDFail(masterText);
                [emitted addObject:out];
            } else if ([line hasPrefix:@"#EXT"]) {
                [emitted addObject:line];  // 未知名的 #EXT-* 标签行：原样保留
            }
            // 其余 # 行为纯注释：丢弃（清单无注释语义）
        } else if (pendingINF) {
            if (!matched && RDMatchesPinned(line, base, pinnedVariantURL)) {
                NSString *abs = nil;
                RDAbsState st = RDAbsoluteURLForOutput(line, base, &abs);
                if (st == RDAbsFailed) return RDFail(masterText);  // 选中变体无法绝对化
                [emitted addObject:pendingINF];  // STREAM-INF 原行原样（含 AUDIO="group-id" 等引用）
                [emitted addObject:abs];
                if (RDIsHTTPScheme([NSURL URLWithString:abs]) && ![collected containsObject:abs]) [collected addObject:abs];
                matched = YES;
            }
            pendingINF = nil;  // 无论是否选中，该变体块已处理完毕
        }
        // 无 pending 的裸 URL 行：master 中未声明的散落地址，丢弃
    }

    if (!matched) return RDFail(masterText);

    NSMutableArray<NSString *> *outLines = [NSMutableArray array];
    [outLines addObject:extm3uLine ?: @"#EXTM3U"];
    if (versionLine) [outLines addObject:versionLine];
    [outLines addObjectsFromArray:emitted];
    for (NSString *l in outLines) RDSweepURLsFromLine(l, collected);

    NSString *playlist = [[outLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    return [[RDPreviewPlaylistResult alloc] initWithPlaylist:playlist URLs:collected succeeded:YES];
}

@end
