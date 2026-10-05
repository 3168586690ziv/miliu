#!/bin/bash
# cookie-import.sh — 浏览器 Cookie 导入纯函数测试（2026-10-05 第 25 轮；不碰真实浏览器数据与钥匙串）
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/build/cookie-import-tests"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"
SRC=("$REPO/tests/Tests/CookieImportTests.m" "$REPO/src/Features/ResourceDetector/RDBrowserCookieImporter.m")
for f in RDManualVerification URLPolicy DetectedMedia RDQualityTier RDResourceDisplayMetadata WebProbe; do SRC+=("$REPO/src/Features/ResourceDetector/$f.m"); done
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient RDLog; do SRC+=("$REPO/src/Shared/Infrastructure/$f.m"); done
SRC+=("$REPO/src/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -O1 -framework Foundation -framework AppKit -framework WebKit -framework Security -lsqlite3 \
  -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src/Shared/Infrastructure" -I"$REPO/src/Shared/Infrastructure/Async" \
  "${SRC[@]}" -o "$OUT/CookieImportTests" > "$OUT/compile.log" 2>&1
if grep -q "error:" "$OUT/compile.log"; then cat "$OUT/compile.log"; exit 1; fi
"$OUT/CookieImportTests"
