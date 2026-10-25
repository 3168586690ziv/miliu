#!/bin/bash
# pagination-styles.sh — 列表页多形态分页专项（第 40 轮）
#
# 背景：站点模式翻页此前只认 `?page=N`。分页形态是 `/page/2`、`/page2`、`_p2`、`-2`、
# `?p=2`、`?pg=2`、`?paged=2`、`/index_2.html` 的站点，填了页数也只会重复请求同一页
# （甚至 404）—— 翻页形同虚设。
#
# 本套件是**纯函数测试**：不触网、不起窗口、不跑 WebKit 运行时。被测的生产方法都在
# `DiscoverySessionController.m` 里；该文件的 import 链覆盖整个 Features 目录，
# 故按 repair.sh 的同一做法全树编译（否则漏一个类就链接失败）。
# 与其它套件一样**串行**执行（共用 build/generated/RDGeneratedVersion.h）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/pagination-styles-tests"
mkdir -p "$OUT"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

# 构建期版本头（幂等：只重算代码行数，不改变修复轮数）
bash "$REPO/scripts/generate-version.sh" >/dev/null

SRC=("$REPO/tests/Tests/PaginationStylesTests.m")
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in IPAddressPolicy DNSResolver HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient \
         RDCurlHopper AppError RDLog PreferencesStore; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m"
      "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
      # Features 全树含引用 UI DesignSystem 的视图（ResourceThumbnailProgressView 用 ColorTokens），
      # 与 repair.sh 一样把 DesignSystem / UI 基础件一并编译。
      "$ROOT/Shared/UI/DesignSystem/ColorTokens.m"
      "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m"
      "$ROOT/Shared/UI/StateView.m"
      "$ROOT/Shared/UI/UIThemeSupport.m")

INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" \
           "$ROOT/Shared" "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" \
           "$ROOT/Shared/Infrastructure/Performance" "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" \
           "$REPO/build/generated"; do INCLUDES+=("-I$dir"); done

# 链接依赖：Features 全树含 import AVKit 的 RDPreviewWindow.m（verify.sh 4f 看门人也会查这一条）；
# 生产代码用 Security / SQLite，一并链接。
xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVKit -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  -lsqlite3 \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/PaginationStylesTests" > "$OUT/compile.log" 2>&1 || {
    cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1
  }
if grep -E "error:" "$OUT/compile.log" >/dev/null; then
  cat "$OUT/compile.log"; echo "FAIL: 编译错误"; exit 1
fi
if grep -E "warning:" "$OUT/compile.log" >/dev/null; then
  echo "WARN: 编译告警如下（不影响判定，但请留意）"
  grep -E "warning:" "$OUT/compile.log" | head -20
fi

"$OUT/PaginationStylesTests" "$@"
printf 'PASS: 列表页多形态分页专项通过\n'
