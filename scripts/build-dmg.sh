#!/bin/bash
set -euo pipefail

APP_NAME="Claude Statistics"
SCHEME="ClaudeStatistics"
BUILD_DIR="build/release"
DMG_DIR="build/dmg"
DMG_NAME="ClaudeStatistics"

# Get version from Info.plist or default
VERSION="${1:-1.0.0}"

echo "==> Building ${APP_NAME} v${VERSION} (Release)..."
xcodebuild -project ClaudeStatistics.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  clean build \
  CONFIGURATION_BUILD_DIR="${PWD}/${BUILD_DIR}" \
  2>&1 | tail -5

APP_PATH="${BUILD_DIR}/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "ERROR: Build failed, ${APP_PATH} not found"
  exit 1
fi

echo "==> Removing quarantine attribute..."
xattr -cr "${APP_PATH}"

echo "==> Preparing DMG contents..."
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

echo "==> Creating DMG..."
DMG_OUTPUT="build/${DMG_NAME}-${VERSION}.dmg"
rm -f "${DMG_OUTPUT}"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_OUTPUT}"

rm -rf "${DMG_DIR}"

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | cut -f1 | xargs)
echo ""
echo "==> Done! DMG created:"
echo "    ${DMG_OUTPUT} (${DMG_SIZE})"
echo ""
echo "Note: This DMG is not signed/notarized."
echo "Users need to run: xattr -cr /Applications/${APP_NAME}.app"
echo "Or: Right-click -> Open -> Open (first launch only)"
