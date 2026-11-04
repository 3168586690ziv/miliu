#!/bin/bash
# 队列 WAL / 失败诊断 / 分片图片外壳剥离 的隔离测试。
# 只编译纯逻辑组件，不启动 App、不触网、不写用户偏好。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/queue-wal-tests"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1

SRC=(
  "$REPO/tests/Tests/QueueWALTests.m"
  "$ROOT/Features/ResourceDownload/RDQueueWAL.m"
  "$ROOT/Features/ResourceDownload/RDFailureDiagnosis.m"
  "$ROOT/Features/ResourceDownload/RDImageWrapperStripper.m"
)
INCLUDES=(-I"$ROOT" -I"$ROOT/Features/ResourceDownload" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure")

if ! xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 -framework Foundation -framework AppKit "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/QueueWALTests" > "$OUT/compile.log" 2>&1; then
  echo "FAIL: 编译失败"; cat "$OUT/compile.log"; exit 1
fi
if grep -E "error:" "$OUT/compile.log" >/dev/null; then
  echo "FAIL: 编译有错误"; cat "$OUT/compile.log"; exit 1
fi
BAD=$(grep -E "warning:" "$OUT/compile.log" | grep -v "nullability" | grep -v "arc-retain-cycles" || true)
if [ -n "$BAD" ]; then
  echo "FAIL: 编译告警"; echo "$BAD"; exit 1
fi

"$OUT/QueueWALTests"
echo "PASS: 队列 WAL / 失败诊断 / 图片外壳剥离"
