#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/performance-smoke"
mkdir -p "$OUT"
START=$(python3 -c 'import time; print(time.time())')
bash "$REPO/tests/Tests/thumbnail.sh" >"$OUT/thumbnail.log" 2>&1
END=$(python3 -c 'import time; print(time.time())')
python3 - "$START" "$END" <<'PY'
import sys
elapsed=float(sys.argv[2])-float(sys.argv[1])
print(f"metadata-thumbnail smoke elapsed={elapsed:.3f}s")
if elapsed > 120: raise SystemExit("performance smoke exceeded 120s")
PY
grep -q 'PASS: ALL FOCUSED TESTS' "$OUT/thumbnail.log"
echo 'PASS: performance smoke and metadata regression'
