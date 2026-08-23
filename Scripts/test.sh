#!/bin/bash
#
# test.sh — run the AusterCore test suite, then build the app.
#
# The engine lives in AusterCore and carries the bulk of the coverage, so it
# runs first: a failure there should not wait on an app build.
#
# The integration suite (AusterCoreIntegrationTests) talks to a real Dropbox
# account. It runs only with AUSTER_INTEGRATION=1 *and* a credential —
# AUSTER_TEST_TOKEN, or AUSTER_TEST_REFRESH_TOKEN with AUSTER_APP_KEY — and
# reports as skipped otherwise. It is left out of the default run entirely, so a
# machine with no account never pays for the network round trips.

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
