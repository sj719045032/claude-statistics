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
STABLE_APP_DIR="${HOME}/Applications"
STABLE_APP_PATH="${STABLE_APP_DIR}/${DEBUG_APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE_DEBUG_CODE_SIGN_SCRIPT="${SCRIPT_DIR}/ensure-debug-codesign.sh"

# 0. Pin SDK references at the locally-built xcframework so any
# catalog plugin you `dev-install.sh` afterwards links the in-progress
# SDK source you're iterating on. Idempotent — sdk-mode.sh checks the
# current marker block and only rewrites when the mode actually changes,
# so this stays a no-op for `bash run-debug.sh` runs that follow another
# `bash run-debug.sh`. The `release.sh` flow flips the modes back to
# published before its commit step.
bash "${SCRIPT_DIR}/sdk-mode.sh" local >/dev/null

# 1. Kill both the previous Debug instance and the Release instance. lsregister
# -trusted can cause backgroundd to re-evaluate SMAppService registrations and
# restart the Release build if it was previously running. Stopping it here keeps
# the development environment clean and avoids the two builds racing over shared
# resources (hooks, status-line config, usage cache).
echo "==> Killing old instances..."
killall "${DEBUG_APP_NAME}" 2>/dev/null || true
killall "${APP_NAME}" 2>/dev/null || true
while pgrep -x "${DEBUG_APP_NAME}" >/dev/null 2>&1 || pgrep -x "${APP_NAME}" >/dev/null 2>&1; do sleep 0.2; done

# 1b. Remove stale hook-bridge socket + pid files. The app's
# `AttentionBridge.stop()` is supposed to unlink them on terminate, but a
# SIGKILL'd or crashed instance never runs that cleanup, leaving an orphan
# `attention.sock` on disk. The next bind() retry path can recover by
# unlinking + rebinding (see `AttentionBridge.startListening`), but during
# the rebuild window EVERY hook fired by a running CLI hits the orphan
# socket and gets ECONNREFUSED instead of ENOENT — appearing to the user
# as "frequent socket disconnects". Removing the files here closes that
# window: hooks during the build see ENOENT (still buffered to pending,
# but with no misleading "connection refused" log noise) and the next
# launch's bind() succeeds on first try.
rm -f "${HOME}/.claude-statistics-debug/run/attention.sock" \
      "${HOME}/.claude-statistics-debug/run/attention.pid" 2>/dev/null || true

# 2. Clean up any stale DerivedData builds to avoid bundle ID conflicts
echo "==> Cleaning stale builds..."
find ~/Library/Developer/Xcode/DerivedData -path "*/Debug/${APP_NAME}.app" -type d -exec rm -rf {} + 2>/dev/null || true

# 3. Regenerate the Xcode project so newly-added Swift files under
#    `ClaudeStatistics/` are picked up automatically by the XcodeGen source
#    directory rules. The checked-in `.xcodeproj` is still a generated static
#    file list, so xcodebuild itself won't notice new files until this runs.
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> Regenerating Xcode project..."
  xcodegen generate >/dev/null
else
  echo "==> WARNING: xcodegen not found; new source files may be missing from the project"
fi

# 4. Build — override bundle ID so Debug has its own TCC slot in System Settings.
# Full xcodebuild output goes to a log file; on failure we grep out
# error/warning lines so the caller sees what actually broke without having
# to re-run xcodebuild by hand. `-quiet` is dropped (the log file keeps noise
# off the terminal, and swallowing it in -quiet mode hides the error context).
echo "==> Building debug (bundle id: ${DEBUG_BUNDLE_ID})..."
mkdir -p "${BUILD_DIR}"
BUILD_LOG="${BUILD_DIR}/xcodebuild.log"
if ! xcodebuild build \
    -scheme ClaudeStatistics \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    PRODUCT_BUNDLE_IDENTIFIER="${DEBUG_BUNDLE_ID}" \
    >"${BUILD_LOG}" 2>&1; then
  echo "==> BUILD FAILED — compile errors:"
  echo "----------------------------------------"
  grep -E "error:|warning:" "${BUILD_LOG}" | head -60 || true
  echo "----------------------------------------"
  echo "==> Full log: ${BUILD_LOG}"
  exit 1
fi

# Surface the xcodebuild summary tail on success too (destination warnings etc.)
tail -4 "${BUILD_LOG}"

if [ ! -d "${BUILT_APP_PATH}" ]; then
  echo "ERROR: Build succeeded but ${BUILT_APP_PATH} not found (unexpected)"
  exit 1
fi

echo "** BUILD SUCCEEDED **"

# 5. Rename the bundle folder so System Settings labels it differently from
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

# 6. Re-sign after all bundle/executable renames so the final app keeps a
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

ENTITLEMENTS_PATH="${SCRIPT_DIR}/../ClaudeStatistics/App/ClaudeStatistics.entitlements"
if /usr/bin/security find-identity -v -p codesigning | grep -Fq "\"${DEBUG_CODE_SIGN_IDENTITY}\""; then
  echo "==> Re-signing debug app with ${DEBUG_CODE_SIGN_IDENTITY}..."
  codesign --force --deep --sign "${DEBUG_CODE_SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS_PATH}" "${APP_PATH}"
else
  echo "==> Stable debug signing identity not found; falling back to ad-hoc signing..."
  codesign --force --deep --sign - --entitlements "${ENTITLEMENTS_PATH}" "${APP_PATH}"
fi

# 7. Copy to ~/Applications for stable TCC registration. Apps in /tmp are not
# treated as persistent by macOS and won't appear in System Settings →
# Accessibility. Copying to ~/Applications gives TCC a stable bundle path.
echo "==> Installing to ${STABLE_APP_PATH}..."
mkdir -p "${STABLE_APP_DIR}"
rm -rf "${STABLE_APP_PATH}"
cp -R "${APP_PATH}" "${STABLE_APP_PATH}"

# 8. Re-register with Launch Services. Unregister both the pre-rename path and
# the /tmp path, then register the stable ~/Applications path so the TCC UI
# can resolve the bundle.
${LSREGISTER} -u "${BUILT_APP_PATH}" 2>/dev/null || true
${LSREGISTER} -u "${APP_PATH}" 2>/dev/null || true
${LSREGISTER} -f -R "${STABLE_APP_PATH}"

# 9. Keep the one-shot accessibility prompt one-shot. The app only shows the
# AXIsProcessTrustedWithOptions dialog if this key is absent AND the app is
# not yet trusted. Older versions of this script deleted the key on every run,
# which made automated debug/test/perf loops repeatedly show the Accessibility
# dialog. Force a fresh prompt only when explicitly requested.
if [[ "${FORCE_DEBUG_ACCESSIBILITY_PROMPT:-0}" == "1" ]]; then
  defaults delete "${DEBUG_BUNDLE_ID}" "debug.accessibility.promptShown" 2>/dev/null || true
fi

# 10. Final kill + launch of Debug only.
killall "${DEBUG_APP_NAME}" 2>/dev/null || true
while pgrep -x "${DEBUG_APP_NAME}" >/dev/null 2>&1; do sleep 0.2; done

#    Using `open <path-to-app>` keeps us pinned to this debug build (unlike
#    `open -a`) while attaching the launch to the user's GUI session more
#    reliably than spawning the binary directly from headless environments.
echo "==> Launching..."
if ! open -n "${STABLE_APP_PATH}"; then
  echo "==> open failed, falling back to direct binary launch..."
  nohup "${STABLE_APP_PATH}/Contents/MacOS/${DEBUG_APP_NAME}" >/dev/null 2>&1 &
fi
sleep 2

if pgrep -x "${DEBUG_APP_NAME}" >/dev/null 2>&1; then
  echo "==> Done! (PID: $(pgrep -x "${DEBUG_APP_NAME}"))"
else
  echo "==> WARNING: App may not have started"
fi
