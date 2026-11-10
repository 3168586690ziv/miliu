#!/bin/bash
# Stage-1 focused production regression. No App, browser, preferences or network.
# All outputs stay in the selected isolated directory; no generated version files.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_PHASE1_OUT:-$REPO/build/phase-one-tests}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
printf 'PHASE_ONE_OUT=%s\n' "$OUT"
STATUS=0
compile_and_run() {
  local name="$1"; shift
  printf 'COMMAND: xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 %s\n' "$*"
  if xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 "$@" -o "$OUT/$name" >"$OUT/$name.compile.log" 2>&1; then
    printf 'COMPILE %s exit=0\n' "$name"
  else
    local rc=$?
    printf 'COMPILE %s exit=%s\n' "$name" "$rc"
    STATUS=1; return
  fi
  local rc=0
  if [ "$name" = QueueWALTailTests ]; then
    "$OUT/$name" "$OUT/wal-fixtures" >"$OUT/$name.run.log" 2>&1 || rc=$?
  else
    "$OUT/$name" >"$OUT/$name.run.log" 2>&1 || rc=$?
  fi
  printf 'RUN %s exit=%s log=%s\n' "$name" "$rc" "$OUT/$name.run.log"
  [ "$rc" = 0 ] || STATUS=1
  if ! python3 - "$OUT/$name.compile.log" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
warnings=[line for line in text.splitlines() if 'warning:' in line]
print('COMPILE_WARNINGS='+str(len(warnings)))
for line in warnings: print(line)
sys.exit(bool(warnings))
PY
  then STATUS=1; fi
}
compile_and_run QueueWALTailTests -framework Foundation \
  -I"$REPO/src/Features/ResourceDownload" \
  "$REPO/tests/Tests/QueueWALTailTests.m" \
  "$REPO/src/Features/ResourceDownload/RDQueueWAL.m"
compile_and_run PreviewControllerTests -DRD_PREVIEW_TESTING=1 -framework Cocoa -framework AVFoundation -framework CoreMedia -framework Security \
  -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src/Shared/Infrastructure" -I"$REPO/src" \
  "$REPO/tests/Tests/PreviewControllerTests.m" \
  "$REPO/src/Features/ResourceDetector/RDPreviewController.m" \
  "$REPO/src/Features/ResourceDetector/RDPreviewEligibility.m" \
  "$REPO/src/Features/ResourceDetector/RDPreviewPlaylistRewrite.m" \
  "$REPO/src/Features/ResourceDetector/DetectedMedia.m" \
  "$REPO/src/Shared/Infrastructure/HTTPPrivacyPolicy.m"
printf 'PHASE_ONE_RESULT exit=%s\n' "$STATUS"
exit "$STATUS"
