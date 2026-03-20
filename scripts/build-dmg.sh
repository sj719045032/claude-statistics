#!/bin/bash
set -euo pipefail

APP_NAME="Claude Statistics"
SCHEME="ClaudeStatistics"
BUILD_DIR="build/release"
DMG_DIR="build/dmg"
DMG_NAME="ClaudeStatistics"
REPO_URL="https://github.com/sj719045032/claude-statistics"

# Get version from argument or default
VERSION="${1:-1.0.0}"

# Find Sparkle tools (downloaded release)
SPARKLE_BIN="/tmp/sparkle/bin"
if [ ! -f "${SPARKLE_BIN}/sign_update" ]; then
  echo "==> Downloading Sparkle tools..."
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz" -o /tmp/sparkle.tar.xz
  mkdir -p /tmp/sparkle
  tar xf /tmp/sparkle.tar.xz -C /tmp/sparkle
fi

echo "==> Building ${APP_NAME} v${VERSION} (Release)..."
xcodebuild -project ClaudeStatistics.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  clean build \
  CONFIGURATION_BUILD_DIR="${PWD}/${BUILD_DIR}" \
  MARKETING_VERSION="${VERSION}" \
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

# Clean up intermediate .app to avoid duplicate registrations in LaunchServices
rm -rf "${BUILD_DIR}"

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | cut -f1 | xargs)

echo "==> Signing DMG for Sparkle..."
# sign_update outputs: sparkle:edSignature="..." length="..."
SIGNATURE=$("${SPARKLE_BIN}/sign_update" "${DMG_OUTPUT}" 2>&1)

echo "==> Generating appcast.xml..."
DOWNLOAD_URL="${REPO_URL}/releases/download/v${VERSION}/${DMG_NAME}-${VERSION}.dmg"
PUB_DATE=$(date -R)

cat > appcast.xml <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>${REPO_URL}</link>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL}"
                 type="application/octet-stream"
                 ${SIGNATURE} />
    </item>
  </channel>
</rss>
APPCAST_EOF

echo ""
echo "==> Done! DMG created:"
echo "    ${DMG_OUTPUT} (${DMG_SIZE})"
echo ""
echo "==> appcast.xml updated with v${VERSION}"
echo ""
echo "Next steps:"
echo "  1. git add appcast.xml && git commit && git push"
echo "  2. gh release create v${VERSION} ${DMG_OUTPUT} --title 'v${VERSION}'"
echo ""
echo "Note: This DMG is not signed/notarized by Apple."
echo "Users need to run: xattr -cr /Applications/${APP_NAME}.app"
