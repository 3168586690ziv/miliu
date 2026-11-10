#!/bin/bash
# Mutate isolated production-source copies, never the working source or assertions.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RD_MUTATION_OUT:-$REPO/build/stage12-evidence-20261110/mutations}"
mkdir -p "$OUT"
python3 - "$REPO/src/Features/ResourceDetector/RDPreviewController.m" "$OUT" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text(); out=Path(sys.argv[2])
changes={
 'empty-body': ('    _loopbackBody = [body copy];','    _loopbackBody = nil;'),
 'unguarded-master': ('            if (generation != _previewGeneration || _masterContext != context) return;','            (void)generation; // deliberate mutation'),
 'unguarded-kvo': ('    if (generation == _previewGeneration) RDPreviewShowError(message, title);','    RDPreviewShowError(message, title);'),
 'no-stop-cancel': ('    [resolve cancel];\n    [master cancel];','    (void)resolve;\n    (void)master;'),
 'unguarded-loopback-cleanup': ('    if (generation == _previewGeneration) RDPreviewLoopbackStop();','    RDPreviewLoopbackStop();')
}
for name,(old,new) in changes.items():
 assert source.count(old)==1,(name,source.count(old))
 (out/(name+'.m')).write_text(source.replace(old,new))
 print('MUTATION_SOURCE='+str(out/(name+'.m')))
PY
for name in empty-body unguarded-master unguarded-kvo no-stop-cancel unguarded-loopback-cleanup; do
  args=("$REPO/tests/Tests/preview-lifecycle.sh")
  case "$name" in empty-body|unguarded-loopback-cleanup) args+=(--loopback-only);; esac
  printf 'COMMAND: RD_PREVIEW_CONTROLLER_SOURCE=%q RD_LIFECYCLE_OUT=%q bash' "$OUT/$name.m" "$OUT/$name"
  printf ' %q' "${args[@]}"; printf '\n'
  rc=0
  RD_PREVIEW_CONTROLLER_SOURCE="$OUT/$name.m" RD_LIFECYCLE_OUT="$OUT/$name" \
    bash "${args[@]}" > "$OUT/$name.log" 2>&1 || rc=$?
  printf 'MUTATION %s exit=%s expected=1 log=%s\n' "$name" "$rc" "$OUT/$name.log"
  [ "$rc" -eq 1 ]
  python3 - "$OUT/$name.log" "$OUT/$name/compile.log" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text(); compile=Path(sys.argv[2]).read_text()
assert 'error:' not in compile and 'warning:' not in compile,compile
result=re.search(r'PREVIEW-(?:LIFECYCLE|LOOPBACK) checks=\d+ failed=(\d+)',text)
assert result and int(result[1])>0,text
print(result[0]+' COMPILE_WARNINGS=0')
PY
done
printf 'MUTATION_GUARDS_RESULT exit=0 (all five deliberately broken variants detected)\n'
