#!/usr/bin/env bash
set -euo pipefail

# Toggle host Package.swift + catalog-repo/project.yml between two
# SDK sources so iterating on the SDK doesn't require manual file
# edits each time.
#
#   local      Point both files at the locally-built xcframework
#              (`build/xcframework/`) and the host repo path. Use
#              while editing `Plugins/Sources/ClaudeStatisticsKit/`
#              and rebuilding catalog plugins via `dev-install.sh`.
#
#   published  Restore the published SDK references (host
#              `Package.swift` binaryTarget url+checksum, catalog
#              `project.yml` SwiftPM url+branch). Required before
#              committing/pushing or running `release-plugins.sh`.
#
# Without arguments, prints which mode each file is currently in.
#
# Typical workflow:
#   1. scripts/sdk-mode.sh local
#   2. edit Plugins/Sources/ClaudeStatisticsKit/*.swift
#   3. scripts/build-xcframework.sh                        # rebuild xcframework
#   4. cd build/catalog-repo && bash scripts/dev-install.sh <Plugin>
#   5. quit + relaunch Claude Statistics, test
#   6. scripts/sdk-mode.sh published
#   7. (when ready) update PUBLISHED_SDK_TAG/CHECKSUM below + Package.swift's
#      embedded url+checksum, commit + push, run release-plugins.sh.
#
# `published` mode's url + checksum are kept in the constants below.
# Bump them in lockstep with each new sdk-v<x.y.z> release.

PUBLISHED_SDK_TAG="sdk-v0.3.0"
PUBLISHED_SDK_CHECKSUM="fc28f2e91118688922f47ab9f46dec614ed509cc9bf67a3798e8ee12acb7a80c"
PUBLISHED_SDK_URL="https://github.com/sj719045032/claude-statistics/releases/download/${PUBLISHED_SDK_TAG}/ClaudeStatisticsKit.xcframework.zip"
CATALOG_PUBLISHED_URL="https://github.com/sj719045032/claude-statistics"
CATALOG_PUBLISHED_BRANCH="main"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${REPO_ROOT}/Package.swift"
CATALOG_YML="${REPO_ROOT}/build/catalog-repo/project.yml"

usage() {
    sed -n '/^# Toggle host/,/^# `published`/p' "$0" | sed 's/^# \?//'
    exit 2
}

mode_of_pkg() {
    if grep -qE '^[[:space:]]*path: "build/xcframework' "$PKG"; then
        echo local
    else
        echo published
    fi
}

mode_of_catalog() {
    if grep -qE '^[[:space:]]+path: \.\./\.\.' "$CATALOG_YML"; then
        echo local
    else
        echo published
    fi
}

# Replace the contents between SDK_MODE_BEGIN/END markers in $1
# with the literal text passed on stdin. Uses python3 for safe
# multiline string handling — avoids `sed`/`awk` quoting traps.
swap_block() {
    local file="$1"
    local marker_prefix="$2"
    local replacement
    replacement="$(cat)"

    BLOCK_FILE="$file" \
    BLOCK_MARKER_PREFIX="$marker_prefix" \
    BLOCK_REPLACEMENT="$replacement" \
    python3 - <<'PY'
import os, re, pathlib, sys
file_path = pathlib.Path(os.environ["BLOCK_FILE"])
prefix = re.escape(os.environ["BLOCK_MARKER_PREFIX"])
replacement = os.environ["BLOCK_REPLACEMENT"]
text = file_path.read_text()
pattern = re.compile(prefix + r" SDK_MODE_BEGIN.*?" + prefix + r" SDK_MODE_END", re.DOTALL)
match = pattern.search(text)
if not match:
    sys.exit(f"{file_path}: SDK_MODE_BEGIN/END markers not found")
text = text[: match.start()] + replacement + text[match.end() :]
file_path.write_text(text)
PY
}

set_local() {
    swap_block "$PKG" "//" <<EOF
// SDK_MODE_BEGIN — managed by scripts/sdk-mode.sh
        .binaryTarget(
            name: "ClaudeStatisticsKit",
            path: "build/xcframework/ClaudeStatisticsKit.xcframework"
        )
        // SDK_MODE_END
EOF

    swap_block "$CATALOG_YML" "#" <<EOF
# SDK_MODE_BEGIN — managed by scripts/sdk-mode.sh
  ClaudeStatisticsKit:
    path: ../..
  # SDK_MODE_END
EOF
}

set_published() {
    swap_block "$PKG" "//" <<EOF
// SDK_MODE_BEGIN — managed by scripts/sdk-mode.sh
        .binaryTarget(
            name: "ClaudeStatisticsKit",
            url: "${PUBLISHED_SDK_URL}",
            checksum: "${PUBLISHED_SDK_CHECKSUM}"
        )
        // SDK_MODE_END
EOF

    swap_block "$CATALOG_YML" "#" <<EOF
# SDK_MODE_BEGIN — managed by scripts/sdk-mode.sh
  ClaudeStatisticsKit:
    url: ${CATALOG_PUBLISHED_URL}
    branch: ${CATALOG_PUBLISHED_BRANCH}
  # SDK_MODE_END
EOF
}

if [ "$#" -eq 0 ]; then
    printf 'Package.swift               : %s\n' "$(mode_of_pkg)"
    printf 'build/catalog-repo/proj.yml : %s\n' "$(mode_of_catalog)"
    exit 0
fi

case "$1" in
    local)
        if [ "$(mode_of_pkg)" = local ] && [ "$(mode_of_catalog)" = local ]; then
            exit 0
        fi
        set_local
        echo "==> SDK mode: local"
        echo "    Next: scripts/build-xcframework.sh, then dev-install.sh in catalog-repo"
        ;;
    published)
        if [ "$(mode_of_pkg)" = published ] && [ "$(mode_of_catalog)" = published ]; then
            exit 0
        fi
        set_published
        echo "==> SDK mode: published (${PUBLISHED_SDK_TAG})"
        echo "    Next: scripts/run-debug.sh to smoke build, then commit + push"
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Unknown mode: $1" >&2
        usage
        ;;
esac
