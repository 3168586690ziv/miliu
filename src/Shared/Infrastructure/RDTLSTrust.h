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
//    4. 放行必须显式开启（偏好键 SevenZZKeyAllowRevokedCertificate，默认关），
//       未配置或关闭均使用系统严格信任。
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

/// 容错开关的偏好键。缺省严格；只有显式开启才允许既有窄容错。
static NSString * const RDTLSAllowRevokedCertificateKey = @"SevenZZKeyAllowRevokedCertificate";

/// 评估结论。
typedef NS_ENUM(NSInteger, RDTLSTrustVerdict) {
    RDTLSTrustVerdictUseDefault = 0,  ///< 系统信任：走默认处理，不接管
    RDTLSTrustVerdictAcceptRevoked,   ///< 仅因「证书被吊销」放行（容错生效）
    RDTLSTrustVerdictReject,          ///< 拒绝（含容错关闭、非吊销类失败）
};

/// 隔离配置入口：仅明确真值开启；缺失、畸形值均严格拒绝容错。
/// NSNumber 1 与常用偏好字符串 YES/true/1 兼容；不把任意非零数字当许可。
static inline BOOL RDTLSAllowRevokedCertificateForValue(id _Nullable value) {
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue] == 1.0;
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = [value lowercaseString];
        return [@[@"yes", @"true", @"1"] containsObject:text];
    }
    return NO;
}

/// 真实调用仍读现有偏好键，但不写偏好；测试直接注入值或替换读取边界。
static inline BOOL RDTLSAllowRevokedCertificateEnabled(void) {
    return RDTLSAllowRevokedCertificateForValue([[NSUserDefaults standardUserDefaults] objectForKey:RDTLSAllowRevokedCertificateKey]);
}

/// 从系统错误里取出「出错的是链上第几张证书」。
///
/// **为什么必须用它**（2026-10-12 复核实测，P0）：`SecTrustCopyProperties` 的
/// 错误**归属不可靠**——本机用本地 OCSP 注入「中间证书被吊销 + leaf 完全合法」
/// 的链时，它同样把 error 放在数组第 0 项、`title` 写的却是 **leaf** 的名字，
/// 于是只看 props 会把「中间 CA 被吊销」误判成「leaf 被吊销」并放行（3/3 复现）。
/// 可靠的索引只出现在错误的 underlying 描述里，形如
/// `Certificate 1 "Review Intermediate" has errors: …`；真实站点 hanime2.org
/// 那轮则是 `Certificate 0 "hanime2.org" has errors: …`。
///
/// 取不到索引时返回 NSNotFound，调用方必须**保守拒绝**——错误格式变化绝不能
/// 变成放行（fail-closed）。
/// 与语言无关地取出「出错证书序号」：扫第一个「数字串 + 可选空白 + 引号名称」形态。
///
/// 为什么需要它（2026-10-13 真机 P0，本机复现）：系统错误文案**随进程本地化**。同一个
/// 「leaf 被吊销」，在 `CFBundleDevelopmentRegion=zh_CN` 的 .app 里是
/// `证书0“hanime2.org”有错误：证书已撤销;`，英文锚点 `Certificate ` 根本不存在
/// ⇒ 索引取不到 ⇒ fail-closed 拒绝 ⇒ 静态腿（探测主链最先发请求的那条腿）整条失败，
/// 用户看到的是一句 TLS 报错、0 个资源。而**所有测试套件都是无 bundle 的裸二进制**
/// （开发区域默认 en），所以 38 套件全绿也照不出这个缺陷。
///
/// 两种语言的共同结构是「序号紧跟在引号包裹的证书名之前」：
///   英文 `Certificate 0 “hanime2.org” has errors: …`
///   中文 `证书0“hanime2.org”有错误：…`
/// 中间证书出错时同理（`Certificate 1 "Review Intermediate"`），所以这条锚点仍能区分
/// leaf 与中间证书，判据未被放宽。取不到一律 NSNotFound（fail-closed）。
static NSUInteger RDTLSCertificateIndexBeforeQuotedName(NSString *_Nullable text) {
    if (!text.length) return NSNotFound;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') continue;
        NSUInteger j = i;
        NSUInteger value = 0;
        BOOL overflow = NO;
        while (j < text.length) {
            unichar d = [text characterAtIndex:j];
            if (d < '0' || d > '9') break;
            value = value * 10u + (NSUInteger)(d - '0');
            if (value > 256) { overflow = YES; break; }
            j++;
        }
        if (overflow) return NSNotFound;
        NSUInteger k = j;
        while (k < text.length) {                    // 半角 / 制表 / 全角空格
            unichar s = [text characterAtIndex:k];
            if (s == ' ' || s == '\t' || s == 0x3000) { k++; continue; }
            break;
        }
        if (k < text.length) {
            unichar q = [text characterAtIndex:k];
            // “ ” " ' ‘ ’ 六种引号形态；证书名在两种语言里都被引号包着。
            if (q == 0x201C || q == 0x201D || q == 0x0022 ||
                q == 0x0027 || q == 0x2018 || q == 0x2019) {
                return value;
            }
        }
        i = j;   // 跳过整串数字，避免逐字符重扫
    }
    return NSNotFound;
}

static NSUInteger RDTLSFailingCertificateIndexFromError(NSError *_Nullable error) {
    if (!error) return NSNotFound;
    NSString *text = error.localizedDescription ?: @"";
    id underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]]) {
        NSString *d = ((NSError *)underlying).localizedDescription;
        if (d.length) text = d;
    }
    // 锚点 1：英文 `Certificate N`（历史行为逐字保留，英文环境结论零变化）。
    NSRange anchor = [text rangeOfString:@"Certificate "];
    if (anchor.location != NSNotFound) {
        NSUInteger i = anchor.location + anchor.length;
        NSUInteger value = 0;
        BOOL any = NO;
        while (i < text.length) {
            unichar c = [text characterAtIndex:i];
            if (c < '0' || c > '9') break;
            value = value * 10u + (NSUInteger)(c - '0');
            any = YES;
            if (value > 256) return NSNotFound;
            i++;
        }
        return any ? value : NSNotFound;
    }
    // 锚点 2：与语言无关的「数字 + 引号名称」形态（本地化环境）。取不到仍 fail-closed。
    return RDTLSCertificateIndexBeforeQuotedName(text);
}

/// 证书是否被吊销：判据是「**链上只有一处 error、该 error 是吊销、且出错的就是 leaf**」。
///
/// 用 `SecTrustCopyProperties` 读「每个证书有无 error」，但它的**错误归属不可靠**
/// （见上），因此「出错的是哪一张」另从 `trustError` 的 underlying 描述取，两者都要过。
///
/// 理想形态（真实站点实测）：
///   ( { error = "CSSMERR_TP_CERT_REVOKED"; title = "hanime2.org"; },
///     { title = YE1; }, { title = "Root YE"; }, { title = "ISRG Root X2"; } )
/// 即：只有 leaf 带 error，链上其余（中间证书、根、锚）全部无 error
/// ⇒ 域名/有效期/信任锚/基本约束/签名全部通过，**唯一**的失败项是吊销。
///
/// 判据的**纯逻辑部分**（测试可直接调用，不需要真实 SecTrust）：
/// `props` = `SecTrustCopyProperties` 的输出；`failingIndex` = 系统错误里给出的
/// 出错证书索引（NSNotFound 表示取不到）。返回 YES 当且仅当：
///   ① 整条链上**只有一处** error；
///   ② 该 error 是吊销（REVOKED）；
///   ③ 出错的就是链上第 0 张（leaf）—— 索引取不到时**拒绝**（fail-closed）。
///
/// 抽成独立函数是 2026-10-12 复核的整改：原先测试里复制了一份「等价内联版本」，
/// 于是删掉生产判据的关键段落后套件仍 12/12 全绿（实测复现）——8/12 条断言
/// 实际没有守卫作用。现在测试直接调本函数，改动生产逻辑必须让测试变红。
static inline BOOL RDTLSTrustRevocationPropsIndicateLeafOnly(NSArray *_Nullable props,
                                                             NSUInteger failingIndex,
                                                             NSString *_Nullable *_Nullable why) {
    if (![props isKindOfClass:[NSArray class]] || props.count == 0) return NO;
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
    // 出错证书必须**就是 leaf**。不能用 props[0] 判断——它的归属不可靠
    // （中间证书被吊销时同样落在第 0 项、title 仍是 leaf 的名字），必须看
    // 错误给出的索引；索引取不到同样拒绝（fail-closed）。
    if (failingIndex != 0) {
        if (why) *why = [NSString stringWithFormat:@"%@，但出错证书索引=%@（不是 leaf，拒绝）",
                         soleError, (failingIndex == NSNotFound ? @"未知" : @(failingIndex).stringValue)];
        return NO;
    }
    if (why) *why = [NSString stringWithFormat:@"证书已吊销（%@，链上其余证书无任何失败项）", soleError];
    return YES;
}

/// 证书是否被吊销、且唯一失败项落在 leaf（真实 SecTrust 入口）。
/// 任一条件不满足即返回 NO——宁可保守拒绝，也不把其他失败形态一并放松。
static inline BOOL RDTLSTrustRevocationIsOnlyFailure(SecTrustRef _Nullable trust,
                                                     NSError *_Nullable trustError,
                                                     NSString *_Nullable *_Nullable why) {
    if (!trust) return NO;
    // SecTrustCopyProperties 自 macOS 12 起标为弃用，但官方替代品
    // SecTrustCopyResult 的 TrustResultDetails 形态完全不同（每个元素是
    // 「错误码字符串 → 详情数组」的字典，key 即错误码），拿不到「哪一张证书
    // 带哪个 error」这一层信息，而本判据恰好只需要这一层。
    // 因此保留本调用，并把弃用警告在最小范围内显式收敛。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFArrayRef rawProps = SecTrustCopyProperties(trust);
#pragma clang diagnostic pop
    if (!rawProps) return NO;
    NSArray *props = (__bridge_transfer NSArray *)rawProps;
    return RDTLSTrustRevocationPropsIndicateLeafOnly(props,
                                                     RDTLSFailingCertificateIndexFromError(trustError),
                                                     why);
}

/// SAN 条目是否涵盖 host（**纯逻辑**，测试可直接注入 entries，无需真实证书）。
/// entries = `SecCertificateCopyValues(kSecOIDSubjectAltName)` 的 `kSecPropertyKeyValue`。
///
/// 只认 **DNS Name** 条目（2026-10-12 复核修复，P0）：原实现用 `containsString:@"DNS"`
/// 判 label，并对「值含点」的条目开了一条「兼容不同系统版本」的回退分支 —— 实测该
/// 回退会把 `Email Address`（值为 victim.example）与 otherName（label 是 OID 如
/// 1.2.3.4、值为 other.example）**当成 DNS 名**，于是「证书并不覆盖该 host」的结论
/// 被翻转。端到端 PoC：一张 SAN=email:victim.example 的证书，在系统明确判
/// name-does-not-match 的情况下，仅因它同时被吊销，本层即放行。
/// 现在只接受 label 严格等于 "DNS Name" 的条目；不匹配即跳过，无回退。
static inline BOOL RDTLSTrustSANEntriesCoverHost(NSArray *_Nullable entries, NSString *_Nullable host) {
    if (![entries isKindOfClass:[NSArray class]] || !host.length) return NO;
    NSString *lowerHost = host.lowercaseString;
    for (id entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *item = (NSDictionary *)entry;
        id label = item[(__bridge NSString *)kSecPropertyKeyLabel];
        id value = item[(__bridge NSString *)kSecPropertyKeyValue];
        NSString *name = nil;
        if ([value isKindOfClass:[NSString class]] &&
            [label isKindOfClass:[NSString class]] &&
            [(NSString *)label isEqualToString:@"DNS Name"]) {
            name = (NSString *)value;
        }
        if (!name.length) continue;
        NSString *pattern = name.lowercaseString;
        NSRange star = [pattern rangeOfString:@"*"];
        if (star.location == NSNotFound) {
            if ([pattern isEqualToString:lowerHost]) return YES;
            continue;
        }
        // 通配形态收敛（2026-10-12 复核修复，P0）：必须严格是 `*.example.com`——
        //   (a) `*` 唯一且位于最左标签；
        //   (b) 其下一个字符必须是 `.`；
        //   (c) 后缀至少两个标签（拒绝 `*.com` 这类跨公共后缀的通配）。
        // 原实现只做 `hasSuffix:`，实测 `*.com` 能匹配 `x.com`、
        // `*foo.example` 能匹配 `barfoo.example`（`*` 后未要求 `.`）。
        // 裸 `*` 也会因 `hasSuffix:@""` 的未文档化行为而处于危险边缘，这里直接拒绝。
        if (star.location != 0) continue;
        if ([pattern rangeOfString:@"*"
                           options:0
                             range:NSMakeRange(1, pattern.length - 1)].location != NSNotFound) continue;
        if (pattern.length < 4) continue;                       // `*.` 之后至少要有两个字符
        if ([pattern characterAtIndex:1] != '.') continue;
        NSString *suffix = [pattern substringFromIndex:1];      // ".example.com"
        NSArray<NSString *> *labels = [suffix componentsSeparatedByString:@"."];
        if (labels.count < 3) continue;                         // ".com" → 1 个有效标签，拒绝
        if ([lowerHost hasSuffix:suffix]) {
            NSString *prefix = [lowerHost substringToIndex:lowerHost.length - suffix.length];
            if (prefix.length > 0 && ![prefix containsString:@"."]) return YES;
        }
    }
    return NO;
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

    return RDTLSTrustSANEntriesCoverHost(entries, host);
}

/// 统一评估：给 NSURLSession 的挑战处理用。返回结论并（放行时）填充理由。
/// 调用方在 RDTLSTrustVerdictUseDefault 时应当走 `PerformDefaultHandling`，
/// 在 AcceptRevoked 时用 `credentialForTrust:` 放行，在 Reject 时取消挑战。
/// 显式配置入口供隔离测试使用，SecTrust/SAN/leaf/index 判据与真实调用共用。
static inline RDTLSTrustVerdict RDTLSEvaluateServerTrustWithRevocationAllowed(SecTrustRef _Nullable trust,
                                                         NSString *_Nullable host,
                                                         BOOL allowRevoked,
                                                         NSString *_Nullable *_Nullable reason) {
    if (!trust) return RDTLSTrustVerdictReject;
    CFErrorRef cfError = NULL;
    if (SecTrustEvaluateWithError(trust, &cfError)) {
        if (cfError) CFRelease(cfError);
        return RDTLSTrustVerdictUseDefault;   // 系统信任：什么都不改
    }
    // 失败原因与「出错的是哪一张证书」都要带上：判据不能只看 CopyProperties
    // 的归属（它会把中间证书的吊销错误写到第 0 项、title 记成 leaf）。
    NSError *trustError = cfError ? (__bridge_transfer NSError *)cfError : nil;
    NSString *failure = trustError.localizedDescription;
    if (!allowRevoked) {
        if (reason) *reason = [NSString stringWithFormat:@"严格模式：%@", failure ?: @"证书不受信任"];
        return RDTLSTrustVerdictReject;
    }
    NSString *why = nil;
    if (!RDTLSTrustRevocationIsOnlyFailure(trust, trustError, &why)) {
        if (reason) *reason = why.length ? why : (failure ?: @"证书不受信任（非吊销类失败）");
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

static inline RDTLSTrustVerdict RDTLSEvaluateServerTrust(SecTrustRef _Nullable trust,
                                                         NSString *_Nullable host,
                                                         NSString *_Nullable *_Nullable reason) {
    return RDTLSEvaluateServerTrustWithRevocationAllowed(trust, host, RDTLSAllowRevokedCertificateEnabled(), reason);
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
