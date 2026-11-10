#!/bin/bash
# Production preview orchestration without real player, window, sockets or network.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_LIFECYCLE_OUT:-$REPO/build/preview-lifecycle-tests}"
mkdir -p "$OUT"
CONTROLLER="${RD_PREVIEW_CONTROLLER_SOURCE:-$REPO/src/Features/ResourceDetector/RDPreviewController.m}"
CMD=(xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -DRD_PREVIEW_TESTING=1 \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework Security \
  -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src/Shared/Infrastructure" -I"$REPO/src" \
  "$REPO/tests/Tests/PreviewLifecycleTests.m" \
  "$CONTROLLER" \
  "$REPO/src/Features/ResourceDetector/RDPreviewEligibility.m" \
  "$REPO/src/Features/ResourceDetector/RDPreviewPlaylistRewrite.m" \
  "$REPO/src/Features/ResourceDetector/DetectedMedia.m" \
  "$REPO/src/Shared/Infrastructure/HTTPPrivacyPolicy.m" -o "$OUT/PreviewLifecycleTests")
printf 'COMMAND:'; printf ' %q' "${CMD[@]}"; printf '\n'
"${CMD[@]}" > "$OUT/compile.log" 2>&1
python3 - "$OUT/compile.log" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
warnings=[x for x in text.splitlines() if 'warning:' in x]
print('COMPILE_WARNINGS='+str(len(warnings)))
for x in warnings: print(x)
sys.exit(bool(warnings))
PY
"$OUT/PreviewLifecycleTests" "$@"
