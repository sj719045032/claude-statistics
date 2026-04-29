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

# Update version in project.yml so xcodegen-generated project picks it up
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${VERSION}\"/" project.yml

# Regenerate Xcode project with updated version
if command -v xcodegen &>/dev/null; then
  xcodegen generate 2>&1 | tail -1
fi

echo "==> Building ${APP_NAME} v${VERSION} (Release)..."
xcodebuild -project ClaudeStatistics.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  clean build \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${VERSION}" \
  2>&1 | tail -5

APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

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

# Create ZIP for Sparkle auto-update (Sparkle handles ZIP natively, DMG has mount issues)
echo "==> Creating ZIP for Sparkle..."
ZIP_OUTPUT="build/${DMG_NAME}-${VERSION}.zip"
rm -f "${ZIP_OUTPUT}"
cd "${BUILD_DIR}/Build/Products/Release"
ditto -c -k --keepParent "${APP_NAME}.app" "${OLDPWD}/${ZIP_OUTPUT}"
cd "${OLDPWD}"

# Pack every standalone .csplugin produced by this Release build into
# `build/marketplace/<Name>.csplugin.zip` + sidecar `<Name>.sha256`.
# These are the artifacts the marketplace catalog points at — they
# need to be uploaded to the same GitHub release so users can install
# plugins from Settings → Plugins → Discover. Wiping the dir first
# keeps stale zips from previous releases out of the upload list.
echo "==> Packing .csplugin marketplace artifacts..."
MARKETPLACE_DIR="build/marketplace"
mkdir -p "${MARKETPLACE_DIR}"
rm -f "${MARKETPLACE_DIR}"/*.csplugin.zip "${MARKETPLACE_DIR}"/*.sha256
RELEASE_PRODUCTS="${BUILD_DIR}/Build/Products/Release"
PACKED_COUNT=0
for csplugin in "${RELEASE_PRODUCTS}"/*.csplugin; do
    [ -d "${csplugin}" ] || continue
    name="$(basename "${csplugin}" .csplugin)"
    bash scripts/pack-csplugin.sh "${name}" "${RELEASE_PRODUCTS}" >/dev/null
    PACKED_COUNT=$((PACKED_COUNT + 1))
done
echo "    Packed ${PACKED_COUNT} .csplugin bundles → ${MARKETPLACE_DIR}/"

# Clean up intermediate build to avoid duplicate app registrations
rm -rf "${BUILD_DIR}"

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | cut -f1 | xargs)
ZIP_SIZE=$(du -h "${ZIP_OUTPUT}" | cut -f1 | xargs)

ARCHIVE_DIR="build/releases-archive"
mkdir -p "${ARCHIVE_DIR}"

# Snapshot delta files that existed before this run so we only upload
# the ones freshly produced for v${VERSION}.
BEFORE_DELTAS=$(mktemp)
find "${ARCHIVE_DIR}" -maxdepth 1 -name "*.delta" 2>/dev/null | sort > "${BEFORE_DELTAS}"

# Copy the new ZIP into the archive so generate_appcast can diff against
# earlier versions sitting there. (Historical ZIPs stay in this directory —
# don't delete them; that's what powers the deltas.)
cp "${ZIP_OUTPUT}" "${ARCHIVE_DIR}/"

echo "==> Generating appcast.xml (with Sparkle deltas)..."
DOWNLOAD_URL_PREFIX="${REPO_URL}/releases/download/v${VERSION}/"
"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
  --maximum-deltas 3 \
  --maximum-versions 3 \
  --link "${REPO_URL}" \
  "${ARCHIVE_DIR}"

# Rename generated deltas so they don't contain spaces — GitHub's release
# upload silently rewrites spaces to dots in the stored asset name, which
# would break the appcast URL (which generate_appcast encoded as %20).
# Doing the rename here keeps filenames aligned end-to-end.
AFTER_DELTAS_RAW=$(mktemp)
find "${ARCHIVE_DIR}" -maxdepth 1 -name "*.delta" 2>/dev/null | sort > "${AFTER_DELTAS_RAW}"
while IFS= read -r d; do
  [ -z "$d" ] && continue
  case "$d" in *" "*)
    new="$(echo "$d" | tr ' ' '.')"
    if [ ! -e "$new" ]; then
      mv "$d" "$new"
    fi
    ;;
  esac
done <"${AFTER_DELTAS_RAW}"
rm -f "${AFTER_DELTAS_RAW}"

# Patch the appcast's delta URLs to match the renamed files.
# `generate_appcast` percent-encodes spaces to %20; rewrite those to dots.
sed -i '' -E 's/Claude%20Statistics([0-9A-Za-z.-]*\.delta)/Claude.Statistics\1/g' \
  "${ARCHIVE_DIR}/appcast.xml"

# The generated appcast lives inside the archive dir — copy it to repo root
# where Sparkle's SUFeedURL points.
cp "${ARCHIVE_DIR}/appcast.xml" appcast.xml

# Collect only the delta files produced in this run.
AFTER_DELTAS=$(mktemp)
find "${ARCHIVE_DIR}" -maxdepth 1 -name "*.delta" 2>/dev/null | sort > "${AFTER_DELTAS}"
NEW_DELTAS=$(comm -13 "${BEFORE_DELTAS}" "${AFTER_DELTAS}")
rm -f "${BEFORE_DELTAS}" "${AFTER_DELTAS}"

DELTA_COUNT=0
DELTA_TOTAL_BYTES=0
if [ -n "${NEW_DELTAS}" ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    DELTA_COUNT=$((DELTA_COUNT + 1))
    size=$(stat -f%z "$d")
    DELTA_TOTAL_BYTES=$((DELTA_TOTAL_BYTES + size))
  done <<<"${NEW_DELTAS}"
fi

echo ""
echo "==> Done!"
echo "    DMG:    ${DMG_OUTPUT} (${DMG_SIZE})"
echo "    ZIP:    ${ZIP_OUTPUT} (${ZIP_SIZE}) — full update"
if [ "${DELTA_COUNT}" -gt 0 ]; then
  DELTA_HUMAN=$(du -h -I "${ARCHIVE_DIR}"/*.delta 2>/dev/null | awk '{s+=$1"M"} END{print s}' || echo "${DELTA_TOTAL_BYTES} bytes")
  echo "    Deltas: ${DELTA_COUNT} file(s) in ${ARCHIVE_DIR}/ — incremental updates"
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    sz=$(du -h "$d" | cut -f1 | xargs)
    echo "            - $(basename "$d") (${sz})"
  done <<<"${NEW_DELTAS}"
else
  echo "    Deltas: none (archive had no prior versions to diff against)"
fi
if [ "${PACKED_COUNT}" -gt 0 ]; then
  echo "    Plugins: ${PACKED_COUNT} .csplugin.zip in ${MARKETPLACE_DIR}/ — marketplace artifacts"
fi

echo ""
echo "==> appcast.xml updated with v${VERSION}"
echo ""

# Build the gh release upload file list. Marketplace .csplugin.zip
# files are added so a single GitHub release v<version> carries both
# the app delta updates and every plugin's installable bundle.
UPLOAD_ARGS="${DMG_OUTPUT} ${ZIP_OUTPUT}"
while IFS= read -r d; do
  [ -z "$d" ] && continue
  UPLOAD_ARGS="${UPLOAD_ARGS} \"${d}\""
done <<<"${NEW_DELTAS}"
for plugin_zip in "${MARKETPLACE_DIR}"/*.csplugin.zip; do
  [ -f "${plugin_zip}" ] || continue
  UPLOAD_ARGS="${UPLOAD_ARGS} \"${plugin_zip}\""
done

echo "Next steps:"
echo "  1. git add appcast.xml && git commit && git push"
echo "  2. gh release create v${VERSION} ${UPLOAD_ARGS} --title 'v${VERSION}'"
echo ""
echo "Note: This DMG is not signed/notarized by Apple."
echo "Users need to run: xattr -cr /Applications/${APP_NAME}.app"
echo ""
echo "Archive dir (${ARCHIVE_DIR}/) keeps historical ZIPs for delta generation."
echo "Keep at least the last couple of versions there; generate_appcast will"
echo "auto-prune beyond --maximum-versions and move extras to old_updates/."
