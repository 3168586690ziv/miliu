#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/fix-chain-tests"

# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
# 构建期版本头（幂等：只重算代码行数，不改变修复轮数）
bash "$REPO/scripts/generate-version.sh" >/dev/null
printf 'FIX-A / FIX-B production-chain focused tests: %s\n' "$(date -u)"
SRC=("$REPO/tests/Tests/FixChainTests.m" "$ROOT/App/ResourceResultRowView.m")
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
           "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" "$BUILD/generated"; do INCLUDES+=("-I$dir"); done
# 编译生产代码；App main 被改名，不启动 NSApplication/窗口/浏览器。
# 只替身外部网络投递与下载入队，App 订阅回调/visibleMedia/downloadSelected 全部为生产实现。
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/FixChainTests" >"$OUT/compile.log" 2>&1
if grep -E "error:" "$OUT/compile.log" >/dev/null; then cat "$OUT/compile.log"; exit 1; fi
# 新增警告门槛：与 repair.sh 导入 App 源码的既有基线一致，nullability
# 完整性提示与历史 retain-cycle 警告不计；类型不匹配/未声明 selector 等
# 一律视为失败。
BAD=$(grep -E "warning:" "$OUT/compile.log" | grep -v "nullability" | grep -v "arc-retain-cycles" || true)
if [ -n "$BAD" ]; then printf '%s\n' "$BAD"; echo "FAIL: 新增编译警告"; exit 1; fi
ASAN_OPTIONS=detect_leaks=0 "$OUT/FixChainTests" "$@"
printf 'PASS: ASan local test executable exited 0\n'
