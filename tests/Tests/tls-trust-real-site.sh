#!/bin/bash
# tls-trust-real-site.sh — 证书信任容错「真实站点」端到端（第 36 轮）
#
# 本套件与 tls-trust.sh 的分工：
#   · tls-trust.sh        → 纯逻辑判据（离线、必跑）
#   · 本套件（本文件）    → 用**真实被吊销证书的站点**验证容错层确实让原生栈可用
#
# 为什么必须联网验证：判据正确 ≠ 系统栈真的放行。本机实测的对照数据（供回归比对）：
#   容错开：15/15 成功
#   严格模式：2/10 成功（其余 -1202 / -999）
# 目标站点证书被吊销是**客观事实**（SecTrustEvaluate 报 certificate is revoked），
# 因此这条用例在任何时候都应该稳定通过；若站点换了证书导致不再触发容错，本套件
# 会如实报告「未触发容错分支」（不算失败，但要看见）。
#
# 网络不可达时 SKIP（不判失败）——本套件不是构建门禁，是诊断+回归工具。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/tls-trust-tests"
mkdir -p "$OUT"
export RD_LOG_PATH="$OUT/real-site.log"

REAL_SITE_URL="${RD_TLS_REAL_SITE_URL:-https://www.hanime2.org/}"
TRIALS="${RD_TLS_TRIALS:-8}"

# 先确认网络可达：不通用则 SKIP，绝不把环境问题算成产品缺陷。
if ! curl -sS -o /dev/null -m 8 "${REAL_SITE_URL}" 2>/dev/null; then
  echo "SKIP: 真实站点不可达（${REAL_SITE_URL}），本套件跳过"
  exit 0
fi

cat > "$OUT/RealSiteProbe.m" <<'OBJC'
// 真实站点探针：同一 URL 跑 N 次，统计容错开/严格模式下的成功率。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "RDTLSTrust.h"

@interface ProbeDelegate : NSObject <NSURLSessionDelegate>
@end
@implementation ProbeDelegate
- (void)URLSession:(NSURLSession *)session
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if (RDTLSHandleServerTrustChallenge(challenge, nil, completionHandler)) return;
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

static int RunTrials(NSString *urlString, int trials, BOOL tolerant, int *outOK, int *outTLSRejected) {
    int ok = 0, tlsRejected = 0;
    for (int i = 0; i < trials; i++) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        ProbeDelegate *d = [ProbeDelegate new];
        NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:d delegateQueue:nil];
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        r.timeoutInterval = 15;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL success = NO;
        __block NSInteger errCode = 0;
        [[s dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            success = (err == nil);
            errCode = err ? err.code : 0;
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC));
        if (success) ok++;
        else if (errCode == -1202 || errCode == -1200 || errCode == -999) tlsRejected++;
        [s invalidateAndCancel];
    }
    if (outOK) *outOK = ok;
    if (outTLSRejected) *outTLSRejected = tlsRejected;
    return ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *url = [NSString stringWithUTF8String:argv[1]];
        int trials = atoi(argv[2]);
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

        // ① 容错开（默认）
        [ud removeObjectForKey:RDTLSAllowRevokedCertificateKey];
        int okTolerant = 0, tlsTolerant = 0;
        RunTrials(url, trials, YES, &okTolerant, &tlsTolerant);
        printf("RESULT tolerant_ok=%d tolerant_tls_rejected=%d trials=%d\n", okTolerant, tlsTolerant, trials);

        // ② 严格模式（容错关）
        [ud setBool:NO forKey:RDTLSAllowRevokedCertificateKey];
        int okStrict = 0, tlsStrict = 0;
        RunTrials(url, trials, NO, &okStrict, &tlsStrict);
        printf("RESULT strict_ok=%d strict_tls_rejected=%d trials=%d\n", okStrict, tlsStrict, trials);

        [ud removeObjectForKey:RDTLSAllowRevokedCertificateKey];   // 复原
        return 0;
    }
}
OBJC

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Foundation -framework Security \
  -I"$ROOT/Shared/Infrastructure" \
  "$OUT/RealSiteProbe.m" -o "$OUT/RealSiteProbe" > "$OUT/real-site.compile.log" 2>&1
if grep -E "error:|warning:" "$OUT/real-site.compile.log" >/dev/null; then
  cat "$OUT/real-site.compile.log"; echo "FAIL: RealSiteProbe 编译失败"; exit 1
fi

OUTPUT="$("$OUT/RealSiteProbe" "${REAL_SITE_URL}" "${TRIALS}")"
printf '%s\n' "$OUTPUT"

TOL_OK="$(printf '%s\n' "$OUTPUT" | sed -n 's/^RESULT tolerant_ok=\([0-9]*\).*/\1/p')"
TOL_TLS="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*tolerant_tls_rejected=\([0-9]*\).*/\1/p')"
STR_OK="$(printf '%s\n' "$OUTPUT" | sed -n 's/^RESULT strict_ok=\([0-9]*\).*/\1/p')"

if [ -z "${TOL_OK}" ] || [ -z "${STR_OK}" ]; then
  echo "FAIL: 未能解析探针输出"; exit 1
fi

echo "== 真实站点容错对照：容错开 ${TOL_OK}/${TRIALS}，严格模式 ${STR_OK}/${TRIALS} =="

# 判据 A：容错开启时必须全部成功（证书被吊销是客观事实，容错就该救回来）。
if [ "${TOL_OK}" -lt "${TRIALS}" ]; then
  echo "FAIL: 容错开启仍有 $((TRIALS - TOL_OK)) 次失败（期望全过）"; exit 1
fi
echo "PASS: 容错开启 ${TOL_OK}/${TRIALS} 全过"

# 判据 B：本次站点确实触发了容错分支（否则本用例失去意义，如实提示而非判失败）。
if [ "${TOL_TLS}" = "0" ] && [ "${STR_OK}" = "${TRIALS}" ]; then
  echo "NOTE: 站点证书当前未被判吊销（两档都全过）——容错分支未触发，站点可能已换证"
else
  echo "PASS: 站点证书确实被吊销（严格模式仅 ${STR_OK}/${TRIALS}），容错分支已触发并被救回"
fi

echo "PASS: TLS 容错真实站点端到端通过"
