#!/bin/bash
# 下载完整性隔离测试（143 字节事故回归）。用法：
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
#   Tests/download-integrity.sh --asan   # 附加 AddressSanitizer
OUT="$BUILD/download-integrity-tests"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
ASAN=0
case "${1:-}" in --asan) ASAN=1 ;; esac
printf '下载完整性隔离测试: %s (ASan=%s)\n' "$(date -u)" "$ASAN"

# 日志隔离：本测试编译并驱动生产 DownloadManager，它的 RDLog 调用若写默认路径
# 会把 zz-dl-tests/zz-downloads 噪声灌进用户真实日志（历史日志里曾占 6 万余行）。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
: > "$RD_LOG_PATH"

# 本地隔离 HTTP 服务器：仅 127.0.0.1，不触外网
python3 "$REPO/tests/Tests/fixtures/download_test_server.py" >"$OUT/server.log" 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT
PORT=""
for _ in $(seq 1 50); do
  # || true：server.log 尚未写入时 head/管道会失败，不能让严格模式跳过
  # 下面的“服务器未能启动”报告路径（该路径自己会以非零退出）。
  PORT=$(head -n1 "$OUT/server.log" 2>/dev/null | tr -dc '0-9') || true
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
  # 端口未取到，或服务器进程已退出（如 python3 启动失败——其报错文本里的
  # 数字会被上面的提取误当成端口，必须以进程存活为准）。
  echo "FAIL: 本地测试服务器未能启动"
  cat "$OUT/server.log" || true
  exit 1
fi
export ZZ_DL_TEST_SERVER="http://127.0.0.1:$PORT"
echo "本地隔离服务器: $ZZ_DL_TEST_SERVER"

# 内嵌 Info.plist：允许本测试进程访问 http（生产 APP 不受影响）
cat > "$OUT/tests-info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict></dict></plist>
PLIST

# 同一份生产源码 + 测试主程序（测试 main 是唯一入口，不引入 GUI）
SRC=(
  "$REPO/tests/Tests/DownloadIntegrityTests.m"
  "$ROOT/Features/ResourceDownload/DownloadManager.m"
  "$ROOT/Features/ResourceDownload/RDStreamDownloadTask.m"
  "$ROOT/Features/ResourceDownload/RDStreamPlan.m"
  "$ROOT/Features/ResourceDetector/RDManifestParser.m"
  "$ROOT/Features/ResourceDownload/DownloadJob.m"
  "$ROOT/Features/ResourceDownload/DownloadStore.m"
  "$ROOT/Features/ResourceDownload/DownloadCapabilityProbe.m"
  "$ROOT/Features/ResourceDownload/DownloadLinkRefresher.m"
  "$ROOT/Features/ResourceDownload/AdaptiveTransferScheduler.m"
  "$ROOT/Features/ResourceDetector/URLPolicy.m"
  "$ROOT/Features/ResourceDetector/DetectedMedia.m"
  "$ROOT/Shared/Infrastructure/DNSResolver.m"
  "$ROOT/Shared/Infrastructure/HTTPPrivacyPolicy.m"
  "$ROOT/Shared/Infrastructure/IPAddressPolicy.m"
  "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
  "$ROOT/Shared/Infrastructure/RDLog.m"
)
INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" \
           "$ROOT/Shared" "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" \
           "$ROOT/Shared/Infrastructure/Performance" "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem"; do
  INCLUDES+=("-I$dir")
done
# RDLog.m 使用 NSWorkspace（打开日志/诊断包），因此需要 AppKit
FLAGS=(-fobjc-arc -g -O1 -mmacosx-version-min=13.0 -framework Foundation -framework Security -framework AppKit)
if [ "$ASAN" = "1" ]; then FLAGS+=(-fsanitize=address); fi

if ! xcrun clang "${FLAGS[@]}" "${INCLUDES[@]}" \
      -sectcreate __TEXT __info_plist "$OUT/tests-info.plist" \
      "${SRC[@]}" -o "$OUT/DownloadIntegrityTests" 2>"$OUT/compile.log"; then
  echo "FAIL: 编译失败"
  cat "$OUT/compile.log"
  exit 1
fi

"$OUT/DownloadIntegrityTests"
echo "PASS: 下载完整性隔离测试全部通过"
