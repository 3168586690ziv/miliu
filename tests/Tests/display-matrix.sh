#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$REPO/src"; BUILD="$REPO/build/display-matrix-tests"; mkdir -p "$BUILD"
# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
export RD_LOG_PATH="$BUILD/test-ResourceDetector.log"
bash "$REPO/scripts/generate-version.sh" >/dev/null
SRC=("$REPO/tests/Tests/DisplayMatrixTests.m" "$ROOT/App/ResourceResultRowView.m")
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in AppError DNSResolver HTTPPrivacyPolicy IPAddressPolicy HTTPRequest HTTPResult HTTPClient PreferencesStore RDLog; do SRC+=("$ROOT/Shared/Infrastructure/$f.m"); done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m" "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m" "$ROOT/Shared/UI/DesignSystem/ColorTokens.m" "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m" "$ROOT/Shared/UI/StateView.m" "$ROOT/Shared/UI/UIThemeSupport.m")
INCLUDES=(); for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" "$ROOT/Shared" "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" "$ROOT/Shared/Infrastructure/Performance" "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" "$REPO/build/generated"; do INCLUDES+=("-I$dir"); done
xcrun clang -fobjc-arc -O1 -mmacosx-version-min=13.0 -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security "${INCLUDES[@]}" "${SRC[@]}" -o "$BUILD/DisplayMatrixTests"
ASAN_OPTIONS=detect_leaks=0 "$BUILD/DisplayMatrixTests"
echo "PASS: display matrix production row behavior"
