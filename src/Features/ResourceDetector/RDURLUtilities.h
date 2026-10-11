#import <Foundation/Foundation.h>

// Decode exactly one HTML attribute layer before interpreting URL syntax.
static inline NSString *RDDecodeHTMLAttribute(NSString *input) {
    if (!input.length) return input ?: @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|amp|quot|apos|lt|gt|nbsp);" options:0 error:nil];
    NSMutableString *out = [input mutableCopy];
    NSDictionary *named = @{@"amp":@"&",@"quot":@"\"",@"apos":@"'",@"lt":@"<",@"gt":@">",@"nbsp":@"\u00a0"};
    for (NSTextCheckingResult *m in [[re matchesInString:input options:0 range:NSMakeRange(0,input.length)] reverseObjectEnumerator]) {
        NSString *entity = [input substringWithRange:[m rangeAtIndex:1]], *value = named[entity];
        if ([entity hasPrefix:@"#"]) {
            unsigned int scalar = 0;
            if ([entity hasPrefix:@"#x"] || [entity hasPrefix:@"#X"]) [[NSScanner scannerWithString:[entity substringFromIndex:2]] scanHexInt:&scalar];
            else scalar = (unsigned int)[[entity substringFromIndex:1] longLongValue];
            if (!scalar || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) value = @"\ufffd";
            else if (scalar <= 0xffff) { unichar c = (unichar)scalar; value = [NSString stringWithCharacters:&c length:1]; }
            else { scalar -= 0x10000; unichar pair[] = {(unichar)(0xd800+(scalar>>10)),(unichar)(0xdc00+(scalar&1023))}; value = [NSString stringWithCharacters:pair length:2]; }
        }
        if (value) [out replaceCharactersInRange:m.range withString:value];
    }
    return out;
}

// RFC 3986 百分号编码规范化：未保留字符（ALPHA/DIGIT/-._~）解码回字面量，
// 其余字节统一大写十六进制。同一条资源经原始 HTML 与 DOM 序列化两条路径发现时
// 常常一个是 "…==,1789009206"、另一个是 "…==%2C1789009206"；不归一化就会被
// 当成两个资源，左侧出现同一影片的两个视频选项（2026-09-09 真实网址回归）。
// 注意：%2F 等保留字符的解码会改变路径语义，绝不处理。
static inline NSString *RDNormalizePercentEncoding(NSString *encoded) {
    if (!encoded.length) return encoded;
    // 性能修复（2026-10-07）：原实现逐字符调用 appendFormat:（每次创建格式化
    // 对象）与 substringWithRange:+NSScanner（每次创建两个对象）。真实站点
    // （tf1.fr 等大页面）的 URL 列表让这变成 CPU 灾难——采样显示 2107 个样本
    // 全部卡在 appendFormat: 上，整站探测卡死 120 秒。改为单次缓冲区填充：
    // 用 unichar 数组就地改写，最后一次性构造 NSString。语义完全不变
    //（同样的百分号解码/还原判据），只是不再逐字符分配对象。
    NSUInteger n = encoded.length;
    unichar *buf = (unichar *)malloc(sizeof(unichar) * n);
    if (!buf) return encoded;
    NSUInteger outLen = 0;
    for (NSUInteger i = 0; i < n; ) {
        unichar ch = [encoded characterAtIndex:i];
        if (ch == '%' && i + 2 < n) {
            unichar h1 = 0, h2 = 0;
            // 就地十六进制解析（免去 substring + NSScanner 的对象分配）
            unichar c1 = [encoded characterAtIndex:i + 1];
            unichar c2 = [encoded characterAtIndex:i + 2];
            if (c1 >= '0' && c1 <= '9') h1 = c1 - '0';
            else if (c1 >= 'a' && c1 <= 'f') h1 = c1 - 'a' + 10;
            else if (c1 >= 'A' && c1 <= 'F') h1 = c1 - 'A' + 10;
            else h1 = 0xFFFF;
            if (c2 >= '0' && c2 <= '9') h2 = c2 - '0';
            else if (c2 >= 'a' && c2 <= 'f') h2 = c2 - 'a' + 10;
            else if (c2 >= 'A' && c2 <= 'F') h2 = c2 - 'A' + 10;
            else h2 = 0xFFFF;
            if (h1 != 0xFFFF && h2 != 0xFFFF) {
                unsigned int value = (unsigned int)(h1 * 16 + h2);
                unichar decoded = (unichar)value;
                BOOL unreserved = (decoded >= 'A' && decoded <= 'Z') || (decoded >= 'a' && decoded <= 'z') ||
                                  (decoded >= '0' && decoded <= '9') || decoded == '-' || decoded == '.' ||
                                  decoded == '_' || decoded == '~';
                // 查询串里常见的可安全还原子分隔符（逗号是签名 URL 的典型差异：
                // DOM 序列化成 %2C，原始 HTML 是字面逗号）。& = + ; : @ / ? # 等
                // 会改变分隔语义，一律保持编码形式。
                BOOL safeSubDelim = decoded == ',' || decoded == '!' || decoded == '\'' ||
                                    decoded == '(' || decoded == ')' || decoded == '*';
                if (unreserved || safeSubDelim) {
                    buf[outLen++] = decoded;
                } else {
                    static const unichar kHex[] = u"0123456789ABCDEF";
                    buf[outLen++] = '%';
                    buf[outLen++] = kHex[(value >> 4) & 0xF];
                    buf[outLen++] = kHex[value & 0xF];
                    // 注意：显式编码会变长（%XX 三字符），但这里 outLen 永不超过
                    // 输入长度——因为每个 %XX 只在解码成单字符时才缩短，保持编码
                    // 形式时按原样三字符写回，长度相同。安全。
                }
                i += 3;
                continue;
            }
        }
        buf[outLen++] = ch;
        i++;
    }
    NSString *result = [[NSString alloc] initWithCharacters:buf length:outLen];
    free(buf);
    return result;
}

// Preserve all content parameters, escaped paths and non-default ports.
static inline NSString *RDCanonicalResourceURL(NSURL *url) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    if (!c) return url.absoluteString ?: @"";
    c.scheme = c.scheme.lowercaseString; c.host = c.host.lowercaseString; c.fragment = nil;
    if (([c.scheme isEqual:@"https"] && c.port.integerValue == 443) || ([c.scheme isEqual:@"http"] && c.port.integerValue == 80)) c.port = nil;
    if (!c.percentEncodedPath.length) c.percentEncodedPath = @"/";
    else c.percentEncodedPath = RDNormalizePercentEncoding(c.percentEncodedPath);
    if (c.percentEncodedQuery.length) c.percentEncodedQuery = RDNormalizePercentEncoding(c.percentEncodedQuery);
    return c.URL.absoluteString ?: @"";
}

// CDN 签名/过期类参数名：同一资源每次取页会拿到不同签名值，用于“同一资源”
// 判定时必须忽略。只做启发式分组，绝不用于放行/拦截，也不改变下载身份。
static inline NSArray<NSString *> *RDEphemeralQueryKeyNames(void) {
    return @[@"expires", @"expire", @"token", @"secure", @"signature", @"sig", @"auth", @"exp"];
}

// 发现/展示层身份：在规范化 URL 的基础上忽略签名/过期类参数。
// 真实网址现场：静态取页与 WebKit 动态取页各拿到一份签名不同的同一地址
// （…secure=A,1789009206 与 …secure=B,1788998438），只按完整 URL 去重会让
// 同一部影片在左侧出现两个视频选项。下载身份仍使用保留全部参数的
// RDCanonicalResourceURL，两者互不替代。
static inline NSString *RDResourceGroupingIdentity(NSURL *url) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    if (!c) return RDCanonicalResourceURL(url);
    NSArray<NSString *> *ephemeralKeys = RDEphemeralQueryKeyNames();
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in c.queryItems ?: @[]) {
        BOOL ephemeral = NO;
        for (NSString *key in ephemeralKeys) {
            if ([item.name.lowercaseString isEqualToString:key]) { ephemeral = YES; break; }
        }
        if (!ephemeral) [kept addObject:item];
    }
    c.queryItems = kept.count ? kept : nil;
    return RDCanonicalResourceURL(c.URL);
}

#pragma mark - 画质变体识别（2026-10-10）

// 真实网址现场：X/Twitter 的同一段视频以「同目录、扩展名相同、分辨率分量不同」
// 的多个地址出现（…/vid/avc1/320x568/xx.mp4、…/480x852/yy.mp4、…/720x1280/zz.mp4）。
// 这类地址是同一条视频的不同画质变体，必须合成一行供用户切档；此前只按 URL
// 去重，于是同一段视频被拆成多行。
//
// 判据刻意保守：只有「路径第一处不同的分量确实是分辨率形态」才认定同族。
// 目录号、集号、文件名主干等非分辨率差异一律视为不同视频，绝不误合并。

// 路径分段（去掉前导斜杠产生的空串）。
static inline NSArray<NSString *> *RDPathSegments(NSURL *url) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *segment in [(url.path ?: @"") componentsSeparatedByString:@"/"]) {
        if (segment.length) [out addObject:segment];
    }
    return out;
}

// 分辨率形态分量（整段匹配）："1280x720" / "720x1280" / "720p" / "1080P"。
// 宽高都拿到时 outW>0；只解析出高度（"720p" 形态）时 outW=0、outH=720。
// 仅接受 3–4 位数字，普通编号（19 位媒体 id、"2024"）不会被当成分辨率。
static inline BOOL RDResolutionTokenValues(NSString *token, double *outW, double *outH) {
    if (!token.length || token.length > 12) return NO;
    NSArray<NSString *> *parts = [token componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"xX\u00d7"]];
    if (parts.count == 2) {
        NSString *a = parts[0], *b = parts[1];
        if (a.length < 3 || a.length > 4 || b.length < 3 || b.length > 4) return NO;
        for (NSUInteger i = 0; i < a.length; i++) {
            unichar c = [a characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
        for (NSUInteger i = 0; i < b.length; i++) {
            unichar c = [b characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
        double w = a.doubleValue, h = b.doubleValue;
        if (!(w > 0) || !(h > 0)) return NO;
        if (outW) *outW = w;
        if (outH) *outH = h;
        return YES;
    }
    if (token.length >= 4 && token.length <= 5) {
        unichar last = [token characterAtIndex:token.length - 1];
        if (last != 'p' && last != 'P') return NO;
        NSString *digits = [token substringToIndex:token.length - 1];
        for (NSUInteger i = 0; i < digits.length; i++) {
            unichar c = [digits characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
        double h = digits.doubleValue;
        if (!(h > 0)) return NO;
        if (outW) *outW = 0;
        if (outH) *outH = h;
        return YES;
    }
    return NO;
}

// 文件名主干尾部的分辨率标记："clip-720p" / "movie_1080p" / "v-1280x720"。
// 只认明确的末段标记；整体主干本身是分辨率的形态由上一条函数处理。
// baseOut 回传分隔符之前的主干（"movie_1080p" → "movie"）——同族判定必须要求
// 两条地址的主干相等：movie1-480p 与 movie2-720p 是两个不同视频，绝不误并。
static inline BOOL RDResolutionSuffixParts(NSString *stem, NSString **baseOut, double *outW, double *outH) {
    if (stem.length < 4) return NO;
    NSRange sep = [stem rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_. "] options:NSBackwardsSearch];
    if (sep.location == NSNotFound || sep.location + 1 >= stem.length) return NO;
    double w = 0, h = 0;
    if (!RDResolutionTokenValues([stem substringFromIndex:sep.location + 1], &w, &h)) return NO;
    if (baseOut) *baseOut = [stem substringToIndex:sep.location];
    if (outW) *outW = w;
    if (outH) *outH = h;
    return YES;
}

static inline BOOL RDResolutionSuffixInStem(NSString *stem, double *outW, double *outH) {
    return RDResolutionSuffixParts(stem, NULL, outW, outH);
}

// 从 URL 路径提取分辨率：目录段整段优先，其次文件名主干尾部标记。
static inline BOOL RDResolutionFromURLPath(NSURL *url, double *outW, double *outH) {
    NSArray<NSString *> *segments = RDPathSegments(url);
    if (!segments.count) return NO;
    for (NSUInteger i = 0; i + 1 < segments.count; i++) {
        double w = 0, h = 0;
        if (RDResolutionTokenValues(segments[i], &w, &h)) {
            if (outW) *outW = w;
            if (outH) *outH = h;
            return YES;
        }
    }
    NSString *stem = segments.lastObject.stringByDeletingPathExtension ?: @"";
    double w = 0, h = 0;
    if (RDResolutionTokenValues(stem, &w, &h) || RDResolutionSuffixInStem(stem, &w, &h)) {
        if (outW) *outW = w;
        if (outH) *outH = h;
        return YES;
    }
    return NO;
}

// 是否为「同一条视频的不同交付形态/画质」。全部判据满足才成立：
//   · host 相同（小写比较）、路径共同前缀至少 1 段 —— 排除第一段即不同的形态；
//   · A) 画质变体：扩展名相同，且第一处不同的分量是分辨率形态（目录段整段，
//        或文件名主干尾部标记）。例：…/vid/avc1/320x568/a.mp4 与 …/720x1280/b.mp4。
//   · B) 清单与直链：路径共同前缀至少 2 段（媒体 ID 级别），一方是流清单
//        （.m3u8/.mpd）、另一方是视频媒体。HLS master 与同片 mp4 直链是同一段
//        视频的两种交付形式，必须同行（否则同一视频仍被拆成两行）。
//        共同前缀要求 ≥2 段是刻意的：只有一段相同（如 /a/… 与 /b/…）不足以
//        证明同一视频，宁可拆开也不误并。
static inline BOOL RDIsManifestExtension(NSString *ext) {
    return [ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"mpd"];
}

static inline BOOL RDSameQualityVariantFamily(NSString *urlA, NSString *urlB) {
    NSURL *ua = [NSURL URLWithString:urlA ?: @""];
    NSURL *ub = [NSURL URLWithString:urlB ?: @""];
    if (!ua.host.length || !ub.host.length) return NO;
    if (![ua.host.lowercaseString isEqualToString:ub.host.lowercaseString]) return NO;
    NSString *extA = ua.path.pathExtension.lowercaseString ?: @"";
    NSString *extB = ub.path.pathExtension.lowercaseString ?: @"";
    if (!extA.length || !extB.length) return NO;
    NSArray<NSString *> *sa = RDPathSegments(ua);
    NSArray<NSString *> *sb = RDPathSegments(ub);
    if (!sa.count || !sb.count) return NO;
    NSUInteger common = 0;
    while (common < MIN(sa.count, sb.count) && [sa[common] isEqualToString:sb[common]]) common++;
    if (common == sa.count && common == sb.count) return NO;   // 路径完全相同：调用方已去重
    if (common == 0) return NO;                                // 共同前缀为空：不同视频
    // B) 清单与直链同族（同一媒体 ID 下的两种交付形式）
    if (common >= 2 && RDIsManifestExtension(extA) != RDIsManifestExtension(extB)) return YES;
    if (common >= sa.count || common >= sb.count) return NO;    // 前缀关系：不是变体
    if (![extA isEqualToString:extB]) return NO;                // A) 画质变体要求扩展名一致
    NSString *ta = sa[common], *tb = sb[common];
    double w1 = 0, h1 = 0, w2 = 0, h2 = 0;
    if (RDResolutionTokenValues(ta, &w1, &h1) && RDResolutionTokenValues(tb, &w2, &h2)) return YES;
    if (common == sa.count - 1 && common == sb.count - 1) {
        NSString *stemA = ta.stringByDeletingPathExtension ?: @"";
        NSString *stemB = tb.stringByDeletingPathExtension ?: @"";
        NSString *baseA = nil, *baseB = nil;
        if (RDResolutionSuffixParts(stemA, &baseA, &w1, &h1) && RDResolutionSuffixParts(stemB, &baseB, &w2, &h2) &&
            baseA.length && [baseA caseInsensitiveCompare:baseB] == NSOrderedSame) return YES;
    }
    return NO;
}

// 分桶键（一次 O(路径长度) 扫描，无逐对比较）：把大页面上的全量两两比较
// 降为「只在同键候选之间比较」。键是同族的必要条件——键相等才做完整判据
// 复核，键不同必不同族。没有分桶，几百条地址的大页面会退化成 O(n²)
//（第 32 轮同类教训：逐对比较 800 条地址实测 2.8 秒）。
//   dirKey    目录型分辨率分量（…/720x1280/…）＝ host|ext|分量下标|前缀段。
//             分量下标必须 ≥1：首段即分辨率时共同前缀为空，判据本就不成立。
//             下标 ≥1 的同键 ⇔ 前缀相同且都在同一下标出现分辨率分量。
//   fileKey   文件名型分辨率后缀（…/a-720p.mp4）＝ host|ext|目录|主干。
//   ownKindKey / crossKindKey 清单与直链 ＝ host|前两段|M 或 V；
//             直链查 M 槽、清单查 V 槽——只有跨类型的一对会被引到同一簇。
static inline NSString *RDQualityKindTagForExtension(NSString *ext) {
    if ([ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"mpd"]) return @"M";
    if (ext.length) return @"V";
    return nil;
}

static inline void RDQualityVariantBucketKeys(NSURL *url,
                                              NSString **dirKey,
                                              NSString **fileKey,
                                              NSString **ownKindKey,
                                              NSString **crossKindKey) {
    if (dirKey) *dirKey = nil;
    if (fileKey) *fileKey = nil;
    if (ownKindKey) *ownKindKey = nil;
    if (crossKindKey) *crossKindKey = nil;
    if (!url.host.length || !url.path.length) return;
    NSArray<NSString *> *segments = RDPathSegments(url);
    if (!segments.count) return;
    NSString *host = url.host.lowercaseString;
    NSString *ext = url.path.pathExtension.lowercaseString ?: @"";
    if (!ext.length) return;
    // 目录型分辨率分量：跳过首段（下标 0 ⇒ 共同前缀为空），取第一个命中位置
    for (NSUInteger i = 1; i + 1 < segments.count; i++) {
        double w = 0, h = 0;
        if (!RDResolutionTokenValues(segments[i], &w, &h)) continue;
        if (dirKey) {
            NSString *prefix = [[segments subarrayWithRange:NSMakeRange(0, i)] componentsJoinedByString:@"/"];
            *dirKey = [NSString stringWithFormat:@"%@|%@|%lu|%@", host, ext, (unsigned long)i, prefix];
        }
        break;
    }
    // 文件名型分辨率后缀（目录 + 主干一并入键：同键 ⇔ 同目录同主干）
    NSString *stem = segments.lastObject.stringByDeletingPathExtension ?: @"";
    NSString *base = nil;
    double w = 0, h = 0;
    if (RDResolutionSuffixParts(stem, &base, &w, &h) && base.length && fileKey) {
        NSString *dirs = segments.count > 1
            ? [[segments subarrayWithRange:NSMakeRange(0, segments.count - 1)] componentsJoinedByString:@"/"] : @"";
        *fileKey = [NSString stringWithFormat:@"%@|%@|%@|%@", host, ext, dirs.lowercaseString, base.lowercaseString];
    }
    // 清单/直链同族（媒体 ID 级别）
    if (segments.count >= 2) {
        NSString *tag = RDQualityKindTagForExtension(ext);
        if (tag) {
            NSString *stem2 = [NSString stringWithFormat:@"%@|%@/%@|", host, segments[0].lowercaseString, segments[1].lowercaseString];
            if (ownKindKey) *ownKindKey = [stem2 stringByAppendingString:tag];
            NSString *cross = [tag isEqualToString:@"M"] ? @"V" : @"M";
            if (crossKindKey) *crossKindKey = [stem2 stringByAppendingString:cross];
        }
    }
}

// Logs intentionally contain neither URL paths, userinfo nor query/fragment data.
static inline NSString *RDRedactedURL(NSURL *url) {
    if (!url) return @"(none)";
    return url.host.length ? [NSString stringWithFormat:@"%@://%@/[redacted]",url.scheme ?: @"",url.host] : @"[redacted]";
}
