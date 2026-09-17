#!/bin/bash
# 统一日志（RDLog）缺陷修复回归测试。用法：bash tests/Tests/rdlog.sh
# 只编译 RDLog.{h,m} 与测试主程序，不涉及 GUI 构建；崩溃类用例在子进程内验证退出码。
# 全程使用临时日志路径（RD_LOG_PATH），绝不读写用户真实日志。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="$REPO/build/rdlog-tests"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
printf '统一日志回归测试: %s\n' "$(date -u)"

# 兜底隔离：即使测试内部漏设，也保证不落到用户真实日志
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

if ! xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
      -framework Foundation -framework AppKit \
      -I"$ROOT/Shared/Infrastructure" \
      "$REPO/tests/Tests/RDLogTests.m" "$ROOT/Shared/Infrastructure/RDLog.m" \
      -o "$OUT/RDLogTests" > "$OUT/compile.log" 2>&1; then
  echo "FAIL: 编译失败"
  cat "$OUT/compile.log"
  exit 1
fi
if grep -q "error:" "$OUT/compile.log"; then
  cat "$OUT/compile.log"; echo "FAIL: 编译出现错误"; exit 1
fi

"$OUT/RDLogTests"
echo "PASS: 统一日志回归测试全部通过"
