#!/usr/bin/env python3
"""Exercise the real runner in an isolated mini-repository, never real suites."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent
checks = failures = 0

def check(ok, name):
    global checks, failures
    checks += 1
    failures += not ok
    print(('PASS: ' if ok else 'FAIL: ') + name, flush=True)

with tempfile.TemporaryDirectory(prefix='miliu-runner-') as td:
    root = Path(td)
    tests = root / 'tests/Tests'
    tests.mkdir(parents=True)
    for name in ('run-suites.sh', 'suite-result.py'):
        if (SOURCE / name).exists():
            shutil.copy2(SOURCE / name, tests / name)
    fixtures = {
        'pass': 'echo "TEST_RESULT stage=suite status=PASS reason=complete"; exit 0',
        'legacy': 'echo "PASS: legacy"; exit 0',
        'fail': 'echo "FAIL: actual assertion"; exit 1',
        'skip': 'echo "TEST_RESULT stage=suite status=SKIP reason=not-selected"; exit 77',
        'env': 'echo "TEST_RESULT stage=suite status=ENVIRONMENT reason=missing-codec"; exit 78',
        'mixed': 'echo "TEST_RESULT stage=logic status=PASS"; echo "TEST_RESULT stage=e2e status=ENVIRONMENT"; exit 78',
        'oldskip': 'echo "SKIP: old optional stage"; echo "PASS: other stage"; exit 0',
        'noise': 'echo "fixture text contains SKIP: not a result"; exit 0',
        'timedskip': 'echo "2026-11-10 01:00:00.001 Fixture[123:456] SKIP: real E2E disabled"; exit 0',
        'timedfail': 'echo "2026-11-10 01:00:00.001 Fixture[123:456] FAIL: assertion"; exit 0',
        'conflict': 'echo "TEST_RESULT stage=suite status=PASS"; echo "TEST_RESULT stage=suite status=SKIP"; exit 0',
        'hiddenfail': 'echo "FAIL: compile error"; echo "SKIP: missing dependency"; exit 0',
        'unknown': 'echo "SKIP: cannot hide exit 9"; exit 9',
        'signal': 'kill -TERM $$',
        'badstate': 'echo "TEST_RESULT stage=suite status=PERHAPS"; exit 0',
        'badline': 'echo "TEST_RESULT malformed"; exit 0',
        'rcconflict': 'echo "TEST_RESULT stage=suite status=PASS"; exit 78',
        'zeroconflict': 'echo "TEST_RESULT stage=suite status=ENVIRONMENT"; exit 0',
        'summaryconflict': 'echo "TEST_RESULT stage=e2e status=SKIP"; echo "TEST_RESULT stage=suite status=PASS"; exit 77',
    }
    for name, body in fixtures.items():
        (tests / (name + '.sh')).write_text('#!/bin/bash\n' + body + '\n')
    cases = [('pass', 'PASS', 0), ('legacy', 'PASS', 0), ('fail', 'FAIL', 1),
             ('skip', 'SKIP', 0), ('env', 'ENVIRONMENT', 0), ('mixed', 'ENVIRONMENT', 0),
             ('oldskip', 'SKIP', 0), ('noise', 'PASS', 0), ('timedskip', 'SKIP', 0),
             ('timedfail', 'FAIL', 1), ('conflict', 'FAIL', 1),
             ('hiddenfail', 'FAIL', 1), ('unknown', 'FAIL', 1), ('signal', 'FAIL', 1),
             ('badstate', 'FAIL', 1), ('badline', 'FAIL', 1), ('rcconflict', 'FAIL', 1),
             ('zeroconflict', 'FAIL', 1), ('summaryconflict', 'FAIL', 1), ('missing', 'FAIL', 1)]
    for strict in (False, True):
        for name, status, normal_rc in cases:
            args = ['bash', str(tests / 'run-suites.sh')]
            if strict:
                args.append('--strict')
            p = subprocess.run(args + [name], capture_output=True, text=True)
            label = f'{name} strict={strict}'
            expected = 1 if strict and status != 'PASS' else normal_rc
            check(p.returncode == expected, f'{label} exit={p.returncode} expected={expected}')
            check(f'status={status}' in p.stdout, f'{label} status={status}')
            check(('ALL SUITES PASSED' in p.stdout) == (status == 'PASS'), f'{label} no false all-pass')
            if status in ('SKIP', 'ENVIRONMENT'):
                check('COMPLETED_WITH_SKIPS' in p.stdout, f'{label} incomplete summary')
    p = subprocess.run(['bash', str(tests/'run-suites.sh'), 'fail', 'pass'], capture_output=True, text=True)
    check(p.returncode == 1, 'mixed failure remains failed')
    check('SUITE pass' in p.stdout, 'failure does not stop next suite')
    check((root/'build/suite-logs/pass.log').read_text().find('complete') >= 0, 'later complete log retained')
    p = subprocess.run(['bash', str(tests/'run-suites.sh'), 'pass', 'env', 'skip'], capture_output=True, text=True)
    check(p.returncode == 0 and 'COMPLETED_WITH_SKIPS' in p.stdout and 'ALL SUITES PASSED' not in p.stdout,
          'mixed pass/skip/environment accurately incomplete')
    old_runs = set((root/'build/suite-logs').glob('run.*'))
    p = subprocess.run(['bash', str(tests/'run-suites.sh'), 'pass', 'pass'], capture_output=True, text=True)
    new_runs = set((root/'build/suite-logs').glob('run.*')) - old_runs
    check(p.returncode == 0 and len(new_runs) == 1, 'each invocation has unique log directory')
    check(len(list(next(iter(new_runs)).glob('*-pass.log'))) == 2 if new_runs else False,
          'duplicate requested suite keeps both complete logs')
print(f'SUITE-RUNNER checks={checks} failed={failures}', flush=True)
raise SystemExit(1 if failures else 0)
