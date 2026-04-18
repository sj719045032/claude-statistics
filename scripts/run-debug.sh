#!/bin/bash
set -euo pipefail

APP_NAME="Claude Statistics"
BUILD_DIR="/tmp/claude-stats-build"
APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}.app"
DEBUG_CODE_SIGN_IDENTITY="${DEBUG_CODE_SIGN_IDENTITY:-Claude Statistics Debug Code Signing}"
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

# 4. Prefer a stable local signing identity for debug builds.
#    Ad-hoc signatures change across rebuilds, which makes Keychain ask for
#    access repeatedly. A stable local identity keeps the app requirement stable.
if security find-identity -v -p codesigning | grep -Fq "\"${DEBUG_CODE_SIGN_IDENTITY}\""; then
  echo "==> Re-signing debug app with ${DEBUG_CODE_SIGN_IDENTITY}..."
  codesign --force --deep --sign "${DEBUG_CODE_SIGN_IDENTITY}" "${APP_PATH}"
else
  echo "==> No stable debug signing identity found; keeping ad-hoc signature."
fi

# 5. Re-register with Launch Services so macOS knows this is the active build
${LSREGISTER} -f -R -trusted "${APP_PATH}"

# 6. Launch directly by binary path (bypasses Launch Services entirely)
echo "==> Launching..."
nohup "${APP_PATH}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
sleep 1

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "==> Done! (PID: $(pgrep -x "${APP_NAME}"))"
else
  echo "==> WARNING: App may not have started"
fi
