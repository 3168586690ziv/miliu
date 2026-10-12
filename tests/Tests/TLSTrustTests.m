// TLSTrustTests.m — 证书信任容错专项（第 36 轮；2026-10-12 复核后整改）
//
// 整改原因（复核实测）：首版把判据「抄成等价的**内联副本**」再测，
// 于是把生产 header 里「失败项必须落在 leaf」整段删掉后，本套件仍 12/12 全绿、
// 退出 0 —— 8/12 条断言对生产代码**没有任何守卫作用**。
// 现在全部改为**直接调用生产函数**（header-only，无需链生产 .m）：
//   · RDTLSTrustSANEntriesCoverHost                    （SAN 解析，可注入 entries）
//   · RDTLSTrustRevocationPropsIndicateLeafOnly        （吊销判据纯逻辑，可注入 props + 索引）
//   · RDTLSFailingCertificateIndexFromError            （出错证书索引解析）
//   · RDTLSAllowRevokedCertificateEnabled / RDTLSHandleServerTrustChallenge（开关与契约）
// 改动这些生产逻辑必须让本套件变红。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "RDTLSTrust.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

// ── 构造 SAN 条目的辅助（形态与 SecCertificateCopyValues 输出一致）──
static NSDictionary *SANEntry(NSString *label, id value) {
    return @{ (__bridge NSString *)kSecPropertyKeyLabel: label,
              (__bridge NSString *)kSecPropertyKeyValue: value };
}

// ── ① SAN 门：只认严格 "DNS Name"，通配收敛 ──
static void SANGateTests(void) {
    NSArray *dnsOnly = @[ SANEntry(@"DNS Name", @"good.example") ];
    Check(RDTLSTrustSANEntriesCoverHost(dnsOnly, @"good.example"),
          @"SAN：DNS Name 精确匹配 → 涵盖");
    Check(RDTLSTrustSANEntriesCoverHost(dnsOnly, @"GOOD.EXAMPLE"),
          @"SAN：大小写不敏感");
    Check(!RDTLSTrustSANEntriesCoverHost(dnsOnly, @"other.example"),
          @"SAN：不同 host → 不涵盖");

    // 复核修复点：非 DNS 条目（值恰好含点）不得被当成 DNS 名
    NSArray *emailOnly = @[ SANEntry(@"Email Address", @"victim.example") ];
    Check(!RDTLSTrustSANEntriesCoverHost(emailOnly, @"victim.example"),
          @"SAN【修复】Email Address 条目不得当作 DNS 名（原实现误判为涵盖）");
    NSArray *otherOnly = @[ SANEntry(@"1.2.3.4", @"victim.example") ];
    Check(!RDTLSTrustSANEntriesCoverHost(otherOnly, @"victim.example"),
          @"SAN【修复】otherName（label=OID）不得当作 DNS 名");
    NSArray *ipOnly = @[ SANEntry(@"IP Address", @"93.184.216.34") ];
    Check(!RDTLSTrustSANEntriesCoverHost(ipOnly, @"93.184.216.34"),
          @"SAN【修复】IP Address 条目不得当作 DNS 名");
    NSArray *uriOnly = @[ SANEntry(@"URI", @"https://uri.example/p") ];
    Check(!RDTLSTrustSANEntriesCoverHost(uriOnly, @"uri.example"),
          @"SAN：URI 条目不涵盖");

    // 复核修复点：通配必须严格 *.example.com
    Check(RDTLSTrustSANEntriesCoverHost(@[ SANEntry(@"DNS Name", @"*.wild.example") ], @"a.wild.example"),
          @"SAN：*.wild.example 覆盖 a.wild.example");
    Check(!RDTLSTrustSANEntriesCoverHost(@[ SANEntry(@"DNS Name", @"*.wild.example") ], @"a.b.wild.example"),
          @"SAN：*.wild.example 不覆盖两级子域");
    Check(!RDTLSTrustSANEntriesCoverHost(@[ SANEntry(@"DNS Name", @"*.com") ], @"x.com"),
          @"SAN【修复】*.com 跨公共后缀必须拒绝（原实现误放行）");
    Check(!RDTLSTrustSANEntriesCoverHost(@[ SANEntry(@"DNS Name", @"*wild.example") ], @"barwild.example"),
          @"SAN【修复】*wild.example（* 后无点）必须拒绝（原实现误放行）");
    Check(!RDTLSTrustSANEntriesCoverHost(@[ SANEntry(@"DNS Name", @"*") ], @"anything.example"),
          @"SAN【修复】裸 * 必须拒绝（原实现依赖 hasSuffix:@\"\" 的未文档化行为）");
    Check(!RDTLSTrustSANEntriesCoverHost(@[ SANEntry(@"DNS Name", @"a.*.example") ], @"a.b.example"),
          @"SAN：【修复】* 不在最左标签 → 拒绝");

    // 保守性
    Check(!RDTLSTrustSANEntriesCoverHost(@[], @"good.example"), @"SAN：空条目 → 拒绝");
    Check(!RDTLSTrustSANEntriesCoverHost(nil, @"good.example"), @"SAN：nil 条目 → 拒绝");
    Check(!RDTLSTrustSANEntriesCoverHost(dnsOnly, @""), @"SAN：空 host → 拒绝");
    Check(!RDTLSTrustSANEntriesCoverHost(dnsOnly, nil), @"SAN：nil host → 拒绝");
}

// ── ② 吊销判据纯逻辑：唯一失败项 + 必须是 leaf ──
static void RevocationJudgementTests(void) {
    NSString *const kRevoked = @"CSSMERR_TP_CERT_REVOKED";
    // 真实站点实测形态：只有 leaf 带 error，链上其余无 error
    NSArray *realShape = @[
        @{@"error": kRevoked, @"title": @"hanime2.org"},
        @{@"title": @"YE1"},
        @{@"title": @"Root YE"},
        @{@"title": @"ISRG Root X2"},
    ];
    Check(RDTLSTrustRevocationPropsIndicateLeafOnly(realShape, 0, NULL),
          @"判据：真实形态（leaf REVOKED + 索引 0）→ 放行");

    // 复核修复点：中间证书被吊销时，CopyProperties **同样**把 error 放在第 0 项、
    // title 写 leaf 的名字（本机 OCSP 注入 3/3 复现）——只有索引能区分。
    NSArray *interShape = @[
        @{@"error": kRevoked, @"title": @"good.example"},
        @{@"title": @"Review Intermediate"},
        @{@"title": @"Review Root"},
    ];
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(interShape, 1, NULL),
          @"判据【修复】中间证书被吊销（props 形态与真实站点相同、仅索引不同）→ 拒绝");
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(interShape, NSNotFound, NULL),
          @"判据【修复】索引取不到 → 拒绝（fail-closed，格式变化不得变成放行）");
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(interShape, 2, NULL),
          @"判据【修复】出错索引=2（根）→ 拒绝");

    // 两个失败项：吊销之外还有别的问题 → 拒绝
    NSArray *twoErrors = @[
        @{@"error": kRevoked, @"title": @"leaf.example"},
        @{@"error": @"CSSMERR_TP_INVALID_ANCHOR_CERT", @"title": @"Root"},
    ];
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(twoErrors, 0, NULL),
          @"判据：leaf 吊销 + 链上另有失败项 → 拒绝");

    // 非吊销类错误
    NSArray *notRevoked = @[ @{@"error": @"CSSMERR_TP_CERT_EXPIRED", @"title": @"leaf.example"} ];
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(notRevoked, 0, NULL),
          @"判据：过期（非吊销）→ 拒绝");

    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(@[], 0, NULL), @"判据：空 props → 拒绝");
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(nil, 0, NULL), @"判据：nil props → 拒绝");
    Check(!RDTLSTrustRevocationPropsIndicateLeafOnly(@[@{}, @{}], 0, NULL),
          @"判据：没有任何 error → 拒绝");
}

// ── ③ 出错证书索引解析（判据的输入，同样必须有守卫）──
static void FailingIndexTests(void) {
    NSError *e0 = [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
        NSLocalizedDescriptionKey: @"\"hanime2.org\" certificate is revoked",
        NSUnderlyingErrorKey: [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
            NSLocalizedDescriptionKey: @"Certificate 0 \"hanime2.org\" has errors: Certificate is revoked;"
        }]}];
    NSError *e1 = [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
        NSLocalizedDescriptionKey: @"\"Review Intermediate\" certificate is revoked",
        NSUnderlyingErrorKey: [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
            NSLocalizedDescriptionKey: @"Certificate 1 \"Review Intermediate\" has errors: Certificate is revoked;"
        }]}];
    NSError *eNone = [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-1 userInfo:@{
        NSLocalizedDescriptionKey: @"certificate is not trusted"}];

    Check(RDTLSFailingCertificateIndexFromError(e0) == 0, @"索引解析：Certificate 0 → 0");
    Check(RDTLSFailingCertificateIndexFromError(e1) == 1, @"索引解析：Certificate 1 → 1");
    Check(RDTLSFailingCertificateIndexFromError(eNone) == NSNotFound,
          @"索引解析：无 \"Certificate N\" → NSNotFound（调用方据此拒绝）");
    Check(RDTLSFailingCertificateIndexFromError(nil) == NSNotFound, @"索引解析：nil → NSNotFound");
}

// ── ④ 开关语义 ──
static void SwitchTests(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:RDTLSAllowRevokedCertificateKey];
    Check(RDTLSAllowRevokedCertificateEnabled(),
          @"开关：未设置时默认开启（该站不可用是主人实测报障，默认必须能用）");
    [ud setBool:NO forKey:RDTLSAllowRevokedCertificateKey];
    Check(!RDTLSAllowRevokedCertificateEnabled(), @"开关：显式关闭后进入严格模式");
    [ud setBool:YES forKey:RDTLSAllowRevokedCertificateKey];
    Check(RDTLSAllowRevokedCertificateEnabled(), @"开关：显式开启后恢复容错");
    [ud removeObjectForKey:RDTLSAllowRevokedCertificateKey];
}

// ── ⑤ 挑战处理契约 ──
static void ChallengeContractTests(void) {
    __block BOOL called = NO;
    BOOL handled = RDTLSHandleServerTrustChallenge(nil, @"test", ^(NSURLSessionAuthChallengeDisposition d, NSURLCredential *c) { called = YES; });
    Check(!handled && !called, @"契约：nil 挑战 → 不接管、不回调");
}

int main(void) {
    @autoreleasepool {
        NSLog(@"== 证书信任容错专项（第 36 轮；复核整改版）==");
        SANGateTests();
        RevocationJudgementTests();
        FailingIndexTests();
        SwitchTests();
        ChallengeContractTests();
        if (getenv("RD_TLS_REAL_SITE")) {
            NSLog(@"SKIP: 真实站点端到端由 tls-trust-real-site.sh 单独跑");
        } else {
            NSLog(@"SKIP: 真实站点端到端未启用（设 RD_TLS_REAL_SITE=1 开启）");
        }
        NSLog(@"TLS-TRUST-%@ checks=%d failed=%d", gFailed == 0 ? @"PASSED" : @"FAILED", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
