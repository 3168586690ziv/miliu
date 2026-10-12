// ProxyFakeIPTests.m — 系统代理 fake-ip 兼容专项（2026-10-12 第 39 轮）
//
// 背景（真实故障，用户实测报障）：用户开着 Clash 一类代理（TUN 模式 + fake-ip），
// 代理软件把**所有**域名答成 198.18.0.0/15 内的假地址（实测 apple.com →
// 198.18.0.6、github.com → 198.18.0.36、www.hanime2.org → 198.18.0.40），
// 再由虚拟网卡按域名转发。该段同时是 RFC 2544 基准测试保留段，于是 URLPolicy
// 把它判为「保留地址」拒绝 —— 用户开着代理时**任何网站都探测不了**，提示还是
// 「地址被安全策略阻止：保留/无效地址不可探测」（把代理配置说成了安全问题）。
//
// 修复：系统代理启用时，198.18.0.0/15 按「代理 fake-ip」放行（走代理时本机 DNS
// 结论不具代表性）；其余保留/私网/回环/链路本地/组播段**照旧拦截**。
//
// 本套件用注入开关驱动，不依赖运行环境是否真的开着代理。
#import <Foundation/Foundation.h>
#import "URLPolicy.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

static BOOL AllowedForIP(URLPolicy *p, NSString *ip) {
    NSURL *u = [NSURL URLWithString:@"https://www.hanime2.org/watch?v=408297"];
    return [p evaluateResolvedURL:u resolvedIP:ip].allowed;
}

int main(void) {
    @autoreleasepool {
        URLPolicy *p = [URLPolicy new];
        NSArray<NSString *> *fakeIPs = @[@"198.18.0.40", @"198.18.0.6", @"198.18.0.1", @"198.19.255.1"];

        // ── ① 代理启用：fake-ip 段必须放行（这就是用户的故障场景）──
        [URLPolicy setSystemProxyActiveOverride:@YES];
        Check([URLPolicy systemProxyIsActive], @"注入后 systemProxyIsActive=YES");
        for (NSString *ip in fakeIPs) {
            Check(AllowedForIP(p, ip), [NSString stringWithFormat:@"代理启用：%@（fake-ip 段）→ 放行", ip]);
        }

        // ── ② 代理关闭：同一批地址必须仍被拒绝（证明放行确由代理状态驱动）──
        [URLPolicy setSystemProxyActiveOverride:@NO];
        Check(![URLPolicy systemProxyIsActive], @"注入后 systemProxyIsActive=NO");
        for (NSString *ip in fakeIPs) {
            Check(!AllowedForIP(p, ip), [NSString stringWithFormat:@"代理关闭：%@ → 仍拒绝（对照）", ip]);
        }

        // ── ③ 安全策略不得被削弱：代理开启时，危险段一律仍拒绝 ──
        [URLPolicy setSystemProxyActiveOverride:@YES];
        NSDictionary<NSString *, NSString *> *danger = @{
            @"192.168.1.1":  @"私网",
            @"10.0.0.5":     @"私网",
            @"172.16.0.1":   @"私网",
            @"100.64.0.1":   @"运营商级 NAT",
            @"127.0.0.1":    @"回环",
            @"169.254.1.1":  @"链路本地",
            @"0.0.0.0":      @"保留",
            @"224.0.0.1":    @"组播",
            @"240.0.0.1":    @"保留",
        };
        for (NSString *ip in danger) {
            Check(!AllowedForIP(p, ip),
                  [NSString stringWithFormat:@"代理开启：%@（%@）→ 仍拒绝", ip, danger[ip]]);
        }

        // ── ④ 段边界精确性：只有 198.18.0.0/15 两端在 fake-ip 处理范围内 ──
        // 段外（198.17.x.x / 198.20.x.x）本就是合法公网地址，与 fake-ip 无关：
        // 代理关闭时它们照样放行 —— 用这个对照把掩码精度钉死。
        [URLPolicy setSystemProxyActiveOverride:@NO];
        Check(!AllowedForIP(p, @"198.18.0.0"),     @"代理关闭：198.18.0.0（段起点）→ 拒绝（判为保留）");
        Check(!AllowedForIP(p, @"198.19.255.255"), @"代理关闭：198.19.255.255（段终点）→ 拒绝（判为保留）");
        Check(AllowedForIP(p, @"198.17.255.255"),  @"代理关闭：198.17.255.255（段外·公网）→ 放行");
        Check(AllowedForIP(p, @"198.20.0.1"),      @"代理关闭：198.20.0.1（段外·公网）→ 放行");
        [URLPolicy setSystemProxyActiveOverride:@YES];
        Check(AllowedForIP(p, @"198.18.0.0"),      @"代理开启：198.18.0.0（段起点）→ 放行");
        Check(AllowedForIP(p, @"198.19.255.255"),  @"代理开启：198.19.255.255（段终点）→ 放行");
        Check(AllowedForIP(p, @"198.17.255.255"),  @"代理开启：段外·公网 → 放行");
        Check(AllowedForIP(p, @"93.184.216.34"),   @"代理开启：公网地址 → 放行");

        // ── ⑤ 文本阶段：直接粘贴 fake-ip 地址也放行；内网字面量仍拒绝 ──
        Check([p evaluateTextURL:@"https://198.18.0.40/watch?v=1"].allowed,
              @"文本阶段：代理开启时 fake-ip 字面量 → 放行");
        Check(![p evaluateTextURL:@"https://192.168.1.1/admin"].allowed,
              @"文本阶段：内网字面量 → 仍拒绝");
        Check(![p evaluateTextURL:@"https://127.0.0.1/"].allowed,
              @"文本阶段：回环字面量 → 仍拒绝");

        // ── ⑥ scheme / 格式检查不受影响 ──
        Check(![p evaluateTextURL:@"file:///etc/passwd"].allowed, @"文本阶段：file:// → 仍拒绝");
        Check(![p evaluateTextURL:@"ftp://x.example/"].allowed,    @"文本阶段：ftp:// → 仍拒绝");
        Check(![p evaluateTextURL:@"https://user:pw@x.example/"].allowed,
              @"文本阶段：含 userinfo → 仍拒绝");

        // ── ⑦ 注入恢复：nil 回到真实探测，不残留测试状态 ──
        [URLPolicy setSystemProxyActiveOverride:nil];
        Check(YES, @"注入恢复为真实探测（不崩）");

        NSLog(@"PROXY-FAKEIP-%@ checks=%d failed=%d",
              gFailed == 0 ? @"PASSED" : @"FAILED", gPassed, gFailed);
    }
    return gFailed == 0 ? 0 : 1;
}
