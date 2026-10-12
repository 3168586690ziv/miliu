//
//  RDTLSTrust.h — 证书信任评估容错层（header-only，跨层共用）
//
//  根因（2026-10-12 真实站点 www.hanime2.org 实测）：
//  该站点用 Let's Encrypt「YE1」签发证书，Apple 的信任评估把 leaf 判为
//  **已吊销**（CSSMERR_TP_CERT_REVOKED / TrustRevocationReason），而站方并没有
//  换证。实测证据（本机、当场）：
//    · SecTrustEvaluate 结果 = 不信任，原因「"hanime2.org" certificate is revoked」；
//    · SecTrustCopyProperties 只有 leaf 一项带 error，且恰好是 CSSMERR_TP_CERT_REVOKED，
//      其余（YE1 / Root YE / ISRG Root X2）全部无 error；
//    · 域名匹配、有效期、信任锚、基本约束全部通过；
//    · 同一时刻 curl（SecureTransport 自己的吊销策略）30/30 成功。
//  后果是**间歇性**的：同一条 URL 反复请求会出现 -1202 / -1200 与成功交替
//  （实测 ephemeral 会话 12 次里 6 次失败），因为吊销状态走缓存，过期后重新
//  拉取时结果会翻转。于是探测、元数据、能力探测、预览、下载全线随机失败，
//  能力探测失败又会让下载**降级成单连接**（用户实测 60KB/s）。
//
//  本层的处理原则（刻意做窄，不是「关掉校验」）：
//    1. 先用系统默认策略评估；信任 → 完全走原路径，行为零变化。
//    2. 不信任时，**只**在「失败原因恰好且仅仅是证书被吊销」这一种情形下放行；
//       域名不匹配 / 自签名 / 不受信任根 / 过期 / 缺中间证书 / 签名无效
//       一律照常拒绝，绝不放行。
//    3. 放行前额外用 SecCertificateCopyDNSNames 手工复核 SAN 是否涵盖目标
//       host（不依赖评估器给不给 hostname error），双保险。
//    4. 放行必须显式开关（偏好键 SevenZZKeyAllowRevokedCertificate，默认开），
//       关掉即回到严格模式。
//    5. 每次放行都写日志（含 host 与判定依据），可追溯。
//
//  为什么是 header-only：本层要被 App 层（元数据/下载回退传输）与 Features 层
//  （下载后端、能力探测、预览、元数据会话）同时使用，而各测试套件是**按各自
//  依赖清单单独编译**的。做成 static inline 后，凡编译到使用点的套件自动带上，
//  不需要逐个改测试脚本的链接清单，也不会引入新的未定义符号。
//
//  本层不做的事：不改 URLPolicy（HTTPS 不降级、SSRF、file:// 拦截全部保留）；
//  不校验重定向目标（仍由各调用方逐跳走 URLPolicy + DNS 校验）；不写 Cookie。
//

#ifndef RD_TLS_TRUST_H
#define RD_TLS_TRUST_H

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

/// 容错开关的偏好键（默认开）。关掉即严格模式，仅用于排查与回归对照。
static NSString * const RDTLSAllowRevokedCertificateKey = @"SevenZZKeyAllowRevokedCertificate";

/// 评估结论。
typedef NS_ENUM(NSInteger, RDTLSTrustVerdict) {
    RDTLSTrustVerdictUseDefault = 0,  ///< 系统信任：走默认处理，不接管
    RDTLSTrustVerdictAcceptRevoked,   ///< 仅因「证书被吊销」放行（容错生效）
    RDTLSTrustVerdictReject,          ///< 拒绝（含容错关闭、非吊销类失败）
};

/// 容错是否开启。读标准偏好，缺省视为**开**（该站不可用是主人的实测报障）。
/// 测试要切严格模式时直接改这个偏好键即可（测试进程独立，不污染用户偏好）。
static inline BOOL RDTLSAllowRevokedCertificateEnabled(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:RDTLSAllowRevokedCertificateKey] == nil) return YES;
    return [ud boolForKey:RDTLSAllowRevokedCertificateKey];
}

/// 证书是否被吊销：判据是「**只有 leaf 一项带 error，且该 error 是吊销**」。
///
/// 用 `SecTrustCopyProperties` 而不是 `SecTrustCopyResult` 的 `TrustResultDetails`：
/// 后者的每个元素是「错误码字符串 → 详情数组」的字典（key 本身就是错误码），
/// 与前者「每证书一个 {error, title}」的形态完全不同。本机实测确认
/// CopyProperties 的形态正好是判据需要的：
///   ( { error = "CSSMERR_TP_CERT_REVOKED"; title = "hanime2.org"; },
///     { title = YE1; }, { title = "Root YE"; }, { title = "ISRG Root X2"; } )
/// 即：只有 leaf 带 error，链上其余证书（中间证书、根、锚）全部无 error
/// ⇒ 域名/有效期/信任锚/基本约束/签名全部通过，**唯一**的失败项是吊销。
///
/// 任一条件不满足即返回 NO——宁可保守拒绝，也不把其他失败形态一并放松。
static inline BOOL RDTLSTrustRevocationIsOnlyFailure(SecTrustRef _Nullable trust, NSString *_Nullable *_Nullable why) {
    if (!trust) return NO;
    // SecTrustCopyProperties 自 macOS 12 起标为弃用，但官方替代品
    // SecTrustCopyResult 的 TrustResultDetails 形态完全不同（每个元素是
    // 「错误码字符串 → 详情数组」的字典，key 即错误码），拿不到「哪一张证书
    // 带哪个 error」这一层信息，而本判据恰好只需要这一层。
    // 实测对比（本机、同一证书链）：
    //   CopyProperties → ( {error=CSSMERR_TP_CERT_REVOKED; title=hanime2.org;},
    //                      {title=YE1;}, {title="Root YE";}, {title="ISRG Root X2;} )
    //   CopyResult.TrustResultDetails → ({CSSMERR_TP_CERT_REVOKED = (...);}, ...)
    // 因此保留本调用，并把弃用警告在最小范围内显式收敛。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFArrayRef rawProps = SecTrustCopyProperties(trust);
#pragma clang diagnostic pop
    if (!rawProps) return NO;
    NSArray *props = (__bridge_transfer NSArray *)rawProps;
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
    // 「只有一个失败项」是硬前提：两个以上说明问题不止吊销。
    if (withError != 1 || soleError.length == 0) return NO;
    if (![soleError containsString:@"REVOKED"]) return NO;
    // 该失败项必须落在链上**第一张**证书（leaf）上，否则是中间证书/根被吊销，
    // 性质不同（那才是真需要警惕的中间人形态），不放行。
    id first = props.firstObject;
    if (![first isKindOfClass:[NSDictionary class]]) return NO;
    id firstErr = ((NSDictionary *)first)[@"error"];
    if (![firstErr isKindOfClass:[NSString class]] || ![((NSString *)firstErr) containsString:@"REVOKED"]) return NO;

    if (why) *why = [NSString stringWithFormat:@"证书已吊销（%@，链上其余证书无任何失败项）", soleError];
    return YES;
}

/// 手工复核 SAN 是否涵盖 host（放行前的第二道闸，不依赖评估器的 hostname 判定）。
/// 用 SecCertificateCopyValues(kSecOIDSubjectAltName) 而不是 SecCertificateCopyDNSNames：
/// 后者要 macOS 15 才有，本项目部署目标是 13.0。
static inline BOOL RDTLSTrustHostCoveredByCertificate(SecTrustRef _Nullable trust, NSString *_Nullable host) {
    if (!trust || !host.length) return NO;
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (!chain) return NO;
    NSArray *certs = (__bridge_transfer NSArray *)chain;
    if (certs.count < 1) return NO;
    SecCertificateRef leaf = (__bridge SecCertificateRef)certs[0];
    if (!leaf) return NO;

    NSArray *oidList = @[(__bridge_transfer id)kSecOIDSubjectAltName];
    CFDictionaryRef rawValues = SecCertificateCopyValues(leaf, (__bridge CFArrayRef)oidList, NULL);
    if (!rawValues) return NO;
    NSDictionary *values = (__bridge_transfer NSDictionary *)rawValues;
    NSDictionary *san = values[(__bridge NSString *)kSecOIDSubjectAltName];
    if (![san isKindOfClass:[NSDictionary class]]) return NO;
    NSArray *entries = san[(__bridge NSString *)kSecPropertyKeyValue];
    if (![entries isKindOfClass:[NSArray class]]) return NO;

    NSString *lowerHost = host.lowercaseString;
    for (id entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *item = (NSDictionary *)entry;
        id label = item[(__bridge NSString *)kSecPropertyKeyLabel];
        id value = item[(__bridge NSString *)kSecPropertyKeyValue];
        // 只认 DNS 名条目：label 是 kSecPropertyTypeDNSName 里的 "DNS Name"
        // （也接受裸字符串形态，兼容不同系统版本的呈现差异）。
        NSString *name = nil;
        if ([value isKindOfClass:[NSString class]]) {
            NSString *text = (NSString *)value;
            if ([label isKindOfClass:[NSString class]] && [((NSString *)label) containsString:@"DNS"]) name = text;
            else if ([text containsString:@"."] || [text containsString:@"*"]) name = text;
        }
        if (!name.length) continue;
        NSString *pattern = name.lowercaseString;
        if (![pattern containsString:@"*"]) {
            if ([pattern isEqualToString:lowerHost]) return YES;
            continue;
        }
        // 通配只允许覆盖第一个点之前的那一段（RFC 6125 的常见收敛做法）：
        // *.hanime2.org 匹配 www.hanime2.org，不匹配 a.b.hanime2.org。
        NSString *suffix = [pattern substringFromIndex:1];   // ".hanime2.org"
        if ([lowerHost hasSuffix:suffix]) {
            NSString *prefix = [lowerHost substringToIndex:lowerHost.length - suffix.length];
            if (prefix.length > 0 && ![prefix containsString:@"."]) return YES;
        }
    }
    return NO;
}

/// 统一评估：给 NSURLSession 的挑战处理用。返回结论并（放行时）填充理由。
/// 调用方在 RDTLSTrustVerdictUseDefault 时应当走 `PerformDefaultHandling`，
/// 在 AcceptRevoked 时用 `credentialForTrust:` 放行，在 Reject 时取消挑战。
static inline RDTLSTrustVerdict RDTLSEvaluateServerTrust(SecTrustRef _Nullable trust,
                                                         NSString *_Nullable host,
                                                         NSString *_Nullable *_Nullable reason) {
    if (!trust) return RDTLSTrustVerdictReject;
    CFErrorRef cfError = NULL;
    if (SecTrustEvaluateWithError(trust, &cfError)) {
        return RDTLSTrustVerdictUseDefault;   // 系统信任：什么都不改
    }
    NSString *failure = cfError ? [(__bridge NSError *)cfError localizedDescription] : nil;
    if (!RDTLSAllowRevokedCertificateEnabled()) {
        if (reason) *reason = [NSString stringWithFormat:@"严格模式：%@", failure ?: @"证书不受信任"];
        return RDTLSTrustVerdictReject;
    }
    NSString *why = nil;
    if (!RDTLSTrustRevocationIsOnlyFailure(trust, &why)) {
        if (reason) *reason = failure ?: @"证书不受信任（非吊销类失败）";
        return RDTLSTrustVerdictReject;
    }
    // 吊销是唯一失败项：再手工复核 SAN，避免「吊销的证书恰好也不是这个域名」。
    if (!RDTLSTrustHostCoveredByCertificate(trust, host)) {
        if (reason) *reason = [NSString stringWithFormat:@"%@，且证书 SAN 未涵盖 %@", why, host ?: @"(未知主机)"];
        return RDTLSTrustVerdictReject;
    }
    if (reason) *reason = [NSString stringWithFormat:@"%@（域名匹配已复核，按容错放行）", why];
    return RDTLSTrustVerdictAcceptRevoked;
}

/// 挑战处理一键封装。返回 YES 表示已接管（调用方不要再调用默认处理），
/// 返回 NO 表示调用方应走 `NSURLSessionAuthChallengePerformDefaultHandling`。
/// logComponent 为空时不写日志。
static inline BOOL RDTLSHandleServerTrustChallenge(NSURLAuthenticationChallenge *_Nullable challenge,
                                                   NSString *_Nullable logComponent,
                                                   void (^_Nullable completionHandler)(NSURLSessionAuthChallengeDisposition, NSURLCredential *_Nullable)) {
    if (!challenge || !completionHandler) return NO;
    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) return NO;
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (!trust) return NO;
    NSString *host = challenge.protectionSpace.host;
    NSString *reason = nil;
    RDTLSTrustVerdict verdict = RDTLSEvaluateServerTrust(trust, host, &reason);
    switch (verdict) {
        case RDTLSTrustVerdictUseDefault:
            return NO;   // 交回系统默认处理
        case RDTLSTrustVerdictAcceptRevoked: {
            if (logComponent.length) {
                NSLog(@"[%@] TLS 吊销容错放行 host=%@ 依据=%@", logComponent, host ?: @"-", reason ?: @"-");
            }
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return YES;
        }
        case RDTLSTrustVerdictReject:
        default: {
            if (logComponent.length) {
                NSLog(@"[%@] TLS 拒绝 host=%@ 原因=%@", logComponent, host ?: @"-", reason ?: @"-");
            }
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return YES;
        }
    }
}

NS_ASSUME_NONNULL_END

#endif /* RD_TLS_TRUST_H */
