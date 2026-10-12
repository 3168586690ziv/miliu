//
//  URLPolicy.m — 模块 17｜URL 安全策略实现
//
#import "URLPolicy.h"
#import "IPAddressPolicy.h"
#import "RDLog.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <CFNetwork/CFNetwork.h>

#pragma mark - 系统代理与 fake-ip（第 39 轮）

// 测试注入（nil = 真实探测）。仅测试使用，生产路径不设置。
static NSNumber *gRDSystemProxyOverride = nil;
// 真实探测结果的短缓存：避免每个 URL 都去读系统配置。
static BOOL gRDSystemProxyCached = NO;
static NSTimeInterval gRDSystemProxyCachedAt = 0;

/// 198.18.0.0/15：RFC 2544 基准测试保留段，同时是主流代理软件
/// （Clash／Surge 等）fake-ip 模式的默认地址段。仅在系统代理启用时按
/// 「代理 fake-ip」对待（理由见 URLPolicy.h）。
static BOOL RDIsProxyFakeIPRange(NSString *ip) {
    if (ip.length == 0) return NO;
    struct in_addr v4;
    if (inet_pton(AF_INET, ip.UTF8String, &v4) != 1) return NO;   // 非 IPv4 字面量
    uint32_t h = ntohl(v4.s_addr);
    return (h & 0xFFFE0000u) == 0xC6120000u;   // 198.18.0.0/15
}

#pragma mark - IP 分类（复用 Shared/IPAddressPolicy 单一事实来源）

typedef NS_ENUM(NSInteger, RDIPCategory) {
    RDIPPublic = 0,
    RDIPLoopback,
    RDIPPrivate,
    RDIPLinkLocal,
    RDIPReserved,
};

static RDIPCategory RDCategorizeIPString(NSString *ip) {
    switch (IPACategoryForIPString(ip)) {
        case IPAddressCategoryLoopback: return RDIPLoopback;
        case IPAddressCategoryPrivate:  return RDIPPrivate;
        case IPAddressCategoryLinkLocal:return RDIPLinkLocal;
        case IPAddressCategoryReserved: return RDIPReserved;
        case IPAddressCategoryPublic:
        default:                        return RDIPPublic;
    }
}

static BOOL RDIsLocalhostHost(NSString *host) {
    if (host == nil) return NO;
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"localhost"] ||
           [h isEqualToString:@"localhost.localdomain"] ||
           [h hasSuffix:@".localhost"];
}

// 主机名是否为 IP 字面量（IPv4/IPv6）。仅字面量才做文本阶段 IP 分类；
// 普通主机名留待 DNS 解析阶段校验，避免把域名误判为保留地址。
static BOOL RDIsIPLiteral(NSString *host) {
    if (host == nil || host.length == 0) return NO;
    const char *c = [host UTF8String];
    struct in_addr v4;
    if (inet_pton(AF_INET, c, &v4) == 1) return YES;
    struct in6_addr v6;
    return (inet_pton(AF_INET6, c, &v6) == 1);
}

#pragma mark - 用户提示（绝不暴露 IP/主机名）

static NSString *RDMessageForVerdict(URLPolicyVerdict v) {
    switch (v) {
        case URLPolicyBlockedScheme:      return @"地址被安全策略阻止：仅允许 http/https 协议";
        case URLPolicyBlockedCustomScheme:return @"地址被安全策略阻止：不支持的自定义协议";
        case URLPolicyBlockedLoopback:    return @"地址被安全策略阻止：本地回环地址不可探测";
        case URLPolicyBlockedPrivate:     return @"地址被安全策略阻止：私网地址不可探测";
        case URLPolicyBlockedLinkLocal:   return @"地址被安全策略阻止：链路本地地址不可探测";
        case URLPolicyBlockedManagement:  return @"地址被安全策略阻止：本机管理地址不可探测";
        case URLPolicyBlockedReserved:    return @"地址被安全策略阻止：保留/无效地址不可探测";
        case URLPolicyBlockedDNSTimeout:  return @"DNS 解析超时：网络波动或 DNS 服务暂时不可用，稍后重试可能恢复";
        case URLPolicyBlockedDNSError:    return @"DNS 解析失败：域名不存在或无法解析";
        default: return @"地址被安全策略阻止";
    }
}

#pragma mark - URLPolicyDecision

@implementation URLPolicyDecision
+ (instancetype)allow { return [self blockWithVerdict:URLPolicyAllowed message:@""]; }
+ (instancetype)blockWithVerdict:(URLPolicyVerdict)verdict message:(NSString *)message {
    URLPolicyDecision *d = [URLPolicyDecision new];
    d.allowed = (verdict == URLPolicyAllowed);
    d.verdict = verdict;
    d.userMessage = message ?: @"";
    return d;
}
@end

#pragma mark - URLPolicy

@implementation URLPolicy

#pragma mark 系统代理 / fake-ip

+ (BOOL)systemProxyIsActive {
    if (gRDSystemProxyOverride != nil) return gRDSystemProxyOverride.boolValue;
    @synchronized (self) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        // 30 秒缓存：读系统配置有开销，但用户中途开关代理也要能跟上。
        if (gRDSystemProxyCachedAt > 0 && now - gRDSystemProxyCachedAt < 30) return gRDSystemProxyCached;
        NSDictionary *settings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
        BOOL active = [settings[(__bridge NSString *)kCFNetworkProxiesHTTPEnable] boolValue]
                   || [settings[(__bridge NSString *)kCFNetworkProxiesHTTPSEnable] boolValue]
                   || [settings[(__bridge NSString *)kCFNetworkProxiesSOCKSEnable] boolValue];
        gRDSystemProxyCached = active;
        gRDSystemProxyCachedAt = now;
        return active;
    }
}

+ (void)setSystemProxyActiveOverride:(NSNumber *)override {
    @synchronized (self) {
        gRDSystemProxyOverride = override;
        gRDSystemProxyCachedAt = 0;   // 解除覆盖后重新探测
    }
}

/// 该 IP 是否应按「代理 fake-ip」放行（仅系统代理启用时成立）。
static BOOL RDShouldTreatAsProxyFakeIP(NSString *ip) {
    return RDIsProxyFakeIPRange(ip) && [URLPolicy systemProxyIsActive];
}

- (URLPolicyDecision *)evaluateTextURL:(NSString *)urlString {
    if (urlString == nil || urlString.length == 0) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil || url.scheme == nil) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedCustomScheme message:RDMessageForVerdict(URLPolicyBlockedCustomScheme)];
    }
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        if ([scheme isEqualToString:@"file"]) {
            return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedScheme message:RDMessageForVerdict(URLPolicyBlockedScheme)];
        }
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedCustomScheme message:RDMessageForVerdict(URLPolicyBlockedCustomScheme)];
    }
    NSString *host = url.host;
    // Reject even empty userinfo (https://@host); never send URL credentials.
    if (host.length == 0 || url.user != nil || url.password != nil) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    if (RDIsLocalhostHost(host)) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedLoopback message:RDMessageForVerdict(URLPolicyBlockedLoopback)];
    }
    // 主机本身是 IP 字面量：直接分类（localhost/127、私网、链路本地、组播/保留等）
    if (RDIsIPLiteral(host)) {
        // 代理 fake-ip 段：系统代理启用时按代理地址放行（用户直接粘贴
        // 代理软件给出的假地址时不该被报成"保留地址"）。
        if (!RDShouldTreatAsProxyFakeIP(host)) {
            RDIPCategory cat = RDCategorizeIPString(host);
            if (cat != RDIPPublic) {
                URLPolicyVerdict v = (cat == RDIPLoopback) ? URLPolicyBlockedLoopback
                                    : (cat == RDIPLinkLocal) ? URLPolicyBlockedLinkLocal
                                    : (cat == RDIPReserved) ? URLPolicyBlockedReserved
                                    : URLPolicyBlockedPrivate;
                return [URLPolicyDecision blockWithVerdict:v message:RDMessageForVerdict(v)];
            }
        }
    }
    // 公网主机名待 DNS 检查；预解析不等于连接 IP 绑定，不能保证防住 DNS rebinding。
    return [URLPolicyDecision allow];
}

- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIP:(NSString *)ipString {
    if (url == nil) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    // 代理 fake-ip（198.18.0.0/15）且系统代理启用：这是代理软件给出的假地址，
    // 真实连接由代理端按域名解析 —— 本机 DNS 结论在此不具代表性，放行。
    if (RDShouldTreatAsProxyFakeIP(ipString)) return [URLPolicyDecision allow];
    RDIPCategory cat = RDCategorizeIPString(ipString);
    if (cat == RDIPPublic) return [URLPolicyDecision allow];
    URLPolicyVerdict v = (cat == RDIPLoopback) ? URLPolicyBlockedLoopback
                        : (cat == RDIPLinkLocal) ? URLPolicyBlockedLinkLocal
                        : (cat == RDIPReserved) ? URLPolicyBlockedReserved
                        : URLPolicyBlockedPrivate;
    return [URLPolicyDecision blockWithVerdict:v message:RDMessageForVerdict(v)];
}

- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips {
    if (url == nil) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    if (ips == nil || ips.count == 0) {
        // 无状态信息的调用方维持原语义：解析失败/无记录宁严勿宽，按保留地址拒绝
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    for (NSString *ip in ips) {
        URLPolicyDecision *d = [self evaluateResolvedURL:url resolvedIP:ip];
        if (!d.allowed) return d;   // 任一 IP 危险即拒绝
    }
    return [URLPolicyDecision allow];
}

- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips resolutionStatus:(DNSResolutionStatus)status {
    if (url == nil) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    if (ips.count == 0 && status == DNSResolutionBusy) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedDNSBusy message:@"DNS 校验暂时繁忙，请稍后重试"];
    }
    if (ips.count == 0 && (status == DNSResolutionTimedOut || status == DNSResolutionFailed)) {
        // 解析不出任何 IP 时按来源单独归类：超时是瞬态故障（调用方可有限
        // 重试），解析失败/无记录 fail-closed——两者都不是“解析到保留地址”，
        // 绝不能复用保留地址的文案误导用户。
        URLPolicyVerdict v = (status == DNSResolutionTimedOut) ? URLPolicyBlockedDNSTimeout : URLPolicyBlockedDNSError;
        return [URLPolicyDecision blockWithVerdict:v message:RDMessageForVerdict(v)];
    }
    // 其余（解析出 IP 的逐 IP fail-closed 校验，以及无状态信息的空列表兜底）
    // 全部走两参入口：子类覆写与既有语义（空列表按保留地址拒绝）保持不变。
    return [self evaluateResolvedURL:url resolvedIPs:ips];
}

- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current {
    if (target == nil) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:RDMessageForVerdict(URLPolicyBlockedReserved)];
    }
    // 重定向目标按完整文本 URL 重新校验（scheme + 主机 IP 分类）
    URLPolicyDecision *d = [self evaluateTextURL:target.absoluteString];
    if (!d.allowed) {
        // 被策略拦下时留痕（host 由 RDLog 脱敏保留），否则"探测为何停在半路"只能靠猜
        RDLogWriteLevel(RDLogLevelWarn, @"probe", @"重定向被安全策略阻止 verdict=%ld host=%@ 原因=%@",
                        (long)d.verdict, target.host ?: @"(无host)", d.userMessage ?: @"(无说明)");
        return d;
    }
    if ([current.scheme.lowercaseString isEqualToString:@"https"] &&
        [target.scheme.lowercaseString isEqualToString:@"http"]) {
        RDLogWriteLevel(RDLogLevelWarn, @"probe", @"重定向被安全策略阻止 原因=HTTPS 降级到 HTTP host=%@",
                        target.host ?: @"(无host)");
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedScheme
                                          message:@"地址被安全策略阻止：不允许 HTTPS 降级到 HTTP"];
    }
    // 来源若是公网、目标虽公网主机名但本阶段无 IP，仍放行；
    // 真实 IP 校验由调用方在解析后再次调用 evaluateResolvedURL:。
    return d;
}

@end
