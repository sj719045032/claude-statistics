#!/bin/bash
set -euo pipefail

# Full release: build → commit → publish to GitHub
#
# Usage:
#   bash scripts/release.sh <version>
#   bash scripts/release.sh <version> --notes "What's New\n- ...\n\n## 中文\n- ..."
#   bash scripts/release.sh <version> --notes-file /tmp/notes.md
#
# If neither --notes nor --notes-file is given, $EDITOR opens with a template.
# Release notes MUST include a "## 中文" section.

PUBLISH_ACCOUNT="sj719045032"
DEFAULT_ACCOUNT="tinystone007"
REPO_URL="https://github.com/sj719045032/claude-statistics"
CATALOG_REPO_URL="https://github.com/sj719045032/claude-statistics-plugins"
ARCHIVE_DIR="build/releases-archive"

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: bash scripts/release.sh <version> [--notes '...' | --notes-file path]"
    echo "Example: bash scripts/release.sh 2.10.0"
    exit 1
fi
shift

RELEASE_NOTES=""
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes)      RELEASE_NOTES="$2"; shift 2 ;;
        --notes-file) NOTES_FILE="$2";    shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────

# Must run from repo root
if [[ ! -f "ClaudeStatistics.xcodeproj/project.pbxproj" ]]; then
    echo "ERROR: Run this script from the repo root."
    exit 1
fi

# Release must not already exist
if gh release view "v${VERSION}" --repo "$REPO_URL" &>/dev/null; then
    echo "ERROR: GitHub release v${VERSION} already exists."
    exit 1
fi

# ── Release notes ─────────────────────────────────────────────────────────────

if [[ -n "$NOTES_FILE" ]]; then
    RELEASE_NOTES="$(cat "$NOTES_FILE")"
elif [[ -z "$RELEASE_NOTES" ]]; then
    TMP_NOTES=$(mktemp /tmp/release-notes-XXXXXX.md)
    cat > "$TMP_NOTES" <<'TEMPLATE'
## What's New

-

## 中文

-

<!-- Lines starting with # or <!-- are kept as-is; remove this line and above when done. -->
TEMPLATE
    "${EDITOR:-vi}" "$TMP_NOTES"
    # Strip comment lines and leading/trailing blank lines
    RELEASE_NOTES=$(grep -v '^<!--' "$TMP_NOTES" | sed '/./,$!d' | sed -e :a -e '/^\s*$/{ $d; N; ba }')
    rm -f "$TMP_NOTES"
fi

if [[ -z "$RELEASE_NOTES" ]]; then
    echo "ERROR: Release notes are empty. Aborting."
    exit 1
fi

if [[ "$RELEASE_NOTES" != *"## 中文"* ]]; then
    echo "ERROR: Release notes must include a '## 中文' section."
    exit 1
fi

# ── Step 1: Build ─────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Releasing Claude Statistics v${VERSION}"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Snapshot deltas before the build so we can detect what's new afterwards
BEFORE_DELTAS=$(mktemp)
find "$ARCHIVE_DIR" -maxdepth 1 -name "*.delta" 2>/dev/null | sort > "$BEFORE_DELTAS"

echo "==> [1/4] Building v${VERSION}..."
bash scripts/build-dmg.sh "$VERSION"

DMG="build/ClaudeStatistics-${VERSION}.dmg"
ZIP="build/ClaudeStatistics-${VERSION}.zip"

if [[ ! -f "$DMG" ]]; then
    echo "ERROR: DMG not found: $DMG"
    exit 1
fi
if [[ ! -f "$ZIP" ]]; then
    echo "ERROR: ZIP not found: $ZIP"
    exit 1
fi

# Collect delta files produced in this run
AFTER_DELTAS=$(mktemp)
find "$ARCHIVE_DIR" -maxdepth 1 -name "*.delta" 2>/dev/null | sort > "$AFTER_DELTAS"
mapfile -t NEW_DELTAS < <(comm -13 "$BEFORE_DELTAS" "$AFTER_DELTAS")
rm -f "$BEFORE_DELTAS" "$AFTER_DELTAS"

# Plugin bundles ship through the catalog repo's own releases —
# this script only handles the host app release.
HOST_ASSET_LIST=(
    "$DMG"
    "$ZIP"
    "${NEW_DELTAS[@]+"${NEW_DELTAS[@]}"}"
)

echo ""
echo "    Host repo (${REPO_URL}) v${VERSION} assets:"
for a in "${HOST_ASSET_LIST[@]}"; do
    sz=$(du -h "$a" | cut -f1 | xargs)
    echo "      - $(basename "$a") (${sz})"
done
echo ""

# ── Step 2: Commit + push ─────────────────────────────────────────────────────

echo "==> [2/4] Committing appcast + project changes..."

FILES_TO_ADD=(appcast.xml ClaudeStatistics.xcodeproj/project.pbxproj)
[[ -f project.yml ]] && FILES_TO_ADD+=(project.yml)

git add "${FILES_TO_ADD[@]}"

if git diff --cached --quiet; then
    echo "    Nothing to commit (appcast unchanged)."
else
    git commit -m "chore: update appcast for v${VERSION}"
    echo "    Committed."
fi

echo "==> Pushing..."
git push
echo "    Pushed."
echo ""

# ── Step 3: Host GitHub release ───────────────────────────────────────────────

echo "==> [3/4] Switching to publish account (${PUBLISH_ACCOUNT})..."
gh auth switch --hostname github.com --user "$PUBLISH_ACCOUNT"

echo "==> Creating host release v${VERSION} on $(basename "$REPO_URL")..."
RELEASE_URL=$(gh release create "v${VERSION}" \
    "${HOST_ASSET_LIST[@]}" \
    --repo "$REPO_URL" \
    --title "v${VERSION}" \
    --notes "$RELEASE_NOTES")

echo "    Host release: ${RELEASE_URL}"
echo ""

# ── Step 4: Restore account ───────────────────────────────────────────────────

echo "==> [4/4] Switching back to ${DEFAULT_ACCOUNT}..."
gh auth switch --hostname github.com --user "$DEFAULT_ACCOUNT"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "✓ Release v${VERSION} complete!"
echo ""
echo "  GitHub: ${RELEASE_URL}"
echo ""
echo "  Note: DMG is not Apple-signed. Users install with:"
echo "    xattr -cr /Applications/Claude\\ Statistics.app"
echo ""
