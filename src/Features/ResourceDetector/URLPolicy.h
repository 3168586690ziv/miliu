//
//  URLPolicy.h — 模块 17｜网页资源探测·URL 安全策略
//
//  纯逻辑、无 GUI、无网络。在三个时机重新校验：
//  1) 文本 URL（用户输入）
//  2) DNS 解析后的真实 IP
//  3) 每次重定向目标
//  任何阶段命中危险地址即拒绝，且用户提示绝不暴露内部网络细节（IP/主机名）。
//

#import <Foundation/Foundation.h>
#import "DNSResolver.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, URLPolicyVerdict) {
    URLPolicyAllowed = 0,
    URLPolicyBlockedScheme,        // 非 http/https（含 file）
    URLPolicyBlockedCustomScheme,  // 自定义/未知 scheme
    URLPolicyBlockedLoopback,      // localhost / 127.0.0.0/8 / ::1
    URLPolicyBlockedPrivate,       // 10/8 · 172.16/12 · 192.168/16 · 100.64/10
    URLPolicyBlockedLinkLocal,     // 169.254/16 · fe80::/10
    URLPolicyBlockedManagement,    // 本机管理地址（路由器等）
    URLPolicyBlockedReserved,      // 保留/未指定地址
    URLPolicyBlockedDNSTimeout,    // DNS 解析超时（瞬态故障，调用方可有限重试）
    URLPolicyBlockedDNSError,      // DNS 解析失败/无记录（fail-closed，但不是保留地址）
    URLPolicyBlockedDNSBusy,       // 有界 DNS 队列已满（可恢复背压）
};

@interface URLPolicyDecision : NSObject
@property (nonatomic, assign) BOOL allowed;
@property (nonatomic, assign) URLPolicyVerdict verdict;
// 用户可见提示：仅按类别描述，绝不包含 IP/主机名等内部细节。
@property (nonatomic, copy) NSString *userMessage;
+ (instancetype)allow;
+ (instancetype)blockWithVerdict:(URLPolicyVerdict)verdict message:(NSString *)message;
@end

@interface URLPolicy : NSObject

// 时机 1：文本 URL（用户输入）。主机为 IP 时直接分类；主机名留待解析阶段。
- (URLPolicyDecision *)evaluateTextURL:(NSString *)urlString;

// 时机 2：DNS 解析后（拿到真实 IP）。即使文本阶段放行，此处仍可拦截（防 DNS rebinding）。
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIP:(NSString *)ipString;

// 时机 2b：DNS 解析后拿到全部 IP（A + AAAA）。任一 IP 命中危险地址即拒绝。
// 空数组视为解析失败，按保留地址拒绝（宁严勿宽）。
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips;

// 时机 2b 的状态感知变体：调用方能区分解析结果来源时（见 DNSResolver 的
// status 出参），空列表按「超时 / 解析失败」单独归类，不再与“保留地址”
// 混为同一种终态；解析出真实 IP 时的逐 IP fail-closed 行为完全不变。
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips
                          resolutionStatus:(DNSResolutionStatus)status;

// 时机 3：每次重定向目标。携带来源 URL，对目标重新做完整校验。
- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current;

#pragma mark - 系统代理与 fake-ip（2026-10-12 第 39 轮）

// 系统代理是否启用。生产读 CFNetworkCopySystemProxySettings()（30 秒缓存，
// 用户中途开关代理能跟上）；测试可用 setSystemProxyActiveOverride: 注入。
//
// 为什么 URLPolicy 需要知道代理状态：主流代理软件（Clash／Surge 等）的
// fake-ip 模式会把**所有**域名答成 198.18.0.0/15 内的假地址，再由虚拟网卡
// 按域名转发。该段同时是 RFC 2544 基准测试保留段，于是本策略会把它当
// 「保留地址」拒绝 —— 用户开着代理时**任何网站都探测不了**，且提示是
// 「地址被安全策略阻止：保留/无效地址不可探测」（把代理配置说成了安全问题）。
// 走代理时本机 DNS 结果不具代表性（连接由代理端解析域名），项目 curl 路径
// 早已用 socks5h 表达同一意图（"域名解析交代理执行，避免本机解析被污染"），
// 原生路径此前缺这一层。故：**系统代理启用时**，198.18.0.0/15 按代理
// fake-ip 放行；其余保留/私网/回环/链路本地段照旧拦截，文本阶段的 scheme、
// 空主机、userinfo、IP 字面量分类也全部照旧。
+ (BOOL)systemProxyIsActive;

// 测试注入：@YES／@NO 覆盖真实探测；nil 恢复真实探测并清缓存。
+ (void)setSystemProxyActiveOverride:(nullable NSNumber *)override;

@end

NS_ASSUME_NONNULL_END
