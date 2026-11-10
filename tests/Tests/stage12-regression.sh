#!/bin/bash
# Serial, isolated stage-1/2 verification. Does not build/install/start the App.
# Local HTTP mode binds only 127.0.0.1; all other new fixtures replace transport.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_STAGE12_OUT:-$REPO/build/stage12-evidence-20261110/final}"
mkdir -p "$OUT"
STATUS=0
run() {
  local label="$1"; shift
  printf 'COMMAND %s:' "$label"; printf ' %q' "$@"; printf '\n'
  "$@" > "$OUT/$label.log" 2>&1
  local rc=$?
  printf 'RESULT %s exit=%s log=%s\n' "$label" "$rc" "$OUT/$label.log"
  [ "$rc" -eq 0 ] || STATUS=1
  python3 - "$OUT/$label.log" <<'PY'
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text().splitlines()
selected=[x for x in lines if any(s in x for s in ['failed=', 'checks=', 'COMPILE_WARNINGS=', 'TEST-SUITE-PASSED', '全部 ', 'FAIL:', 'PHASE_ONE_RESULT'])]
print('\n'.join(selected[-8:]))
PY
}
run phase-one env RD_PHASE1_OUT="$OUT/phase-one" bash "$REPO/tests/Tests/phase-one.sh"
run failure-precision env RD_FAILURE_OUT="$OUT/failure" bash "$REPO/tests/Tests/failure-precision.sh"
run preview-lifecycle env RD_LIFECYCLE_OUT="$OUT/lifecycle" bash "$REPO/tests/Tests/preview-lifecycle.sh"
run preview-loopback "$OUT/lifecycle/PreviewLifecycleTests" --loopback-only
run preview-timeout "$OUT/lifecycle/PreviewLifecycleTests" --timeout-only
run existing-queue-wal bash "$REPO/tests/Tests/queue-wal.sh"
run existing-redirect-policy bash "$REPO/tests/Tests/redirect-policy.sh"
run eligibility-compile xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -framework Foundation \
  -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src" \
  "$REPO/tests/Tests/PreviewEligibilityTests.m" "$REPO/src/Features/ResourceDetector/RDPreviewEligibility.m" \
  "$REPO/src/Features/ResourceDetector/DetectedMedia.m" -o "$OUT/PreviewEligibilityTests"
run existing-preview-eligibility "$OUT/PreviewEligibilityTests"
run rewrite-compile xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -framework Foundation \
  -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src" \
  "$REPO/tests/Tests/PreviewRewriteTests.m" "$REPO/src/Features/ResourceDetector/RDPreviewPlaylistRewrite.m" -o "$OUT/PreviewRewriteTests"
run existing-preview-rewrite "$OUT/PreviewRewriteTests"
for arch in arm64 x86_64; do
  run "production-$arch-compile" xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -arch "$arch" \
    -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src/Shared/Infrastructure" -I"$REPO/src" \
    -c "$REPO/src/Features/ResourceDetector/RDPreviewController.m" -o "$OUT/controller-$arch.o"
done
python3 - "$OUT" "$REPO" > "$OUT/all-compile-warnings.log" <<'PY'
from pathlib import Path
import sys
out,repo=map(Path,sys.argv[1:])
logs=[out/'phase-one/QueueWALTailTests.compile.log',out/'phase-one/PreviewControllerTests.compile.log',out/'failure/compile.log',out/'lifecycle/compile.log',repo/'build/queue-wal-tests/compile.log',repo/'build/redirect-policy-tests/compile.log']
logs += [out/(x+'.log') for x in ['eligibility-compile','rewrite-compile','production-arm64-compile','production-x86_64-compile']]
total=0
for p in logs:
 if not p.is_file(): print('MISSING_COMPILE_LOG='+str(p)); total+=1; continue
 warnings=[x for x in p.read_text().splitlines() if 'warning:' in x]
 total+=len(warnings)
 print(str(p)+': warnings='+str(len(warnings)))
 for line in warnings: print(line)
print('ALL_COMPILE_WARNINGS='+str(total))
sys.exit(bool(total))
PY
warnings=$?
printf 'RESULT warning-audit exit=%s log=%s\n' "$warnings" "$OUT/all-compile-warnings.log"
[ "$warnings" -eq 0 ] || STATUS=1
printf 'STAGE12_FOCUSED_RESULT exit=%s (real AVPlayer E2E not run)\n' "$STATUS"
exit "$STATUS"
