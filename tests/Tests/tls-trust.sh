#!/bin/bash
# tls-trust.sh — 证书信任容错专项（第 36 轮）
# 真实生产纯函数/默认 wrapper + Security 边界替身 + 离线真实 SecTrust。
# 无网络、无窗口、无 NSApplication；不读写真实用户偏好/钥匙串。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="${RD_TLS_OUT:-$REPO/build/tls-trust-tests}"
HEADER_DIR="${RD_TLS_HEADER_DIR:-$ROOT/Shared/Infrastructure}"
mkdir -p "$OUT"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

run_command() {
  printf 'COMMAND:'; printf ' %q' "$@"; printf '\n'
  "$@"
}
run_command /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -config "$REPO/tests/fixtures/tls-trust.cnf" \
  -keyout "$OUT/fixture-key.pem" -out "$OUT/fixture.pem" > "$OUT/certificate.log" 2>&1
run_command /usr/bin/openssl x509 -in "$OUT/fixture.pem" -outform DER -out "$OUT/fixture.der" >> "$OUT/certificate.log" 2>&1
for test in TLSTrustTests TLSDefaultPolicyTests TLSRevocationIntegrationTests; do
  if ! run_command xcrun clang -fobjc-arc -fblocks -g -O1 -mmacosx-version-min=13.0 \
    -framework Foundation -framework Security -I"$HEADER_DIR" \
    "$REPO/tests/Tests/$test.m" -o "$OUT/$test" > "$OUT/$test.compile.log" 2>&1; then
    echo "TEST_RESULT stage=compile-$test status=FAIL reason=compiler-exit"; exit 1
  fi
  python3 - "$OUT/$test.compile.log" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); warnings=s.count('warning:')
print('COMPILE_WARNINGS='+str(warnings))
if warnings: print(s); raise SystemExit(1)
PY
  set +e
  RD_TLS_CERT_PATH="$OUT/fixture.der" "$OUT/$test" > "$OUT/$test.run.log" 2>&1
  rc=$?
  set -e
  python3 - "$OUT/$test.run.log" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(),end='')
PY
  echo "RESULT $test exit=$rc"
  if [ "$rc" -ne 0 ]; then echo "TEST_RESULT stage=$test status=FAIL reason=assertion-exit-$rc"; exit 1; fi
  echo "TEST_RESULT stage=$test status=PASS"
done
echo "PASS: TLS 默认严格及隔离信任专项通过"
echo "TEST_RESULT stage=suite status=PASS"
