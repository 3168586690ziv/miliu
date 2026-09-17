//
//  HTTPPrivacyPolicy.m — 模块 08｜请求隐私头策略实现
//
#import "HTTPPrivacyPolicy.h"

@implementation HTTPPrivacyPolicy

+ (nullable NSString *)originForURL:(NSURL *)url {
    if (url == nil) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0 || url.user != nil || url.password != nil) return nil;
    NSNumber *port = url.port;
    BOOL defaultPort = !port || ([scheme isEqualToString:@"https"] ? port.integerValue == 443 : port.integerValue == 80);
    return defaultPort ? [NSString stringWithFormat:@"%@://%@", scheme, host]
                       : [NSString stringWithFormat:@"%@://%@:%@", scheme, host, port];
}

+ (nullable NSString *)refererHeaderForRequestURL:(NSURL *)requestURL
                                     fromPageURL:(NSURL *)pageURL {
    NSString *reqOrigin = [self originForURL:requestURL];
    NSString *pageOrigin = [self originForURL:pageURL];
    if (reqOrigin.length == 0 || pageOrigin.length == 0) return nil;
    // 跨域：不发 Referer。同域：仅 origin（不含 path/query/fragment）。
    if (![reqOrigin isEqualToString:pageOrigin]) return nil;
    return pageOrigin;
}

+ (void)sanitizeMediaRequest:(NSMutableURLRequest *)request {
    NSString *value = [request valueForHTTPHeaderField:@"Referer"];
    NSURL *page = value.length ? [NSURL URLWithString:value] : nil;
    // Explicit per-request source only; never synthesize from redirect Location.
    [request setValue:[self originForURL:page] forHTTPHeaderField:@"Referer"];
}

+ (void)sanitizeRedirectRequest:(NSMutableURLRequest *)request fromRequest:(NSURLRequest *)previous {
    NSString *source = [self originForURL:previous.URL];
    NSString *target = [self originForURL:request.URL];
    BOOL sameOrigin = source.length && [source isEqualToString:target];
    for (NSString *header in @[@"Authorization", @"Cookie"]) {
        [request setValue:sameOrigin ? [previous valueForHTTPHeaderField:header] : nil forHTTPHeaderField:header];
    }
    [request setValue:[previous valueForHTTPHeaderField:@"Referer"] forHTTPHeaderField:@"Referer"];
    [self sanitizeMediaRequest:request];
}

@end
