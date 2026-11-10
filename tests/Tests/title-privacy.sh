#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_TITLE_OUT:-$REPO/build/title-privacy-tests}"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -framework Cocoa \
 -I"$REPO/src/Features/ResourceDetector" "$REPO/tests/Tests/TitleTranslatorPrivacyTests.m" \
 "${RD_TITLE_SOURCE:-$REPO/src/Features/ResourceDetector/ResourceTitleTranslator.m}" -o "$OUT/TitleTranslatorPrivacyTests" > "$OUT/compile.log" 2>&1
python3 - "$OUT/compile.log" <<'PY'
import sys,pathlib
s=pathlib.Path(sys.argv[1]).read_text(); n=s.count('warning:'); print(f'COMPILE_WARNINGS={n}')
if n: print(s);sys.exit(1)
PY
"$OUT/TitleTranslatorPrivacyTests"
