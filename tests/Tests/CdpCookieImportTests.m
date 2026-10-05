//
//  CdpCookieImportTests.m — CDP 导入纯函数测试（不启动浏览器进程）
//
//  覆盖（2026-10-05 第 27 轮）：CDP 条目 → NSHTTPCookie 转换（会话/持久/secure/
//  缺字段拒绝）、白名单路径集合、来源扫描冒烟。
//

#import <Foundation/Foundation.h>
#import "RDCdpCookieImporter.h"

static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }

int main(void) { @autoreleasepool {
    // 1) 完整条目：持久 + secure
    NSDictionary *full = @{@"name": @"auth_token", @"value": @"abc123",
                           @"domain": @".x.com", @"path": @"/",
                           @"expires": @1777777777.0, @"secure": @YES,
                           @"httpOnly": @YES, @"session": @NO};
    NSHTTPCookie *c = [RDCdpCookieImporter httpCookieFromCdpDictionary:full];
    check(c != nil, "full CDP entry converts");
    check([c.name isEqualToString:@"auth_token"] && [c.value isEqualToString:@"abc123"],
          "name and value preserved");
    check([c.domain isEqualToString:@".x.com"], "leading-dot domain preserved");
    check(c.expiresDate != nil && [c.expiresDate timeIntervalSince1970] == 1777777777,
          "persistent expiry converted from unix seconds");
    check(c.secure, "secure flag preserved");

    // 2) 会话 Cookie：expires = -1
    NSDictionary *session = @{@"name": @"sid", @"value": @"v1", @"domain": @"example.com",
                              @"path": @"/sub", @"expires": @-1};
    NSHTTPCookie *s = [RDCdpCookieImporter httpCookieFromCdpDictionary:session];
    check(s != nil && s.expiresDate == nil, "expires=-1 becomes session cookie");

    // 3) 缺字段拒绝：无 name / 无 domain / 非字典
    check([RDCdpCookieImporter httpCookieFromCdpDictionary:@{@"value": @"x", @"domain": @"a.com"}] == nil,
          "entry without name is rejected");
    check([RDCdpCookieImporter httpCookieFromCdpDictionary:@{@"name": @"a", @"value": @"x"}] == nil,
          "entry without domain is rejected");
    check([RDCdpCookieImporter httpCookieFromCdpDictionary:(NSDictionary *)@[@"not", @"dict"]] == nil,
          "non-dictionary payload is rejected");

    // 4) 白名单路径：必须含 Local State 与两代 Cookies 路径
    NSArray *wl = [RDCdpCookieImporter whitelistedProfileRelativePaths];
    check([wl containsObject:@"Local State"], "whitelist includes Local State");
    check([wl containsObject:@"Default/Cookies"] && [wl containsObject:@"Default/Network/Cookies"],
          "whitelist includes both generations of Cookies path");

    // 5) 来源扫描冒烟
    NSArray *sources = [RDCdpCookieImporter availableSources];
    check(sources != nil, "availableSources returns a list");
    for (RDCdpCookieSource *src in sources) {
        check(src.executablePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:src.executablePath],
              "candidate executable exists");
        check(src.cookieCount > 0, "candidate has cookies");
        break;
    }

    printf("%s\n", failures == 0 ? "ALL PASS" : "HAS FAILURES");
    return failures == 0 ? 0 : 1;
}}
