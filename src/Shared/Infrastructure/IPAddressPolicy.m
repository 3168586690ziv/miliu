//
//  IPAddressPolicy.m — 模块 08｜IP 地址分类核心实现
//
#import "IPAddressPolicy.h"
#import <arpa/inet.h>
#import <netinet/in.h>

IPAddressCategory IPACategoryForIPv4(struct in_addr addr) {
    uint32_t ip = ntohl(addr.s_addr);
    uint8_t a = (ip >> 24) & 0xFF;
    uint8_t b = (ip >> 16) & 0xFF;
    if (a == 127) return IPAddressCategoryLoopback;                 // 127.0.0.0/8
    if (a == 0) return IPAddressCategoryReserved;                   // 0.0.0.0/8
    if (a == 10) return IPAddressCategoryPrivate;                   // 10.0.0.0/8
    if (a == 172 && (b >= 16 && b <= 31)) return IPAddressCategoryPrivate;   // 172.16.0.0/12
    if (a == 192 && b == 168) return IPAddressCategoryPrivate;      // 192.168.0.0/16
    if (a == 169 && b == 254) return IPAddressCategoryLinkLocal;    // 169.254.0.0/16（含云元数据 169.254.169.254）
    if (a == 100 && (b >= 64 && b <= 127)) return IPAddressCategoryPrivate;  // 100.64.0.0/10 CGNAT
    if (a >= 224 && a <= 239) return IPAddressCategoryReserved;     // 224.0.0.0/4 组播
    if (a >= 240) return IPAddressCategoryReserved;                 // 240.0.0.0/4 保留 + 255.255.255.255 广播
    if (a == 192 && b == 0 && ((ip >> 8) & 0xFF) == 0) return IPAddressCategoryReserved;   // 192.0.0.0/24
    if (a == 192 && b == 0 && ((ip >> 8) & 0xFF) == 2) return IPAddressCategoryReserved;   // 192.0.2.0/24
    if (a == 198 && (b == 18 || b == 19)) return IPAddressCategoryReserved;  // 198.18.0.0/15 基准测试
    if (a == 203 && b == 0 && ((ip >> 8) & 0xFF) == 113) return IPAddressCategoryReserved;  // 203.0.113.0/24 文档
    return IPAddressCategoryPublic;
}

IPAddressCategory IPACategoryForIPv6(struct in6_addr addr) {
    if (IN6_IS_ADDR_UNSPECIFIED(&addr)) return IPAddressCategoryReserved;   // ::
    if (IN6_IS_ADDR_LOOPBACK(&addr)) return IPAddressCategoryLoopback;      // ::1
    if (IN6_IS_ADDR_LINKLOCAL(&addr)) return IPAddressCategoryLinkLocal;    // fe80::/10
    // Deprecated site-local fec0::/10 is not routable public space.
    if (addr.s6_addr[0] == 0xFE && (addr.s6_addr[1] & 0xC0) == 0xC0) return IPAddressCategoryReserved;
    // IPv4-mapped（::ffff:x.x.x.x）与 IPv4-compatible（::x.x.x.x）→ 按 v4 处理
    if (IN6_IS_ADDR_V4MAPPED(&addr)) {
        struct in_addr v4;
        memcpy(&v4.s_addr, &addr.s6_addr[12], sizeof(v4.s_addr));
        return IPACategoryForIPv4(v4);
    }
    if (IN6_IS_ADDR_V4COMPAT(&addr)) {
        struct in_addr v4;
        memcpy(&v4.s_addr, &addr.s6_addr[12], sizeof(v4.s_addr));
        return IPACategoryForIPv4(v4);
    }
    // 唯一本地地址 fc00::/7
    if (addr.s6_addr[0] == 0xFC || addr.s6_addr[0] == 0xFD) return IPAddressCategoryPrivate;
    // 组播 ff00::/8
    if (addr.s6_addr[0] == 0xFF) return IPAddressCategoryReserved;
    // 文档示例网段 2001:db8::/32
    if (addr.s6_addr[0] == 0x20 && addr.s6_addr[1] == 0x01 &&
        addr.s6_addr[2] == 0x0D && addr.s6_addr[3] == 0xB8) return IPAddressCategoryReserved;
    // 6to4 中继 2002::/16、Teredo 2001:0000::/32 等特殊用途统一从严按保留处理，
    // 避免把特殊地址误当公网转发目标。
    if (addr.s6_addr[0] == 0x20 && addr.s6_addr[1] == 0x02) return IPAddressCategoryReserved;   // 2002::/16
    if (addr.s6_addr[0] == 0x20 && addr.s6_addr[1] == 0x01 &&
        addr.s6_addr[2] == 0x00 && addr.s6_addr[3] == 0x00) return IPAddressCategoryReserved;   // 2001:0000::/32
    // Well-known NAT64 prefixes: translations must not be mistaken for a public peer.
    static const uint8_t nat64_96[12] = {0x00,0x64,0xFF,0x9B,0,0,0,0,0,0,0,0};
    if (memcmp(addr.s6_addr, nat64_96, sizeof(nat64_96)) == 0) return IPAddressCategoryReserved;
    static const uint8_t nat64_48[6] = {0x00,0x64,0xFF,0x9B,0x00,0x01};
    if (memcmp(addr.s6_addr, nat64_48, sizeof(nat64_48)) == 0) return IPAddressCategoryReserved;
    return IPAddressCategoryPublic;
}

IPAddressCategory IPACategoryForIPString(NSString * _Nullable ip) {
    if (ip == nil || ip.length == 0) return IPAddressCategoryReserved;
    const char *c = [ip UTF8String];
    struct in_addr v4;
    if (inet_pton(AF_INET, c, &v4) == 1) return IPACategoryForIPv4(v4);
    struct in6_addr v6;
    if (inet_pton(AF_INET6, c, &v6) == 1) return IPACategoryForIPv6(v6);
    return IPAddressCategoryReserved;   // 非法字符串 → 保留（宁严勿宽）
}
