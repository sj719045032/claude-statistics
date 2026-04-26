#!/usr/bin/env bash
# Enforces the 500-line hard limit on Swift files under Plugins/.
#
# Files inside Plugins/ MUST stay <= 500 lines (rewrite hard rule, see
# docs/REWRITE_PLAN.md decision D7 + section 17). Files inside
# ClaudeStatistics/ (the kernel) are reported as warnings only — the
# rewrite stages whittle them down progressively.
#
# Usage:
#   bash scripts/check-plugin-file-size.sh           # check both, fail on plugin violations
#   bash scripts/check-plugin-file-size.sh --strict  # also fail on kernel violations
#
set -euo pipefail

LIMIT=500
STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Plugins/: hard fail ---
plugin_violations=""
if [[ -d Plugins ]]; then
  plugin_violations=$(find Plugins -type f -name '*.swift' -exec wc -l {} + 2>/dev/null \
    | awk -v limit=$LIMIT '$1 > limit && $2 != "total" {printf "  %5d  %s\n", $1, $2}')
fi

# --- ClaudeStatistics/: warn (or fail under --strict) ---
kernel_violations=""
if [[ -d ClaudeStatistics ]]; then
  kernel_violations=$(find ClaudeStatistics -type f -name '*.swift' -exec wc -l {} + 2>/dev/null \
    | awk -v limit=$LIMIT '$1 > limit && $2 != "total" {printf "  %5d  %s\n", $1, $2}')
fi

exit_code=0

if [[ -n "$plugin_violations" ]]; then
  echo "FAIL  Files under Plugins/ exceeding $LIMIT lines:"
  echo "$plugin_violations"
  exit_code=1
fi

if [[ -n "$kernel_violations" ]]; then
  if [[ "$STRICT" == "1" ]]; then
    echo "FAIL  Files under ClaudeStatistics/ exceeding $LIMIT lines (--strict):"
    echo "$kernel_violations"
    exit_code=1
  else
    echo "WARN  Files under ClaudeStatistics/ exceeding $LIMIT lines (kernel rewrite in progress):"
    echo "$kernel_violations"
  fi
fi

if [[ $exit_code -eq 0 ]] && [[ -z "$plugin_violations" ]] && [[ -z "$kernel_violations" ]]; then
  echo "OK    All Swift files within $LIMIT lines."
fi

exit $exit_code
