#!/bin/bash
# Serial runner. --strict rejects incomplete requested suites; normal mode reports them.
# Structured contract: TEST_RESULT stage=<name> status=PASS|FAIL|SKIP|ENVIRONMENT reason=...
# Suite exits: 0 complete, 1 failure, 77 skipped, 78 environment unavailable.
set -u
strict=0
if [ "${1:-}" = "--strict" ]; then strict=1; shift; fi
if [ "$#" -eq 0 ]; then
  echo "Usage: bash tests/Tests/run-suites.sh [--strict] <suite> [suite...]" >&2
  exit 2
fi
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$REPO/build/suite-logs" || exit 1
RUN_DIR="$(mktemp -d "$REPO/build/suite-logs/run.XXXXXX")" || exit 1
failed=0; incomplete=0; passed=0; tmp=""; ordinal=0
cleanup() {
  # mktemp below is restricted to this exact repository directory.
  case "$tmp" in "$REPO"/tests/Tests/.sandbox-*) [ ! -f "$tmp" ] || rm -f -- "$tmp" ;; esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for suite in "$@"; do
  src="$REPO/tests/Tests/$suite.sh"
  if [[ ! "$suite" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "SUITE invalid-name status=FAIL exit=2 reason=invalid-suite-name"; failed=$((failed+1)); continue
  fi
  ordinal=$((ordinal+1))
  log="$RUN_DIR/$ordinal-$suite.log"
  if [ ! -f "$src" ]; then
    printf 'FAIL: MISSING %s\n' "$src" > "$log"
    echo "SUITE $suite status=FAIL exit=1 reason=missing-script log=$log"; failed=$((failed+1)); continue
  fi
  tmp="$(mktemp "$REPO/tests/Tests/.sandbox-$suite.XXXXXX")" || { failed=$((failed+1)); continue; }
  # Preserve legacy path resolution while removing only unsupported process-substitution logging.
  if ! sed 's|^exec > >(tee .*$|: # runner owns complete log|' "$src" > "$tmp"; then
    failed=$((failed+1)); cleanup; tmp=""; continue
  fi
  start=$(date +%s)
  bash "$tmp" > "$log" 2>&1
  rc=$?
  end=$(date +%s)
  cleanup; tmp=""
  # Keep a latest alias for older callers; original invocation logs are never overwritten.
  cp "$log" "$REPO/build/suite-logs/$suite.log" || { failed=$((failed+1)); continue; }
  result=$(python3 "$REPO/tests/Tests/suite-result.py" "$log" "$rc") || result="FAIL classifier-error"
  status=${result%% *}; reason=${result#* }
  case "$status" in
    PASS) passed=$((passed+1)) ;;
    SKIP|ENVIRONMENT) incomplete=$((incomplete+1)) ;;
    *) status=FAIL; failed=$((failed+1)) ;;
  esac
  echo "SUITE $suite status=$status exit=$rc elapsed=$((end-start))s reason=$reason log=$log"
done
echo "SUITE_SUMMARY passed=$passed failed=$failed incomplete=$incomplete strict=$strict"
if [ "$incomplete" -gt 0 ]; then echo "COMPLETED_WITH_SKIPS"; fi
if [ "$failed" -gt 0 ]; then echo "FAILED SUITES: $failed"; exit 1; fi
if [ "$incomplete" -gt 0 ]; then [ "$strict" -eq 0 ] && exit 0; exit 1; fi
echo "ALL SUITES PASSED"
exit 0
