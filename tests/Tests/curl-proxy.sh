#!/bin/bash
# curl-proxy.sh — 系统代理 → curl 参数：纯函数单测 + 生产路径 argv 捕获（2026-10-05 第 21 轮）
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/build/curl-proxy-tests"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"
SRC=("$REPO/tests/Tests/CurlProxyArgsTests.m" "$REPO/src/Shared/Infrastructure/RDCurlHopper.m")
for f in DNSResolver RDLog IPAddressPolicy HTTPPrivacyPolicy; do SRC+=("$REPO/src/Shared/Infrastructure/$f.m"); done
SRC+=("$REPO/src/Features/ResourceDetector/URLPolicy.m")
xcrun clang -fobjc-arc -O1 -framework Foundation -framework AppKit \
  -I"$REPO/src/Shared/Infrastructure" -I"$REPO/src/Features/ResourceDetector" \
  "${SRC[@]}" -o "$OUT/CurlProxyArgsTests" > "$OUT/compile.log" 2>&1
if grep -q "error:" "$OUT/compile.log"; then cat "$OUT/compile.log"; exit 1; fi
"$OUT/CurlProxyArgsTests"
