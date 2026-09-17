//
//  IPAddressPolicy.h — 模块 08｜IP 地址分类核心（纯逻辑、无网络、无 GUI）
//
//  供 URLPolicy（Features/ResourceDetector）与 DNSResolver 校验链复用，
//  是 SSRF 防护的单一分类事实来源。Shared 仅依赖 Shared/系统框架。
//

#import <Foundation/Foundation.h>
#import <netinet/in.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, IPAddressCategory) {
    IPAddressCategoryPublic = 0,     // 公网可达地址
    IPAddressCategoryLoopback,       // 127.0.0.0/8 · ::1
    IPAddressCategoryPrivate,        // 10/8 · 172.16/12 · 192.168/16 · 100.64/10 · fc00::/7
    IPAddressCategoryLinkLocal,      // 169.254/16 · fe80::/10
    IPAddressCategoryReserved,       // 0.0.0.0/8 · 组播 · 广播 · 保留/测试/文档网段 · :: 等
};

/// 对单个 IP 字符串（IPv4 或 IPv6，含 IPv4-mapped IPv6）分类。
/// 非合法 IP 字符串返回 IPAddressCategoryReserved（宁严勿宽）。
IPAddressCategory IPACategoryForIPString(NSString * _Nullable ip);

/// IPv4 分类（按网络字节序的 in_addr）。
IPAddressCategory IPACategoryForIPv4(struct in_addr addr);

/// IPv6 分类（按网络字节序的 in6_addr，含 v4-mapped/v4-compatible）。
IPAddressCategory IPACategoryForIPv6(struct in6_addr addr);

NS_ASSUME_NONNULL_END
