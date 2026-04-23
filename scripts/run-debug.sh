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
ENSURE_DEBUG_CODE_SIGN_IDENTITY="${ENSURE_DEBUG_CODE_SIGN_IDENTITY:-1}"
# Distinct bundle ID for debug so macOS TCC (Accessibility, Screen Recording,
# etc.) records grants separately from the installed Release build. Otherwise
# Release's authorization shadows Debug in the Settings UI even though CGEventTap
# creation keeps failing for the Debug signature.
DEBUG_BUNDLE_ID="${DEBUG_BUNDLE_ID:-com.tinystone.ClaudeStatistics.debug}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE_DEBUG_CODE_SIGN_SCRIPT="${SCRIPT_DIR}/ensure-debug-codesign.sh"

# 1. Kill only the previous Debug instance. Release is a separate app now and
# should be allowed to coexist; touching it here makes diagnosis harder and can
# provoke system-level relaunch behavior we don't want during local testing.
echo "==> Killing old instances..."
killall "${DEBUG_APP_NAME}" 2>/dev/null || true
while pgrep -x "${DEBUG_APP_NAME}" >/dev/null 2>&1; do sleep 0.2; done

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

# Also rename the executable. TCC identifies apps by (bundle id, executable
# path), so if Debug and Release both ship a binary literally named
# "Claude Statistics", macOS deduplicates them in the Accessibility list and
# Debug silently never appears. Giving it a distinct filename fixes that.
if [ -f "${APP_PATH}/Contents/MacOS/${APP_NAME}" ] && [ ! -f "${APP_PATH}/Contents/MacOS/${DEBUG_APP_NAME}" ]; then
  mv "${APP_PATH}/Contents/MacOS/${APP_NAME}" "${APP_PATH}/Contents/MacOS/${DEBUG_APP_NAME}"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${DEBUG_APP_NAME}" "${PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${DEBUG_APP_NAME}" "${PLIST}"

# 5. Re-sign after all bundle/executable renames so the final app keeps a
# stable designated requirement. That lets Debug reuse the same local TCC /
# Keychain identity across rebuilds instead of looking like a fresh ad-hoc app
# every time. If the named local identity is missing, fall back to ad-hoc so
# debug runs still work on a fresh machine.
if [[ "${ENSURE_DEBUG_CODE_SIGN_IDENTITY}" == "1" ]] && \
   ! /usr/bin/security find-identity -v -p codesigning | grep -Fq "\"${DEBUG_CODE_SIGN_IDENTITY}\"" && \
   [[ -x "${ENSURE_DEBUG_CODE_SIGN_SCRIPT}" ]]; then
  echo "==> Stable debug signing identity missing; attempting one-time setup..."
  if ! DEBUG_CODE_SIGN_IDENTITY="${DEBUG_CODE_SIGN_IDENTITY}" bash "${ENSURE_DEBUG_CODE_SIGN_SCRIPT}"; then
    echo "==> Debug signing identity setup failed; continuing with ad-hoc fallback..."
  fi
fi

if /usr/bin/security find-identity -v -p codesigning | grep -Fq "\"${DEBUG_CODE_SIGN_IDENTITY}\""; then
  echo "==> Re-signing debug app with ${DEBUG_CODE_SIGN_IDENTITY}..."
  codesign --force --deep --sign "${DEBUG_CODE_SIGN_IDENTITY}" "${APP_PATH}"
else
  echo "==> Stable debug signing identity not found; falling back to ad-hoc signing..."
  codesign --force --deep --sign - "${APP_PATH}"
fi

# 6. Re-register with Launch Services. Xcode first registers the bundle id
# under "Claude Statistics.app" (pre-rename), leaving a stale path entry
# that makes macOS show two identical rows and the TCC list silently
# drop us. Unregister the old path first, then register the Debug path.
${LSREGISTER} -u "${BUILT_APP_PATH}" 2>/dev/null || true
${LSREGISTER} -f -R -trusted "${APP_PATH}"

# 6. Final kill + launch of Debug only.
killall "${DEBUG_APP_NAME}" 2>/dev/null || true
while pgrep -x "${DEBUG_APP_NAME}" >/dev/null 2>&1; do sleep 0.2; done

#    Using `open <path-to-app>` keeps us pinned to this debug build (unlike
#    `open -a`) while attaching the launch to the user's GUI session more
#    reliably than spawning the binary directly from headless environments.
echo "==> Launching..."
if ! open -n "${APP_PATH}"; then
  echo "==> open failed, falling back to direct binary launch..."
  nohup "${APP_PATH}/Contents/MacOS/${DEBUG_APP_NAME}" >/dev/null 2>&1 &
fi
sleep 2

if pgrep -x "${DEBUG_APP_NAME}" >/dev/null 2>&1; then
  echo "==> Done! (PID: $(pgrep -x "${DEBUG_APP_NAME}"))"
else
  echo "==> WARNING: App may not have started"
fi
