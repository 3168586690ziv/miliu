#!/bin/bash
# 抓取能力升级专项测试（第 29 轮）：og:video / JSON-LD / 全文兜底 / 扩展名。
# 纯函数，无网络、无窗口；与其它套件一样串行执行。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="$REPO/build/media-discovery-tests"

export RD_LOG_PATH="$OUT/test.log"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
bash "$REPO/scripts/generate-version.sh" >/dev/null

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  -lsqlite3 \
  -I"$ROOT" -I"$ROOT/App" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Features/ResourceDownload" -I"$ROOT/Shared" \
  -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" -I"$ROOT/Shared/Infrastructure/Performance" \
  -I"$ROOT/Shared/UI" -I"$ROOT/Shared/UI/DesignSystem" -I"$REPO/build/generated" \
  "$REPO/tests/Tests/MediaDiscoveryTests.m" \
  "$ROOT/Features/ResourceDetector/WebProbe.m" \
  "$ROOT/Features/ResourceDetector/RDStaticScriptAnalyzer.m" \
  "$ROOT/Features/ResourceDetector/DetectedMedia.m" \
  "$ROOT/Features/ResourceDetector/RDQualityTier.m" \
  "$ROOT/Features/ResourceDetector/RDWatchlistStore.m" \
  "$ROOT/Features/ResourceDetector/RDMetadataService.m" \
  "$ROOT/Features/ResourceDetector/RDMetadataTransport.m" \
  "$ROOT/Features/ResourceDetector/ResourceURLGate.m" \
  "$ROOT/Features/ResourceDetector/URLPolicy.m" \
  "$ROOT/Features/ResourceDetector/RDCoverRecoveryEngine.m" \
  "$ROOT/Features/ResourceDetector/RDDisplayMetadataRecoveryStore.m" \
  "$ROOT/Features/ResourceDetector/RDResourceDisplayMetadata.m" \
  "$ROOT/Features/ResourceDetector/RDManualVerification.m" \
  "$ROOT/Features/ResourceDetector/RDManifestParser.m" \
  "$ROOT/Features/ResourceDetector/RDBoundedMovie.m" \
  "$ROOT/Features/ResourceDetector/RDRangeAsset.m" \
  "$ROOT/Features/ResourceDetector/RDThumbnailGenerator.m" \
  "$ROOT/Shared/Infrastructure/Async/RequestGeneration.m" \
  "$ROOT/Shared/Infrastructure/AppError.m" \
  "$ROOT/Shared/Infrastructure/DNSResolver.m" \
  "$ROOT/Shared/Infrastructure/HTTPPrivacyPolicy.m" \
  "$ROOT/Shared/Infrastructure/IPAddressPolicy.m" \
  "$ROOT/Shared/Infrastructure/HTTPRequest.m" \
  "$ROOT/Shared/Infrastructure/HTTPResult.m" \
  "$ROOT/Shared/Infrastructure/HTTPClient.m" \
  "$ROOT/Shared/Infrastructure/RDLog.m" \
  "$ROOT/Shared/Infrastructure/RDCurlHopper.m" \
  "$ROOT/Shared/Infrastructure/PreferencesStore.m" \
  -o "$OUT/MediaDiscoveryTests" >"$OUT/compile.log" 2>&1 || { cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1; }
grep -E "error:" "$OUT/compile.log" && { echo "FAIL: 编译错误"; exit 1; } || true

"$OUT/MediaDiscoveryTests" "$@"
printf 'PASS: 抓取能力升级专项通过\n'
