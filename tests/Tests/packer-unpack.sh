#!/bin/bash
# packer-unpack.sh — Dean Edwards packer 解包专项（第 47 轮）
# 锁死「播放器地址被整段混淆时静态腿仍能看到 m3u8」这条能力，
# 并保证解包是纯字符串变换（不执行脚本）、非 packer 输入零副作用。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="$REPO/build/packer-unpack-tests"
export RD_LOG_PATH="$OUT/test.log"
mkdir -p "$OUT"
bash "$REPO/scripts/generate-version.sh" >/dev/null

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework ImageIO \
  -framework UniformTypeIdentifiers -framework Security -lsqlite3 \
  -I"$ROOT" -I"$ROOT/App" -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Features/ResourceDownload" \
  -I"$ROOT/Shared" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
  -I"$ROOT/Shared/Infrastructure/Performance" -I"$ROOT/Shared/UI" -I"$ROOT/Shared/UI/DesignSystem" \
  -I"$REPO/build/generated" \
  "$REPO/tests/Tests/PackerUnpackTests.m" \
  "$ROOT/Features/ResourceDetector/RDStaticScriptAnalyzer.m" \
  "$ROOT/Features/ResourceDetector/WebProbe.m" \
  "$ROOT/Features/ResourceDetector/DetectedMedia.m" \
  "$ROOT/Features/ResourceDetector/URLPolicy.m" \
  "$ROOT/Features/ResourceDetector/RDQualityTier.m" \
  "$ROOT/Features/ResourceDetector/RDResourceDisplayMetadata.m" \
  "$ROOT/Features/ResourceDetector/RDManualVerification.m" \
  "$ROOT/Features/ResourceDetector/RDManifestParser.m" \
  "$ROOT/Features/ResourceDetector/RDBoundedMovie.m" \
  "$ROOT/Features/ResourceDetector/RDRangeAsset.m" \
  "$ROOT/Features/ResourceDetector/RDMetadataService.m" \
  "$ROOT/Features/ResourceDetector/RDMetadataTransport.m" \
  "$ROOT/Features/ResourceDetector/RDCoverRecoveryEngine.m" \
  "$ROOT/Features/ResourceDetector/RDDisplayMetadataRecoveryStore.m" \
  "$ROOT/Features/ResourceDetector/RDThumbnailGenerator.m" \
  "$ROOT/Features/ResourceDetector/ResourceURLGate.m" \
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
  -o "$OUT/PackerUnpackTests" >"$OUT/compile.log" 2>&1 || {
    cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1; }
if grep -E 'warning:' "$OUT/compile.log" >/dev/null; then
  cat "$OUT/compile.log"; echo "FAIL: 编译有警告"; exit 1
fi

"$OUT/PackerUnpackTests"
echo "PASS: packer 解包（纯字符串变换；非 packer 零副作用）"
