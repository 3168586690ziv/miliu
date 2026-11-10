#!/bin/bash
# Mutate isolated production source copies; never change workspace source.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_CURL_MUTATION_OUT:-$REPO/build/curl-privacy-mutations}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
python3 - "$REPO" "$OUT" <<'PY'
from pathlib import Path
import sys
repo,out=map(Path,sys.argv[1:])
hopper=(repo/'src/Shared/Infrastructure/RDCurlHopper.m').read_text()
wrapper=(repo/'src/App/RDCurlFallbackBackend.m').read_text()
changes={
 'hopper-auth':(hopper,'if (RDHeadersContainAuthentication(headers ?: @{})) {','if (NO) {'),
 'redirect-sanitize':(hopper,'if (previous) [HTTPPrivacyPolicy sanitizeRedirectRequest:effective fromRequest:previous];','if (previous) { /* mutation: skip redirect sanitizer */ }'),
 'wrapper-marker':(wrapper,'BOOL requiresNative = RDRequestRequiresNativeTransport(request);','BOOL requiresNative = RDHeadersContainAuthentication(request.allHTTPHeaderFields ?: @{});'),
}
for name,(source,old,new) in changes.items():
 assert source.count(old)==1, name
 (out/(name+'.m')).write_text(source.replace(old,new))
print('ISOLATED_MUTATIONS_PREPARED=3')
PY
for name in hopper-auth redirect-sanitize wrapper-marker; do
  export RD_CURL_PRIVACY_OUT="$OUT/$name"
  unset RD_CURL_HOPPER_SOURCE RD_CURL_FALLBACK_SOURCE
  if [ "$name" = wrapper-marker ]; then export RD_CURL_FALLBACK_SOURCE="$OUT/$name.m"
  else export RD_CURL_HOPPER_SOURCE="$OUT/$name.m"; fi
  set +e
  bash "$REPO/tests/Tests/curl-privacy.sh" > "$OUT/$name-command.log" 2>&1
  rc=$?
  set -e
  python3 - "$OUT" "$name" "$rc" <<'PY'
from pathlib import Path
import sys,re
out,name,rc=Path(sys.argv[1]),sys.argv[2],int(sys.argv[3])
log=(out/(name+'-command.log')).read_text()
match=re.search(r'CURL-PRIVACY checks=(\d+) failed=(\d+)',log)
expected={'hopper-auth':'direct hopper refuses','redirect-sanitize':'follows effective previous request','wrapper-marker':'native context'}[name]
if rc!=1 or 'COMPILE exit=0' not in log or 'COMPILE_WARNINGS=0' not in log or not match or int(match[2])==0 or not any('FAIL:' in line and expected in line for line in log.splitlines()):
 print('FAIL: mutation did not behaviorally trip expected assertion:',name,'exit=',rc)
 raise SystemExit(1)
print('MUTATION_CAUGHT name=%s compile=0 warnings=0 run=%d checks=%s failed=%s' % (name,rc,match[1],match[2]))
PY
done
echo 'TEST_RESULT stage=curl-privacy-mutations status=PASS reason=three-behavioral-mutations-caught'
