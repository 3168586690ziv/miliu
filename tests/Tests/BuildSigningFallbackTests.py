#!/usr/bin/env python3
"""Exercise the real build.sh identity selection under macOS bash/pipefail.

Only security/codesign boundaries are shell functions; no keychain, private key,
App, generated version state or user preferences are touched.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2] / 'scripts/build.sh')
    args = parser.parse_args()
    source = args.source.resolve()
    text = source.read_text()
    start = text.index('SIG_ID="$(security ')
    end = text.index('\n# ── 构建后自检', start)
    fragment = text[start:end]
    cases = [
        ('no-identity', '     0 valid identities found', 0, None),
        ('matching-identity', '  1) TEST_HASH "SevenZZDev"', 0, 'TEST_HASH'),
        ('other-identity', '  1) OTHER_HASH "Unrelated Developer"', 0, None),
        ('query-failure', '', 1, None),
    ]
    rows = []
    for name, identities, security_exit, identity in cases:
        script = '''set -euo pipefail
SRCROOT=/fixture/src
OUT=/fixture/FinalValidation.app
security() {
  [ "$*" = "find-identity -p codesigning -v" ] || return 91
  printf '%s\\n' "$FIXTURE_IDENTITIES"
  return "$FIXTURE_SECURITY_EXIT"
}
codesign() { printf 'ARG:%s\\n' "$@"; }
'''
        env = dict(os.environ, FIXTURE_IDENTITIES=identities, FIXTURE_SECURITY_EXIT=str(security_exit))
        result = subprocess.run(['/bin/bash', '-c', script + fragment], env=env, capture_output=True, text=True)
        expected = ['--force', '--sign', '-', '/fixture/FinalValidation.app']
        if identity:
            expected = ['--force', '--deep', '--options', 'runtime', '--entitlements',
                        '/fixture/src/Packaging/ResourceDetector.entitlements', '--sign', identity,
                        '/fixture/FinalValidation.app']
        actual = [line[4:] for line in result.stdout.splitlines() if line.startswith('ARG:')]
        passed = result.returncode == 0 and actual == expected and not result.stderr
        rows.append(dict(case=name, passed=passed, exit=result.returncode,
                         expected_codesign_arguments=expected, actual_codesign_arguments=actual,
                         stderr=result.stderr))
    failed = sum(not row['passed'] for row in rows)
    print(json.dumps(dict(source=str(source), shell='/bin/bash', checks=len(rows), failed=failed,
                          real_keychain_access=False, results=rows), ensure_ascii=False, indent=2))
    print(f'BUILD-SIGNING-FALLBACK checks={len(rows)} failed={failed}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
