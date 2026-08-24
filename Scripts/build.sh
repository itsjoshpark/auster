#!/bin/bash
# build.sh — build AusterCore and the app.
# Usage: Scripts/build.sh [Debug|Release]   (default: Debug)

set -euo pipefail

CONFIGURATION="${1:-Debug}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Building AusterCore ($CONFIGURATION)"
swift build --package-path AusterCore --configuration "$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"

echo "==> Building Auster.app ($CONFIGURATION)"
xcodebuild build \
    -project Auster.xcodeproj \
    -scheme Auster \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

echo "==> Build succeeded"
