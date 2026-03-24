#!/bin/bash
set -euo pipefail

APP_NAME="Claude Statistics"
BUILD_DIR="/tmp/claude-stats-build"
APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# 1. Kill all running instances and wait for full exit
echo "==> Killing old instances..."
killall "${APP_NAME}" 2>/dev/null || true
while pgrep -x "${APP_NAME}" >/dev/null 2>&1; do sleep 0.2; done

# 2. Clean up any stale DerivedData builds to avoid bundle ID conflicts
echo "==> Cleaning stale builds..."
find ~/Library/Developer/Xcode/DerivedData -path "*/Debug/${APP_NAME}.app" -type d -exec rm -rf {} + 2>/dev/null || true

# 3. Build
echo "==> Building debug..."
xcodebuild build \
  -scheme ClaudeStatistics \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  -quiet 2>&1 | tail -3

if [ ! -d "${APP_PATH}" ]; then
  echo "ERROR: Build failed, ${APP_PATH} not found"
  exit 1
fi

echo "** BUILD SUCCEEDED **"

# 4. Re-register with Launch Services so macOS knows this is the active build
${LSREGISTER} -f -R -trusted "${APP_PATH}"

# 5. Launch
echo "==> Launching..."
open "${APP_PATH}"

echo "==> Done!"
