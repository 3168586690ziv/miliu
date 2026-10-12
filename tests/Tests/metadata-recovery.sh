#!/bin/bash
# metadata-recovery.sh — 元数据恢复接线专项（第 38 轮）
#
# 两件事：
#   ① 动态：协调器把三个「零引用」组件真正接上（记录/查询/持久化往返/翻译短路/恢复发起）；
#   ② 静态：App 层确实调用了这些接线点（否则组件仍可能「代码里写了、运行时走不到」）。
# 无网络、无窗口、无 NSApplication。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/metadata-recovery-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产类（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework Security \
  -I"$ROOT" -I"$ROOT/App" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared" \
  -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/UI" -I"$ROOT/Shared/UI/DesignSystem" \
  "$REPO/tests/Tests/MetadataRecoveryTests.m" \
  "$ROOT/App/RDMetadataRecoveryCoordinator.m" \
  "$ROOT/Features/ResourceDetector/RDDisplayMetadataRecoveryStore.m" \
  "$ROOT/Features/ResourceDetector/ResourceTitleTranslator.m" \
  "$ROOT/Features/ResourceDetector/RDCoverRecoveryEngine.m" \
  "$ROOT/Features/ResourceDetector/RDResourceDisplayMetadata.m" \
  "$ROOT/Features/ResourceDetector/DetectedMedia.m" \
  "$ROOT/Features/ResourceDetector/URLPolicy.m" \
  "$ROOT/Shared/Infrastructure/IPAddressPolicy.m" \
  "$ROOT/Shared/Infrastructure/PreferencesStore.m" \
  "$ROOT/Shared/Infrastructure/RDLog.m" \
  -o "$OUT/MetadataRecoveryTests" > "$OUT/compile.log" 2>&1
if grep -E "error:|warning:" "$OUT/compile.log" >/dev/null; then
  cat "$OUT/compile.log"; echo "FAIL: MetadataRecoveryTests 编译失败"; exit 1
fi

"$OUT/MetadataRecoveryTests"

# ── 静态接线断言：三个组件在生产代码里必须有真实调用点 ──
# 若将来有人把接线拆掉，组件会重新变回「代码完整但永不执行」，这里必须变红。
APP="$ROOT/App/ResourceDetectorApp.m"
assert_uses() {   # $1=文件 $2=符号 $3=说明
  if ! grep -qE "(^|[^A-Za-z_])$2([^A-Za-z_]|\$)" "$1" 2>/dev/null; then
    echo "FAIL: $3 —— $1 里找不到接线点 $2" >&2; exit 1
  fi
}
assert_uses "$APP" "metadataRecovery"                     "元数据恢复协调器未被 App 层持有"
assert_uses "$APP" "recordDetectedMedia"                  "探测结果未写入展示元数据存储"
assert_uses "$APP" "recordListingPosters"                 "列表页封面回调未接线"
assert_uses "$APP" "translateTitlesIfNeededForMedia"      "标题翻译未接线"
assert_uses "$APP" "attemptCoverRecoveryForMedia"         "封面恢复未接线"
assert_uses "$APP" "backfillDisplayMetadataForMedia"      "标题/封面回补未接线"
assert_uses "$APP" "listingPagePreviewHandler"            "列表页封面回调未挂载到探测会话"
assert_uses "$APP" "loadPersistedState"                   "启动时未载入展示元数据历史"
if ! grep -q "persist\]" "$APP" 2>/dev/null; then
  echo "FAIL: 结果落地后未持久化展示元数据历史" >&2; exit 1
fi

# 三个组件各自必须仍有生产引用点（零引用就是回归）
for pair in "RDCoverRecoveryEngine:RDCoverRecoveryEngine" \
            "RDDisplayMetadataRecoveryStore:RDDisplayMetadataRecoveryStore" \
            "ResourceTitleTranslator:ResourceTitleTranslator"; do
  name="${pair%%:*}"
  if ! grep -rqE "(^|[^A-Za-z_])${name}([^A-Za-z_]|\$)" \
        "$ROOT/App" "$ROOT/Features" 2>/dev/null; then
    echo "FAIL: $name 又变回零引用组件" >&2; exit 1
  fi
done

echo "PASS: 元数据恢复接线专项通过（三个组件均有真实调用点）"
