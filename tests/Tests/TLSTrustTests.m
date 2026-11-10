// TLSTrustTests.m — 证书信任容错专项（第 36 轮；2026-10-12 复核后整改）
//
// 整改原因（复核实测）：首版把判据「抄成等价的**内联副本**」再测，
// 于是把生产 header 里「失败项必须落在 leaf」整段删掉后，本套件仍 12/12 全绿、
// 退出 0 —— 8/12 条断言对生产代码**没有任何守卫作用**。
// 现在全部改为**直接调用生产函数**（header-only，无需链生产 .m）：
//   · RDTLSTrustSANEntriesCoverHost                    （SAN 解析，可注入 entries）
//   · RDTLSTrustRevocationPropsIndicateLeafOnly        （吊销判据纯逻辑，可注入 props + 索引）
//   · RDTLSFailingCertificateIndexFromError            （出错证书索引解析）
//   · RDTLSAllowRevokedCertificateForValue / RDTLSHandleServerTrustChallenge（隔离开关与契约）
//   · RDTLSEvaluateServerTrustWithRevocationAllowed（本地真实 SecTrust，不读用户偏好）
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

    // ③-2 本地化锚点（2026-10-13 真机 P0，逐字来自本机 zh_CN bundle 实测）：
    // CFBundleDevelopmentRegion=zh_CN 的进程里，同一个「leaf 被吊销」的 underlying
    // 描述是「证书0“hanime2.org”有错误：证书已撤销;」，英文锚点 "Certificate "
    // 不存在 ⇒ 修复前索引取不到 ⇒ fail-closed 拒绝 ⇒ 静态腿整条探测失败。
    // 守卫：两种本地化形态都必须解出同一索引；判据不因语言放宽（无数字+引号结构仍拒绝）。
    NSError *eZh0 = [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
        NSLocalizedDescriptionKey: @"“hanime2.org”证书已撤销",
        NSUnderlyingErrorKey: [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
            NSLocalizedDescriptionKey: @"证书0“hanime2.org”有错误：证书已撤销;"
        }]}];
    NSError *eZh1 = [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
        NSLocalizedDescriptionKey: @"“Review Intermediate”证书已撤销",
        NSUnderlyingErrorKey: [NSError errorWithDomain:@"NSOSStatusErrorDomain" code:-67820 userInfo:@{
            NSLocalizedDescriptionKey: @"证书1“Review Intermediate”有错误：证书已撤销;"
        }]}];
    Check(RDTLSFailingCertificateIndexFromError(eZh0) == 0,
          @"索引解析（中文本地化）：证书0“hanime2.org” → 0（leaf，容错放行前提）");
    Check(RDTLSFailingCertificateIndexFromError(eZh1) == 1,
          @"索引解析（中文本地化）：证书1“Review Intermediate” → 1（非 leaf，仍拒绝）");
    Check(RDTLSFailingCertificateIndexFromError(eNone) == NSNotFound,
          @"索引解析：无「数字+引号名称」结构（如 \"certificate is not trusted\"）→ NSNotFound，fail-closed");
}

// ── ④ 开关语义 ──
static void SwitchTests(void) {
    Check(!RDTLSAllowRevokedCertificateForValue(nil), @"开关：未设置默认严格（批准的更严格规格）");
    Check(!RDTLSAllowRevokedCertificateForValue(@NO), @"开关：显式关闭后进入严格模式");
    Check(RDTLSAllowRevokedCertificateForValue(@YES), @"开关：显式开启后保留窄容错");
    for(id value in @[@"YES", @"true", @"1", @1])
        Check(RDTLSAllowRevokedCertificateForValue(value), [NSString stringWithFormat:@"开关：明确真值 %@ 开启", value]);
    for(id value in @[@"NO", @"false", @"0", @"", @"garbage", @" true", @2, @(-1), NSNull.null, @[], @{}])
        Check(!RDTLSAllowRevokedCertificateForValue(value), [NSString stringWithFormat:@"开关：关闭或畸形值 %@ 默认严格", value]);
}

// A locally generated self-signed fixture is explicitly anchored only in each
// test SecTrust object. No keychain, network, global trust or preference changes.
static SecTrustRef LocalTrust(SecCertificateRef certificate, NSString *host, BOOL anchored, BOOL expired) {
    SecPolicyRef policy=SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
    SecTrustRef trust=NULL;
    OSStatus status=SecTrustCreateWithCertificates(certificate, policy, &trust);
    CFRelease(policy);
    if(status!=errSecSuccess||!trust)return NULL;
    SecTrustSetNetworkFetchAllowed(trust, false);
    NSArray *anchors=anchored?@[(__bridge id)certificate]:@[];
    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
    SecTrustSetAnchorCertificatesOnly(trust, true);
    NSDate *date=expired?[NSDate dateWithTimeIntervalSince1970:4102444800.0]:NSDate.date;
    SecTrustSetVerifyDate(trust, (__bridge CFDateRef)date);
    return trust;
}

static void LocalSecTrustTests(void) {
    const char *path=getenv("RD_TLS_CERT_PATH");
    NSData *der=path?[NSData dataWithContentsOfFile:@(path)]:nil;
    SecCertificateRef certificate=der?SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der):NULL;
    Check(certificate!=NULL, @"本地证书：DER 夹具可读取");
    if(!certificate)return;
    for(NSNumber *allow in @[@NO,@YES]) {
        SecTrustRef trusted=LocalTrust(certificate,@"good.tls.fixture",YES,NO);
        Check(RDTLSEvaluateServerTrustWithRevocationAllowed(trusted,@"good.tls.fixture",allow.boolValue,NULL)==RDTLSTrustVerdictUseDefault,
              [NSString stringWithFormat:@"真实 SecTrust：局部锚定且域名有效，allow=%@ 仍交系统默认",allow]);
        if(trusted)CFRelease(trusted);
        SecTrustRef untrusted=LocalTrust(certificate,@"good.tls.fixture",NO,NO);
        Check(RDTLSEvaluateServerTrustWithRevocationAllowed(untrusted,@"good.tls.fixture",allow.boolValue,NULL)==RDTLSTrustVerdictReject,
              [NSString stringWithFormat:@"真实 SecTrust：未信任自签，allow=%@ 仍拒绝",allow]);
        if(untrusted)CFRelease(untrusted);
        SecTrustRef wrongHost=LocalTrust(certificate,@"wrong.tls.fixture",YES,NO);
        Check(RDTLSEvaluateServerTrustWithRevocationAllowed(wrongHost,@"wrong.tls.fixture",allow.boolValue,NULL)==RDTLSTrustVerdictReject,
              [NSString stringWithFormat:@"真实 SecTrust：域名不符，allow=%@ 仍拒绝",allow]);
        if(wrongHost)CFRelease(wrongHost);
        SecTrustRef expired=LocalTrust(certificate,@"good.tls.fixture",YES,YES);
        Check(RDTLSEvaluateServerTrustWithRevocationAllowed(expired,@"good.tls.fixture",allow.boolValue,NULL)==RDTLSTrustVerdictReject,
              [NSString stringWithFormat:@"真实 SecTrust：本地校验时刻已过期，allow=%@ 仍拒绝",allow]);
        if(expired)CFRelease(expired);
    }
    CFRelease(certificate);
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
        LocalSecTrustTests();
        ChallengeContractTests();
        NSLog(@"NOTE: 本套件仅离线；真实网站不属于本次选定检查，不声称在线吊销端到端通过");
        NSLog(@"TLS-TRUST-%@ checks=%d failed=%d", gFailed == 0 ? @"PASSED" : @"FAILED", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
