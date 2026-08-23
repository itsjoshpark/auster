#!/bin/bash
#
# test.sh — run the AusterCore test suite, then build the app.
#
# The engine lives in AusterCore and carries the bulk of the coverage, so it
# runs first: a failure there should not wait on an app build.
#
# Integration tests (Phase 9) additionally need AUSTER_INTEGRATION=1 in the
# environment; without it they skip.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Testing AusterCore"
swift test --package-path AusterCore

echo "==> Building Auster.app"
xcodebuild build \
    -project Auster.xcodeproj \
    -scheme Auster \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

echo "==> All checks passed"
