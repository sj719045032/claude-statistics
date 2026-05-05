#!/bin/bash
# Capture an os_signpost trace of a warm startup of the Claude
# Statistics Debug app, then print a per-signpost duration table.
# Used as the baseline measurement step for the performance
# optimization project (see docs/PERFORMANCE_OPTIMIZATION_PROJECT.md).
#
# Usage:
#     bash scripts/perf-trace-startup.sh [output-file]
#
# Optional env vars:
#     WAIT_SECONDS — how long to wait for startup to settle (default 15)
#     APP_PATH     — Debug app bundle
#                    (default $HOME/Applications/Claude Statistics Debug.app)
#
# Requires PR1's PerformanceTracer signposts to be in the build. Run
# `bash scripts/run-debug.sh` first if the Debug app isn't installed.

set -euo pipefail

APP_PATH="${APP_PATH:-${HOME}/Applications/Claude Statistics Debug.app}"
WAIT_SECONDS="${WAIT_SECONDS:-15}"
OUTPUT="${1:-/tmp/perf-baseline-startup-$(date +%Y%m%dT%H%M%S).log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$APP_PATH" ]; then
    echo "error: debug app not found at $APP_PATH" >&2
    echo "       run 'bash scripts/run-debug.sh' first" >&2
    exit 1
fi

echo "==> Killing existing instance..."
killall "Claude Statistics Debug" 2>/dev/null || true
while pgrep -x "Claude Statistics Debug" >/dev/null 2>&1; do sleep 0.2; done

defaults write com.tinystone.ClaudeStatistics.debug "debug.accessibility.promptShown" -bool true 2>/dev/null || true

START_TS=$(date "+%Y-%m-%d %H:%M:%S")
echo "==> Launching..."
open "$APP_PATH"

echo "==> Waiting ${WAIT_SECONDS}s for startup to settle..."
sleep "$WAIT_SECONDS"
END_TS=$(date "+%Y-%m-%d %H:%M:%S")

echo "==> Pulling signposts ($START_TS → $END_TS)..."
# Use /usr/bin/log explicitly: zsh users may have a `log` shell alias
# that intercepts this command and prints "too many arguments".
/usr/bin/log show --start "$START_TS" --end "$END_TS" \
    --signpost \
    --predicate 'subsystem == "com.tinystone.ClaudeStatistics"' \
    --style compact > "$OUTPUT"

LINES=$(wc -l < "$OUTPUT" | tr -d ' ')
echo "==> Captured $LINES log lines → $OUTPUT"
echo

python3 "${SCRIPT_DIR}/perf-parse-signposts.py" "$OUTPUT"
