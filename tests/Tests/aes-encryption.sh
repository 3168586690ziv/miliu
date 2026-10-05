#!/bin/bash
# AES-128 加密流专项（第 30 轮）：显式 IV / 隐式 IV / 密钥轮换 / KEYFORMAT / DRM 拒绝。
# 纯函数，无网络、无窗口；与其它套件一样串行执行。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="$REPO/build/aes-encryption-tests"

export RD_LOG_PATH="$OUT/test.log"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 -framework Foundation \
  -I"$ROOT/Features/ResourceDownload" -I"$ROOT/Features/ResourceDetector" -I"$ROOT" \
  "$REPO/tests/Tests/AESEncryptionTests.m" \
  "$ROOT/Features/ResourceDownload/RDStreamPlan.m" \
  "$ROOT/Features/ResourceDetector/RDManifestParser.m" \
  -o "$OUT/AESEncryptionTests" >"$OUT/compile.log" 2>&1 || { cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1; }
grep -E "error:" "$OUT/compile.log" && { echo "FAIL: 编译错误"; exit 1; } || true

"$OUT/AESEncryptionTests" "$@"
printf 'PASS: AES-128 加密流专项通过\n'
