#!/bin/bash
# websocket-scan.sh — 注入脚本「WebSocket 帧媒体地址扫描」真实 WebKit 端到端测试
# （第 44 轮；服务器夹具 fixtures/websocket_scan_server.py）
#
# 媒体地址只出现在 WS 文本帧里，页面 HTML 不含、也从不请求它们 ——
# 探到就只可能来自新增的 WebSocket 帧解析。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/websocket-scan-tests"
mkdir -p "$OUT"
rm -f "$OUT/server.log"
python3 "$REPO/tests/Tests/fixtures/websocket_scan_server.py" > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
PORT=""
for _ in {1..50}; do PORT="$(head -1 "$OUT/server.log")"; [[ "$PORT" =~ ^[0-9]+$ ]] && break; sleep .1; done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "FAIL server did not start"; exit 1; }
BASE="http://127.0.0.1:${PORT}"
export RD_WEBSOCKET_SCAN_HTTP="$BASE"
printf '%s\n' '<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict></dict></plist>' > "$OUT/fixture.plist"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

# 断言前置：页面 HTML 里不含任何媒体 URL（证明探到的一定来自 WS 帧）。
PAGE_HTML="$OUT/page.html"
python3 - "$BASE/" "$PAGE_HTML" <<'PY'
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=10) as r:
    open(sys.argv[2], 'wb').write(r.read())
PY
if grep -qE '(ws_only\.mp4|ws_plain\.webm|filler\.mp4)' "$PAGE_HTML"; then
  echo "FAIL page HTML must not contain any media URL (fixture invariant broken)"
  exit 1
fi
echo "PASS page HTML contains no media URL at all (media exists only in WS frames)"

SRC=("$REPO/tests/Tests/RealWebSocketScanTests.m")
for f in WebProbe RDManualVerification URLPolicy DetectedMedia RDQualityTier RDResourceDisplayMetadata RDStaticScriptAnalyzer; do SRC+=("$ROOT/Features/ResourceDetector/$f.m"); done
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient RDLog; do SRC+=("$ROOT/Shared/Infrastructure/$f.m"); done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -g -O1 -framework Cocoa -framework WebKit -framework AVFoundation -framework Security \
 -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
 -sectcreate __TEXT __info_plist "$OUT/fixture.plist" "${SRC[@]}" -o "$OUT/RealWebSocketScanTests" > "$OUT/compile.log" 2>&1
if grep -q "error:" "$OUT/compile.log"; then cat "$OUT/compile.log"; exit 1; fi
"$OUT/RealWebSocketScanTests"

# 反向证明：帧内地址从未走网络请求路径 —— 服务器日志里这两个路径必须零 GET。
for m in ws_only.mp4 ws_plain.webm filler.mp4; do
  if grep -qE "REQ GET /media/${m}([? ]|$)" "$OUT/server.log"; then
    echo "FAIL /media/${m} was requested over HTTP — WS-only path violated"
    exit 1
  fi
done
echo "PASS server log shows zero GET for /media/ws_only.mp4 and /media/ws_plain.webm (frame-only path)"
