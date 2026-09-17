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
    NSMutableString *out = [NSMutableString stringWithCapacity:encoded.length];
    NSUInteger i = 0, n = encoded.length;
    while (i < n) {
        unichar ch = [encoded characterAtIndex:i];
        if (ch == '%' && i + 2 < n) {
            NSString *hex = [encoded substringWithRange:NSMakeRange(i + 1, 2)];
            unsigned int value = 0;
            NSScanner *scanner = [NSScanner scannerWithString:hex];
            if ([scanner scanHexInt:&value] && scanner.isAtEnd) {
                unichar decoded = (unichar)value;
                BOOL unreserved = (decoded >= 'A' && decoded <= 'Z') || (decoded >= 'a' && decoded <= 'z') ||
                                  (decoded >= '0' && decoded <= '9') || decoded == '-' || decoded == '.' ||
                                  decoded == '_' || decoded == '~';
                // 查询串里常见的可安全还原子分隔符（逗号是签名 URL 的典型差异：
                // DOM 序列化成 %2C，原始 HTML 是字面逗号）。& = + ; : @ / ? # 等
                // 会改变分隔语义，一律保持编码形式。
                BOOL safeSubDelim = decoded == ',' || decoded == '!' || decoded == '\'' ||
                                    decoded == '(' || decoded == ')' || decoded == '*';
                if (unreserved || safeSubDelim) [out appendFormat:@"%C", decoded];
                else [out appendFormat:@"%%%02X", value];
                i += 3;
                continue;
            }
        }
        [out appendFormat:@"%C", ch];
        i++;
    }
    return out;
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

// Logs intentionally contain neither URL paths, userinfo nor query/fragment data.
static inline NSString *RDRedactedURL(NSURL *url) {
    if (!url) return @"(none)";
    return url.host.length ? [NSString stringWithFormat:@"%@://%@/[redacted]",url.scheme ?: @"",url.host] : @"[redacted]";
}
