#!/bin/bash
# Isolated production failure classification; no UI, network or preferences.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_FAILURE_OUT:-$REPO/build/failure-precision-tests}"
mkdir -p "$OUT"
printf 'COMMAND: xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -framework Foundation -I%s/src/Features/ResourceDownload %s/tests/Tests/FailureDiagnosisPrecisionTests.m %s/src/Features/ResourceDownload/RDFailureDiagnosis.m -o %s/FailureDiagnosisPrecisionTests\n' "$REPO" "$REPO" "$REPO" "$OUT"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -framework Foundation \
  -I"$REPO/src/Features/ResourceDownload" "$REPO/tests/Tests/FailureDiagnosisPrecisionTests.m" \
  "$REPO/src/Features/ResourceDownload/RDFailureDiagnosis.m" -o "$OUT/FailureDiagnosisPrecisionTests" > "$OUT/compile.log" 2>&1
python3 - "$OUT/compile.log" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
warnings=[x for x in text.splitlines() if 'warning:' in x]
print('COMPILE_WARNINGS='+str(len(warnings)))
for x in warnings: print(x)
sys.exit(bool(warnings))
PY
"$OUT/FailureDiagnosisPrecisionTests"
