#!/bin/bash
# Pure build-script selection regression; no actual keychain or codesign calls.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$REPO/tests/Tests/BuildSigningFallbackTests.py" "$@"
echo 'TEST_RESULT stage=build-signing-fallback status=PASS reason=isolated-production-script-fragment'
