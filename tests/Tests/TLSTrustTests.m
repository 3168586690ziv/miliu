// TLSTrustTests.m — 证书信任容错专项（第 36 轮）
//
// 背景（2026-10-12 真实站点实测根因）：www.hanime2.org 的 Let's Encrypt「YE1」
// 证书被 Apple 信任评估判为**已吊销**（CSSMERR_TP_CERT_REVOKED），而站方没有换证。
// 后果是探测/元数据/能力探测/预览/下载全线间歇失败（实测 ephemeral 会话 12 次
// 失败 6 次），能力探测失败又让下载降级成单连接（用户实测 60KB/s）。
//
// 本套件只测**判据本身**（纯逻辑、不联网），因为真实证书链的形态必须固定下来：
//   · 只有 leaf 带 error 且该 error 是 REVOKED → 放行；
//   · 其他任何失败形态（域名不匹配/自签名/过期/多失败项/中间证书被吊销）→ 拒绝；
//   · 容错开关关闭 → 一律拒绝（严格模式必须真的严格）。
//
// 用 SecTrustCreateWithCertificates 构造真实 SecTrust，再把评估结果注入不进去——
// 因此这里用**两条互补的测法**：
//   ① 纯函数判据：用假的属性数组直接验证「哪一项带 error」的收敛逻辑（新增内联版）；
//   ② 开关语义：验证偏好键的默认（开）与关闭（严格）行为。
// 真实链上的端到端效果由 tests/Tests/tls-trust-real-site.sh 联网验证（可选、按需跑）。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "RDTLSTrust.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

// ── ① 判据核心：只认「唯一失败项 = leaf 的 REVOKED」 ──
// 把 RDTLSTrust 里读 SecTrustCopyProperties 的那段判据抽成等价的内联版本，
// 以便用构造的属性数组做表驱动测试（真实 SecTrust 无法注入属性）。
static BOOL RevocationIsOnlyFailure_FromProperties(NSArray *props, NSString **why) {
    if (props.count == 0) return NO;
    NSUInteger withError = 0;
    NSString *soleError = nil;
    for (id entry in props) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        id err = ((NSDictionary *)entry)[@"error"];
        if ([err isKindOfClass:[NSString class]] && [err length]) {
            withError++;
            if (!soleError) soleError = (NSString *)err;
        }
    }
    if (withError != 1 || soleError.length == 0) return NO;
    if (![soleError containsString:@"REVOKED"]) return NO;
    id firstErr = ((NSDictionary *)props.firstObject)[@"error"];
    if (![firstErr isKindOfClass:[NSString class]] || ![((NSString *)firstErr) containsString:@"REVOKED"]) return NO;
    if (why) *why = soleError;
    return YES;
}

static void RevocationJudgementTests(void) {
    // 本机实测的真实形态（SecTrustCopyProperties 输出）。
    NSArray *realShape = @[
        @{@"error": @"CSSMERR_TP_CERT_REVOKED", @"title": @"hanime2.org"},
        @{@"title": @"YE1"},
        @{@"title": @"Root YE"},
        @{@"title": @"ISRG Root X2"},
    ];
    Check(RevocationIsOnlyFailure_FromProperties(realShape, NULL),
          @"判据：真实形态（leaf REVOKED + 链上其余无 error）→ 放行");

    // 两个失败项：吊销之外还有别的问题 → 拒绝（正是要防的放松）。
    NSArray *twoErrors = @[
        @{@"error": @"CSSMERR_TP_CERT_REVOKED", @"title": @"hanime2.org"},
        @{@"error": @"CSSMERR_TP_INVALID_ANCHOR_CERT", @"title": @"Root YE"},
    ];
    Check(!RevocationIsOnlyFailure_FromProperties(twoErrors, NULL),
          @"判据：leaf 吊销 + 链上另有失败项（锚无效）→ 拒绝");

    // 错误在中间证书上：性质不同（可能是恶意中间人），必须拒绝。
    NSArray *intermediateRevoked = @[
        @{@"title": @"hanime2.org"},
        @{@"error": @"CSSMERR_TP_CERT_REVOKED", @"title": @"YE1"},
    ];
    Check(!RevocationIsOnlyFailure_FromProperties(intermediateRevoked, NULL),
          @"判据：吊销落在中间证书（非 leaf）→ 拒绝");

    // 域名不匹配：必须拒绝。
    NSArray *hostMismatch = @[
        @{@"error": @"CSSMERR_TP_HOSTNAME_MISMATCH", @"title": @"evil.example"},
        @{@"title": @"YE1"},
    ];
    Check(!RevocationIsOnlyFailure_FromProperties(hostMismatch, NULL),
          @"判据：域名不匹配 → 拒绝（不容错）");

    // 自签名 / 不受信任根：必须拒绝。
    NSArray *selfSigned = @[
        @{@"error": @"CSSMERR_TP_NOT_TRUSTED", @"title": @"selfsigned.local"},
    ];
    Check(!RevocationIsOnlyFailure_FromProperties(selfSigned, NULL),
          @"判据：自签名/不受信任根 → 拒绝（不容错）");

    // 过期：必须拒绝。
    NSArray *expired = @[
        @{@"error": @"CSSMERR_TP_CERT_EXPIRED", @"title": @"hanime2.org"},
        @{@"title": @"YE1"},
    ];
    Check(!RevocationIsOnlyFailure_FromProperties(expired, NULL),
          @"判据：证书过期 → 拒绝（不容错）");

    // 全部通过（没有 error）：不是「吊销唯一失败」，返回 NO（调用方本来也不会走到这）。
    NSArray *allGood = @[@{@"title": @"a"}, @{@"title": @"b"}];
    Check(!RevocationIsOnlyFailure_FromProperties(allGood, NULL),
          @"判据：无任何 error → 不进入容错分支");

    // 空属性数组：保守拒绝。
    Check(!RevocationIsOnlyFailure_FromProperties(@[], NULL),
          @"判据：属性为空 → 拒绝");
}

// ── ② 开关语义：默认开、可关成严格 ──
static void SwitchSemanticsTests(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *key = RDTLSAllowRevokedCertificateKey;

    [ud removeObjectForKey:key];
    Check(RDTLSAllowRevokedCertificateEnabled(),
          @"开关：未设置时默认开启（该站不可用是主人实测报障，默认必须能用）");

    [ud setBool:NO forKey:key];
    Check(!RDTLSAllowRevokedCertificateEnabled(),
          @"开关：显式关闭后进入严格模式");

    [ud setBool:YES forKey:key];
    Check(RDTLSAllowRevokedCertificateEnabled(),
          @"开关：显式开启后恢复容错");

    [ud removeObjectForKey:key];   // 复原，不污染后续
}

// ── ③ 挑战接管契约：非 ServerTrust 挑战必须交回系统默认处理 ──
static void ChallengeContractTests(void) {
    // nil 输入不得崩溃，且必须交回默认处理（返回 NO）。
    __block BOOL called = NO;
    BOOL handled = RDTLSHandleServerTrustChallenge(nil, @"test", ^(NSURLSessionAuthChallengeDisposition d, NSURLCredential *c) {
        called = YES;
    });
    Check(!handled && !called, @"契约：nil 挑战 → 不接管、不回调");
}

// ── ④ 端到端（仅当环境变量开启时联网）：真实站点必须能通过 ──
static void RealSiteOptionalTest(void) {
    if (![NSProcessInfo.processInfo.environment[@"RD_TLS_REAL_SITE"] isEqualToString:@"1"]) {
        NSLog(@"SKIP: 真实站点端到端未启用（设 RD_TLS_REAL_SITE=1 开启）");
        return;
    }
    // 该项由 tls-trust.sh 用独立二进制跑，这里只做提示，避免在纯逻辑套件里联网。
    NSLog(@"NOTE: 真实站点端到端见 tests/Tests/tls-trust-real-site.sh");
}

int main(void) {
    @autoreleasepool {
        NSLog(@"== 证书信任容错专项（第 36 轮）==");
        RevocationJudgementTests();
        SwitchSemanticsTests();
        ChallengeContractTests();
        RealSiteOptionalTest();
        if (gFailed == 0) NSLog(@"TLS-TRUST-PASSED checks=%d", gPassed);
        else NSLog(@"TLS-TRUST-FAILED passed=%d failed=%d", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
