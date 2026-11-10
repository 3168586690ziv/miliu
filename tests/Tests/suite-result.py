#!/usr/bin/env python3
"""Classify one complete suite log and its actual process exit, fail closed."""
import re
import sys
from pathlib import Path


def classify(text, rc):
    valid = {'PASS', 'FAIL', 'SKIP', 'ENVIRONMENT'}
    stages = {}
    for line in text.splitlines():
        if not line.startswith('TEST_RESULT '):
            continue
        m = re.fullmatch(r'TEST_RESULT stage=([A-Za-z0-9_-]+) status=([A-Z]+)(?: reason=.*)?', line)
        if not m or m[2] not in valid:
            return 'FAIL', 'invalid-result-record'
        if m[1] in stages and stages[m[1]] != m[2]:
            return 'FAIL', 'conflicting-stage-records'
        stages[m[1]] = m[2]
    # NSLog's fixed process/timestamp prefix is a log envelope, not fixture text.
    envelope = r'^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ [^\n\[]+\[\d+:[^\]\n]+\]\s+)?'
    legacy_fail = re.search(envelope + r'(?:FAIL(?:ED)?(?:[: ]|$)|TEST-SUITE-FAILED)', text, re.M)
    if rc not in (0, 77, 78) or legacy_fail or 'FAIL' in stages.values():
        return 'FAIL', f'process-or-assertion-failed-exit-{rc}'
    values = set(stages.values())
    if 'suite' in stages:
        children = set(v for k, v in stages.items() if k != 'suite')
        expected = 'ENVIRONMENT' if 'ENVIRONMENT' in children else ('SKIP' if 'SKIP' in children else 'PASS')
        if children and stages['suite'] != expected:
            return 'FAIL', 'summary-conflicts-with-stages'
    if stages:
        status = 'ENVIRONMENT' if 'ENVIRONMENT' in values else ('SKIP' if 'SKIP' in values else 'PASS')
        if rc != {'PASS': 0, 'SKIP': 77, 'ENVIRONMENT': 78}[status]:
            return 'FAIL', 'result-conflicts-with-exit'
        return status, 'structured-result'
    if rc == 77:
        return 'SKIP', 'explicit-skip-exit'
    if rc == 78:
        return 'ENVIRONMENT', 'environment-exit'
    if re.search(envelope + r'SKIP:', text, re.M):
        return 'SKIP', 'legacy-skip-marker'
    return 'PASS', 'legacy-success-exit'


if __name__ == '__main__':
    status, reason = classify(Path(sys.argv[1]).read_text(errors='replace'), int(sys.argv[2]))
    print(status, reason)
