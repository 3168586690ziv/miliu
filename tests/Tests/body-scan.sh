#!/bin/bash
# body-scan.sh — 注入脚本「接口响应体媒体链接扫描」真实 WebKit 端到端测试
# （2026-10-05 第 21 轮；服务器夹具 fixtures/body_scan_server.py）
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/body-scan-tests"
mkdir -p "$OUT"
python3 "$REPO/tests/Tests/fixtures/body_scan_server.py" > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
PORT=""
for _ in {1..50}; do PORT="$(head -1 "$OUT/server.log")"; [[ "$PORT" =~ ^[0-9]+$ ]] && break; sleep .1; done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "FAIL server did not start"; exit 1; }
export RD_BODYSCAN_HTTP="http://127.0.0.1:${PORT}"
printf '%s\n' '<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict></dict></plist>' > "$OUT/fixture.plist"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
SRC=("$REPO/tests/Tests/RealBodyScanTests.m")
for f in WebProbe RDManualVerification URLPolicy DetectedMedia RDQualityTier RDResourceDisplayMetadata; do SRC+=("$ROOT/Features/ResourceDetector/$f.m"); done
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient RDLog; do SRC+=("$ROOT/Shared/Infrastructure/$f.m"); done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -g -O1 -framework Cocoa -framework WebKit -framework AVFoundation -framework Security \
 -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
 -sectcreate __TEXT __info_plist "$OUT/fixture.plist" "${SRC[@]}" -o "$OUT/RealBodyScanTests" > "$OUT/compile.log" 2>&1
if grep -q "error:" "$OUT/compile.log"; then cat "$OUT/compile.log"; exit 1; fi
"$OUT/RealBodyScanTests"
