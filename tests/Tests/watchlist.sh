#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/watchlist-tests"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
printf 'RDWatchlistStore contract tests: %s\n' "$(date -u)"
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
  -framework Foundation \
  -I"$ROOT" -I"$ROOT/Features/ResourceDetector" \
  "$REPO/tests/Tests/WatchlistTests.m" "$ROOT/Features/ResourceDetector/RDWatchlistStore.m" \
  -o "$OUT/WatchlistTests" >"$OUT/compile.log" 2>&1 || { cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1; }
ASAN_OPTIONS=detect_leaks=0 "$OUT/WatchlistTests"
printf 'PASS: watchlist contract tests exited 0\n'
