#!/bin/bash
set -euo pipefail

# Package a built `.csplugin` directory into a `.csplugin.zip` payload
# the marketplace `PluginInstaller` can consume. Outputs the zip + a
# sidecar `<name>.sha256` to `build/marketplace/`.
#
# Usage:
#   bash scripts/pack-csplugin.sh <PluginName>
#   bash scripts/pack-csplugin.sh <PluginName> <build-products-dir>
#
# With one argument, looks under
#   /tmp/claude-stats-build/Build/Products/{Debug,Release}/
# (the path `scripts/run-debug.sh` writes to). The release-pipeline
# variant passes the second argument so `scripts/build-dmg.sh` can
# point at its own `build/release/Build/Products/Release/` instead of
# requiring a debug build to exist on disk.
#
# Prereq: the chosen build dir contains `<PluginName>.csplugin/` —
# every standalone plugin target lands its bundle there.

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <PluginName> [build-products-dir]" >&2
    exit 2
fi

PLUGIN_NAME="$1"
SOURCE_OVERRIDE="${2:-}"

# Resolve repo-relative output dir to an absolute path so the
# subshell `cd` below doesn't confuse it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/build/marketplace"
mkdir -p "${OUTPUT_DIR}"

SOURCE_BUNDLE=""
if [ -n "${SOURCE_OVERRIDE}" ]; then
    candidate="${SOURCE_OVERRIDE}/${PLUGIN_NAME}.csplugin"
    if [ -d "${candidate}" ]; then
        SOURCE_BUNDLE="${candidate}"
    else
        echo "==> ${PLUGIN_NAME}.csplugin not found at ${candidate}" >&2
        exit 3
    fi
else
    BUILD_DIR="/tmp/claude-stats-build"
    # Look for the .csplugin in Debug first, then Release. xcodegen builds
    # each standalone target into its configuration's Products directory.
    for config in Debug Release; do
        candidate="${BUILD_DIR}/Build/Products/${config}/${PLUGIN_NAME}.csplugin"
        if [ -d "${candidate}" ]; then
            SOURCE_BUNDLE="${candidate}"
            break
        fi
    done

    if [ -z "${SOURCE_BUNDLE}" ]; then
        echo "==> ${PLUGIN_NAME}.csplugin not found under ${BUILD_DIR}/Build/Products/{Debug,Release}/" >&2
        echo "    Run \`bash scripts/run-debug.sh\` first to produce the bundle." >&2
        exit 3
    fi
fi

ZIP_PATH="${OUTPUT_DIR}/${PLUGIN_NAME}.csplugin.zip"
SHA_PATH="${OUTPUT_DIR}/${PLUGIN_NAME}.sha256"

PARENT="$(dirname "${SOURCE_BUNDLE}")"
BASENAME="$(basename "${SOURCE_BUNDLE}")"

echo "==> Packing ${SOURCE_BUNDLE}"
rm -f "${ZIP_PATH}"
# `-r` recursive, `-X` strip extended attrs / resource forks, `-q` quiet.
# We zip from the bundle's parent so the archive's top-level entry is
# `<Name>.csplugin/…` (which `PluginInstaller.findCspluginBundle` expects).
( cd "${PARENT}" && zip -qrX "${ZIP_PATH}" "${BASENAME}" )

if [ ! -f "${ZIP_PATH}" ]; then
    echo "==> Failed to produce ${ZIP_PATH}" >&2
    exit 4
fi

SHA="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo "${SHA}  $(basename "${ZIP_PATH}")" > "${SHA_PATH}"

SIZE="$(stat -f%z "${ZIP_PATH}")"
echo "==> Done"
echo "    zip:    ${ZIP_PATH}  (${SIZE} bytes)"
echo "    sha256: ${SHA}"
echo "    sha file: ${SHA_PATH}"
