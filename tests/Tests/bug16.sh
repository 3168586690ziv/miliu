#!/bin/bash
# Focused headless executable only; no app build, version generation or installation.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$REPO/src"
OUT="$REPO/build/bug16-tests"

# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"
SRC=("$REPO/tests/Tests/Bug16RegressionTests.m")
for f in ResourceDiscoveryCoordinator MultiPageResourceProbe MultiPageProbeResult SubpageLinkExtractor RDResourceModeFilter DetectedMedia RDQualityTier RDResourceDisplayMetadata WebProbe RDManualVerification URLPolicy ResourceDetectorViewModel; do
  SRC+=("$ROOT/Features/ResourceDetector/$f.m")
done
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient RDLog; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation \
  -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
  "${SRC[@]}" -o "$OUT/Bug16RegressionTests" > "$OUT/compile.log" 2>&1
"$OUT/Bug16RegressionTests"
