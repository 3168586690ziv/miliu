#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$REPO/src"; OUT="$REPO/build/external-script-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
SRC=("$REPO/tests/Tests/ExternalScriptTests.m")
for f in StaticHTMLDiscoveryPageProbe RDHybridPageProbe ProductionDiscoveryHTMLProvider ResourceURLGate ResourceDiscoveryCoordinator MultiPageResourceProbe MultiPageProbeResult SubpageLinkExtractor RDResourceModeFilter DetectedMedia RDQualityTier RDResourceDisplayMetadata WebProbe URLPolicy; do SRC+=("$ROOT/Features/ResourceDetector/$f.m"); done
if [ -f "$ROOT/Features/ResourceDetector/RDStaticScriptAnalyzer.m" ]; then SRC+=("$ROOT/Features/ResourceDetector/RDStaticScriptAnalyzer.m"); fi
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient RDLog; do SRC+=("$ROOT/Shared/Infrastructure/$f.m"); done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 -framework Cocoa -framework WebKit -framework AVFoundation \
 -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
 "${SRC[@]}" -o "$OUT/ExternalScriptTests" > "$OUT/compile.log" 2>&1
"$OUT/ExternalScriptTests"
