#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/audit-tests"

# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
# 构建期版本头（幂等：只重算代码行数，不改变修复轮数）
bash "$REPO/scripts/generate-version.sh" >/dev/null
printf 'Focused local production-class tests: %s\n' "$(date -u)"
SRC=("$REPO/tests/Tests/AuditChecks.m" "$ROOT/App/ResourceResultRowView.m")
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
# Compile production classes; renamed application main is never called. No NSApplication/window/browser.
# ASan checks invalid release/use-after-free while images are used after callbacks return.
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/AuditChecks" >"$OUT/compile.log" 2>&1
ASAN_OPTIONS=detect_leaks=0 "$OUT/AuditChecks" "$@"
printf 'PASS: ASan local test executable exited 0\n'
