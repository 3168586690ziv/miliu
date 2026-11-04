#!/bin/bash
# segment-filter.sh — HLS/DASH 分片收口专项（第 47 轮）
#
# 锁定「一个视频不能被拆成几十个碎片」这条判据，双向验证：
#   · HLS 分片（seg-000.ts…）在同批存在清单时必须被收口；
#   · 整段 .ts 直链（ep01.ts / live.ts）必须保留 —— 项目既有用例明确要求。
# 与其它套件一样串行（共用 build/generated/RDGeneratedVersion.h）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="$REPO/build/segment-filter-tests"
export RD_LOG_PATH="$OUT/test.log"
mkdir -p "$OUT"
bash "$REPO/scripts/generate-version.sh" >/dev/null

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Foundation \
  -I"$ROOT" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" \
  -I"$REPO/build/generated" \
  "$REPO/tests/Tests/SegmentFragmentTests.m" \
  -o "$OUT/SegmentFragmentTests" >"$OUT/compile.log" 2>&1 || {
    cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1; }
# 任何警告也当失败（与 media-discovery 等套件一致：避免 nullability 审计噪音混入）
if grep -E 'warning:' "$OUT/compile.log" >/dev/null; then
  cat "$OUT/compile.log"; echo "FAIL: 编译有警告"; exit 1
fi

"$OUT/SegmentFragmentTests"
echo "PASS: 分片收口判据（双向：分片收口 / 整段 .ts 保留）"
