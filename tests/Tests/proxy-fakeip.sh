#!/bin/bash
# proxy-fakeip.sh — 系统代理 fake-ip 兼容专项（第 39 轮）
#
# 真实故障回归：用户开着 Clash 一类代理（TUN + fake-ip）时，所有域名被答成
# 198.18.0.0/15 内的假地址，被 URLPolicy 当「保留地址」拒绝 ⇒ 任何网站都
# 探测不了。本套件用注入开关驱动，不依赖运行环境是否真的开着代理。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/proxy-fakeip-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Foundation -framework AppKit -framework Security \
  -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Features/ResourceDetector" \
  "$REPO/tests/Tests/ProxyFakeIPTests.m" \
  "$ROOT/Features/ResourceDetector/URLPolicy.m" \
  "$ROOT/Shared/Infrastructure/IPAddressPolicy.m" \
  "$ROOT/Shared/Infrastructure/RDLog.m" \
  -o "$OUT/ProxyFakeIPTests" > "$OUT/compile.log" 2>&1
if grep -E "error:|warning:" "$OUT/compile.log" >/dev/null; then
  cat "$OUT/compile.log"; echo "FAIL: ProxyFakeIPTests 编译失败"; exit 1
fi

"$OUT/ProxyFakeIPTests"
echo "PASS: 系统代理 fake-ip 兼容专项通过"
