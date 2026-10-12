#!/bin/bash
# tls-trust.sh — 证书信任容错专项（第 36 轮）
# 纯逻辑：判据收敛（只认 leaf 唯一失败项 = REVOKED）+ 开关语义 + 挑战接管契约。
# 无网络、无窗口、无 NSApplication。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/tls-trust-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产头（含 RDTLSTrust.h），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Foundation -framework Security \
  -I"$ROOT/Shared/Infrastructure" \
  "$REPO/tests/Tests/TLSTrustTests.m" \
  -o "$OUT/TLSTrustTests" > "$OUT/compile.log" 2>&1
if grep -E "error:|warning:" "$OUT/compile.log" >/dev/null; then
  cat "$OUT/compile.log"; echo "FAIL: TLSTrustTests 编译失败"; exit 1
fi

"$OUT/TLSTrustTests"
echo "PASS: TLS 容错专项通过"
