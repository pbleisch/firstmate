#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# A GitHub merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the pull request
# is open, not a draft, mergeable, free of conflicts, and every unwaived check
# is green at the exact current head commit, where github_checks_not_green below
# owns what makes a check green and judges each one by its current run.
# Every failing condition is reported, not
# just the first. The verified head is then passed to gh as
# --match-head-commit, so a push that lands between that read and the merge
# fails the merge instead of landing commits nothing verified. Reading that
# state needs gh and jq, and either one absent stops the merge before any
# state is recorded. An attended --allow-red <check-name> may be passed once,
# with the name as a separate argument; it waives only checks with that exact
# name, still requires every other check green, and still binds the head. It is
# refused while the away-posture record exists, and it never
# applies on GitLab, where a merge already requires the head pipeline to have
# succeeded. After gh returns success, GitHub's live state is read back and
# accepted only when the pull request is merged or in the merge queue. gh's
# GraphQL API supplies that queue-aware read; when that read fails, gh-axi's
# own view still proves a landed merge, and every outcome it cannot prove
# refuses, reporting the failed gh read and naming both failed reads when the
# gh-axi view could not prove the outcome either.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, an attended refusal names the queue's configured merge
# method and exact --attended-override -- --auto --<method> retry flags. While
# the away-posture record exists, asynchronous merge requests are refused and
# queue retry flags are not offered because they would outlive away authority.
# An attended caller that already passed the configured method with --auto is
# told instead that the accepted request has not entered the queue and its queue
# state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# A Gitea pull request is merged through tea's authenticated API, because tea
# has no merge command that binds a head. The instance comes from the one tea
# login bin/fm-pr-lib.sh resolves for the parsed host, and every read is bound
# to the requested URL through the pull request's own html_url. The merge is
# refused unless every pre-merge condition holds, each read live: the pull
# request is open, not merged, not a draft, mergeable, and every commit status
# at the exact current head is success, where an --allow-red <context> waives
# only that exact context. A head with no statuses at all has nothing red. The
# verified head is sent as head_commit_id, so Gitea itself refuses a merge whose
# head moved after that read. The merge style is the caller's --squash,
# --merge, --rebase, or --method <style>, and otherwise the repository's own
# default_merge_style; no other extra argument is accepted, and the request
# never asks Gitea to wait for checks, force past protection, or delete the
# branch. tea api exits 0 on an HTTP error, so each call's HTTP status line is
# read and only a 200 counts. After the merge, the pull request is read back
# and accepted only when it reports merged. Reading that state needs tea, jq,
# and exactly one tea login for the host, and any of them absent stops the
# merge before any state is recorded.
#
# Before any forge merge, the task's existing per-task control lock
# serializes the captain-hold check through the forge command. A still-held or
# unreadable row refuses before that command, so a captain approval must be
# recorded as an `answer --release` before this entrypoint is invoked. While
# state/.afk-contract exists any green merge may proceed under away authority:
# the record's presence is the whole mechanical fact, and which merge the
# captain's away words meant is the supervision session's reading
# (bin/fm-branch-prompt.sh "Postures"). An unreadable record refuses rather
# than being skipped, neither posture releases a captain hold, and away
# authority lapses when the record is archived.
# The authority read and synchronous forge command share the away record's
# cross-subsystem lock, which bin/fm-afk-contract.sh owns, closing the common
# live-owner TOCTOU; failure to take it refuses before the forge call. Async and
# queued paths are refused while away. Two confused-agent-grade limitations are
# accepted rather than hidden: queue or base changes after GitHub's preflight can
# still enqueue, and killing this shell can orphan a forge child after stale-lock
# recovery. docs/architecture.md owns those away-merge limits, while
# docs/captain-hold-lifecycle.md owns the separate merge-to-cleanup residual.
# A failed forge command releases the lock after it returns. A successful one
# retains the lock until the accepted merge authority is persisted against the
# still-matching task metadata.
#
# Merge authority is bound to the content that was recorded and presented.
# bin/fm-pr-check.sh is the only writer of a task's binding (pr=, pr_head=, and
# the integrity record bin/fm-pr-binding-lib.sh owns), so before anything is
# recorded a metadata binding that disagrees with that record, or one with no
# record at all, is refused as hand-edited. A GitHub or Gitea merge is then
# bound to the recorded head: a live head that differs, a tree that differs from
# the recorded tree, or a binding with no recorded head is refused until
# bin/fm-pr-check.sh records the pull request again and the changed pull
# request, with its diff stat, is presented to the captain again. A first
# merge-time record binds the head the forge reports at that moment, which for
# Gitea is always the first merge attempt, because a Gitea registration records
# no head. GitLab has no recorded head at all, so a GitLab merge is bound by
# identity only.
#
# A GitHub or Gitea merge also passes the content guard bin/fm-merge-guard-lib.sh owns:
# it prints the diff stat against a freshly fetched origin/<base>, records it in
# state/<task-id>.merge-guard, and refuses on any guard that lib names - a
# stale tree, deleted migrations or tests, mass deletion, a young unreviewed
# pull request on a base that requires no check, or a guard that could not run.
# An attended --allow-content <guard> waives exactly that named guard, may be
# repeated once per guard, is refused while the away-posture record exists like
# --allow-red, and is passed only when the captain names the guard. It never
# waives the head binding.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha or --match-head-commit because the head comes only from the
# live read. An existing task-meta pr= must equal the requested canonical URL;
# a task cannot be rebound here. Auto-merge (--auto), a protection bypass
# (--admin), and branch
# deletion (--delete-branch, -d and short-flag clusters, and GitLab's
# --remove-source-branch) are refused by default; --attended-override, parsed
# before the optional -- separator, re-enables those forge flags for an
# explicit captain instruction and never skips the live green check, the
# away-record read, or a captain hold.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--attended-override] [--allow-red <check-name>] [--allow-content <guard>]... [-- <extra forge merge args>]
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-pr-binding-lib.sh
. "$SCRIPT_DIR/fm-pr-binding-lib.sh"
# shellcheck source=bin/fm-merge-guard-lib.sh
. "$SCRIPT_DIR/fm-merge-guard-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
# Only providers with a merge path here are accepted; any other is refused
# before anything is recorded or armed rather than sent to a forge CLI.
case "$FM_PR_PROVIDER" in
  github|gitlab|gitea) ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
shift 2
ATTENDED_OVERRIDE=false
ALLOW_RED=()
ALLOW_CONTENT=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attended-override)
      ATTENDED_OVERRIDE=true
      shift
      ;;
    --attended-override=*)
      echo "error: --attended-override takes no value" >&2
      exit 2
      ;;
    --allow-red)
      [ -n "${2:-}" ] || { echo "error: --allow-red requires a check name" >&2; exit 2; }
      [ "${#ALLOW_RED[@]}" -eq 0 ] || { echo "error: --allow-red may be specified only once" >&2; exit 2; }
      ALLOW_RED+=("$2")
      shift 2
      ;;
    --allow-red=*)
      echo "error: --allow-red requires a separate check name argument" >&2
      exit 2
      ;;
    --allow-content)
      fm_merge_guard_name_valid "${2:-}" \
        || { echo "error: --allow-content requires one guard name: $FM_MERGE_GUARD_NAMES" >&2; exit 2; }
      case " ${ALLOW_CONTENT[*]-} " in
        *" $2 "*) echo "error: --allow-content $2 may be specified only once" >&2; exit 2 ;;
      esac
      ALLOW_CONTENT+=("$2")
      shift 2
      ;;
    --allow-content=*)
      echo "error: --allow-content requires a separate guard name argument" >&2
      exit 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [ "${#ALLOW_RED[@]}" -gt 0 ] && [ "$PROVIDER" = gitlab ]; then
  echo "error: --allow-red does not apply to GitLab, where a merge already requires the head pipeline to have succeeded" >&2
  exit 2
fi
if [ "${#ALLOW_CONTENT[@]}" -gt 0 ] && [ "$PROVIDER" = gitlab ]; then
  echo "error: --allow-content does not apply to GitLab, where the content guard does not run" >&2
  exit 2
fi

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*|--match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_protected_forge_args() {
  local arg
  [ "$ATTENDED_OVERRIDE" = true ] && return 0
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*|--admin|--admin=*|--delete-branch|--delete-branch=*|--remove-source-branch|--remove-source-branch=*)
        echo "error: extra merge arguments must not request auto-merge, a protection bypass, or branch deletion; pass --attended-override only for an explicit captain instruction" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster. -d is gh's
      # --delete-branch, and -yd carries it the same way -yR carries --repo.
      -*d*)
        echo "error: extra merge arguments must not request auto-merge, a protection bypass, or branch deletion; pass --attended-override only for an explicit captain instruction" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
reject_head_overrides "$@" || exit 1
reject_protected_forge_args "$@" || exit 1

# The Gitea merge is one API request this script composes, so the only extra
# arguments it can honor are a merge style. Anything else is refused rather
# than silently dropped.
GITEA_CALLER_STYLE=
if [ "$PROVIDER" = gitea ]; then
  pending_style=false
  for arg in "$@"; do
    if [ "$pending_style" = true ]; then
      GITEA_CALLER_STYLE=$arg
      pending_style=false
      continue
    fi
    case "$arg" in
      --squash) GITEA_CALLER_STYLE=squash ;;
      --merge) GITEA_CALLER_STYLE=merge ;;
      --rebase) GITEA_CALLER_STYLE=rebase ;;
      --method) pending_style=true ;;
      --method=*) GITEA_CALLER_STYLE=${arg#--method=} ;;
      *)
        echo "error: a Gitea merge accepts only a merge style (--squash, --merge, --rebase, or --method <style>) as an extra argument, not '$arg'" >&2
        exit 2
        ;;
    esac
  done
  if [ "$pending_style" = true ]; then
    echo "error: --method requires a merge style" >&2
    exit 2
  fi
  case "$GITEA_CALLER_STYLE" in
    ''|merge|rebase|rebase-merge|squash|fast-forward-only) ;;
    *)
      echo "error: '$GITEA_CALLER_STYLE' is not a Gitea merge style this script sends (merge, rebase, rebase-merge, squash, fast-forward-only)" >&2
      exit 2
      ;;
  esac
fi

FM_PR_GITHUB_AUTO_REQUESTED=false
if [ "$PROVIDER" = github ] && caller_requested_auto_merge "$@"; then
  FM_PR_GITHUB_AUTO_REQUESTED=true
fi
FM_PR_GITLAB_ASYNC_REQUESTED=false
if [ "$PROVIDER" = gitlab ]; then
  for arg in "$@"; do
    case "$arg" in
      --auto-merge|--when-pipeline-succeeds) FM_PR_GITLAB_ASYNC_REQUESTED=true ;;
      --auto-merge=*|--when-pipeline-succeeds=*)
        case "${arg#*=}" in
          [tT]|[tT][rR][uU][eE]|1) FM_PR_GITLAB_ASYNC_REQUESTED=true ;;
          [fF]|[fF][aA][lL][sS][eE]|0) FM_PR_GITLAB_ASYNC_REQUESTED=false ;;
        esac
        ;;
    esac
  done
fi
FM_PR_AWAY_POSTURE=false

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: PR merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Role partition: merging is MAIN-owned while attended; the Pi supervision
# branch reports the green PR and never merges (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). While the away-posture record exists
# main is parked and this one action relocates to the branch, which then meets
# exactly the same gates below as main would: green at its live head,
# synchronous, under the record lock. This precedes
# reading the task record, because the wrong actor is refused for its role
# whatever that record says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)" --away-relocated

if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: PR merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  fm_afk_contract_lock_release || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi
GITHUB_MISSING=
if [ "$PROVIDER" = github ]; then
  command -v gh >/dev/null 2>&1 || GITHUB_MISSING="gh"
  if ! command -v jq >/dev/null 2>&1; then
    GITHUB_MISSING="${GITHUB_MISSING:+$GITHUB_MISSING and }jq"
  fi
  if [ -n "$GITHUB_MISSING" ]; then
    echo "error: merging a GitHub pull request requires $GITHUB_MISSING on PATH" >&2
    exit 1
  fi
fi

GITEA_LOGIN=
if [ "$PROVIDER" = gitea ]; then
  GITEA_MISSING=
  command -v tea >/dev/null 2>&1 || GITEA_MISSING="tea"
  if ! command -v jq >/dev/null 2>&1; then
    GITEA_MISSING="${GITEA_MISSING:+$GITEA_MISSING and }jq"
  fi
  if [ -n "$GITEA_MISSING" ]; then
    echo "error: merging a Gitea pull request requires $GITEA_MISSING on PATH" >&2
    exit 1
  fi
  GITEA_LOGIN=$(fm_pr_gitea_login "$PR_HOST") || GITEA_LOGIN=
  if [ -z "$GITEA_LOGIN" ]; then
    echo "error: merging a Gitea pull request requires exactly one tea login for https://$PR_HOST" >&2
    exit 1
  fi
fi

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
FM_PR_GITLAB_ASYNC_CONFIGURED=false
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status='' async_configured=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring),
        "async_configured=" + (if .merge_when_pipeline_succeeds == true or (.merge_after != null) then "true" else "false" end)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      async_configured=*) async_configured=${line#async_configured=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 8 ] || [ "$total" -ne 8 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_GITLAB_ASYNC_CONFIGURED=$async_configured
}

# Every GitHub check that is not green in the given live pull-request JSON, one
# name per line. An entry is green when it is a status context whose state is
# SUCCESS, or a check run that completed with SUCCESS, NEUTRAL, or SKIPPED (so
# a pending check is not green either). Exits nonzero when the rollup cannot be
# read, so a malformed answer is a failed read and never an empty red set.
#
# The rollup can hold several runs of one check name at the same head, because
# GitHub cancels a pull request's in-flight run when the base branch advances
# and re-triggers it; the cancelled run stays in the rollup beside the passing
# re-run. A check is therefore judged by its current run rather than by any run
# that a later one superseded, which is what makes this agree with GitHub's own
# CLEAN mergeStateStatus instead of refusing a pull request GitHub considers
# mergeable.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# reported independently. A still-running, queued, undated, or tied check run
# stays red. A name whose runs are all green needs no timestamp, while a name
# with no green run stays red.
#
# The reported name is also what --allow-red matches. An unnamed check run is
# grouped alone and can neither supersede nor be superseded, because unrelated
# unnamed checks must not be treated as one.
github_checks_not_green() {
  local json=$1
  printf '%s' "$json" | jq -r '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {kind: "status_context", name: (.context // ""), ok: (.state == "SUCCESS")}
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | .name
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | .name
        )
      )
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

# How many status checks the base branch requires, from its classic branch
# protection and its active ruleset rules. It feeds only the content guard's
# young-unreviewed check, so any read that fails counts as none required, which
# leaves that guard able to fire rather than silently quiet.
github_required_check_count() {  # <base>
  local base=$1 branch_path classic=0 rules=0
  branch_path=$(github_urlencode_path_segment "$base")
  classic=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null | jq -r '
      if type == "object" and .protected == true
        and (.protection.required_status_checks | type) == "object" then
        [((.protection.required_status_checks.contexts // [])[]),
         ((.protection.required_status_checks.checks // [])[] | .context)] | unique | length
      else 0 end' 2>/dev/null) || classic=0
  rules=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>/dev/null | jq -rs '
      [ .[] | if type == "array" then .[] else empty end
        | select(type == "object" and .type == "required_status_checks")
        | (.parameters.required_status_checks // [])[] | .context ] | unique | length' 2>/dev/null) || rules=0
  case "$classic" in ''|*[!0-9]*) classic=0 ;; esac
  case "$rules" in ''|*[!0-9]*) rules=0 ;; esac
  printf '%s' "$((classic + rules))"
}

# Pre-merge conditions for a GitHub pull request, read from one live view.
# Sets FM_PR_MERGE_HEAD to the verified head on success.
github_verify_mergeable() {
  local json fields line red name covered
  local total=0 named=0 refusals=''
  local state='' draft='' mergeable='' merge_state='' live_head='' base='' created='' reviews=''

  if ! json=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,createdAt,reviews,statusCheckRollup 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + ((.mergeable // "") | tostring),
        "merge_state=" + ((.mergeStateStatus // "") | tostring),
        "head=" + ((.headRefOid // "") | tostring),
        "base=" + ((.baseRefName // "") | tostring),
        "created=" + ((.createdAt // "") | (try fromdateiso8601 catch "") | tostring),
        "reviews=" + (if (.reviews | type) == "array" then (.reviews | length | tostring) else "" end)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      merge_state=*) merge_state=${line#merge_state=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      created=*) created=${line#created=} ;;
      reviews=*) reviews=${line#reviews=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ] || [ -z "$base" ]; then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi

  draft=$(fm_pr_json_draft_state "$json")
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitHub pull request head commit before merging" >&2
    return 1
  fi
  if ! red=$(github_checks_not_green "$json"); then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi

  case "$state" in
    [oO][pP][eE][nN]) ;;
    *)
      refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
      ;;
  esac
  [ "$draft" = false ] \
    || refusals="$refusals  - the pull request is a draft
"
  [ "$mergeable" = MERGEABLE ] \
    || refusals="$refusals  - mergeable is \"${mergeable:-unreadable}\", not MERGEABLE
"
  [ "$merge_state" != DIRTY ] \
    || refusals="$refusals  - mergeStateStatus is DIRTY (conflicts)
"

  uncovered=''
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    covered=0
    if [ "${#ALLOW_RED[@]}" -gt 0 ]; then
      for check in "${ALLOW_RED[@]}"; do
        [ "$check" = "$name" ] && covered=1
      done
    fi
    [ "$covered" -eq 1 ] || {
      refusals="$refusals  - check '$name' is not green
"
      uncovered="${uncovered:+$uncovered, }$name"
    }
  done <<EOF
$red
EOF

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    [ -z "$uncovered" ] || printf 'error: these checks are not green: %s\n' "$uncovered" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with every required check green at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_CREATED_EPOCH=$created
  FM_PR_GITHUB_REVIEWS=$reviews
  FM_PR_GITHUB_REQUIRED_COUNT=$(github_required_check_count "$base")
}

# Read one live GitHub pull request view after gh returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view; if that post-merge read becomes unavailable, gh-axi is the degradation
# path that can prove only a landed merge. gh remains a pre-merge prerequisite.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
FM_PR_GITHUB_CREATED_EPOCH=
FM_PR_GITHUB_REVIEWS=
FM_PR_GITHUB_REQUIRED_COUNT=
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
      return 0
    fi
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false api_err api_err_text
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-queue-rules.XXXXXX") || return 0
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>"$api_err"); then
    api_err_text=$(cat "$api_err" 2>/dev/null)
    rm -f "$api_err"
    # A plan-gated 403 on this endpoint ("Upgrade to GitHub Pro or make this
    # repository public") means the repository's plan cannot expose branch
    # rules at all, on GitHub or GitHub Enterprise Server - not that this
    # script failed to read them. A repository that cannot have branch rules
    # cannot have a merge_queue rule either, so that specific 403 resolves to
    # no queue rather than the generic unreadable status. Any other failure
    # (auth, rate limit, network, a 404, an unrelated 403) stays unreadable.
    case "$api_err_text" in
      *"Upgrade to GitHub Pro or make this repository public"*)
        FM_PR_GITHUB_QUEUE_STATUS=none
        ;;
    esac
    return 0
  fi
  rm -f "$api_err"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

record_pr_metadata() {
  if ! FM_PR_CHECK_MERGE=1 "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

require_released_captain_hold() {
  local hold_status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
  case "$hold_status" in
    0)
      echo "error: task $ID is still held for the captain; release it before merging" >&2
      return 1
      ;;
    1|3) return 0 ;;
    *)
      echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
      return 1
      ;;
  esac
}

FM_PR_MERGE_AUTHORITY=
# The authority read. bin/fm-merge-authority-lib.sh owns what the away-posture
# record's presence means; this function owns what a merge run may do about it,
# so the answer the merge poll later tags its ledger row with is the same answer
# resolved here. An unreadable record refuses rather than being skipped.
resolve_merge_authority() {
  FM_PR_MERGE_AUTHORITY=
  if fm_merge_authority_resolve "$FM_HOME" "$STATE" "$META" "$ID"; then
    FM_PR_MERGE_AUTHORITY=$FM_MERGE_AUTHORITY
    return 0
  fi
  echo "error: PR merge refused - the away-posture record could not be read; nothing was merged" >&2
  return 1
}

# Take the away record's own lock (bin/fm-afk-contract.sh owns it) so that
# record cannot be published, replaced, or archived between the authority read
# below and the forge command that acts on it. Refuses without the lock: a merge
# on authority nothing is holding still is exactly what this closes. This is the
# only path that holds both the per-task control lock and the away-record lock,
# and it always takes them in that order; the away-record side takes only its own
# lock, so the pair cannot deadlock.
hold_away_record_for_merge() {
  fm_afk_contract_lock_hold "$STATE" && return 0
  echo "error: PR merge refused - the away-posture record could not be locked for the merge; nothing was merged" >&2
  return 1
}

require_current_away_authority() {
  FM_PR_AWAY_POSTURE=false
  if fm_afk_contract_present "$STATE"; then
    FM_PR_AWAY_POSTURE=true
    if [ "$PROVIDER" = github ] && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
      echo "error: --auto is attended-only; while the away-posture record exists only a synchronous merge may run under its authority lock" >&2
      return 2
    fi
    if [ "$PROVIDER" = gitlab ] \
      && { [ "$FM_PR_GITLAB_ASYNC_REQUESTED" = true ] || [ "$FM_PR_GITLAB_ASYNC_CONFIGURED" = true ]; }; then
      echo "error: GitLab auto-merge is attended-only; while the away-posture record exists only an immediate merge may run under its authority lock" >&2
      return 2
    fi
  fi
  fm_lease_forbid_branch "PR merge (fm-pr-merge)" --away-relocated
  resolve_merge_authority || return 1
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "${#ALLOW_RED[@]}" -gt 0 ]; then
    echo "error: --allow-red is attended-only; while the away-posture record exists the green check is absolute" >&2
    return 2
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "${#ALLOW_CONTENT[@]}" -gt 0 ]; then
    echo "error: --allow-content is attended-only; while the away-posture record exists the content guard is absolute" >&2
    return 2
  fi
}

persist_accepted_merge_authority() {
  local status=0
  MERGE_META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$MERGE_META_LOCK" || return 1
  fm_merge_authority_persist "$STATE" "$ID" "$META" \
    "$PROVIDER" "$PR_HOST" "$PR_PATH" "$PR_NUMBER" "$FM_PR_MERGE_AUTHORITY" \
    || status=1
  fm_lock_release "$MERGE_META_LOCK" || status=1
  MERGE_META_LOCK=
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  printf 'actionable: the forge accepted the merge request for %s but its merge authority could not be persisted; the merge poll remains armed\n' \
    "$URL" >&2
  return 1
}

# While away, a merge proceeds only when the base branch's rules prove no
# merge queue, because a queued merge can land after its away authority
# lapses with the record's archive. A repository whose
# plan does not expose branch rules at all (GitHub's "Upgrade to GitHub Pro or
# make this repository public" 403) proves that on its own, since such a
# repository cannot have a merge_queue rule either; see
# github_read_queue_method, which resolves that specific 403 to status=none.
# Every other failure to read the queue state (auth, rate limit, network, a
# 404, or an unrelated 403) stays unreadable and refuses the merge. The merge
# stays synchronous (--auto is refused earlier) and every other gate still
# applies.
refuse_github_queue_while_away() {
  [ "$FM_PR_AWAY_POSTURE" = true ] || return 0
  # Accepted confused-agent-grade limitation, as in bin/fm-lease-lib.sh, not an
  # oversight: a queue rule or PR base change after this preflight can still
  # enqueue the merge, which can land after its away authority lapses.
  github_read_queue_method
  [ "$FM_PR_GITHUB_QUEUE_STATUS" = none ] && return 0
  echo "error: GitHub merge refused while away because the base branch's merge-queue state does not prove an immediate merge; nothing was handed to the forge" >&2
  return 2
}

# The binding in the task metadata must be exactly the one bin/fm-pr-check.sh
# recorded (bin/fm-pr-binding-lib.sh); a hand-edited binding is refused before
# anything is recorded or read from the forge.
require_intact_pr_binding() {
  fm_pr_binding_meta_check "$STATE" "$ID" "$META" && return 0
  printf 'error: refusing to merge %s: %s; record the pull request with bin/fm-pr-check.sh, present it and its diff stat to the captain, and merge only on fresh approval\n' \
    "$URL" "$FM_PR_BINDING_ERROR" >&2
  return 1
}

BOUND_HEAD=
BOUND_TREE=
read_merge_binding() {
  if ! fm_pr_binding_read "$STATE" "$ID" || [ "$FM_PR_BINDING_PRESENT" -ne 1 ] \
    || [ "$FM_PR_BINDING_URL" != "$URL" ]; then
    echo "error: refusing to merge $URL: its PR binding could not be read back after recording" >&2
    return 1
  fi
  BOUND_HEAD=$FM_PR_BINDING_HEAD
  BOUND_TREE=$FM_PR_BINDING_TREE
}

# The live head must be the recorded head the captain was shown.
require_bound_head() {
  if [ -z "$BOUND_HEAD" ]; then
    printf 'error: refusing to merge %s: no head was recorded for it, so there is no approved content to bind the merge to; record it with bin/fm-pr-check.sh where its head is readable, present it and its diff stat to the captain, and merge only on fresh approval\n' \
      "$URL" >&2
    return 1
  fi
  [ "$BOUND_HEAD" = "$FM_PR_MERGE_HEAD" ] && return 0
  printf 'error: refusing to merge %s: its head is %s, but the head recorded for approval is %s; record it again with bin/fm-pr-check.sh, present the changed pull request and its diff stat (bin/fm-review-diff.sh %s --stat) to the captain, and merge only on fresh approval\n' \
    "$URL" "$FM_PR_MERGE_HEAD" "$BOUND_HEAD" "$ID" >&2
  return 1
}

# The content guard (bin/fm-merge-guard-lib.sh) on the verified head. Prints
# and records the diff stat, then refuses on every guard that fired and was not
# waived by name.
run_content_guard() {  # <base> <forge-head-ref> <created-epoch> <review-count> <required-check-count>
  local base=$1 forge_ref=$2 created=$3 reviews=$4 required=$5
  local wt branch hint hits='' young line name waived='' unwaived='' verdict=pass
  wt=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  branch=$(grep '^branch=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$branch" ] || branch="fm/$ID"
  if fm_merge_guard_fetch "$wt" "$base" "$FM_PR_MERGE_HEAD" \
      "$forge_ref" "refs/fm-merge-guard/$ID/head"; then
    hint=$(fm_merge_guard_branch_origin "$wt" "$branch")
    fm_merge_guard_analyze "$wt" "$base" "$FM_PR_MERGE_HEAD" "$hint" || true
  fi
  if [ -n "$FM_MERGE_GUARD_ERROR" ]; then
    hits="unavailable: $FM_MERGE_GUARD_ERROR"
  else
    hits=$FM_MERGE_GUARD_HITS
    if [ -n "$BOUND_TREE" ] && [ "$BOUND_TREE" != "$FM_MERGE_GUARD_TREE" ]; then
      printf 'error: refusing to merge %s: head %s has tree %s, but the tree recorded for approval is %s\n' \
        "$URL" "$FM_PR_MERGE_HEAD" "$FM_MERGE_GUARD_TREE" "$BOUND_TREE" >&2
      return 1
    fi
    printf 'content: %s against origin/%s at %s for head %s\n' \
      "$FM_MERGE_GUARD_SHORTSTAT" "$base" "$FM_MERGE_GUARD_BASE_SHA" "$FM_PR_MERGE_HEAD" >&2
    [ -z "$FM_MERGE_GUARD_STAT" ] || printf '%s\n' "$FM_MERGE_GUARD_STAT" | sed 's/^/content: /' >&2
  fi
  young=$(fm_merge_guard_young_unreviewed "$created" "${reviews:-0}" "${required:-0}" "$(date +%s)")
  [ -z "$young" ] || hits="${hits:+$hits
}young-unreviewed: $young"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%:*}
    case " ${ALLOW_CONTENT[*]-} " in
      *" $name "*) waived="${waived:+$waived }$name" ;;
      *) unwaived="${unwaived:+$unwaived
}$line" ;;
    esac
  done <<HITS
$hits
HITS
  [ -z "$unwaived" ] || verdict=refused
  fm_merge_guard_record "$STATE" "$ID" "$URL" "$FM_PR_MERGE_HEAD" "$base" \
    "$verdict" "$hits" "$waived" \
    || echo "warning: the content guard record for $URL could not be written" >&2
  [ -z "$waived" ] || printf 'content: waived by the captain'"'"'s named override: %s\n' "$waived" >&2
  [ -n "$unwaived" ] || return 0
  printf 'error: refusing to merge %s: the content guard found\n' "$URL" >&2
  printf '%s\n' "$unwaived" | sed 's/^/  - /' >&2
  echo "error: present this diff stat and these findings to the captain; only the captain's explicit, attended instruction naming a guard permits --allow-content <guard>" >&2
  return 1
}

require_recorded_pr_identity() {
  local existing
  existing=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$existing" ] || return 0
  [ "$existing" = "$URL" ] && return 0
  echo "error: task $ID is bound to $existing, not $URL" >&2
  return 1
}

FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  if [ "$FM_PR_AWAY_POSTURE" = true ]; then
    printf 'error: the direct merge did not land while the away-posture record exists; merge-queue retry flags are unavailable because a queued merge would outlive its authority\n' >&2
    return 0
  fi
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s --attended-override -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    if [ "$FM_PR_AWAY_POSTURE" = true ]; then
      printf 'error: the synchronous merge did not land while the away-posture record exists; no asynchronous merge or queue retry is available under away authority\n' >&2
    else
      printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
        "$URL" >&2
    fi
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# One tea api request against the resolved login. Sets GITEA_HTTP_STATUS to the
# response's HTTP status code and GITEA_BODY to its body. tea api exits 0 on an
# HTTP error, so the status line it prints with -i is the only success signal;
# a request whose status line cannot be read returns non-zero.
GITEA_HTTP_STATUS=
GITEA_BODY=
gitea_api() {  # <endpoint> [<raw JSON body to POST>]
  local endpoint=$1 body=${2-} err status_line rc=0
  GITEA_HTTP_STATUS=
  GITEA_BODY=
  err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gitea.XXXXXX") || return 1
  if [ "$#" -ge 2 ]; then
    GITEA_BODY=$(tea api -i --login "$GITEA_LOGIN" -X POST -d "$body" "$endpoint" 2>"$err") || rc=$?
  else
    GITEA_BODY=$(tea api -i --login "$GITEA_LOGIN" "$endpoint" 2>"$err") || rc=$?
  fi
  status_line=$(grep -E '^HTTP/[0-9.]+ [0-9]{3}( |$)' "$err" | head -1 || true)
  rm -f -- "$err"
  [ "$rc" -eq 0 ] && [ -n "$status_line" ] || return 1
  status_line=${status_line#* }
  GITEA_HTTP_STATUS=${status_line%% *}
}

# Pre-merge conditions for a Gitea pull request, read from one live view of the
# pull request plus the commit statuses at its head. Sets FM_PR_MERGE_HEAD and
# GITEA_MERGE_STYLE on success and returns non-zero after reporting every
# condition that failed.
GITEA_MERGE_STYLE=
gitea_verify_mergeable() {
  local fields line total=0 named=0 refusals=''
  local url='' state='' merged='' draft='' mergeable='' live_head='' base='' created=''
  local statuses status_sha='' red='' context name waived

  if ! gitea_api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" || [ "$GITEA_HTTP_STATUS" != 200 ]; then
    echo "error: could not read the Gitea pull request state before merging" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$GITEA_BODY" | jq -r '
      if type == "object" then
        "url=" + ((.html_url // "") | tostring),
        "state=" + ((.state // "") | tostring),
        "merged=" + (.merged | tostring),
        "draft=" + (.draft | tostring),
        "mergeable=" + (.mergeable | tostring),
        "head=" + ((.head.sha // "") | tostring),
        "base=" + ((.base.ref // "") | tostring),
        "created=" + ((.created_at // "") | tostring
          | (try (if test("Z$") then sub("\\.[0-9]+"; "") | fromdateiso8601
                  else capture("^(?<t>[^.+-]*-[^.+-]*-[^.+-]*)(\\.[0-9]+)?(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$")
                    | ((.t + "Z") | fromdateiso8601)
                      - ((if .s == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60))
                  end) catch "")
          | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the Gitea pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      url=*) url=${line#url=} ;;
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      draft=*) draft=${line#draft=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      created=*) created=${line#created=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 8 ] || [ "$total" -ne 8 ] || [ -z "$base" ]; then
    echo "error: could not read the Gitea pull request state before merging" >&2
    return 1
  fi
  # tea resolves the instance from a login rather than the URL, so the answer is
  # honored only when it describes exactly the requested pull request.
  if [ "$url" != "$URL" ]; then
    echo "error: the Gitea pull request read back as '${url:-unreadable}', not $URL; refusing to merge" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the Gitea pull request head commit before merging" >&2
    return 1
  fi

  [ "$state" = open ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$merged" = false ] \
    || refusals="$refusals  - merged is \"${merged:-unreadable}\", not false
"
  [ "$draft" = false ] \
    || refusals="$refusals  - draft is \"${draft:-unreadable}\", not false
"
  [ "$mergeable" = true ] \
    || refusals="$refusals  - mergeable is \"${mergeable:-unreadable}\", not true
"

  # Gitea's combined status lists the latest status per context. A page that
  # holds fewer entries than total_count is refused as unreadable rather than
  # judged on part of the set.
  if ! gitea_api "/repos/$PR_OWNER/$PR_REPO/commits/$live_head/status?limit=50" \
    || [ "$GITEA_HTTP_STATUS" != 200 ] \
    || ! statuses=$(printf '%s' "$GITEA_BODY" | jq -r '
        if type == "object" and (.statuses | type == "array")
          and ((.total_count // 0) == (.statuses | length)) then
          "sha=" + ((.sha // "") | tostring),
          (.statuses[] | ((.status // "") | tostring) + "\t" + ((.context // "") | tostring | gsub("[\t\n]"; " ")))
        else
          error("combined status is unreadable or incomplete")
        end' 2>/dev/null); then
    refusals="$refusals  - the commit statuses at head $live_head could not be read completely
"
  else
    while IFS= read -r line; do
      case "$line" in
        sha=*) status_sha=${line#sha=}; continue ;;
        '') continue ;;
      esac
      [ "${line%%$'\t'*}" = success ] && continue
      context=${line#*$'\t'}
      waived=false
      for name in ${ALLOW_RED[@]+"${ALLOW_RED[@]}"}; do
        [ "$context" = "$name" ] && waived=true
      done
      if [ "$waived" = true ]; then
        printf 'notice: waiving status "%s" (%s) at head %s on the attended --allow-red instruction\n' \
          "$context" "${line%%$'\t'*}" "$live_head" >&2
        continue
      fi
      red="$red  - status \"$context\" is \"${line%%$'\t'*}\", not success
"
    done <<STATUSES
$statuses
STATUSES
    if [ -n "$status_sha" ] && [ "$status_sha" != "$live_head" ]; then
      refusals="$refusals  - the commit statuses describe $status_sha, not the current head $live_head
"
    fi
    refusals="$refusals$red"
  fi

  GITEA_MERGE_STYLE=$GITEA_CALLER_STYLE
  if [ -z "$GITEA_MERGE_STYLE" ]; then
    if gitea_api "/repos/$PR_OWNER/$PR_REPO" && [ "$GITEA_HTTP_STATUS" = 200 ]; then
      GITEA_MERGE_STYLE=$(printf '%s' "$GITEA_BODY" \
        | jq -r 'if type == "object" and (.default_merge_style | type == "string") then .default_merge_style else empty end' \
          2>/dev/null) || GITEA_MERGE_STYLE=
    fi
    case "$GITEA_MERGE_STYLE" in
      merge|rebase|rebase-merge|squash|fast-forward-only) ;;
      *)
        refusals="$refusals  - the repository's default merge style \"${GITEA_MERGE_STYLE:-unreadable}\" is not one this script sends; pass --squash, --merge, --rebase, or --method <style>
"
        ;;
    esac
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with every commit status green at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  GITEA_BASE=$base
  GITEA_CREATED_EPOCH=$created
}

# The review count and required status-check count the content guard's
# young-unreviewed check reads. A failed read counts as none, which leaves that
# guard able to fire rather than silently quiet.
GITEA_BASE=
GITEA_CREATED_EPOCH=
GITEA_REVIEWS=0
GITEA_REQUIRED=0
gitea_read_review_and_required_counts() {
  local value branch_path
  GITEA_REVIEWS=0
  GITEA_REQUIRED=0
  if gitea_api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/reviews" && [ "$GITEA_HTTP_STATUS" = 200 ]; then
    value=$(printf '%s' "$GITEA_BODY" | jq -r 'if type == "array" then length else empty end' 2>/dev/null) || value=
    case "$value" in ''|*[!0-9]*) ;; *) GITEA_REVIEWS=$value ;; esac
  fi
  branch_path=$(github_urlencode_path_segment "$GITEA_BASE")
  if gitea_api "/repos/$PR_OWNER/$PR_REPO/branch_protections/$branch_path" && [ "$GITEA_HTTP_STATUS" = 200 ]; then
    value=$(printf '%s' "$GITEA_BODY" | jq -r '
        if type == "object" and .enable_status_check == true then
          ([(.status_check_contexts // [])[]] | length) as $n | if $n > 0 then $n else 1 end
        else 0 end' 2>/dev/null) || value=
    case "$value" in ''|*[!0-9]*) ;; *) GITEA_REQUIRED=$value ;; esac
  fi
}

# Read the pull request back after the forge accepted the merge. Returns 0 when
# it reports merged, 1 when it reads back unmerged, and 2 when it is unreadable.
gitea_confirm_merged() {
  local merged
  if ! gitea_api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" || [ "$GITEA_HTTP_STATUS" != 200 ] \
    || ! merged=$(printf '%s' "$GITEA_BODY" | jq -r --arg url "$URL" '
        if type == "object" and .html_url == $url and (.merged | type == "boolean")
        then .merged | tostring else error("unreadable") end' 2>/dev/null); then
    return 2
  fi
  [ "$merged" = true ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
away_status=0
require_current_away_authority || away_status=$?
[ "$away_status" -eq 0 ] || exit "$away_status"
require_intact_pr_binding || exit 1
require_recorded_pr_identity || exit 1
record_pr_metadata || exit 1
read_merge_binding || exit 1
require_released_captain_hold || exit 1

# Accepted confused-agent-grade limitation, as in bin/fm-lease-lib.sh, not an
# oversight: if this lock-owning shell dies while its gh or glab child lives,
# stale-owner recovery can release the record for archive or replacement and
# the orphaned forge child can still merge on the lapsed away authority.
case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    github_verify_mergeable || exit 1
    require_bound_head || exit 1
    run_content_guard "$FM_PR_GITHUB_BASE" "refs/pull/$PR_NUMBER/head" "$FM_PR_GITHUB_CREATED_EPOCH" \
      "$FM_PR_GITHUB_REVIEWS" "$FM_PR_GITHUB_REQUIRED_COUNT" || exit 1
    # The away record is locked first, so this last presence and authority read
    # and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    refuse_github_queue_while_away || exit 2
    merge_status=0
    merge_output=$(gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      --match-head-commit "$FM_PR_MERGE_HEAD" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1) || merge_status=$?
    if [ "$merge_status" -eq 0 ]; then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
      persist_accepted_merge_authority || exit 1
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
    else
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
          github_report_unmerged_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        fi
      fi
      exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    # The away record is locked first, so this last presence and authority read
    # and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    merge_status=0
    gitlab_merge_args=()
    if [ "$FM_PR_AWAY_POSTURE" = true ]; then
      gitlab_merge_args=(--auto-merge=false)
    fi
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@" "${gitlab_merge_args[@]+"${gitlab_merge_args[@]}"}" || merge_status=$?
    if [ "$merge_status" -ne 0 ]; then
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      exit "$merge_status"
    fi
    persist_accepted_merge_authority || exit 1
    fm_afk_contract_lock_release || true
    fm_lock_release "$MERGE_CONTROL_LOCK" || true
    MERGE_CONTROL_LOCK=
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  gitea)
    gitea_verify_mergeable || exit 1
    require_bound_head || exit 1
    gitea_read_review_and_required_counts
    run_content_guard "$GITEA_BASE" "refs/pull/$PR_NUMBER/head" "$GITEA_CREATED_EPOCH" \
      "$GITEA_REVIEWS" "$GITEA_REQUIRED" || exit 1
    # head_commit_id binds the merge to the head this run verified, so Gitea
    # refuses a merge whose head moved after that read. The body never asks
    # Gitea to wait for checks, force past branch protection, or delete the
    # branch. The away record is locked first, so this last presence and
    # authority read and the forge request share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    gitea_merge_body=$(jq -cn --arg style "$GITEA_MERGE_STYLE" --arg head "$FM_PR_MERGE_HEAD" \
      '{Do: $style, head_commit_id: $head}') || exit 1
    merge_status=0
    gitea_api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" "$gitea_merge_body" || merge_status=$?
    if [ "$merge_status" -ne 0 ] || [ "$GITEA_HTTP_STATUS" != 200 ]; then
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      printf 'error: Gitea refused the merge of %s (HTTP %s)\n' "$URL" "${GITEA_HTTP_STATUS:-unreadable}" >&2
      [ -z "$GITEA_BODY" ] || printf 'forge said: %s\n' "$GITEA_BODY" >&2
      if gitea_confirm_merged; then
        printf 'actionable: the merge request for %s failed, but the pull request reads back as merged\n' "$URL" >&2
      fi
      exit 1
    fi
    persist_accepted_merge_authority || exit 1
    fm_afk_contract_lock_release || true
    fm_lock_release "$MERGE_CONTROL_LOCK" || true
    MERGE_CONTROL_LOCK=
    gitea_confirm_rc=0
    gitea_confirm_merged || gitea_confirm_rc=$?
    case "$gitea_confirm_rc" in
      0) ;;
      1)
        printf 'actionable: Gitea accepted the merge request for %s but the pull request reads back unmerged; the merge poll remains armed\n' \
          "$URL" >&2
        exit 1
        ;;
      *)
        printf 'actionable: Gitea accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
          "$URL" >&2
        exit 0
        ;;
    esac
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self \
  "${FM_PR_MERGE_AUTHORITY:-}" || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
