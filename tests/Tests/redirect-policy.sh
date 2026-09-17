#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/redirect-policy-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
xcrun clang -fobjc-arc -g -O1 -framework Foundation -framework AppKit \
 -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Features/ResourceDownload" \
 "$REPO/tests/Tests/RedirectPolicyTests.m" "$ROOT/Shared/Infrastructure/HTTPPrivacyPolicy.m" \
 "$ROOT/Shared/Infrastructure/DNSResolver.m" "$ROOT/Shared/Infrastructure/RDLog.m" "$ROOT/Shared/Infrastructure/IPAddressPolicy.m" \
 "$ROOT/Features/ResourceDetector/URLPolicy.m" "$ROOT/Features/ResourceDetector/RDMetadataTransport.m" \
 "$ROOT/Features/ResourceDownload/DownloadCapabilityProbe.m" -o "$OUT/RedirectPolicyTests" > "$OUT/compile.log" 2>&1
"$OUT/RedirectPolicyTests"
