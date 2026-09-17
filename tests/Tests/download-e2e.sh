#!/bin/bash
# download-e2e.sh — 受控本地下载的行级验收（确定性、约 20 秒）：
#   DownloadE2ETests.m：真实字节流下进度条/指标文字/状态的连续更新、暂停↔恢复往返、
#   didUpdateJob 回调持续性、刷新合并、终态满格。
# 全程只访问 127.0.0.1；使用独立 tempRoot 与独立 UserDefaults suite。
#
# 为什么不在这里再跑 download-integrity：
#   它是传输层的独立套件（约 200 秒），且其 T43 断言（"换连接次数恰为上限 3" + 60 秒窗口）
#   对机器负载敏感，会把本套件一起带成随机红。传输层覆盖请单跑：
#       bash tests/Tests/run-suites.sh download-integrity
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$REPO/src"
OUT="$REPO/build/e2e-tests"

# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"

# ---------- 1. 受控本地服务（20MB / 约 14 秒 / 单连接） ----------
python3 "$REPO/tests/Tests/fixtures/e2e_test_server.py" 20971520 14 >"$OUT/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  rm -rf /tmp/rd-e2e-* 2>/dev/null || true
}
trap cleanup EXIT

PORT=""
for _ in $(seq 1 50); do
  # server.log 可能尚未写入，管道失败不能让严格模式提前退出
  PORT=$(head -n1 "$OUT/server.log" 2>/dev/null | tr -dc '0-9') || true
  [ -n "$PORT" ] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: 本地测试服务启动失败" >&2
    cat "$OUT/server.log" >&2 || true
    exit 1
  fi
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "FAIL: 未取到本地测试服务端口" >&2
  cat "$OUT/server.log" >&2 || true
  exit 1
fi

# ---------- 2. 编译行级时间轴测试 ----------
bash "$REPO/scripts/generate-version.sh" >/dev/null
SRC=("$REPO/tests/Tests/DownloadE2ETests.m" "$ROOT/App/ResourceResultRowView.m")
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in AppError DNSResolver HTTPPrivacyPolicy IPAddressPolicy HTTPRequest HTTPResult HTTPClient PreferencesStore RDLog; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m" "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
      "$ROOT/Shared/UI/DesignSystem/ColorTokens.m" "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m"
      "$ROOT/Shared/UI/StateView.m" "$ROOT/Shared/UI/UIThemeSupport.m")
INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" "$ROOT/Shared" \
           "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" "$ROOT/Shared/Infrastructure/Performance" \
           "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" "$REPO/build/generated"; do INCLUDES+=("-I$dir"); done
xcrun clang -fobjc-arc -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/DownloadE2ETests"

# ---------- 3. 行级时间轴 ----------
RD_E2E_BASE="http://127.0.0.1:$PORT" "$OUT/DownloadE2ETests"

echo "PASS: local download E2E via DownloadManager"
