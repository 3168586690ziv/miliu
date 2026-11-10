#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$REPO/tests/Tests/SuiteRunnerTests.py"
echo 'TEST_RESULT stage=suite status=PASS reason=isolated-runner-regression'
