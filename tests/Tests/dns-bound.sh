#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/build/dns-bound-tests"

# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -O1 -framework Foundation -framework AppKit \
  -I"$REPO/src/Shared/Infrastructure" \
  "$REPO/tests/Tests/DNSBoundRegressionTests.m" "$REPO/src/Shared/Infrastructure/DNSResolver.m" "$REPO/src/Shared/Infrastructure/RDLog.m" \
  -o "$OUT/DNSBoundRegressionTests" > "$OUT/compile.log" 2>&1
"$OUT/DNSBoundRegressionTests"
