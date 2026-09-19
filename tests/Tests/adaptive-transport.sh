#!/bin/bash
# adaptive-transport.sh — curl 按跳回退传输（元数据 + 下载）离线单元测试
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/adaptive-transport-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
 -framework Foundation -framework AppKit \
 -I"$ROOT/App" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Features/ResourceDownload" \
 "$REPO/tests/Tests/AdaptiveTransportTests.m" \
 "$ROOT/App/RDAdaptiveTransport.m" "$ROOT/App/RDCurlFallbackBackend.m" \
 "$ROOT/Shared/Infrastructure/RDCurlHopper.m" "$ROOT/Shared/Infrastructure/RDLog.m" \
 "$ROOT/Shared/Infrastructure/DNSResolver.m" "$ROOT/Shared/Infrastructure/HTTPPrivacyPolicy.m" \
 "$ROOT/Shared/Infrastructure/IPAddressPolicy.m" \
 "$ROOT/Features/ResourceDetector/URLPolicy.m" "$ROOT/Features/ResourceDetector/RDMetadataTransport.m" \
 -o "$OUT/AdaptiveTransportTests" > "$OUT/compile.log" 2>&1
if grep -E "error:" "$OUT/compile.log" >/dev/null; then cat "$OUT/compile.log"; exit 1; fi
BAD=$(grep -E "warning:" "$OUT/compile.log" | grep -v "nullability" | grep -v "arc-retain-cycles" || true)
if [ -n "$BAD" ]; then printf '%s\n' "$BAD"; echo "FAIL: 新增编译警告"; exit 1; fi
ASAN_OPTIONS=detect_leaks=0 "$OUT/AdaptiveTransportTests"
printf 'PASS: adaptive-transport tests exited 0\n'
