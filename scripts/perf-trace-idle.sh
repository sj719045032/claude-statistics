#!/bin/bash
# Capture the running Debug app's idle CPU + RSS over a fixed
# observation window. Pairs with perf-trace-startup.sh — start the
# app first, let startup settle, then run this for the steady-state
# numbers.
#
# Usage:
#     bash scripts/perf-trace-idle.sh
#
# Optional env vars:
#     IDLE_SECONDS — total observation window (default 60)
#     SAMPLE_EVERY — interval between ps samples (default 15)
#     PROC         — process name to attach to (default
#                    "Claude Statistics Debug")

set -euo pipefail

IDLE_SECONDS="${IDLE_SECONDS:-60}"
SAMPLE_EVERY="${SAMPLE_EVERY:-15}"
PROC="${PROC:-Claude Statistics Debug}"

PID=$(pgrep -f "$PROC" | head -1 || true)
if [ -z "${PID:-}" ]; then
    echo "error: '$PROC' is not running" >&2
    echo "       launch it first with: bash scripts/run-debug.sh" >&2
    exit 1
fi

echo "==> Observing PID=$PID ('$PROC') for ${IDLE_SECONDS}s, sample every ${SAMPLE_EVERY}s"
echo
printf "%-8s %-7s %-12s %-10s %-10s\n" "elapsed" "%CPU" "RSS(KB)" "utime" "stime"
printf "%-8s %-7s %-12s %-10s %-10s\n" "-------" "----" "-------" "-----" "-----"

elapsed=0
while [ "$elapsed" -le "$IDLE_SECONDS" ]; do
    line=$(ps -o pid,%cpu,rss,utime,stime -p "$PID" 2>/dev/null | tail -1 || true)
    if [ -z "$line" ]; then
        echo "error: process $PID disappeared" >&2
        exit 1
    fi
    cpu=$(echo "$line" | awk '{print $2}')
    rss=$(echo "$line" | awk '{print $3}')
    utime=$(echo "$line" | awk '{print $4}')
    stime=$(echo "$line" | awk '{print $5}')
    printf "%-8s %-7s %-12s %-10s %-10s\n" "${elapsed}s" "$cpu" "$rss" "$utime" "$stime"
    [ "$elapsed" -lt "$IDLE_SECONDS" ] || break
    next=$((elapsed + SAMPLE_EVERY))
    if [ "$next" -gt "$IDLE_SECONDS" ]; then
        sleep $((IDLE_SECONDS - elapsed))
        elapsed=$IDLE_SECONDS
    else
        sleep "$SAMPLE_EVERY"
        elapsed=$next
    fi
done

echo
echo "==> utime/stime are cumulative; growth between samples is the work done in that window."
