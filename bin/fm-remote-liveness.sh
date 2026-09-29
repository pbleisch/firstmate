#!/usr/bin/env bash
# Host-side liveness for the remote secondmate whose home is FM_HOME.
#
# Usage:
#   fm-remote-liveness.sh probe [--textfile <path>]
#   fm-remote-liveness.sh install <id>
#   fm-remote-liveness.sh remove <id>
#
# WHY. The parent's session-start sweep relaunches a dead remote secondmate, but
# nothing noticed one that died mid-session, and after a host reboot nothing
# noticed at all. This probe runs on the secondmate's own host, every
# FM_REMOTE_LIVENESS_INTERVAL seconds, from a systemd --user timer that the
# host-local launch installs (bin/fm-remote-secondmate-control.sh), so it keeps
# working while the secondmate's own agent and watcher are gone.
#
# probe reads, and never changes, the secondmate's endpoint, using the same
# recovery-grade state the parent's sweep reads (`fm-remote-secondmate-control.sh
# state`), plus whether the fm-remote Herdr server runs and whether the remote
# job worker published a fresh heartbeat. It prints one fact per line:
#   secondmate=<id>
#   state=alive|dead|missing|ambiguous|unreadable|unverified|unlaunched
#   herdr=up|down
#   worker=up|down
# unlaunched means this home has no host-local endpoint record, so there is
# nothing to watch. With --textfile it also writes those facts atomically in the
# Prometheus text format, for a node_exporter textfile collector.
#
# When two consecutive probes read the endpoint positively dead or missing, it
# appends one keyed `blocked` line to the home's parent channel
# (bin/fm-parent-channel-lib.sh), which the parent's remote reply adapter
# mirrors into the parent's status channel, so the parent learns of the death
# within about two intervals and relaunches through
# `bin/fm-spawn.sh <id> --secondmate`. The first alive probe after that appends
# the matching `resolved` line. Requiring two reads keeps a deliberate relaunch
# window from raising a false alarm. Every other state publishes nothing. The
# probe never relaunches anything itself: recovery stays the parent's decision.
# state/.remote-liveness holds the episode between runs.
#
# install writes and enables dev.firstmate.remote-liveness-<id>.service and its
# .timer for FM_HOME, and remove disables and deletes them. Both act only when a
# systemd user manager for this same HOME is reachable
# (fm_remote_job_systemd_user_available), print what they did on stderr, and
# otherwise exit 0 having changed nothing, so a host without systemd keeps
# working with startup-only recovery.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
STATE="$TARGET_HOME/state"
EPISODE="$STATE/.remote-liveness"
INTERVAL=${FM_REMOTE_LIVENESS_INTERVAL:-120}
case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=120 ;; esac

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

home_id() {
  local marker="$TARGET_HOME/.fm-secondmate-home" id
  [ -f "$marker" ] && [ ! -L "$marker" ] || die "FM_HOME is not a seeded secondmate home"
  id=$(head -1 "$marker")
  validate_id "$id"
  printf '%s\n' "$id"
}

endpoint_state() { # <id>
  local id=$1 out
  if [ ! -f "$STATE/parent-route/$id.meta" ] || [ -L "$STATE/parent-route/$id.meta" ]; then
    printf 'unlaunched\n'
    return 0
  fi
  out=$(FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-remote-secondmate-control.sh" state "$id" 2>/dev/null) || out=unreadable
  out=$(printf '%s\n' "$out" | tail -1)
  case "$out" in
    alive|dead|missing|ambiguous|unreadable|unverified) printf '%s\n' "$out" ;;
    *) printf 'unreadable\n' ;;
  esac
}

herdr_up() {
  local running
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  running=$(HERDR_SESSION=fm-remote herdr status --json --session fm-remote 2>/dev/null \
    | jq -r '.server.running // false' 2>/dev/null) || return 1
  [ "$running" = true ]
}

write_textfile() { # <path> <id> <state> <herdr> <worker>
  local path=$1 id=$2 state=$3 herdr=$4 worker=$5 tmp up=0 herdr_value=0 worker_value=0
  [ "$state" = alive ] && up=1
  [ "$herdr" = up ] && herdr_value=1
  [ "$worker" = up ] && worker_value=1
  mkdir -p "$(dirname "$path")"
  tmp="$(dirname "$path")/.$(basename "$path").tmp.$$"
  {
    printf '# HELP firstmate_remote_secondmate_up 1 when the remote secondmate agent is alive on this host.\n'
    printf '# TYPE firstmate_remote_secondmate_up gauge\n'
    printf 'firstmate_remote_secondmate_up{id="%s",state="%s"} %s\n' "$id" "$state" "$up"
    printf '# HELP firstmate_remote_herdr_up 1 when the fm-remote Herdr server is running.\n'
    printf '# TYPE firstmate_remote_herdr_up gauge\n'
    printf 'firstmate_remote_herdr_up{id="%s"} %s\n' "$id" "$herdr_value"
    printf '# HELP firstmate_remote_job_worker_up 1 when the remote job worker has a fresh heartbeat.\n'
    printf '# TYPE firstmate_remote_job_worker_up gauge\n'
    printf 'firstmate_remote_job_worker_up{id="%s"} %s\n' "$id" "$worker_value"
    printf '# HELP firstmate_remote_liveness_timestamp_seconds When this probe last ran.\n'
    printf '# TYPE firstmate_remote_liveness_timestamp_seconds gauge\n'
    printf 'firstmate_remote_liveness_timestamp_seconds{id="%s"} %s\n' "$id" "$(date +%s)"
  } > "$tmp"
  mv -f -- "$tmp" "$path"
}

# The episode record is "<phase> <since-epoch> <state>", where phase is
# suspect after one down read and reported once the blocked line is published.
publish() { # <id> <state>
  local id=$1 state=$2 phase='' since='' rc=0 now
  if [ -f "$EPISODE" ] && [ ! -L "$EPISODE" ]; then
    read -r phase since _ < "$EPISODE" || true
  fi
  now=$(date +%s)
  case "$state" in
    dead|missing)
      case "$phase" in
        reported) return 0 ;;
        suspect)
          fm_parent_channel_report "$TARGET_HOME" "$STATE" \
            "blocked [key=remote-liveness-$since]: remote secondmate $id agent is $state on its host; relaunch it with bin/fm-spawn.sh $id --secondmate" \
            || rc=$?
          [ "$rc" -eq 0 ] || { printf 'warning: could not publish the down secondmate (rc=%s)\n' "$rc" >&2; return 0; }
          printf 'reported %s %s\n' "$since" "$state" > "$EPISODE"
          ;;
        *) printf 'suspect %s %s\n' "$now" "$state" > "$EPISODE" ;;
      esac
      ;;
    alive)
      if [ "$phase" = reported ]; then
        fm_parent_channel_report "$TARGET_HOME" "$STATE" \
          "resolved [key=remote-liveness-$since]: remote secondmate $id agent is alive again" || rc=$?
        [ "$rc" -eq 0 ] || { printf 'warning: could not publish the recovered secondmate (rc=%s)\n' "$rc" >&2; return 0; }
      fi
      rm -f -- "$EPISODE"
      ;;
    unlaunched) rm -f -- "$EPISODE" ;;
  esac
}

cmd_probe() {
  local textfile='' id state herdr=down worker=down
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --textfile) [ -n "${2:-}" ] || usage; textfile=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  id=$(home_id)
  # A timer run has systemd's minimal PATH, so compose the same one remote
  # jobs use before resolving herdr and jq.
  fm_remote_job_compose_operator_path "${HOME:-}" >/dev/null
  fm_remote_job_build_child_path "$FM_ROOT" >/dev/null
  PATH=$FM_REMOTE_JOB_CHILD_PATH
  state=$(endpoint_state "$id")
  herdr_up && herdr=up
  fm_remote_job_probe "${HOME:-}" && worker=up
  printf 'secondmate=%s\nstate=%s\nherdr=%s\nworker=%s\n' "$id" "$state" "$herdr" "$worker"
  [ -z "$textfile" ] || write_textfile "$textfile" "$id" "$state" "$herdr" "$worker"
  publish "$id" "$state"
}

unit_base() { printf 'dev.firstmate.remote-liveness-%s\n' "$1"; }

render_service() { # <id>
  local id=$1 script="$FM_ROOT/bin/fm-remote-liveness.sh" textfile value
  textfile="${HOME:-}/.firstmate/metrics/$id.prom"
  for value in "$script" "$TARGET_HOME" "$FM_ROOT" "${HOME:-}" "$textfile"; do
    fm_remote_job_systemd_safe_value "$value" || return 1
  done
  cat <<UNIT
# Firstmate-owned; bin/fm-remote-liveness.sh install rewrites this file.
[Unit]
Description=Firstmate remote secondmate $id liveness probe

[Service]
Type=oneshot
Environment="HOME=${HOME:-}" "FM_HOME=$TARGET_HOME" "FM_ROOT_OVERRIDE=$FM_ROOT"
ExecStart="$script" probe --textfile "$textfile"
UNIT
}

render_timer() { # <id>
  cat <<UNIT
# Firstmate-owned; bin/fm-remote-liveness.sh install rewrites this file.
[Unit]
Description=Run the Firstmate remote secondmate $1 liveness probe

[Timer]
OnBootSec=${INTERVAL}s
OnUnitActiveSec=${INTERVAL}s

[Install]
WantedBy=timers.target
UNIT
}

cmd_install() {
  local id=$1 dir base service timer
  validate_id "$id"
  [ "$(home_id)" = "$id" ] || die "FM_HOME belongs to $(home_id), not $id"
  if ! fm_remote_job_systemd_user_available; then
    printf 'note: no systemd user manager serves %s; the liveness timer is not installed\n' "${HOME:-}" >&2
    return 0
  fi
  dir="${HOME:-}/.config/systemd/user"
  base=$(unit_base "$id")
  service=$(render_service "$id") || die "the liveness unit paths cannot be embedded safely in a systemd unit"
  timer=$(render_timer "$id")
  mkdir -p "$dir"
  printf '%s\n' "$service" > "$dir/.$base.service.tmp.$$"
  mv -f -- "$dir/.$base.service.tmp.$$" "$dir/$base.service"
  printf '%s\n' "$timer" > "$dir/.$base.timer.tmp.$$"
  mv -f -- "$dir/.$base.timer.tmp.$$" "$dir/$base.timer"
  fm_remote_job_systemd_user daemon-reload >/dev/null 2>&1 || die "systemctl --user daemon-reload failed"
  fm_remote_job_systemd_user enable --now "$base.timer" >/dev/null 2>&1 || die "systemctl --user could not enable $base.timer"
  printf 'installed: %s.timer every %ss\n' "$base" "$INTERVAL" >&2
}

cmd_remove() {
  local id=$1 dir base
  validate_id "$id"
  if ! fm_remote_job_systemd_user_available; then
    return 0
  fi
  dir="${HOME:-}/.config/systemd/user"
  base=$(unit_base "$id")
  [ -e "$dir/$base.timer" ] || [ -e "$dir/$base.service" ] || return 0
  fm_remote_job_systemd_user disable --now "$base.timer" >/dev/null 2>&1 || true
  rm -f -- "$dir/$base.timer" "$dir/$base.service"
  fm_remote_job_systemd_user daemon-reload >/dev/null 2>&1 || true
  printf 'removed: %s.timer\n' "$base" >&2
}

case "${1:-}" in
  probe) shift; cmd_probe "$@" ;;
  install) shift; [ "$#" -eq 1 ] || usage; cmd_install "$1" ;;
  remove) shift; [ "$#" -eq 1 ] || usage; cmd_remove "$1" ;;
  *) usage ;;
esac
