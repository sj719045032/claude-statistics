#!/bin/bash
set -euo pipefail

APP_NAME="Claude Statistics"
DEBUG_APP_NAME="Claude Statistics Debug"
BUILD_DIR="/tmp/claude-stats-build"
# Xcode always writes the bundle using PRODUCT_NAME → "${APP_NAME}.app". We
# rename it after the build so System Settings → Accessibility (which labels
# entries by bundle folder name, not CFBundleDisplayName) shows "Claude
# Statistics Debug" distinct from the installed Release "Claude Statistics".
BUILT_APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}.app"
APP_PATH="${BUILD_DIR}/Build/Products/Debug/${DEBUG_APP_NAME}.app"
DEBUG_CODE_SIGN_IDENTITY="${DEBUG_CODE_SIGN_IDENTITY:-Claude Statistics Debug Code Signing}"
# Distinct bundle ID for debug so macOS TCC (Accessibility, Screen Recording,
# etc.) records grants separately from the installed Release build. Otherwise
# Release's authorization shadows Debug in the Settings UI even though CGEventTap
# creation keeps failing for the Debug signature.
DEBUG_BUNDLE_ID="${DEBUG_BUNDLE_ID:-com.tinystone.ClaudeStatistics.debug}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# 1. Kill all running instances and wait for full exit
echo "==> Killing old instances..."
killall "${APP_NAME}" 2>/dev/null || true
while pgrep -x "${APP_NAME}" >/dev/null 2>&1; do sleep 0.2; done

# 2. Clean up any stale DerivedData builds to avoid bundle ID conflicts
echo "==> Cleaning stale builds..."
find ~/Library/Developer/Xcode/DerivedData -path "*/Debug/${APP_NAME}.app" -type d -exec rm -rf {} + 2>/dev/null || true

# 3. Build — override bundle ID so Debug has its own TCC slot in System Settings.
echo "==> Building debug (bundle id: ${DEBUG_BUNDLE_ID})..."
xcodebuild build \
  -scheme ClaudeStatistics \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  PRODUCT_BUNDLE_IDENTIFIER="${DEBUG_BUNDLE_ID}" \
  -quiet 2>&1 | tail -3

if [ ! -d "${BUILT_APP_PATH}" ]; then
  echo "ERROR: Build failed, ${BUILT_APP_PATH} not found"
  exit 1
fi

echo "** BUILD SUCCEEDED **"

# 4. Rename the bundle folder so System Settings labels it differently from
#    the installed Release build. Also tag CFBundleDisplayName for Finder/
#    Dock consistency. Bundle path references below use ${APP_PATH}.
rm -rf "${APP_PATH}"
mv "${BUILT_APP_PATH}" "${APP_PATH}"
PLIST="${APP_PATH}/Contents/Info.plist"
# CFBundleName is what System Settings → Privacy & Security groups entries
# by. If we leave it at "Claude Statistics", the TCC UI merges Debug and
# Release under one row. Overriding it alongside CFBundleDisplayName keeps
# the two builds distinct in every Apple-provided UI.
for key in CFBundleName CFBundleDisplayName; do
  /usr/libexec/PlistBuddy -c "Set :${key} ${DEBUG_APP_NAME}" "${PLIST}" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :${key} string ${DEBUG_APP_NAME}" "${PLIST}"
done

# 5. Prefer a stable local signing identity for debug builds.
#    Ad-hoc signatures change across rebuilds, which makes Keychain ask for
#    access repeatedly. A stable local identity keeps the app requirement stable.
#    Must run after the Info.plist edit so the signature covers the new value.
if security find-identity -v -p codesigning | grep -Fq "\"${DEBUG_CODE_SIGN_IDENTITY}\""; then
  echo "==> Re-signing debug app with ${DEBUG_CODE_SIGN_IDENTITY}..."
  codesign --force --deep --sign "${DEBUG_CODE_SIGN_IDENTITY}" "${APP_PATH}"
else
  echo "==> No stable debug signing identity found; keeping ad-hoc signature."
fi

# 5. Re-register with Launch Services so macOS knows this is the active build
${LSREGISTER} -f -R -trusted "${APP_PATH}"

# 6. Launch the exact built app bundle.
#    Using `open <path-to-app>` keeps us pinned to this debug build (unlike
#    `open -a`) while attaching the launch to the user's GUI session more
#    reliably than spawning the binary directly from headless environments.
echo "==> Launching..."
if ! open -n "${APP_PATH}"; then
  echo "==> open failed, falling back to direct binary launch..."
  nohup "${APP_PATH}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
fi
sleep 2

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "==> Done! (PID: $(pgrep -x "${APP_NAME}"))"
else
  echo "==> WARNING: App may not have started"
fi
