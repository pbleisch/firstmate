#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_PR_BINDING_* are public results for sourcing callers.
# The integrity record of a task's PR binding: which pull request, at which
# head and tree, merge authority applies to.
#
# bin/fm-pr-check.sh is the only writer. It records the binding together with
# the task metadata's pr= and pr_head= lines, under the same metadata lock:
#   state/<task-id>.pr-binding
#   fm-pr-binding-v1
#   pr=<canonical PR URL>
#   pr_head=<head commit, or empty when the forge read gave none>
#   pr_tree=<tree of that head, or empty when it was not readable locally>
#   recorded_epoch=<unix seconds>
#   reason=<one line: why this binding was recorded>
# The file is atomically published, mode 0600, single-link, and on the state
# filesystem.
#
# bin/fm-pr-merge.sh reads it twice. Before anything is recorded, the metadata's
# pr= and pr_head= must equal the record's exactly, so a binding changed by
# hand rather than through bin/fm-pr-check.sh is refused, and so is metadata
# carrying pr= or pr_head= with no record at all. After the live read, the
# merge is bound to the recorded head: a pull request whose head or tree moved
# since it was recorded and presented is refused until it is recorded again and
# presented to the captain again. bin/fm-pr-check.sh's header owns when a
# re-record may replace an existing binding.
#
# Sourced by those scripts and by tests. No side effects on source beyond its
# sourced library.

_FM_PR_BINDING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_PR_BINDING_LIB_DIR/fm-pr-lib.sh"

FM_PR_BINDING_PRESENT=0
FM_PR_BINDING_URL=
FM_PR_BINDING_HEAD=
FM_PR_BINDING_TREE=
FM_PR_BINDING_EPOCH=
FM_PR_BINDING_REASON=
FM_PR_BINDING_ERROR=

fm_pr_binding_path() {  # <state> <task-id>
  fm_pr_task_id_valid "$2" || return 1
  printf '%s/%s.pr-binding' "$1" "$2"
}

# One printable line of at most 300 bytes, so a reason can never add a field.
fm_pr_binding_clean_reason() {  # <text>
  local LC_ALL=C text
  text=$(printf '%s' "$1" | tr '\n\r\t' '   ' | tr -cd '[:print:]')
  printf '%s' "${text:0:300}"
}

# Parse one record file into FM_PR_BINDING_*. Returns 1 for anything that is not
# exactly the documented shape.
fm_pr_binding_parse() {  # <record> <device>
  local record=$1 device=$2 version pr head tree epoch reason
  FM_PR_BINDING_URL=
  FM_PR_BINDING_HEAD=
  FM_PR_BINDING_TREE=
  FM_PR_BINDING_EPOCH=
  FM_PR_BINDING_REASON=
  fm_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 8< "$record" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r pr <&8 || { exec 8<&-; return 1; }
  IFS= read -r head <&8 || { exec 8<&-; return 1; }
  IFS= read -r tree <&8 || { exec 8<&-; return 1; }
  IFS= read -r epoch <&8 || { exec 8<&-; return 1; }
  IFS= read -r reason <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-binding-v1 ] || return 1
  case "$pr" in pr=*) pr=${pr#pr=} ;; *) return 1 ;; esac
  case "$head" in pr_head=*) head=${head#pr_head=} ;; *) return 1 ;; esac
  case "$tree" in pr_tree=*) tree=${tree#pr_tree=} ;; *) return 1 ;; esac
  case "$epoch" in recorded_epoch=*) epoch=${epoch#recorded_epoch=} ;; *) return 1 ;; esac
  case "$reason" in reason=*) reason=${reason#reason=} ;; *) return 1 ;; esac
  ( fm_pr_url_parse "$pr" && [ "$FM_PR_URL" = "$pr" ] ) || return 1
  [ -z "$head" ] || fm_pr_head_valid "$head" || return 1
  [ -z "$tree" ] || fm_pr_head_valid "$tree" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  FM_PR_BINDING_URL=$pr
  FM_PR_BINDING_HEAD=$head
  FM_PR_BINDING_TREE=$tree
  FM_PR_BINDING_EPOCH=$epoch
    FM_PR_BINDING_REASON=$reason
}

# Read the task's record. Returns 0 with FM_PR_BINDING_PRESENT=0 when there is
# none, 0 with FM_PR_BINDING_PRESENT=1 and the fields set for a valid one, and
# 1 when a record exists but is unsafe or malformed.
fm_pr_binding_read() {  # <state> <task-id>
  local state=$1 id=$2 record device
  FM_PR_BINDING_PRESENT=0
  FM_PR_BINDING_URL=
  FM_PR_BINDING_HEAD=
  FM_PR_BINDING_TREE=
  FM_PR_BINDING_EPOCH=
  FM_PR_BINDING_REASON=
  record=$(fm_pr_binding_path "$state" "$id") || return 1
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    return 0
  fi
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_binding_parse "$record" "$device" || return 1
  FM_PR_BINDING_PRESENT=1
}

# Publish a record. The caller holds the task's metadata lock and writes the
# matching pr= and pr_head= lines in the same critical section.
fm_pr_binding_write() {  # <state> <task-id> <url> <head> <tree> <reason>
  local state=$1 id=$2 url=$3 head=$4 tree=$5 reason record device tmp='' status=0
  reason=$(fm_pr_binding_clean_reason "$6")
  record=$(fm_pr_binding_path "$state" "$id") || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$record" "$device" || return 1
  tmp=$(umask 077 && mktemp "$state/.fm-pr-binding.XXXXXX") || return 1
  printf 'fm-pr-binding-v1\npr=%s\npr_head=%s\npr_tree=%s\nrecorded_epoch=%s\nreason=%s\n' \
    "$url" "$head" "$tree" "$(date +%s)" "$reason" > "$tmp" || status=1
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" \
      && fm_pr_binding_parse "$tmp" "$device" \
      && fm_pr_regular_destination_on_device_or_absent "$record" "$device" \
      && mv -f -- "$tmp" "$record" \
      && fm_pr_binding_parse "$record" "$device" \
      || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  return "$status"
}

# Whether the metadata's pr= and pr_head= lines are exactly the recorded
# binding. Sets FM_PR_BINDING_ERROR to the refusal on mismatch, and leaves the
# record's fields in FM_PR_BINDING_* on success.
fm_pr_binding_meta_check() {  # <state> <task-id> <meta>
  local state=$1 id=$2 meta=$3 meta_pr meta_head
  FM_PR_BINDING_ERROR=
  meta_pr=$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2- || true)
  meta_head=$(grep '^pr_head=' "$meta" | tail -1 | cut -d= -f2- || true)
  if ! fm_pr_binding_read "$state" "$id"; then
    FM_PR_BINDING_ERROR="the PR binding record for task $id is unreadable or unsafe"
    return 1
  fi
  if [ "$FM_PR_BINDING_PRESENT" -eq 0 ]; then
    if [ -n "$meta_pr" ] || [ -n "$meta_head" ]; then
      FM_PR_BINDING_ERROR="task $id's metadata names pr=${meta_pr:-<none>} pr_head=${meta_head:-<none>} with no binding record, so that binding was not written by bin/fm-pr-check.sh"
      return 1
    fi
    return 0
  fi
  if [ "$meta_pr" != "$FM_PR_BINDING_URL" ] || [ "$meta_head" != "$FM_PR_BINDING_HEAD" ]; then
    FM_PR_BINDING_ERROR="task $id's metadata names pr=${meta_pr:-<none>} pr_head=${meta_head:-<none>}, but bin/fm-pr-check.sh recorded pr=$FM_PR_BINDING_URL pr_head=${FM_PR_BINDING_HEAD:-<none>}, so the metadata was changed by hand"
    return 1
  fi
}
