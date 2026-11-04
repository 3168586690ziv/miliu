//
//  HTTPPrivacyPolicy.m — 模块 08｜请求隐私头策略实现
//
//  档位注入沿用本项目「静态变量 + 类方法读写」模式（与 URLPolicy 的
//  systemProxyIsActive / setSystemProxyActiveOverride: 同族）：本文件
//  只读一个 static 值，绝不 import PreferencesStore —— redirect-policy /
//  adaptive-transport / download-integrity 三个套件都编译本文件但不链接
//  PreferencesStore.m，任何新依赖都会让它们 Undefined symbols 链接失败。
//
#import "HTTPPrivacyPolicy.h"

/// 档位注入值；nil 表示未注入（按默认 Origin 处理）。
static NSNumber *gRDRefererModeOverride;

@implementation HTTPPrivacyPolicy

#pragma mark - 档位注入

+ (HTTPRefererMode)refererMode {
    @synchronized (self) {
        NSNumber *override = gRDRefererModeOverride;
        if (override == nil) return HTTPRefererModeOrigin;
        // 非法值（越界/非整数形态）一律按默认 Origin 处理，绝不崩。
        NSInteger raw = override.integerValue;
        // 上限必须跟着枚举一起前进（第 47 轮加 CrossOrigin 时这里漏改，
        // 导致第 4 档被当成非法值静默退回 Origin —— 自测当场抓到）。
        if (raw < (NSInteger)HTTPRefererModeOrigin || raw > (NSInteger)HTTPRefererModeCrossOrigin) {
            return HTTPRefererModeOrigin;
        }
        return (HTTPRefererMode)raw;
    }
}

+ (void)setRefererModeOverride:(NSNumber *)override {
    @synchronized (self) {
        gRDRefererModeOverride = override;
    }
}

#pragma mark - origin

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

#pragma mark - 完整来源页 URL（FullPath 档）

/// 完整来源页 URL：scheme+host+port+path+query，剥掉 fragment 与 userinfo。
/// query 原样保留（不重排、不重新 percent-encode）；安全检查与 originForURL: 一致：
/// 非 http/https、缺 host、带 userinfo 一律返回 nil。
///
/// 实现刻意用 components 只取**原始字节**（percentEncodedPath / percentEncodedQuery）
/// 再手工拼接，而不是让 NSURLComponents.string 重新组装：后者会对整条 URL 做一次
/// 规范化往返，既可能改动 query 的编码形态，也把「原样保留」变成「碰巧一样」。
+ (nullable NSString *)fullPageURLStringForURL:(NSURL *)url {
    // 复用 originForURL: 的 scheme / host / userinfo 检查（FullPath 档同样必须生效）。
    NSString *origin = [self originForURL:url];
    if (origin.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components == nil) return nil;
    // userinfo 二次确认（originForURL: 已拒过，这里防止解析路径差异）：
    // 一旦来源页带凭据，整体不发 Referer —— 绝不把凭据带进请求头。
    if (components.user != nil || components.password != nil) return nil;
    // origin 已是「scheme://host[:port]」的归一形态（scheme/host 小写、默认端口已省略），
    // 直接以它作前缀，保证与同源判定用的是同一份归一结果。
    // path 取原始字节；空 path 不补 "/"（与 NSURL 对 "https://host" 的形态一致）。
    NSString *path = components.percentEncodedPath ?: @"";
    // query 原样搬运：不重排参数、不重新 percent-encode；区分「无 query」与「空 query」。
    NSString *query = components.percentEncodedQuery;
    NSString *result = origin;
    if (path.length > 0) result = [result stringByAppendingString:path];
    if (query != nil) result = [result stringByAppendingFormat:@"?%@", query];
    // 兜底：任何形态下 Referer 都不得带 fragment。
    NSRange hash = [result rangeOfString:@"#"];
    if (hash.location != NSNotFound) result = [result substringToIndex:hash.location];
    return result.length ? result : nil;
}

#pragma mark - Referer 计算

/// 单个 Referer 头值按当前档位归一。requestURL 仅 FullPath 档用于跨域判定。
+ (nullable NSString *)sanitizedRefererForValue:(nullable NSString *)value
                                     requestURL:(nullable NSURL *)requestURL {
    HTTPRefererMode mode = [self refererMode];
    if (mode == HTTPRefererModeNone) return nil;
    NSURL *page = value.length ? [NSURL URLWithString:value] : nil;
    if (mode == HTTPRefererModeFullPath) {
        NSString *pageOrigin = [self originForURL:page];
        NSString *full = [self fullPageURLStringForURL:page];
        if (pageOrigin.length == 0 || full.length == 0) return nil;
        // 同源判定仍按 origin 比较（同站不同路径不得被判成跨域），
        // 跨域一律不发 —— 绝不把来源页路径泄露给别的域。
        NSString *requestOrigin = [self originForURL:requestURL];
        if (requestOrigin.length == 0 || ![requestOrigin isEqualToString:pageOrigin]) return nil;
        return full;
    }
    // Origin 档 = 改动前行为，逐字保留：只把显式 Referer 归一成 origin，
    // **不做跨域判定**（历史实现如此：跨域媒体请求同样带来源页 origin）。
    // 零回归优先——六个生产调用点的既有行为不得因本次加档而改变。
    return [self originForURL:page];
}

+ (nullable NSString *)refererHeaderForRequestURL:(NSURL *)requestURL
                                     fromPageURL:(NSURL *)pageURL {
    HTTPRefererMode mode = [self refererMode];
    if (mode == HTTPRefererModeNone) return nil;
    NSString *reqOrigin = [self originForURL:requestURL];
    NSString *pageOrigin = [self originForURL:pageURL];
    if (reqOrigin.length == 0 || pageOrigin.length == 0) return nil;
    // 跨域：不发 Referer。同域：Origin 档仅 origin（不含 path/query/fragment）；
    // FullPath 档发完整来源页 URL（去 fragment、去 userinfo）。
    // 跨域档（第 47 轮）：跨域也发**来源页 origin**（不含 path/query）。
    // 只发 origin 是最小暴露面：目标域能知道"从哪个站点来"，但拿不到具体页面。
    if (![reqOrigin isEqualToString:pageOrigin]) {
        if (mode == HTTPRefererModeCrossOrigin) return pageOrigin;
        return nil;
    }
    if (mode == HTTPRefererModeFullPath) return [self fullPageURLStringForURL:pageURL];
    return pageOrigin;
}

+ (void)sanitizeMediaRequest:(NSMutableURLRequest *)request {
    NSString *value = [request valueForHTTPHeaderField:@"Referer"];
    // Explicit per-request source only; never synthesize from redirect Location.
    [request setValue:[self sanitizedRefererForValue:value requestURL:request.URL]
   forHTTPHeaderField:@"Referer"];
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
