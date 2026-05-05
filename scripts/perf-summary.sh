#!/bin/bash
# Run every headless perf scenario in sequence and print a unified
# summary. Use before / after each PR for a one-command "did this
# move the numbers?" check.
#
# Scenarios covered:
#   S2 — warm startup signposts (kills + relaunches the Debug app)
#   Idle — CPU + RSS samples over a fixed window after startup
#
# UI-driven scenarios (S4 force rescan, S5 Usage tab, S7 search,
# S8 large transcript, S9 share export, S10 notch) need manual
# interaction; trigger them yourself, then rerun
# `python3 scripts/perf-parse-signposts.py <log>` against the
# captured signpost log.
#
# Usage:
#     bash scripts/perf-summary.sh
#
# Optional env vars:
#     WAIT_SECONDS — startup settle wait passed to perf-trace-startup.sh
#     IDLE_SECONDS — idle observation window passed to perf-trace-idle.sh
#     SAMPLE_EVERY — idle sample interval

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date "+%Y%m%dT%H%M%S")

echo "============================================================"
echo "  Performance summary  ($(date "+%Y-%m-%d %H:%M:%S"))"
echo "============================================================"
echo

echo "------------------------------------------------------------"
echo "  S2 — Warm startup"
echo "------------------------------------------------------------"
bash "${SCRIPT_DIR}/perf-trace-startup.sh" "/tmp/perf-summary-startup-${TS}.log"

echo
echo "------------------------------------------------------------"
echo "  Idle — steady-state CPU + RSS"
echo "------------------------------------------------------------"
bash "${SCRIPT_DIR}/perf-trace-idle.sh"

echo
echo "============================================================"
echo "  Summary written to /tmp/perf-summary-startup-${TS}.log"
echo "  For UI-driven scenarios (S4 / S5 / S7 / S8 / S9 / S10),"
echo "  capture a signpost log manually and pipe it through"
echo "  scripts/perf-parse-signposts.py."
echo "============================================================"
