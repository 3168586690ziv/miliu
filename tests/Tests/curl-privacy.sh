#!/bin/bash
# Native-only auth boundary + production curl redirect walk, no real DNS/curl/UI.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_CURL_PRIVACY_OUT:-$REPO/build/curl-privacy-tests}"
mkdir -p "$OUT/tmp"
OUT="$(cd "$OUT" && pwd)"
export TMPDIR="$OUT/tmp/" RD_CURL_TEST_ROOT="$OUT" RD_LOG_PATH="$OUT/production.log"
export RD_SESSION_PROXY_OVERRIDE=direct
FALLBACK="${RD_CURL_FALLBACK_SOURCE:-$REPO/src/App/RDCurlFallbackBackend.m}"
HOPPER="${RD_CURL_HOPPER_SOURCE:-$REPO/src/Shared/Infrastructure/RDCurlHopper.m}"
SOURCES=("$REPO/tests/Tests/CurlPrivacyTests.m" "$FALLBACK" "$HOPPER")
for name in HTTPPrivacyPolicy DNSResolver IPAddressPolicy RDLog; do SOURCES+=("$REPO/src/Shared/Infrastructure/$name.m"); done
SOURCES+=("$REPO/src/Features/ResourceDetector/URLPolicy.m")
CMD=(xcrun clang -fobjc-arc -fblocks -DNSTemporaryDirectory=RDCurlPrivacyTemporaryDirectory -mmacosx-version-min=13.0 -framework Foundation -framework AppKit -framework Security
  -I"$REPO/src/App" -I"$REPO/src/Shared/Infrastructure" -I"$REPO/src/Features/ResourceDetector" -I"$REPO/src/Features/ResourceDownload"
  "${SOURCES[@]}" -o "$OUT/CurlPrivacyTests")
if [ "${RD_CURL_PRIVACY_ASAN:-0}" = 1 ]; then CMD+=(-g -O1 -fsanitize=address); fi
printf 'COMMAND:'; printf ' %q' "${CMD[@]}"; printf '\n'
set +e
"${CMD[@]}" > "$OUT/compile.log" 2>&1
rc=$?
set -e
printf 'COMPILE exit=%s\n' "$rc"
if [ "$rc" -ne 0 ]; then printf 'FAIL: compile error; see %s\n' "$OUT/compile.log"; echo 'TEST_RESULT stage=curl-privacy status=FAIL reason=compile-error'; exit 1; fi
warnings=$(python3 - "$OUT/compile.log" <<'PY'
from pathlib import Path
import sys
print(sum('warning:' in line for line in Path(sys.argv[1]).read_text().splitlines()))
PY
)
echo "COMPILE_WARNINGS=$warnings"
if [ "$warnings" -ne 0 ]; then echo 'FAIL: compiler warnings'; echo 'TEST_RESULT stage=curl-privacy status=FAIL reason=compile-warnings'; exit 1; fi
set +e
"$OUT/CurlPrivacyTests" > "$OUT/run.log" 2>&1
rc=$?
set -e
python3 - "$OUT/run.log" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(),end='')
PY
printf 'RUN exit=%s\n' "$rc"
if [ "$rc" -eq 0 ]; then
  echo 'TEST_RESULT stage=curl-privacy status=PASS reason=production-boundary-and-hops'
else
  echo 'TEST_RESULT stage=curl-privacy status=FAIL reason=behavior-check'
fi
exit "$rc"
