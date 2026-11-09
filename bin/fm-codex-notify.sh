#!/usr/bin/env bash
# fm-codex-notify.sh - the `-c notify=` turn-end program of a Codex crewmate or
# scout launch (bin/fm-spawn.sh's launch template owns the wiring).
#
# Usage (Codex appends its JSON payload as the final argument):
#   fm-codex-notify.sh <state-dir> <task-id> <busy-gen> <payload-json>
#
# Codex runs this after every completed turn of every thread the worker hosts.
# It does two things and always exits 0, so it can never disturb Codex:
#   1. hands the payload to bin/fm-busy-event.sh codex-turn-end, which records
#      the gen-bound idle marker only when bin/fm-busy-lib.sh's "Codex turn-end
#      marker" contract accepts it;
#   2. touches state/<task-id>.turn-ended, the watcher's turn-end notification,
#      exactly as the launch's earlier inline `touch` did for every payload.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state=${1:-}
id=${2:-}
gen=${3:-}
payload=${4:-}
case "$id" in ''|*/*) exit 0 ;; esac
[ -d "$state" ] || exit 0
if [ -n "$gen" ] && [ -n "$payload" ]; then
  printf '%s' "$payload" | "$SCRIPT_DIR/fm-busy-event.sh" codex-turn-end "$state" "$id" --gen "$gen" >/dev/null 2>&1 || true
fi
touch "$state/$id.turn-ended" 2>/dev/null || true
exit 0
