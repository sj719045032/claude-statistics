#!/bin/bash
set -euo pipefail

# Sync the marketplace catalog repo (claude-statistics-plugins)
# against `build/marketplace/<Name>.sha256` sidecars produced by
# build-dmg.sh.
#
# Usage:
#   bash scripts/sync-catalog.sh <release-version>
#
# What it does:
#   1. Clones (or `git pull`s) the catalog repo into
#      `build/catalog-repo/` (gitignored under `build/`).
#   2. For each `build/marketplace/<Name>.sha256` sidecar, locates the
#      matching entry in `index.json` (by the plugin name embedded in
#      `downloadURL`) and rewrites its `sha256`, `version`, and
#      `downloadURL`. The download URL is repinned to
#      `https://github.com/sj719045032/claude-statistics-plugins/releases/download/v<version>/<Name>-<version>.csplugin.zip`
#      — i.e. the **catalog repo's** v<version> release tag, which
#      release.sh's step 3b creates and populates with the plugin
#      bundles.
#   3. Bumps `updatedAt` to the current ISO-8601 UTC timestamp.
#   4. Prints `git diff` and the exact `git commit` + `git push` the
#      operator needs to run from `sj719045032`'s account. The push
#      itself is intentionally left to the operator — pushing to a
#      public repo on someone else's GitHub account is a deliberate
#      action that should not be automated away.
#
# Prereqs: a Release build has populated `build/marketplace/` with
# `*.csplugin.zip` + `*.sha256`. Run `bash scripts/build-dmg.sh
# <version>` (or `bash scripts/release.sh <version>`) first.

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
    echo "Usage: $0 <release-version>" >&2
    echo "Example: $0 3.2.0" >&2
    exit 2
fi

# Pure dotted-numeric, same rule as Sparkle's appcast comparison.
if ! echo "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "==> Version must be pure dotted-numeric (got '${VERSION}')." >&2
    exit 2
fi

if ! command -v jq >/dev/null; then
    echo "==> jq not installed. brew install jq" >&2
    exit 3
fi

CATALOG_REPO_URL="https://github.com/sj719045032/claude-statistics-plugins"
CATALOG_DIR="build/catalog-repo"
INDEX_JSON="${CATALOG_DIR}/index.json"
MARKETPLACE_DIR="build/marketplace"

if [ ! -d "${MARKETPLACE_DIR}" ]; then
    echo "==> ${MARKETPLACE_DIR}/ not found." >&2
    echo "    Run \`bash scripts/build-dmg.sh ${VERSION}\` first." >&2
    exit 4
fi

if ! ls "${MARKETPLACE_DIR}"/*.sha256 >/dev/null 2>&1; then
    echo "==> No .sha256 sidecars in ${MARKETPLACE_DIR}/. Was build-dmg's pack step skipped?" >&2
    exit 5
fi

# Step 1: ensure a fresh local clone of the catalog repo.
if [ -d "${CATALOG_DIR}/.git" ]; then
    echo "==> Pulling latest catalog..."
    (cd "${CATALOG_DIR}" && git pull --rebase --quiet)
else
    echo "==> Cloning catalog repo..."
    rm -rf "${CATALOG_DIR}"
    git clone --quiet "${CATALOG_REPO_URL}" "${CATALOG_DIR}"
fi

if [ ! -f "${INDEX_JSON}" ]; then
    echo "==> ${INDEX_JSON} missing — repo layout doesn't match expectations." >&2
    exit 6
fi

# Step 2: replace each entry whose downloadURL contains the plugin
# name. We match `<Name>-` so e.g. "CodexPlugin-" doesn't accidentally
# match "CodexAppPlugin-" (the latter has "App" between). The new
# downloadURL points at the **catalog repo's** v<version> release
# (release.sh creates it in step 3b) — the catalog owns both the
# metadata and the bytes.
DOWNLOAD_URL_PREFIX="https://github.com/sj719045032/claude-statistics-plugins/releases/download/v${VERSION}"
TOUCHED_COUNT=0
TMPFILE="$(mktemp)"
cp "${INDEX_JSON}" "${TMPFILE}"

for sidecar in "${MARKETPLACE_DIR}"/*.sha256; do
    [ -f "${sidecar}" ] || continue
    NAME="$(basename "${sidecar}" .sha256)"
    SHA256="$(awk '{print $1}' "${sidecar}")"
    # Match by `<Name>.csplugin.zip` substring so e.g. CodexPlugin
    # doesn't match CodexAppPlugin (different basename). The new URL
    # carries the catalog release tag in the path; filename has no
    # version (pack-csplugin writes `<Name>.csplugin.zip` and we
    # upload that name verbatim to the GitHub release).
    MATCH_FRAGMENT="${NAME}.csplugin.zip"
    DOWNLOAD_URL="${DOWNLOAD_URL_PREFIX}/${MATCH_FRAGMENT}"

    BEFORE_SHA="$(jq -r --arg n "${MATCH_FRAGMENT}" \
        '[.entries[] | select(.downloadURL | endswith($n)) | .sha256] | .[0] // ""' \
        "${TMPFILE}")"

    jq --arg frag "${MATCH_FRAGMENT}" \
       --arg sha "${SHA256}" \
       --arg ver "${VERSION}" \
       --arg url "${DOWNLOAD_URL}" \
       '.entries |= map(if (.downloadURL | endswith($frag)) then
            .sha256 = $sha | .version = $ver | .downloadURL = $url
        else . end)' \
        "${TMPFILE}" > "${TMPFILE}.new"
    mv "${TMPFILE}.new" "${TMPFILE}"

    AFTER_SHA="$(jq -r --arg n "${MATCH_FRAGMENT}" \
        '[.entries[] | select(.downloadURL | endswith($n)) | .sha256] | .[0] // ""' \
        "${TMPFILE}")"

    if [ -z "${BEFORE_SHA}" ]; then
        echo "    ! ${NAME}: no matching entry in index.json (skipped)"
    elif [ "${BEFORE_SHA}" != "${AFTER_SHA}" ]; then
        TOUCHED_COUNT=$((TOUCHED_COUNT + 1))
    fi
done

# Step 3: bump updatedAt.
UPDATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
jq --arg t "${UPDATED_AT}" '.updatedAt = $t' "${TMPFILE}" > "${TMPFILE}.new"
mv "${TMPFILE}.new" "${INDEX_JSON}"
rm -f "${TMPFILE}"

# Step 4: report + tell the operator how to push.
echo ""
echo "==> Synced ${TOUCHED_COUNT} entries"
echo "    Catalog: ${INDEX_JSON}"
echo "    updatedAt: ${UPDATED_AT}"
echo ""
echo "Next steps (push from sj719045032's account):"
echo "  cd ${CATALOG_DIR}"
echo "  git diff index.json"
echo "  gh auth switch --hostname github.com --user sj719045032"
echo "  git commit -am 'sync catalog for v${VERSION}'"
echo "  git push"
echo "  gh auth switch --hostname github.com --user tinystone007"
echo ""
echo "After push, ≤ 5 min for raw.githubusercontent.com to propagate."
