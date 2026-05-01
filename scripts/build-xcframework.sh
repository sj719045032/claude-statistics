#!/bin/bash
set -euo pipefail

# Build ClaudeStatisticsKit.xcframework — the binary form of the SDK
# that catalog-repo plugins (and third-party `.csplugin` projects)
# link against. Critical: this gets the plugin to share the SAME
# protocol metadata as the host module instead of static-linking its
# own copy (the Swift runtime conformance check
# `cls as? (NSObject & Plugin).Type` fails when the plugin carries
# its own `Plugin` protocol descriptor — observed in Phase 2 dev
# test where SwiftPM `package: ClaudeStatisticsKit` smuggled 2389
# SDK symbols into the plugin binary).
#
# Output: build/xcframework/ClaudeStatisticsKit.xcframework
# (gitignored under build/).
#
# Usage:
#   bash scripts/build-xcframework.sh
#
# Prereqs: xcodegen project regenerated (run `xcodegen generate` if
# project.yml changed). The script requires
# `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` so the framework gets
# `.swiftinterface` files for Swift module stability across binary
# boundaries — third-party clients compiled against a different
# Swift compiler version still resolve symbols.

ARCHIVE_DIR="build/xcframework-archives"
OUTPUT_DIR="build/xcframework"
FRAMEWORK_NAME="ClaudeStatisticsKit"

rm -rf "${ARCHIVE_DIR}" "${OUTPUT_DIR}"
mkdir -p "${ARCHIVE_DIR}" "${OUTPUT_DIR}"

echo "==> Archiving ${FRAMEWORK_NAME} for macOS..."
xcodebuild archive \
    -project ClaudeStatistics.xcodeproj \
    -scheme "${FRAMEWORK_NAME}" \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_DIR}/macOS.xcarchive" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    2>&1 | tail -5

ARCHIVED_FRAMEWORK="${ARCHIVE_DIR}/macOS.xcarchive/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework"
if [ ! -d "${ARCHIVED_FRAMEWORK}" ]; then
    echo "==> ${ARCHIVED_FRAMEWORK} not produced. xcodebuild archive failed?" >&2
    exit 1
fi

echo "==> Creating xcframework..."
xcodebuild -create-xcframework \
    -framework "${ARCHIVED_FRAMEWORK}" \
    -output "${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework" \
    2>&1 | tail -3

if [ ! -d "${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework" ]; then
    echo "==> xcframework not produced." >&2
    exit 2
fi

echo ""
echo "==> Done"
echo "    xcframework: ${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"
echo "    arches: $(lipo -archs "${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework/macos-arm64/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" 2>/dev/null || echo "?")"

# Pre-compute a sha256 of the zipped xcframework for catalog
# `Package.swift .binaryTarget(checksum:)`. The zip itself is what
# Apple's SwiftPM expects; the checksum is over the zip bytes.
echo ""
echo "==> Zipping for distribution..."
ZIP_PATH="${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework.zip"
rm -f "${ZIP_PATH}"
# `zip -y` preserves the framework's `Versions/Current -> A` symlink
# in a way SwiftPM unpacks correctly on the consumer side. `ditto`
# also preserves symlinks but SwiftPM's binaryTarget unzip pipeline
# deref's them back to directories — `zip -y` produces standard
# PKZIP entries SwiftPM round-trips cleanly. Without this Xcode
# warns: "Couldn't resolve framework symlink for ... Versions/Current"
# and consumer plugin builds fail with `cannot find <SDK type> in scope`.
( cd "${OUTPUT_DIR}" && zip -qry "${FRAMEWORK_NAME}.xcframework.zip" "${FRAMEWORK_NAME}.xcframework" )
SHA256="$(swift package compute-checksum "${ZIP_PATH}" 2>/dev/null || shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo "    zip: ${ZIP_PATH} ($(du -h "${ZIP_PATH}" | cut -f1 | xargs))"
echo "    SwiftPM checksum (.binaryTarget): ${SHA256}"
