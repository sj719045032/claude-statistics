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

# Plugin .csplugin bundles are NOT built or packed by this script —
# they live in the catalog repo (claude-statistics-plugins) and ship
# through that repo's own GitHub releases. See PLUGIN_ARCHITECTURE.md
# §1.1 in this repo + the catalog repo's release script.
#
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

# generate_appcast auto-picks a same-basename `.md` next to the ZIP, inlines
# it into `<description>` as CDATA, and stamps `sparkle:format="markdown"`
# so the Sparkle 2.9+ client renders it through the system Markdown parser
# (requires macOS 12+ — this app targets 14.0). Drop the bilingual notes
# (passed by release.sh via env var) in place verbatim; no host-side
# markdown→HTML conversion.
NOTES_FILE="${CLAUDE_STATS_NOTES_FILE:-}"
if [[ -n "${NOTES_FILE}" ]] && [[ -f "${NOTES_FILE}" ]]; then
    echo "==> Embedding release notes from ${NOTES_FILE}..."
    NOTES_MD="${ARCHIVE_DIR}/${DMG_NAME}-${VERSION}.md"
    cp "${NOTES_FILE}" "${NOTES_MD}"
    echo "    Wrote ${NOTES_MD}"
fi

echo "==> Generating appcast.xml (with Sparkle deltas)..."
DOWNLOAD_URL_PREFIX="${REPO_URL}/releases/download/v${VERSION}/"
"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
  --maximum-deltas 3 \
  --maximum-versions 3 \
  --link "${REPO_URL}" \
  --embed-release-notes \
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
echo ""
echo "==> appcast.xml updated with v${VERSION}"
echo ""

# Build the gh release upload file list for the host app release on
# the main repo. Plugin bundles ship through the catalog repo's own
# releases — see catalog repo's `scripts/release-plugins.sh`.
UPLOAD_ARGS="${DMG_OUTPUT} ${ZIP_OUTPUT}"
while IFS= read -r d; do
  [ -z "$d" ] && continue
  UPLOAD_ARGS="${UPLOAD_ARGS} \"${d}\""
done <<<"${NEW_DELTAS}"

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
