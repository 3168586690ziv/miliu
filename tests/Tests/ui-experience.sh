#!/bin/bash
# ui-experience.sh — 本轮 UI 体验专项测试（分栏比例 / 探测状态文案 / 详情标题 / 设置页稳定）
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build/ui-experience-tests"
# 日志隔离：不得污染用户真实日志
export RD_LOG_PATH="$BUILD/test-ResourceDetector.log"
mkdir -p "$BUILD"
bash "$REPO/scripts/generate-version.sh" >/dev/null
printf 'UI experience focused tests: %s\n' "$(date -u)"
SRC=("$REPO/tests/Tests/UIExperienceTests.m" "$ROOT/App/ResourceResultRowView.m")
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
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$BUILD/UIExperienceTests" >"$BUILD/compile.log" 2>&1
if grep -E "error:" "$BUILD/compile.log" >/dev/null; then cat "$BUILD/compile.log"; exit 1; fi
ASAN_OPTIONS=detect_leaks=0 "$BUILD/UIExperienceTests" "$@"
printf 'PASS: ui-experience tests exited 0\n'