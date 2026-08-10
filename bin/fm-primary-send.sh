#!/usr/bin/env bash
# Send a normal captain message to the active top-level firstmate session.
# This is deliberately separate from fm-send.sh, which targets recorded crew
# task endpoints under state/*.meta.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

message="${*:-}"
if [ -z "$message" ] && [ ! -t 0 ]; then
  message=$(cat)
fi
[ -n "$message" ] || { echo "error: primary message is empty" >&2; exit 2; }

target=$(discover_supervisor_target) || true
backend=$(discover_supervisor_backend) || true
[ -n "$target" ] || { echo "error: primary session target is not configured" >&2; exit 1; }
[ -n "$backend" ] || { echo "error: primary session backend is not configured" >&2; exit 1; }

fm_backend_target_exists "$backend" "$target" || {
  echo "error: primary session target '$target' is not reachable via $backend; set FM_SUPERVISOR_TARGET and FM_SUPERVISOR_BACKEND" >&2
  exit 1
}

# Never merge an external message into text the captain has already started.
composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || true)
if [ "$composer" != empty ]; then
  echo "error: primary session composer is not confirmed empty (state=${composer:-unknown})" >&2
  exit 1
fi

retries="${FM_PRIMARY_SEND_RETRIES:-3}"
sleep_s="${FM_PRIMARY_SEND_SLEEP:-0.4}"
settle="${FM_PRIMARY_SEND_SETTLE:-1}"
verdict=$(fm_backend_send_text_submit "$backend" "$target" "$message" "$retries" "$sleep_s" "$settle")
[ "$verdict" = empty ] || {
  echo "error: primary session submit was not confirmed (verdict=$verdict)" >&2
  exit 1
}
printf 'delivered primary via %s:%s\n' "$backend" "$target"
