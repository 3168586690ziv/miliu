#!/bin/bash
# Real-controller, no-window, muted AVPlayer preview acceptance. Never builds/starts App.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="${RD_PREVIEW_OUT:-$REPO/build/preview-tests}"
FIX="$REPO/tests/fixtures/preview"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
stage=setup; SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'rc=$?; echo "TEST_RESULT stage=$stage status=FAIL reason=command-exit-$rc"; exit 1' ERR
result() { echo "TEST_RESULT stage=$1 status=$2 reason=$3"; }
compile_component() {
  local name="$1"; shift
  echo "COMMAND xcrun clang $name (sources: $*)"
  xcrun clang -fobjc-arc -fblocks -g -O1 -mmacosx-version-min=13.0 \
    -framework Cocoa -framework AVFoundation -framework CoreMedia -framework Security \
    -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT" \
    "$@" -o "$OUT/$name" > "$OUT/$name.compile.log" 2>&1 || return 1
  if grep -E 'error:|warning:' "$OUT/$name.compile.log"; then return 1; fi
  echo "COMPILE $name exit=0 warnings=0"
}
stage=eligibility
compile_component PreviewEligibilityTests "$REPO/tests/Tests/PreviewEligibilityTests.m" \
  "$ROOT/Features/ResourceDetector/RDPreviewEligibility.m" "$ROOT/Features/ResourceDetector/DetectedMedia.m"
"$OUT/PreviewEligibilityTests"
result "$stage" PASS complete
stage=rewrite
compile_component PreviewRewriteTests "$REPO/tests/Tests/PreviewRewriteTests.m" "$ROOT/Features/ResourceDetector/RDPreviewPlaylistRewrite.m"
"$OUT/PreviewRewriteTests"
result "$stage" PASS complete
stage=controller-guards
RD_PHASE1_OUT="$OUT/controller-guards" bash "$REPO/tests/Tests/phase-one.sh"
RD_LIFECYCLE_OUT="$OUT/lifecycle-guards" bash "$REPO/tests/Tests/preview-lifecycle.sh"
result "$stage" PASS real-production-orchestration-with-boundary-fixtures
stage=e2e-compile
# Compile even on machines without an encoder: missing media must not hide broken wiring.
compile_component PreviewE2E -DRD_PREVIEW_TESTING=1 "$REPO/tests/Tests/PreviewE2E.m" \
  "$ROOT/Features/ResourceDetector/RDPreviewController.m" "$ROOT/Features/ResourceDetector/RDPreviewEligibility.m" \
  "$ROOT/Features/ResourceDetector/RDPreviewPlaylistRewrite.m" "$ROOT/Features/ResourceDetector/DetectedMedia.m" \
  "$ROOT/Shared/Infrastructure/HTTPPrivacyPolicy.m"
result e2e-compile PASS real-controller-linked
stage=fixtures
# A new per-run directory avoids destructive fixture cleanup and stale server/media logs.
MEDIA="$(mktemp -d "$OUT/media.XXXXXX")"
if bash "$FIX/make-fixtures.sh" "$MEDIA"; then rc=0; else rc=$?; fi
case "$rc" in
  0) result fixtures PASS generated ;;
  3) result fixtures ENVIRONMENT encoder-ffmpeg-unavailable
     result real-avplayer ENVIRONMENT fixture-generation-unavailable
     result suite ENVIRONMENT incomplete
     exit 78 ;;
  *) result fixtures FAIL "generation-exit-$rc"; exit 1 ;;
esac
stage=server
: > "$OUT/server.log"
python3 "$FIX/server.py" --port 0 --root "$MEDIA" --log "$OUT/server.log" > "$OUT/server.stdout" 2>&1 &
SRV_PID=$!
# Managed child: only this PID, cleanup trap always terminates and reaps it.
for ((i=0;i<50;i++)); do
  if grep -q '^LISTEN [0-9]' "$OUT/server.stdout"; then break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then result server FAIL server-exited; exit 1; fi
  sleep 0.1
done
PORT="$(awk '/^LISTEN / {print $2; exit}' "$OUT/server.stdout")"
[[ "$PORT" =~ ^[0-9]+$ ]] || { result server FAIL no-listen-port; exit 1; }
# Never allow shell proxy environment/system proxy to route local fixtures externally.
export NO_PROXY='127.0.0.1,localhost'; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true
base="http://127.0.0.1:$PORT"
c1=$(curl --noproxy '*' -fsS -o /dev/null -w '%{http_code}' "$base/av-master.m3u8")
[ "$c1" = 200 ]
curl --noproxy '*' -fsS -o "$OUT/range.bin" -D "$OUT/range.headers" -r 0-99 "$base/direct.mp4"
c2=$(head -1 "$OUT/range.headers" | awk '{print $2}')
cr=$(grep -i '^Content-Range' "$OUT/range.headers" | tr -d '\r')
[ "$c2" = 206 ]
[ "$cr" = "Content-Range: bytes 0-99/$(stat -f %z "$MEDIA/direct.mp4")" ]
c3=$(curl --noproxy '*' -fsS -o /dev/null -w '%{http_code}' "$base/av-enc.m3u8")
[ "$c3" = 200 ]
echo 'OK: server selfcheck 3/3 (200 / 206+Content-Range / 200)'
result server PASS http-selfcheck-3-of-3
stage=real-avplayer
"$OUT/PreviewE2E" "$PORT" "$OUT/server.log"
result real-avplayer PASS real-controller-decoding-origin-headers-and-pinning
result suite PASS all-selected-stages-complete
