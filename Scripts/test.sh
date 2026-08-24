#!/bin/bash
# test.sh — run the AusterCore test suite, then build the app.
# The integration suite needs AUSTER_INTEGRATION=1 and a credential, and is left
# out of the default run so a machine with no account pays nothing for it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Testing AusterCore"
if [ "${AUSTER_INTEGRATION:-}" = "1" ]; then
    swift test --package-path AusterCore
else
    swift test --package-path AusterCore --skip "IntegrationTests"
fi

echo "==> Building Auster.app"
xcodebuild build \
    -project Auster.xcodeproj \
    -scheme Auster \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

echo "==> All checks passed"
