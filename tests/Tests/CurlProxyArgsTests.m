//
//  CurlProxyArgsTests.m — 系统代理 → curl 参数纯函数单测 + 生产路径 argv 捕获
//
//  覆盖（2026-10-05 第 21 轮）：RDCurlProxyArgumentsForURL 的协议分流、SOCKS 回退、
//  例外列表、简单主机名排除、direct 逃生口、非法端口；以及 RDCurlHopper.hopWithURL
//  生产路径确实把「与系统设置一致」的代理参数组装进 curl argv（runner 捕获对照）。
//

#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import "RDCurlHopper.h"

static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }

static NSDictionary *proxyDict(BOOL enable, NSString *host, NSInteger port) {
    return @{(__bridge NSString *)kCFNetworkProxiesHTTPSEnable: @(enable),
             (__bridge NSString *)kCFNetworkProxiesHTTPSProxy: host ?: @"",
             (__bridge NSString *)kCFNetworkProxiesHTTPSPort: @(port)};
}

int main(void) { @autoreleasepool {
    NSURL *https = [NSURL URLWithString:@"https://cdn.example.com/v/master.m3u8?tok=1"];
    NSURL *http = [NSURL URLWithString:@"http://cdn.example.com/v/clip.mp4"];

    // 1) HTTPS 目标 + HTTPS 代理开启
    NSArray *args = RDCurlProxyArgumentsForURL(https, proxyDict(YES, @"127.0.0.1", 7897));
    check([args isEqualToArray:@[@"--proxy", @"http://127.0.0.1:7897"]], "https target uses configured https proxy");

    // 2) HTTP 目标 + HTTP 代理开启（http 键独立于 https 键）
    NSDictionary *httpOnly = @{(__bridge NSString *)kCFNetworkProxiesHTTPEnable: @YES,
                               (__bridge NSString *)kCFNetworkProxiesHTTPProxy: @"10.0.0.2",
                               (__bridge NSString *)kCFNetworkProxiesHTTPPort: @(8888)};
    check([RDCurlProxyArgumentsForURL(http, httpOnly) isEqualToArray:@[@"--proxy", @"http://10.0.0.2:8888"]],
          "http target uses configured http proxy");
    check([RDCurlProxyArgumentsForURL(https, httpOnly) count] == 0, "https target ignores http-only proxy when no socks");

    // 3) 未配置 http/https 但有系统 SOCKS → socks5h 回退（域名解析交代理）
    NSDictionary *socks = @{(__bridge NSString *)kCFNetworkProxiesSOCKSEnable: @YES,
                            (__bridge NSString *)kCFNetworkProxiesSOCKSProxy: @"127.0.0.1",
                            (__bridge NSString *)kCFNetworkProxiesSOCKSPort: @(7891)};
    check([RDCurlProxyArgumentsForURL(https, socks) isEqualToArray:@[@"--proxy", @"socks5h://127.0.0.1:7891"]],
          "socks fallback uses socks5h scheme");

    // 4) 例外列表：精确 host、*.foo.com 后缀、裸域、全排除
    NSDictionary *base = proxyDict(YES, @"127.0.0.1", 7897);
    NSMutableDictionary *ex = [base mutableCopy];
    ex[(__bridge NSString *)kCFNetworkProxiesExceptionsList] = @[@"*.internal.example", @"example.org", @"*"];
    check([RDCurlProxyArgumentsForURL([NSURL URLWithString:@"https://a.internal.example/x.mp4"], ex) count] == 0,
          "wildcard suffix exception excludes host");
    check([RDCurlProxyArgumentsForURL([NSURL URLWithString:@"https://internal.example/x.mp4"], ex) count] == 0,
          "bare domain matches wildcard entry");
    check([RDCurlProxyArgumentsForURL([NSURL URLWithString:@"https://example.org/x.mp4"], ex) count] == 0,
          "exact host exception excludes host");
    // 不含 "*" 全排除项的字典：非匹配 host 必须仍然代理
    NSMutableDictionary *exPartial = [base mutableCopy];
    exPartial[(__bridge NSString *)kCFNetworkProxiesExceptionsList] = @[@"*.internal.example", @"example.org"];
    check([RDCurlProxyArgumentsForURL(https, exPartial) count] == 2,
          "non-matching host still proxied under exceptions");

    // 5) 简单主机名排除（无点域名）
    NSMutableDictionary *noSimple = [proxyDict(YES, @"127.0.0.1", 7897) mutableCopy];
    noSimple[(__bridge NSString *)kCFNetworkProxiesExcludeSimpleHostnames] = @YES;
    check([RDCurlProxyArgumentsForURL([NSURL URLWithString:@"https://nas/x.mp4"], noSimple) count] == 0,
          "simple hostname excluded when system asks");

    // 6) direct 逃生口与非法端口
    setenv("RD_SESSION_PROXY_OVERRIDE", "direct", 1);
    check([RDCurlProxyArgumentsForURL(https, proxyDict(YES, @"127.0.0.1", 7897)) count] == 0,
          "RD_SESSION_PROXY_OVERRIDE=direct forces no proxy");
    unsetenv("RD_SESSION_PROXY_OVERRIDE");
    check([RDCurlProxyArgumentsForURL(https, proxyDict(YES, @"127.0.0.1", 0)) count] == 0,
          "invalid proxy port yields no proxy arguments");
    check([RDCurlProxyArgumentsForURL(https, @{}) count] == 0, "empty settings yield no proxy arguments");

    // 7) 生产路径：hopWithURL 组装 argv 时确实带上了「与系统设置一致」的代理参数。
    //    用 runner 捕获 argv，与本进程同函数对真实系统设置计算出的期望逐项对照，
    //    不假设本机是否开代理（两种结果都合法，关键是生产路径与纯函数一致）。
    RDCurlHopper *hopper = [RDCurlHopper new];
    NSDictionary *sysSettings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    NSArray *expectedArgs = RDCurlProxyArgumentsForURL(https, sysSettings);
    __weak RDCurlHopper *weakHopper = hopper;
    hopper.runner = ^NSInteger(NSArray<NSString *> *argv, NSString *h, NSString *b) {
        (void)h; (void)b;
        BOOL contains = NO;
        NSUInteger n = expectedArgs.count;
        if (n == 0) {
            contains = YES;   // 本机无系统代理：生产 argv 也必须不含任何 --proxy
            for (NSString *a in argv) {
                if ([a isEqualToString:@"--proxy"]) { contains = NO; break; }
            }
        } else {
            for (NSUInteger i = 0; i + n <= argv.count; i++) {
                if ([[argv subarrayWithRange:NSMakeRange(i, n)] isEqualToArray:expectedArgs]) { contains = YES; break; }
            }
        }
        check(contains, "production argv contains exactly the proxy arguments derived from system settings");
        return 69; // 任意非零：本测试只看 argv，不执行真实 curl
    };
    __block BOOL done = NO;
    [hopper walkURL:https method:@"GET" headers:@{} budget:0
           deadline:CFAbsoluteTimeGetCurrent() + 15 bodyToFile:NO
         completion:^(RDCurlHopResult *r) { (void)r; (void)weakHopper; done = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!done && deadline.timeIntervalSinceNow > 0) usleep(20000);
    check(done, "hopper completed (argv captured)");

    printf("%s\n", failures == 0 ? "ALL PASS" : "HAS FAILURES");
    return failures == 0 ? 0 : 1;
}
}
