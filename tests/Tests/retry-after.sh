#!/bin/bash
# Retry-After 策略的受控验证（独立入口；不联网、无真实 WebKit 导航、不读 Cookie/凭据）。
#
# 编译单元**直接包含生产源码** src/Features/ResourceDetector/StaticHTMLDiscoveryPageProbe.m，
# 不复制算法、不抽取副本。内核回退用测试替身（经类扩展私有注入点
# rd_mediaResponseProbeFactory，KVC 设置）替代，因此没有任何真实 WebKit 导航；
# 静态腿用 NSURLProtocol 夹具，因此没有任何真实网络。
#
# 独立入口，刻意不并入默认全量套件：需要时显式执行
#   bash tests/Tests/retry-after.sh
#   bash tests/Tests/run-suites.sh retry-after    # 沙箱内串行运行
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$REPO/src"; OUT="$REPO/build/retry-after-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
SRC=("$REPO/tests/Tests/RetryAfterPolicyTests.m")
# RDManualVerification 是必需依赖：StaticHTMLDiscoveryPageProbe / ProductionDiscoveryHTMLProvider
# / WebProbe 都引用 RDManualVerificationController.sharedSessionDataStore，且该类的唯一实现在
# src/Features/ResourceDetector/RDManualVerification.m。
for f in StaticHTMLDiscoveryPageProbe RDManualVerification RDHybridPageProbe \
         ProductionDiscoveryHTMLProvider ResourceURLGate ResourceDiscoveryCoordinator \
         MultiPageResourceProbe MultiPageProbeResult SubpageLinkExtractor \
         RDResourceModeFilter DetectedMedia RDQualityTier RDResourceDisplayMetadata \
         WebProbe URLPolicy; do SRC+=("$ROOT/Features/ResourceDetector/$f.m"); done
if [ -f "$ROOT/Features/ResourceDetector/RDStaticScriptAnalyzer.m" ]; then SRC+=("$ROOT/Features/ResourceDetector/RDStaticScriptAnalyzer.m"); fi
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient RDLog; do SRC+=("$ROOT/Shared/Infrastructure/$f.m"); done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 -framework Cocoa -framework WebKit -framework AVFoundation \
 -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
 "${SRC[@]}" -o "$OUT/RetryAfterPolicyTests" > "$OUT/compile.log" 2>&1
"$OUT/RetryAfterPolicyTests"
