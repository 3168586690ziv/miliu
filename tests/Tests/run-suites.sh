#!/bin/bash
# run-suites.sh — 在受限沙箱内运行现有测试脚本（去掉 exec > >(tee ...) 这一行，
# 因为沙箱禁止 /dev/fd 进程替换；脚本其余内容一字不改）。
# 用法：bash tests/Tests/run-suites.sh <suite> [suite...]
set -u
if [ "$#" -eq 0 ]; then
  echo "Usage: bash tests/Tests/run-suites.sh <suite> [suite...]" >&2
  exit 2
fi
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$REPO/build/suite-logs"
failed=()
tmp=""
cleanup() { [ -z "$tmp" ] || rm -f -- "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for suite in "$@"; do
  src="$REPO/tests/Tests/$suite.sh"
  if [[ ! "$suite" =~ ^[a-zA-Z0-9_-]+$ ]] || [ ! -f "$src" ]; then
    echo "MISSING $src"
    failed+=("$suite")
    continue
  fi
  tmp="$(mktemp "$REPO/tests/Tests/.sandbox-$suite.XXXXXX")" || { failed+=("$suite"); continue; }
  if ! sed 's|^exec > >(tee .*$|: # sandbox: tee 进程替换已跳过|' "$src" > "$tmp"; then
    failed+=("$suite")
    cleanup; tmp=""
    continue
  fi
  log="$REPO/build/suite-logs/$suite.log"
  start=$(date +%s)
  bash "$tmp" > "$log" 2>&1
  rc=$?
  end=$(date +%s)
  cleanup; tmp=""
  [ "$rc" -eq 0 ] || failed+=("$suite")
  echo "SUITE $suite exit=$rc elapsed=$((end-start))s log=$log"
  grep -E "^(PASS|FAIL|FAILED)|ALL .*TESTS|PASS: ALL" "$log" | tail -4 || true
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED SUITES: ${failed[*]}"
  exit 1
fi
echo "ALL SUITES PASSED"
exit 0
