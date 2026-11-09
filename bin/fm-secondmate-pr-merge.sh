#!/usr/bin/env bash
# Merge a Forgejo pull request a registered second mate reported, on the
# captain's explicit word, from the main home.
#
# A second mate's pull request belongs to a task in the mate's own home, so
# bin/fm-pr-check.sh refuses to record it against the mate and the main home has
# no task record bin/fm-pr-merge.sh could merge it through. This script gives
# the main home one narrow, captain-bound record per pull request instead, and
# merges only through bin/fm-pr-merge.sh --secondmate-pr, so every merge gate
# that script owns applies unchanged: open, not a draft, mergeable, a successful
# combined status at the live head, the head bound to the content that was
# presented, the content guard, the away-posture and captain-hold reads, a
# head-bound merge call, and a recorded outcome. Nothing here merges on its own.
#
# Usage:
#   fm-secondmate-pr-merge.sh arm <secondmate-id> <pr-url> --instruction <words> [--head <sha>]
#   fm-secondmate-pr-merge.sh merge <record-id>
#   fm-secondmate-pr-merge.sh poll <record-id>
#   fm-secondmate-pr-merge.sh disarm <record-id> [--reason <text>]
#   fm-secondmate-pr-merge.sh list
#   fm-secondmate-pr-merge.sh -h | --help
#
# arm records the captain's instruction and binds the pull request's head. It is
# refused unless this is a main home, <secondmate-id> is a secondmate this home
# records (state/<id>.meta with kind=secondmate), <pr-url> is a Forgejo pull
# request URL that appears in a done line on that mate's routed status channel
# (state/<id>.status), --instruction carries the captain's own words and names
# that pull request by its URL or its number, and exactly one "tea login" is
# registered for the host. The head bound is the live head at arm time, and
# --head <sha>, the head that was presented, refuses the arm when the live head
# differs. arm also fetches that head into a private bare repository for the
# content guard, and refuses when it cannot. The record id it prints is
# <secondmate-id>-pr-<repo>-<number>, with characters outside [A-Za-z0-9_-]
# replaced by "_". arm then registers a custom watcher check, state/<record-id>.check.sh,
# that runs "poll" on every check sweep, so the merge happens once checks are
# green without another turn. No standing authority is created: one record names
# one pull request at one head, and closes for good after one outcome.
#
# merge attempts the merge now. poll is what the armed check runs, and differs
# only in printing nothing while there is nothing to report, because its stdout
# becomes the watcher's wake text. Both read the pull request first:
#   - checks pending, or no status reported yet: nothing happens and the record
#     stays armed (merge exits 3 saying so);
#   - an unreadable read: nothing happens and the record stays armed (merge
#     exits 1 saying so);
#   - merged, closed, a head that moved from the bound one, or a combined
#     status that is not success: the record closes and the outcome is
#     reported, with no merge attempted;
#   - green at the bound head: bin/fm-pr-merge.sh --secondmate-pr runs, and
#     whatever it decides closes the record - merged, or refused with its own
#     first error lines reported.
# A closed record never merges again; arming the same pull request again needs a
# fresh captain instruction. disarm closes an armed record without merging.
# Every close moves the record's files to state/secondmate-prs/closed/ and
# retires its watcher check. The mate's own task records and home are never read
# or written beyond its main-home status and metadata lines; the mate learns of
# the merge through the forge.
#
# A poll that merges runs inside the watcher's per-check time bound
# (bin/fm-watch.sh FM_CHECK_TIMEOUT). A cut run leaves the record armed, and the
# next sweep re-reads the pull request, so a merge that landed before the cut is
# reported as merged rather than attempted again.
#
# Record layout, all mode 0600 under state/secondmate-prs/:
#   <record-id>.meta    kind=secondmate-pr, secondmate=, reported_pr=,
#                       instruction=, instructed_at=, worktree= (the private
#                       bare repository), then pr= and pr_head= from the binding
#   <record-id>.git/    the private bare repository the content guard fetches into
#   <record-id>.*       the binding, guard, and authority records
#                       bin/fm-pr-check.sh and bin/fm-pr-merge.sh write there
#   closed/<record-id>-<epoch>/  a closed record, its meta carrying outcome=
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORDS="$STATE/secondmate-prs"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-binding-lib.sh
. "$SCRIPT_DIR/fm-pr-binding-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

die() {  # <message> [exit-code]
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

record_value() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   '
}

# 0 when a done line on the mate's routed status channel names <url>, compared
# by canonical identity so trailing punctuation or a non-canonical spelling of
# the same pull request still matches.
mate_reported_url() {  # <status-file> <canonical-url>
  local file=$1 want=$2 line token
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = "done" ] || continue
    while IFS= read -r token; do
      while :; do
        case "$token" in
          *[\).,\;:\'\"]) token=${token%?} ;;
          *) break ;;
        esac
      done
      if ( fm_pr_url_parse "$token" && [ "$FM_PR_URL" = "$want" ] ); then
        return 0
      fi
    done < <(printf '%s\n' "$line" | grep -oE 'https://[^[:space:]]+' || true)
  done < "$file"
  return 1
}

# The instruction names the pull request by its URL or by its number as a whole
# token, so an instruction about PR 7 never authorizes PR 70.
instruction_names_pr() {  # <instruction> <url> <number>
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf '%s\n' "$1" | grep -Eq "(^|[^0-9])$3([^0-9]|\$)"
}

record_lock() {  # <record-id>
  printf '%s/.secondmate-pr-%s.lock\n' "$RECORDS" "$1"
}

LOCK_HELD=
release_lock() {
  [ -z "$LOCK_HELD" ] || fm_lock_release "$LOCK_HELD" || true
  LOCK_HELD=
}
trap release_lock EXIT

valid_record_id() {
  fm_pr_task_id_valid "$1" || die "invalid second mate PR record id" 2
}

# Move every file of an armed record to closed/, record why, and retire its
# watcher check, so a closed record can never be merged or polled again.
close_record() {  # <record-id> <outcome> <detail>
  local rid=$1 outcome=$2 detail now dest entry
  detail=$(one_line "$3")
  now=$(date +%s)
  dest="$RECORDS/closed/$rid-$now"
  mkdir -p "$RECORDS/closed" || die "could not close second mate PR record $rid"
  mkdir "$dest" || die "could not close second mate PR record $rid"
  printf 'outcome=%s\noutcome_detail=%s\nclosed_at=%s\n' "$outcome" "$detail" "$now" >> "$RECORDS/$rid.meta" \
    || die "could not close second mate PR record $rid"
  for entry in "$RECORDS/$rid".*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    mv -- "$entry" "$dest/" || die "could not close second mate PR record $rid"
  done
  # The fetch cache is only the content guard's input; the closed meta keeps
  # the record of what happened.
  [ ! -d "$dest/$rid.git" ] || rm -rf -- "${dest:?}/$rid.git"
  if [ -e "$STATE/$rid.check.sh" ] || [ -e "$STATE/$rid.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$rid" >/dev/null \
      || printf 'warning: the watcher check for %s could not be retired\n' "$rid" >&2
  fi
}

cmd_arm() {
  local mate=${1:-} raw_url=${2:-} instruction='' presented_head='' url host path owner repo number
  local rid login cache meta tmp check check_tmp fetched bound
  [ "$#" -ge 2 ] || die "usage: fm-secondmate-pr-merge.sh arm <secondmate-id> <pr-url> --instruction <words> [--head <sha>]" 2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instruction)
        [ "$#" -ge 2 ] || die "--instruction requires the captain's words" 2
        instruction=$(one_line "$2")
        shift 2
        ;;
      --head)
        [ "$#" -ge 2 ] || die "--head requires a commit" 2
        presented_head=$2
        shift 2
        ;;
      *) die "unknown arm argument: $1" 2 ;;
    esac
  done

  # Only the main home answers to the captain directly; a secondmate home's
  # merges belong to its own tasks.
  local home_rc=0
  fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1 || home_rc=$?
  [ "$home_rc" -eq 1 ] \
    || die "arm is refused outside a main home: a secondmate home merges only its own tasks' pull requests"
  fm_pr_task_id_valid "$mate" || die "invalid secondmate id" 2
  [ -f "$STATE/$mate.meta" ] && [ ! -L "$STATE/$mate.meta" ] \
    && [ "$(record_value "$STATE/$mate.meta" kind)" = secondmate ] \
    || die "$mate is not a secondmate this home records"
  fm_pr_url_parse "$raw_url" || die "invalid pull request URL" 2
  url=$FM_PR_URL
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  owner=$FM_PR_OWNER
  repo=$FM_PR_REPO
  number=$FM_PR_NUMBER
  [ "$FM_PR_PROVIDER" = forgejo ] \
    || die "only Forgejo pull requests are supported; $url is a $FM_PR_PROVIDER URL"
  mate_reported_url "$STATE/$mate.status" "$url" \
    || die "$url was not reported in a done line on second mate $mate's status channel; arm only a URL the mate reported"
  [ -n "$(printf '%s' "$instruction" | tr -d '[:space:]')" ] \
    || die "no captain instruction recorded; pass the captain's own words with --instruction"
  instruction_names_pr "$instruction" "$url" "$number" \
    || die "the captain instruction does not name $url by its URL or number $number"
  if [ -n "$presented_head" ]; then
    fm_pr_head_valid "$presented_head" || die "--head must be a full commit id" 2
  fi
  local tool
  for tool in tea jq git; do
    command -v "$tool" >/dev/null 2>&1 || die "arming a Forgejo merge requires tea, jq, and git on PATH"
  done
  login=$(fm_pr_forgejo_login "$host") \
    || die "merging a Forgejo pull request at $host requires exactly one 'tea login' registered for that host (see 'tea login list')"

  rid=$(printf '%s-pr-%s-%s' "$mate" "$repo" "$number" | LC_ALL=C tr -c 'A-Za-z0-9_\n-' '_')
  fm_pr_task_id_valid "$rid" || die "could not derive a record id for $url"
  [ ! -e "$STATE/$rid.meta" ] && [ ! -e "$STATE/$rid.check.sh" ] && [ ! -e "$STATE/$rid.check-trust" ] \
    || die "record id $rid collides with an existing task or check in this home"
  [ ! -L "$RECORDS" ] || die "the second mate PR record directory is not a real directory"
  mkdir -p "$RECORDS"
  chmod 0700 "$RECORDS"
  fm_lock_acquire_wait "$(record_lock "$rid")"
  LOCK_HELD=$(record_lock "$rid")
  meta="$RECORDS/$rid.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    die "$rid is already armed for $(record_value "$meta" reported_pr); disarm it before arming again"
  fi

  fm_pr_forgejo_read_record "$host" "$path" "$number" || die "could not read $url"
  [ "$FM_PR_RECORD_MERGED" = false ] && [ "$FM_PR_RECORD_STATE" = open ] \
    || die "$url is not an open, unmerged pull request (state=$FM_PR_RECORD_STATE, merged=$FM_PR_RECORD_MERGED)"
  fm_pr_head_valid "$FM_PR_RECORD_HEAD" || die "could not read the head of $url"
  if [ -n "$presented_head" ] && [ "$presented_head" != "$FM_PR_RECORD_HEAD" ]; then
    die "the head of $url is now $FM_PR_RECORD_HEAD, not the presented $presented_head; present the changed pull request to the captain again"
  fi

  # The content guard compares the head against a freshly fetched base inside
  # a git repository; a private bare one is fetched now so the merge-time fetch
  # is incremental and an unreachable repository refuses the arm, not the merge.
  cache="$RECORDS/$rid.git"
  [ ! -e "$cache" ] || rm -rf -- "${RECORDS:?}/$rid.git"
  git init -q --bare "$cache"
  git -C "$cache" remote add origin "https://$host/$owner/$repo.git"
  fetched=
  if GIT_TERMINAL_PROMPT=0 git -C "$cache" fetch --no-tags --quiet origin \
      "+refs/pull/$number/head:refs/fm-merge-guard/$rid/head" >/dev/null 2>&1; then
    fetched=$(git -C "$cache" rev-parse --verify --quiet "refs/fm-merge-guard/$rid/head^{commit}" 2>/dev/null || true)
  fi
  if [ "$fetched" != "$FM_PR_RECORD_HEAD" ]; then
    rm -rf -- "${RECORDS:?}/$rid.git"
    die "could not fetch the head of $url from https://$host/$owner/$repo.git for the content guard"
  fi

  umask 077
  tmp=$(mktemp "$RECORDS/.secondmate-pr-meta.XXXXXX")
  printf '%s\n' \
    "kind=secondmate-pr" \
    "secondmate=$mate" \
    "reported_pr=$url" \
    "instruction=$instruction" \
    "instructed_at=$(date +%s)" \
    "worktree=$cache" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$meta"

  # bin/fm-pr-check.sh is the only binding writer; its merge-time path is the one
  # that reads a Forgejo head, so the binding names the head read just above.
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$RECORDS" FM_PR_CHECK_MERGE=1 \
      "$SCRIPT_DIR/fm-pr-check.sh" "$rid" "$url" >/dev/null; then
    close_record "$rid" arm-failed "the pull request binding could not be recorded"
    die "could not bind $url; nothing is armed"
  fi
  bound=
  if fm_pr_binding_read "$RECORDS" "$rid" && [ "$FM_PR_BINDING_URL" = "$url" ]; then
    bound=$FM_PR_BINDING_HEAD
  fi
  if [ "$bound" != "$FM_PR_RECORD_HEAD" ]; then
    close_record "$rid" arm-failed "the head moved while the instruction was recorded"
    die "the head of $url moved while arming (bound ${bound:-none}, read $FM_PR_RECORD_HEAD); present it to the captain again"
  fi

  check="$STATE/$rid.check.sh"
  check_tmp=$(mktemp "$STATE/.secondmate-pr-check.XXXXXX")
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Armed by bin/fm-secondmate-pr-merge.sh for %s, reported by second mate %s.\n' "$url" "$mate"
    printf 'FM_HOME=%q FM_STATE_OVERRIDE=%q exec %q poll %q\n' "$FM_HOME" "$STATE" "$SCRIPT_DIR/fm-secondmate-pr-merge.sh" "$rid"
  } > "$check_tmp"
  chmod 0700 "$check_tmp"
  mv -f -- "$check_tmp" "$check"
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$rid" >/dev/null; then
    close_record "$rid" arm-failed "the watcher check could not be registered"
    die "could not register the watcher check for $rid; nothing is armed"
  fi
  printf 'armed: %s merges %s, reported by second mate %s, once its checks are green at head %s\n' \
    "$rid" "$url" "$mate" "$bound"
}

# One attempt for an armed record. <mode> is merge or poll; see the header for
# what each outcome does. Prints the captain-relevant outcome on stdout.
attempt() {  # <mode> <record-id>
  local mode=$1 rid=$2 meta url mate login output rc first
  meta="$RECORDS/$rid.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    [ "$mode" = poll ] && return 0
    die "no second mate PR record is armed for $rid"
  fi
  url=$(record_value "$meta" reported_pr)
  mate=$(record_value "$meta" secondmate)
  # A record this script cannot read back can never merge; closing it reports
  # the fault once instead of a silent poll on every sweep.
  if ! fm_pr_url_parse "$url" || ! fm_pr_binding_read "$RECORDS" "$rid" \
    || [ "$FM_PR_BINDING_URL" != "$url" ] || ! fm_pr_head_valid "$FM_PR_BINDING_HEAD"; then
    close_record "$rid" unreadable "the record or its head binding could not be read"
    printf 'second mate PR record %s was unreadable and is disarmed; nothing was merged\n' "$rid"
    [ "$mode" = poll ] && return 0
    return 1
  fi
  if ! login=$(fm_pr_forgejo_login "$FM_PR_HOST") \
    || ! fm_pr_forgejo_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    [ "$mode" = poll ] && return 0
    die "could not read $url; $rid stays armed"
  fi
  if [ "$FM_PR_RECORD_MERGED" = true ]; then
    close_record "$rid" merged-elsewhere "already merged when read"
    printf 'second mate %s PR %s is merged; this armed instruction found it already merged, so no merge was attempted\n' "$mate" "$url"
    return 0
  fi
  if [ "$FM_PR_RECORD_STATE" != open ]; then
    close_record "$rid" closed "state is $FM_PR_RECORD_STATE"
    printf 'second mate %s PR %s is %s, not open; the armed merge is withdrawn and nothing was merged\n' "$mate" "$url" "$FM_PR_RECORD_STATE"
    return 0
  fi
  if [ "$FM_PR_RECORD_HEAD" != "$FM_PR_BINDING_HEAD" ]; then
    close_record "$rid" head-moved "head moved from $FM_PR_BINDING_HEAD to $FM_PR_RECORD_HEAD"
    printf 'second mate %s PR %s: merge refused and disarmed, its head moved from the presented %s to %s; present the changed pull request to the captain again\n' \
      "$mate" "$url" "$FM_PR_BINDING_HEAD" "$FM_PR_RECORD_HEAD"
    return 0
  fi
  fm_pr_forgejo_combined_status "$login" "$FM_PR_PATH" "$FM_PR_RECORD_HEAD"
  case "$FM_PR_FORGEJO_CI_STATE" in
    success) ;;
    pending | none)
      [ "$mode" = poll ] && return 0
      printf 'not green yet: %s has combined status "%s" at head %s; %s stays armed and merges once it is green\n' \
        "$url" "$FM_PR_FORGEJO_CI_STATE" "$FM_PR_RECORD_HEAD" "$rid" >&2
      return 3
      ;;
    unreadable)
      [ "$mode" = poll ] && return 0
      die "could not read the checks of $url; $rid stays armed"
      ;;
    *)
      close_record "$rid" checks-red "combined status $FM_PR_FORGEJO_CI_STATE at $FM_PR_RECORD_HEAD"
      printf 'second mate %s PR %s: merge refused and disarmed, its checks are "%s" at head %s; nothing was merged\n' \
        "$mate" "$url" "$FM_PR_FORGEJO_CI_STATE" "$FM_PR_RECORD_HEAD"
      return 0
      ;;
  esac

  rc=0
  output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-pr-merge.sh" "$rid" "$url" --secondmate-pr 2>&1) || rc=$?
  [ "$mode" = poll ] || printf '%s\n' "$output" >&2
  if [ "$rc" -eq 0 ]; then
    close_record "$rid" merged "merged at head $FM_PR_RECORD_HEAD"
    printf 'second mate %s PR %s merged at head %s on the recorded captain instruction; the mate'"'"'s own home cleans up its task\n' \
      "$mate" "$url" "$FM_PR_RECORD_HEAD"
    return 0
  fi
  first=$(printf '%s\n' "$output" | grep -E '^(error|actionable):|^  - ' | head -4 | tr '\n' ' ')
  close_record "$rid" merge-refused "${first:-bin/fm-pr-merge.sh exited $rc}"
  printf 'second mate %s PR %s: merge refused and disarmed by the merge gate: %s\n' \
    "$mate" "$url" "$(one_line "${first:-bin/fm-pr-merge.sh exited $rc}")"
  [ "$mode" = poll ] && return 0
  return 1
}

cmd_merge() {
  local rid=${1:-} rc=0
  [ "$#" -eq 1 ] || die "usage: fm-secondmate-pr-merge.sh merge <record-id>" 2
  valid_record_id "$rid"
  [ -d "$RECORDS" ] && [ ! -L "$RECORDS" ] || die "no second mate PR record is armed for $rid"
  fm_lock_acquire_wait "$(record_lock "$rid")"
  LOCK_HELD=$(record_lock "$rid")
  attempt merge "$rid" || rc=$?
  return "$rc"
}

cmd_poll() {
  local rid=${1:-}
  [ "$#" -eq 1 ] || die "usage: fm-secondmate-pr-merge.sh poll <record-id>" 2
  valid_record_id "$rid"
  [ -d "$RECORDS" ] && [ ! -L "$RECORDS" ] || return 0
  # A manual merge or disarm already holds the record; the next sweep re-reads.
  fm_lock_try_acquire "$(record_lock "$rid")" || return 0
  LOCK_HELD=$(record_lock "$rid")
  attempt poll "$rid" || true
}

cmd_disarm() {
  local rid=${1:-} reason='disarmed on request' meta url
  [ "$#" -ge 1 ] || die "usage: fm-secondmate-pr-merge.sh disarm <record-id> [--reason <text>]" 2
  shift
  if [ "$#" -gt 0 ]; then
    [ "$1" = --reason ] && [ "$#" -eq 2 ] || die "usage: fm-secondmate-pr-merge.sh disarm <record-id> [--reason <text>]" 2
    reason=$2
  fi
  valid_record_id "$rid"
  [ -d "$RECORDS" ] && [ ! -L "$RECORDS" ] || die "no second mate PR record is armed for $rid"
  fm_lock_acquire_wait "$(record_lock "$rid")"
  LOCK_HELD=$(record_lock "$rid")
  meta="$RECORDS/$rid.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "no second mate PR record is armed for $rid"
  url=$(record_value "$meta" reported_pr)
  close_record "$rid" disarmed "$reason"
  printf 'disarmed: %s; %s will not be merged by this record\n' "$rid" "$url"
}

cmd_list() {
  local meta rid
  [ -d "$RECORDS" ] || return 0
  for meta in "$RECORDS"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    rid=${meta##*/}
    rid=${rid%.meta}
    printf '%s secondmate=%s pr=%s head=%s instruction=%s\n' "$rid" \
      "$(record_value "$meta" secondmate)" "$(record_value "$meta" reported_pr)" \
      "$(record_value "$meta" pr_head)" "$(record_value "$meta" instruction)"
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
sub=$1
shift
case "$sub" in
  arm) cmd_arm "$@" ;;
  merge) cmd_merge "$@" ;;
  poll) cmd_poll "$@" ;;
  disarm) cmd_disarm "$@" ;;
  list) cmd_list ;;
  *) usage >&2; exit 2 ;;
esac
