#!/usr/bin/env bash
# Merge a Forgejo pull request a registered second mate reported, on the
# captain's explicit word or the captain's standing grant for its repository,
# from the main home.
#
# A second mate's pull request belongs to a task in the mate's own home, so
# bin/fm-pr-check.sh refuses to record it against the mate and the main home has
# no task record bin/fm-pr-merge.sh could merge it through. This script gives
# the main home one narrow, captain-bound record per pull request instead, and
# merges only through bin/fm-pr-merge.sh --secondmate-pr, so every merge gate
# that script owns applies unchanged: open, not a draft, mergeable, a successful
# combined status at the live head, the head bound to the content that was
# presented, the content guard, the away-posture and captain-hold reads, a
# head-bound merge call, and a recorded outcome. Nothing here merges without a
# recorded per-PR captain instruction or a standing captain grant.
#
# Usage:
#   fm-secondmate-pr-merge.sh arm <secondmate-id> <pr-url> --instruction <words> [--head <sha>]
#   fm-secondmate-pr-merge.sh arm <secondmate-id> <pr-url> --grant [--head <sha>]
#   fm-secondmate-pr-merge.sh auto
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
# green without another turn. An instruction creates no standing authority: one
# record names one pull request at one head, and closes for good after one
# outcome.
#
# Standing grant. The captain may grant one second mate standing merge
# authority for one Forgejo repository; firstmate writes the grant to the
# captain-private config/secondmate-pr-auto-merge, and nothing else ever does.
# One grant per line, blank lines and lines starting with # ignored:
#   <secondmate-id> <repository-url> <the captain's verbatim words>
# for example
#   agent-dev https://git.example/owner/repo merge their PRs once green
# The file must be a regular, single-link file that only its owner can write;
# otherwise it grants nothing. A line that does not parse grants nothing and is
# reported once per change of the file.
# arm --grant arms under that grant instead of a per-PR instruction: the
# record's instruction is the grant's words and its authority=grant, and every
# other arming condition above still holds. It is refused when no grant names
# the mate and the pull request's repository, and refused for escalation (exit
# 4) when the pull request's own diff, from its merge base with the fetched base
# branch, touches a dependency manifest, lockfile, or vendored tree: go.mod,
# go.sum, go.work, go.work.sum, Cargo.toml, Cargo.lock, package.json,
# package-lock.json, npm-shrinkwrap.json, yarn.lock, pnpm-lock.yaml,
# pnpm-workspace.yaml, bun.lock, bun.lockb, requirements*.txt, requirements*.in,
# constraints*.txt, pyproject.toml, uv.lock, poetry.lock, Pipfile, Pipfile.lock,
# setup.py, setup.cfg, Gemfile, Gemfile.lock, in any directory, or anything
# under a vendor/ directory. Such a pull request merges only on the captain's
# per-PR instruction.
# auto is the sweep the watcher runs before its other checks while
# config/secondmate-pr-auto-merge exists (bin/fm-watch.sh). For each granted
# mate it reads the newest done line on the mate's status channel naming each
# pull request in a granted repository, and acts once per such line: a
# pull request that is already armed, or that the sweep cannot read right now,
# waits for a later sweep; a merged or closed one is noted silently; otherwise
# it runs arm --grant, with --head <sha> when the line carries "<url> head
# <sha>". An escalation or a refused arm prints one line naming the pull
# request. A later done line for the same pull request, such as the mate's
# report of a new head after red checks or a moved head, is acted on again;
# the same line never is. What the sweep acted on is kept in
# state/secondmate-prs/auto/<record-id>.seen.
# A grant-armed record also closes, unmerged, when its grant has been removed.
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
#     first error lines reported. A content-guard finding is such a refusal;
#     nothing here passes --allow-content.
# A closed record never merges again; arming the same pull request again needs a
# fresh captain instruction, or under a grant a new done line from the mate.
# disarm closes an armed record without merging.
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
#                       instruction=, instructed_at=, authority= (instruction
#                       or grant), grant_repo= under a grant, worktree= (the
#                       private bare repository), then pr= and pr_head= from
#                       the binding
#   <record-id>.git/    the private bare repository the content guard fetches into
#   <record-id>.*       the binding, guard, and authority records
#                       bin/fm-pr-check.sh and bin/fm-pr-merge.sh write there
#   closed/<record-id>-<epoch>/  a closed record, its meta carrying outcome=
#   auto/<record-id>.seen        the done line the auto sweep last acted on
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORDS="$STATE/secondmate-prs"
GRANTS="$CONFIG/secondmate-pr-auto-merge"
AUTO="$RECORDS/auto"

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

record_id_for() {  # <secondmate-id> <repo> <number>
  printf '%s-pr-%s-%s' "$1" "$2" "$3" | LC_ALL=C tr -c 'A-Za-z0-9_\n-' '_'
}

# 0 when the grant file may be trusted: a regular, single-link file no one but
# its owner can write. Anything else grants nothing.
grants_file_trusted() {
  [ -f "$GRANTS" ] && [ ! -L "$GRANTS" ] || return 1
  [ "$(fm_pr_file_link_count "$GRANTS" 2>/dev/null)" = 1 ] || return 1
  [ -O "$GRANTS" ] || return 1
  [ -z "$(find "$GRANTS" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]
}

# Each well-formed grant as "<mate>\t<host>\t<path>\t<words>" on stdout, the
# repository canonicalized through the same parser that reads pull request
# URLs. With <malformed-var>, the numbers of the lines that grant nothing are
# stored there.
grants_read() {  # [<malformed-var>]
  local line n=0 mate repo words bad=''
  grants_file_trusted || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=$(one_line "$line")
    case "$line" in
      '' | '#'*) continue ;;
    esac
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    read -r mate repo words <<EOF
$line
EOF
    repo=${repo%/}
    repo=${repo%.git}
    if [ -z "${words:-}" ] || ! fm_pr_task_id_valid "${mate:-}" \
      || ! ( fm_pr_url_parse "$repo/pulls/1" && [ "$FM_PR_PROVIDER" = forgejo ] ); then
      bad="${bad:+$bad }$n"
      continue
    fi
    fm_pr_url_parse "$repo/pulls/1"
    printf '%s\t%s\t%s\t%s\n' "$mate" "$FM_PR_HOST" "$FM_PR_PATH" "$words"
  done < "$GRANTS"
  [ -z "${1:-}" ] || printf -v "$1" '%s' "$bad"
}

# 0 when a grant names <mate> for the repository <host>/<path>; GRANT_WORDS and
# GRANT_REPO then hold the captain's words and the repository URL.
GRANT_WORDS=
GRANT_REPO=
grant_for() {  # <mate> <host> <path>
  local mate host path words
  GRANT_WORDS=
  GRANT_REPO=
  while IFS="$(printf '\t')" read -r mate host path words; do
    if [ "$mate" = "$1" ] && [ "$host" = "$2" ] && [ "$path" = "$3" ]; then
      GRANT_WORDS=$words
      GRANT_REPO="https://$host/$path"
      return 0
    fi
  done < <(grants_read)
  return 1
}

# 0 when <file> is a dependency manifest, lockfile, or vendored file; the
# header owns the list.
dependency_file() {  # <repo-relative path>
  case "$1" in
    vendor/* | */vendor/*) return 0 ;;
  esac
  case "${1##*/}" in
    go.mod | go.sum | go.work | go.work.sum | Cargo.toml | Cargo.lock | package.json \
      | package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-lock.yaml \
      | pnpm-workspace.yaml | bun.lock | bun.lockb | requirements*.txt | requirements*.in \
      | constraints*.txt | pyproject.toml | uv.lock | poetry.lock | Pipfile | Pipfile.lock \
      | setup.py | setup.cfg | Gemfile | Gemfile.lock)
      return 0
      ;;
  esac
  return 1
}

# The dependency files the pull request's own diff touches, space-separated,
# from the fetched head in <cache> against its merge base with the fetched
# base branch. Returns 1 when the diff cannot be computed.
pr_dependency_files() {  # <cache> <login> <path> <number> <head>
  local cache=$1 login=$2 path=$3 number=$4 head=$5 base mb changed file found=''
  base=$(tea api --login "$login" --repo "$path" "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null \
    | jq -r 'if type == "object" and (.base.ref | type) == "string" then .base.ref else empty end' 2>/dev/null) \
    || return 1
  [ -n "$base" ] && git check-ref-format --branch "$base" >/dev/null 2>&1 || return 1
  GIT_TERMINAL_PROMPT=0 git -C "$cache" fetch --no-tags --quiet origin \
    "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 || return 1
  mb=$(git -C "$cache" merge-base "refs/remotes/origin/$base" "$head" 2>/dev/null) && [ -n "$mb" ] || return 1
  changed=$(git -C "$cache" -c core.quotePath=false diff --no-ext-diff --no-renames --name-only "$mb" "$head" -- 2>/dev/null) \
    || return 1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    dependency_file "$file" && found="${found:+$found }$file"
  done <<EOF
$changed
EOF
  printf '%s\n' "$found"
}

LOCK_HELD=
SWEEP_LOCK_HELD=
release_lock() {
  [ -z "$LOCK_HELD" ] || fm_lock_release "$LOCK_HELD" || true
  LOCK_HELD=
}
release_locks() {
  release_lock
  [ -z "$SWEEP_LOCK_HELD" ] || fm_lock_release "$SWEEP_LOCK_HELD" || true
  SWEEP_LOCK_HELD=
}
trap release_locks EXIT

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
  local rid login cache meta tmp check check_tmp fetched bound use_grant=false instruction_given=false
  local authority=instruction grant_repo='' deps
  [ "$#" -ge 2 ] || die "usage: fm-secondmate-pr-merge.sh arm <secondmate-id> <pr-url> (--instruction <words> | --grant) [--head <sha>]" 2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instruction)
        [ "$#" -ge 2 ] || die "--instruction requires the captain's words" 2
        instruction=$(one_line "$2")
        instruction_given=true
        shift 2
        ;;
      --grant)
        use_grant=true
        shift
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
  if [ "$use_grant" = true ]; then
    [ "$instruction_given" = false ] || die "--grant and --instruction are exclusive: a grant carries the captain's own words" 2
    grant_for "$mate" "$host" "$path" \
      || die "no standing captain grant in config/secondmate-pr-auto-merge names second mate $mate for https://$host/$path"
    instruction=$(one_line "$GRANT_WORDS")
    grant_repo=$GRANT_REPO
    authority=grant
  else
    [ -n "$(printf '%s' "$instruction" | tr -d '[:space:]')" ] \
      || die "no captain instruction recorded; pass the captain's own words with --instruction"
    instruction_names_pr "$instruction" "$url" "$number" \
      || die "the captain instruction does not name $url by its URL or number $number"
  fi
  if [ -n "$presented_head" ]; then
    fm_pr_head_valid "$presented_head" || die "--head must be a full commit id" 2
  fi
  local tool
  for tool in tea jq git; do
    command -v "$tool" >/dev/null 2>&1 || die "arming a Forgejo merge requires tea, jq, and git on PATH"
  done
  login=$(fm_pr_forgejo_login "$host") \
    || die "merging a Forgejo pull request at $host requires exactly one 'tea login' registered for that host (see 'tea login list')"

  rid=$(record_id_for "$mate" "$repo" "$number")
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

  # A standing grant never covers a dependency change; the captain keeps those.
  if [ "$use_grant" = true ]; then
    if ! deps=$(pr_dependency_files "$cache" "$login" "$path" "$number" "$FM_PR_RECORD_HEAD"); then
      rm -rf -- "${RECORDS:?}/$rid.git"
      die "could not compute the diff of $url against its base branch to check for dependency changes; nothing is armed"
    fi
    if [ -n "$deps" ]; then
      rm -rf -- "${RECORDS:?}/$rid.git"
      die "$url changes dependency files ($deps); the standing grant does not cover dependency changes, so it waits for the captain's per-PR word" 4
    fi
  fi

  umask 077
  tmp=$(mktemp "$RECORDS/.secondmate-pr-meta.XXXXXX")
  {
    printf '%s\n' \
      "kind=secondmate-pr" \
      "secondmate=$mate" \
      "reported_pr=$url" \
      "instruction=$instruction" \
      "instructed_at=$(date +%s)" \
      "authority=$authority"
    [ -z "$grant_repo" ] || printf 'grant_repo=%s\n' "$grant_repo"
    printf 'worktree=%s\n' "$cache"
  } > "$tmp"
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
  if [ "$use_grant" = true ]; then
    printf 'armed: %s merges %s, reported by second mate %s, once its checks are green at head %s, under the standing grant for %s\n' \
      "$rid" "$url" "$mate" "$bound" "$grant_repo"
  else
    printf 'armed: %s merges %s, reported by second mate %s, once its checks are green at head %s\n' \
      "$rid" "$url" "$mate" "$bound"
  fi
}

# One attempt for an armed record. <mode> is merge or poll; see the header for
# what each outcome does. Prints the captain-relevant outcome on stdout.
attempt() {  # <mode> <record-id>
  local mode=$1 rid=$2 meta url mate login output rc first grant_repo again
  meta="$RECORDS/$rid.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    [ "$mode" = poll ] && return 0
    die "no second mate PR record is armed for $rid"
  fi
  url=$(record_value "$meta" reported_pr)
  mate=$(record_value "$meta" secondmate)
  grant_repo=
  again='present the changed pull request to the captain again'
  if [ "$(record_value "$meta" authority)" = grant ]; then
    grant_repo=$(record_value "$meta" grant_repo)
    again='it re-arms under the standing grant when the second mate reports done again'
    # A grant the captain withdrew stops every record armed under it.
    if ! fm_pr_url_parse "$url" || ! grant_for "$mate" "$FM_PR_HOST" "$FM_PR_PATH" \
      || [ "$GRANT_REPO" != "$grant_repo" ]; then
      close_record "$rid" grant-revoked "no standing grant names $mate for ${grant_repo:-the repository}"
      printf 'second mate %s PR %s: the standing grant for %s is gone, so the automatic merge is withdrawn and nothing was merged\n' \
        "$mate" "$url" "${grant_repo:-its repository}"
      return 0
    fi
  fi
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
    printf 'second mate %s PR %s: merge refused and disarmed, its head moved from the presented %s to %s; %s\n' \
      "$mate" "$url" "$FM_PR_BINDING_HEAD" "$FM_PR_RECORD_HEAD" "$again"
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
      if [ -n "$grant_repo" ]; then
        printf 'second mate %s PR %s: merge refused and disarmed, its checks are "%s" at head %s; nothing was merged; %s\n' \
          "$mate" "$url" "$FM_PR_FORGEJO_CI_STATE" "$FM_PR_RECORD_HEAD" "$again"
      else
        printf 'second mate %s PR %s: merge refused and disarmed, its checks are "%s" at head %s; nothing was merged\n' \
          "$mate" "$url" "$FM_PR_FORGEJO_CI_STATE" "$FM_PR_RECORD_HEAD"
      fi
      return 0
      ;;
  esac

  rc=0
  output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-pr-merge.sh" "$rid" "$url" --secondmate-pr 2>&1) || rc=$?
  [ "$mode" = poll ] || printf '%s\n' "$output" >&2
  if [ "$rc" -eq 0 ]; then
    close_record "$rid" merged "merged at head $FM_PR_RECORD_HEAD"
    if [ -n "$grant_repo" ]; then
      printf 'second mate %s PR %s merged automatically at head %s under the captain'"'"'s standing grant for %s; the mate'"'"'s own home cleans up its task\n' \
        "$mate" "$url" "$FM_PR_RECORD_HEAD" "$grant_repo"
    else
      printf 'second mate %s PR %s merged at head %s on the recorded captain instruction; the mate'"'"'s own home cleans up its task\n' \
        "$mate" "$url" "$FM_PR_RECORD_HEAD"
    fi
    return 0
  fi
  first=$(printf '%s\n' "$output" | grep -E '^(error|actionable):|^  - ' | head -4 | tr '\n' ' ')
  close_record "$rid" merge-refused "${first:-bin/fm-pr-merge.sh exited $rc}"
  if [ -n "$grant_repo" ]; then
    # A merge-gate refusal, a content-guard finding among them, is never
    # overridden under a grant; the same head stays unmerged until the captain
    # rules on it.
    printf 'second mate %s PR %s: automatic merge refused and disarmed by the merge gate: %s; nothing merges past this refusal without the captain'"'"'s per-PR word\n' \
      "$mate" "$url" "$(one_line "${first:-bin/fm-pr-merge.sh exited $rc}")"
  else
    printf 'second mate %s PR %s: merge refused and disarmed by the merge gate: %s\n' \
      "$mate" "$url" "$(one_line "${first:-bin/fm-pr-merge.sh exited $rc}")"
  fi
  [ "$mode" = poll ] && return 0
  return 1
}

# Each granted pull request the mate's done lines name, one per line as
# "<url>\t<reported-head>\t<line-key>", taken from the newest done line naming
# it. The reported head is the commit after "<url> head" on that line, or empty;
# the key identifies the line itself so the sweep acts on it once.
granted_reports() {  # <mate>
  local mate=$1 file="$STATE/$1.status" line key token next after url head i
  local -a toks
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = "done" ] || continue
    key=$(printf '%s' "$line" | cksum | awk '{print $1 "-" $2}')
    read -ra toks <<EOF
$line
EOF
    i=0
    while [ "$i" -lt "${#toks[@]}" ]; do
      token=${toks[$i]}
      i=$((i + 1))
      case "$token" in
        *https://*) token="https://${token#*https://}" ;;
        *) continue ;;
      esac
      while :; do
        case "$token" in
          *[\).,\;:\'\"]) token=${token%?} ;;
          *) break ;;
        esac
      done
      fm_pr_url_parse "$token" && [ "$FM_PR_PROVIDER" = forgejo ] || continue
      url=$FM_PR_URL
      grant_for "$mate" "$FM_PR_HOST" "$FM_PR_PATH" || continue
      head=
      next=${toks[$i]:-}
      after=${toks[$((i + 1))]:-}
      after=${after%%[!0-9a-f]*}
      if [ "$next" = head ] && fm_pr_head_valid "$after"; then
        head=$after
      fi
      printf '%s\t%s\t%s\n' "$url" "$head" "$key"
    done
  done < "$file"
}

seen_key() {  # <record-id>
  record_value "$AUTO/$1.seen" key
}

mark_seen() {  # <record-id> <key> <outcome>
  local tmp
  tmp=$(mktemp "$AUTO/.seen.XXXXXX") || return 1
  printf 'key=%s\noutcome=%s\nat=%s\n' "$2" "$3" "$(date +%s)" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$AUTO/$1.seen"
}

# Close a grant-armed record that an interrupted arm left without its watcher
# check, so the sweep can arm it again; the caller holds no lock on it.
close_orphaned_grant_record() {  # <record-id>
  local rid=$1 meta="$RECORDS/$1.meta"
  [ "$(record_value "$meta" authority)" = grant ] || return 1
  [ ! -e "$STATE/$rid.check-trust" ] || return 1
  fm_lock_try_acquire "$(record_lock "$rid")" || return 1
  LOCK_HELD=$(record_lock "$rid")
  if [ -f "$meta" ] && [ ! -e "$STATE/$rid.check-trust" ]; then
    close_record "$rid" arm-interrupted "the arm stopped before its watcher check was registered"
  fi
  release_lock
  [ ! -e "$meta" ]
}

cmd_auto() {
  local home_rc=0 malformed='' fingerprint mate seen_mates=' ' url head key rid out rc
  [ "$#" -eq 0 ] || die "usage: fm-secondmate-pr-merge.sh auto" 2
  [ -e "$GRANTS" ] || [ -L "$GRANTS" ] || return 0
  fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1 || home_rc=$?
  [ "$home_rc" -eq 1 ] || return 0
  [ ! -L "$RECORDS" ] || return 0
  mkdir -p "$AUTO"
  chmod 0700 "$RECORDS" "$AUTO"
  fm_lock_try_acquire "$RECORDS/.secondmate-pr-auto.lock" || return 0
  SWEEP_LOCK_HELD="$RECORDS/.secondmate-pr-auto.lock"

  # A grant file that cannot be trusted, or a line that grants nothing, is
  # reported once per change of the file.
  fingerprint=$( { ls -ln "$GRANTS" 2>/dev/null; cksum < "$GRANTS" 2>/dev/null; } | cksum | awk '{print $1}')
  if grants_file_trusted; then
    grants_read malformed >/dev/null
  else
    malformed=untrusted
  fi
  if [ "$(cat "$AUTO/.grants-reported" 2>/dev/null || true)" != "$fingerprint" ]; then
    if [ "$malformed" = untrusted ]; then
      printf 'config/secondmate-pr-auto-merge grants nothing: it must be a regular, single-link file only its owner can write\n'
    elif [ -n "$malformed" ]; then
      printf 'config/secondmate-pr-auto-merge lines %s grant nothing: each grant is "<secondmate-id> <Forgejo repository URL> <the captain'"'"'s words>"\n' "$malformed"
    fi
    printf '%s\n' "$fingerprint" > "$AUTO/.grants-reported"
  fi
  [ "$malformed" != untrusted ] || return 0

  while IFS="$(printf '\t')" read -r mate _; do
    case "$seen_mates" in *" $mate "*) continue ;; esac
    seen_mates="$seen_mates$mate "
    [ -f "$STATE/$mate.meta" ] && [ ! -L "$STATE/$mate.meta" ] \
      && [ "$(record_value "$STATE/$mate.meta" kind)" = secondmate ] || continue
    # Only the newest report of each pull request counts.
    while IFS="$(printf '\t')" read -r url head key; do
      fm_pr_url_parse "$url" || continue
      rid=$(record_id_for "$mate" "$FM_PR_REPO" "$FM_PR_NUMBER")
      fm_pr_task_id_valid "$rid" || continue
      [ "$(seen_key "$rid")" != "$key" ] || continue
      if [ -e "$RECORDS/$rid.meta" ] || [ -L "$RECORDS/$rid.meta" ]; then
        close_orphaned_grant_record "$rid" || continue
      fi
      # An unreadable pull request is retried on a later sweep; a merged or
      # closed one needs nothing.
      fm_pr_forgejo_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" < /dev/null || continue
      if [ "$FM_PR_RECORD_MERGED" != false ] || [ "$FM_PR_RECORD_STATE" != open ]; then
        mark_seen "$rid" "$key" not-open || true
        continue
      fi
      rc=0
      out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
        "$SCRIPT_DIR/fm-secondmate-pr-merge.sh" arm "$mate" "$url" --grant ${head:+--head "$head"} 2>&1 >/dev/null < /dev/null) \
        || rc=$?
      out=$(printf '%s\n' "$out" | sed -n 's/^error: //p' | head -1)
      case "$rc" in
        0) mark_seen "$rid" "$key" armed || true ;;
        4)
          mark_seen "$rid" "$key" dependency-change || true
          printf 'second mate %s PR %s is not merged automatically: %s\n' "$mate" "$url" "${out:-it changes dependency files}"
          ;;
        *)
          mark_seen "$rid" "$key" arm-refused || true
          printf 'second mate %s PR %s could not be armed under the standing grant: %s\n' "$mate" "$url" "${out:-arm exited $rc}"
          ;;
      esac
    done < <(granted_reports "$mate" | awk -F '\t' '{ last[$1] = $0; if (!($1 in order)) { order[$1] = ++n; urls[n] = $1 } }
      END { for (i = 1; i <= n; i++) print last[urls[i]] }')
  done < <(grants_read)
  return 0
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
  auto) cmd_auto "$@" ;;
  merge) cmd_merge "$@" ;;
  poll) cmd_poll "$@" ;;
  disarm) cmd_disarm "$@" ;;
  list) cmd_list ;;
  *) usage >&2; exit 2 ;;
esac
