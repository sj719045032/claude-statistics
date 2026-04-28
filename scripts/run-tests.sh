#!/bin/bash
set -euo pipefail

# Run the test suite without colliding with the installed Release build.
#
# `xcodebuild test` on macOS launches the host app (XCTest injects into it).
# The project's default PRODUCT_BUNDLE_IDENTIFIER is `com.tinystone.ClaudeStatistics`
# — the same bundle ID as the installed Release `/Applications/Claude Statistics.app`.
# Running the raw `xcodebuild test ...` command therefore wakes up (or
# re-registers over) the Release app, which is exactly the Launch Services
# conflict CLAUDE.md warns about.
#
# This script overrides the bundle ID to the same `.debug` slot
# `scripts/run-debug.sh` uses, so the test host app stays distinct from
# Release.

APP_NAME="Claude Statistics"
BUILD_DIR="/tmp/claude-stats-build"
DEBUG_BUNDLE_ID="${DEBUG_BUNDLE_ID:-com.tinystone.ClaudeStatistics.debug}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
TEST_APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}.app"

echo "==> Running tests (bundle id: ${DEBUG_BUNDLE_ID})..."
mkdir -p "${BUILD_DIR}"
TEST_LOG="${BUILD_DIR}/xcodebuild-test.log"
TEST_STATUS=0
xcodebuild test \
    -project ClaudeStatistics.xcodeproj \
    -scheme ClaudeStatistics \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    PRODUCT_BUNDLE_IDENTIFIER="${DEBUG_BUNDLE_ID}" \
    >"${TEST_LOG}" 2>&1 || TEST_STATUS=$?

# Unregister + delete the test host app so Launch Services doesn't keep a
# stale entry pointing at /tmp. The build may have left an `.app` here
# even on test failure; clean it up either way.
#
# Why both `lsregister -u` AND `rm -rf`: `lsregister -u` only succeeds
# while the path is still on disk, so we have to unregister before
# deleting. If we left the bundle behind after unregistering, the next
# Spotlight / LaunchServices rescan would re-register it — which is
# how stale `Claude Statistics` rows ended up in System Settings →
# Privacy after several test runs. Removing the bundle right after
# unregister closes that re-discovery window. The Test bundle XCTest
# wraps inside Plugins/ goes with it (xcodebuild rebuilds when needed).
if [ -d "${TEST_APP_PATH}" ]; then
    ${LSREGISTER} -u "${TEST_APP_PATH}" 2>/dev/null || true
    rm -rf "${TEST_APP_PATH}"
fi

if [ "${TEST_STATUS}" -ne 0 ]; then
    echo "==> TESTS FAILED — failures + errors:"
    echo "----------------------------------------"
    grep -E "error:|failed|FAIL" "${TEST_LOG}" | head -80 || true
    echo "----------------------------------------"
    echo "==> Full log: ${TEST_LOG}"
    exit "${TEST_STATUS}"
fi

# On success, surface just the test totals (last few lines of the log).
grep -E "Executed [0-9]+ tests|Test Suite '.*' passed" "${TEST_LOG}" | tail -5 || tail -4 "${TEST_LOG}"
echo "==> Tests passed."
