#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and projects with no origin remote against the local
# default branch.
# A task whose meta records base_branch= (bin/fm-spawn.sh) compares against
# origin/<base_branch> instead of the default branch.
# A home that creates config/spawn-base-primary-checkout, where bin/fm-spawn.sh
# can start a local-only ship or a scout from the primary checkout's <default>,
# instead anchors a remote-backed task without base_branch= on the branch it
# delivers to. A publishing mode (bin/fm-dod-lib.sh fm_mode_publishes) keeps
# origin/<default>, which its pull request targets, so everything that pull
# request would carry stays in the review. A local-only ship or a scout is
# compared against whichever of the local <default> and origin/<default> meets
# the branch later, the one whose merge base with it descends from the other's:
# that follows a branch planted on, or rebased onto, the local <default> without
# listing other tasks' local landings as its own, and keeps origin/<default> for
# a branch planted there because the local <default> trailed or diverged from
# it. Equal merge bases anchor on the local <default>, as does a local <default>
# that already contains the branch, whose empty review says why; two unrelated
# merge bases are reported and anchor there too.
# When state/<id>.meta records pr= as a GitHub pull-request URL, a Forgejo
# pull-request URL (addressed /pulls/<n> but served by the instance as the
# same refs/pull/<n>/head ref), or a bare number for an open PR, the compare
# side is ALWAYS a freshly fetched
# refs/pull/<n>/head by default so review stays current after no-mistakes fix
# rounds push to the PR. A recorded pr_head= is only a fallback when fetch fails
# (stale recorded SHAs must never win over a reachable remote PR head). If
# neither PR head can be resolved, fall back to the local branch with a warning.
# A GitLab merge request and a Gerrit change expose no comparable ref and record
# no pr_head, so a task recording one always takes that warning path;
# docs/architecture.md owns that fallback. Without pr=, compare the task's
# immutable ship branch recorded in state/<id>.meta ("fm/<id>" for records
# created before that field existed), or the worktree's checked-out branch when
# that branch does not exist in the worktree. A recorded branch that is not a
# valid git branch name is refused instead of taking that fallback, the same
# refusal fm-merge-local.sh applies, so a corrupt meta record can never turn a
# review into a diff of the wrong content.
#
# --stat prints the stat summary and then the PR state block firstmate presents
# with every merge ask: the compared head, the content guard's findings from
# bin/fm-merge-guard-lib.sh against origin/<default> with the earlier base
# commits whose work the head would revert (or "none"), and, for a recorded
# GitHub or Forgejo pull request, its state, draft flag, mergeability, forge
# head, reported checks, and reviews read live from the forge. Each part that
# cannot be read says so instead of being left out. The block is read-only: it
# never records, waives, or merges anything, and bin/fm-pr-merge.sh still runs
# the guard itself at merge time.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints the stat summary and the PR state block; default prints the
#   stat summary plus the full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
"$FM_ROOT/bin/fm-guard.sh" || true
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-guard-lib.sh
. "$FM_ROOT/bin/fm-merge-guard-lib.sh"

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

RECORDED_BASE=$(grep '^base_branch=' "$META" | cut -d= -f2- || true)
DEFAULT=$RECORDED_BASE
[ -n "$DEFAULT" ] || DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  WANT=$BRANCH
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: ship branch $WANT does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    *"/pulls/"*)  # Forgejo addresses pulls as /pulls/<n>.
      n=${target##*/pulls/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fetch_pull_head() {
  local n=$1 resolved
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a private ref so a later base-branch fetch cannot clobber the
  # compare tip via FETCH_HEAD, and so we never review a stale local object.
  git -C "$WT" fetch --quiet origin \
    "+refs/pull/$n/head:refs/fm-review/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "refs/fm-review/pull/$n/head^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  n=$(pr_number_from_target "$pr_url") || true
  if [ -n "$n" ]; then
    if resolved=$(fetch_pull_head "$n"); then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  # Offline / unreachable remote: recorded pr_head is better than the local
  # branch, but never preferred over a successful pull-head fetch above.
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

# The commit `git diff <anchor>...<compare>` starts from: the anchor's merge base
# with the compare ref, empty when the two histories are unrelated.
merge_base_with_compare() { # <rev>
  git -C "$WT" merge-base "$1" "$COMPARE_REF" 2>/dev/null || true
}

# The anchor a home with config/spawn-base-primary-checkout reviews a
# remote-backed task against; the header owns the rule.
resolve_review_base() {
  local local_rev origin_rev compare_rev mb_local mb_origin
  if fm_mode_publishes "$MODE"; then
    printf '%s' "origin/$DEFAULT"
    return 0
  fi
  local_rev=$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$DEFAULT^{commit}" 2>/dev/null || true)
  if [ -z "$local_rev" ]; then
    printf '%s' "origin/$DEFAULT"
    return 0
  fi
  origin_rev=$(git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT^{commit}" 2>/dev/null || true)
  compare_rev=$(git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" 2>/dev/null || true)
  mb_local=$(merge_base_with_compare "$local_rev")
  mb_origin=
  [ -z "$origin_rev" ] || mb_origin=$(merge_base_with_compare "$origin_rev")
  if [ -n "$mb_local" ] && [ "$mb_local" = "$compare_rev" ]; then
    echo "note: $DEFAULT already contains $COMPARE_REF, so there is nothing left to review against it" >&2
  fi
  if [ -z "$mb_origin" ] || [ "$mb_local" = "$mb_origin" ] \
    || { [ -n "$mb_local" ] && git -C "$WT" merge-base --is-ancestor "$mb_origin" "$mb_local" 2>/dev/null; }; then
    printf '%s' "$DEFAULT"
    return 0
  fi
  if [ -z "$mb_local" ] || git -C "$WT" merge-base --is-ancestor "$mb_local" "$mb_origin" 2>/dev/null; then
    printf '%s' "origin/$DEFAULT"
    return 0
  fi
  echo "note: $DEFAULT and origin/$DEFAULT meet $COMPARE_REF at unrelated commits, so neither is the tighter anchor; anchoring on $DEFAULT" >&2
  printf '%s' "$DEFAULT"
}

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
  if [ -z "$RECORDED_BASE" ] && [ -e "$CONFIG/spawn-base-primary-checkout" ]; then
    # shellcheck source=bin/fm-dod-lib.sh
    . "$SCRIPT_DIR/fm-dod-lib.sh"
    MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
    BASE=$(resolve_review_base)
  fi
else
  BASE="$DEFAULT"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

# The content guard's findings against origin/<default>, which is what
# bin/fm-pr-merge.sh compares a GitHub or Forgejo merge against.
print_guard_findings() {  # <head>
  local head=$1 hint
  if [ "$BASE" != "origin/$DEFAULT" ]; then
    echo "  guard findings: not run (this review compares against $BASE, not origin/$DEFAULT)"
    return 0
  fi
  hint=$(fm_merge_guard_branch_origin "$WT" "$BRANCH")
  if ! fm_merge_guard_analyze "$WT" "$DEFAULT" "$head" "$hint"; then
    echo "  guard findings: could not run: $FM_MERGE_GUARD_ERROR"
    return 0
  fi
  if [ -z "$FM_MERGE_GUARD_HITS" ]; then
    echo "  guard findings: none"
  else
    echo "  guard findings:"
    printf '%s\n' "$FM_MERGE_GUARD_HITS" | sed 's/^/    - /'
  fi
  if [ -z "$FM_MERGE_GUARD_REVERTED" ]; then
    echo "  reverts work from: none"
  else
    echo "  reverts work from:"
    printf '%s\n' "$FM_MERGE_GUARD_REVERTED" | sed 's/^/    - /'
  fi
}

# Checks and reviews as "<label>: <summary>" lines from one GitHub view. A
# check name reported more than once counts only its newest run.
github_state_lines() {
  local json
  fm_pr_github_host_export "$FM_PR_HOST"
  json=$(gh pr view "$FM_PR_URL" \
    --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,reviewDecision,latestReviews,statusCheckRollup \
    2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '
    def count($v): [.[] | select(.verdict == $v)] | length;
    if type != "object" then error("not a pull request") else . end
    | ([(.statusCheckRollup // [])[]
        | { name: ((.name // .context // "") | tostring),
            at: ((.completedAt // .startedAt // "") | tostring),
            verdict: (if .__typename == "StatusContext" then
                        (if .state == "SUCCESS" then "passing"
                         elif .state == "PENDING" or .state == "EXPECTED" then "pending"
                         else "failing" end)
                      elif .status != "COMPLETED" then "pending"
                      elif (.conclusion // "") as $c | ["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c) then "passing"
                      else "failing" end) }]
       | group_by(.name) | map(max_by(.at))) as $checks
    | "head=\(.headRefOid // "")",
      "base: \(.baseRefName // "unknown")",
      "state: \((.state // "unknown") | ascii_downcase), \(if .isDraft == true then "draft" elif .isDraft == false then "not a draft" else "draft unknown" end)",
      "mergeable: \(.mergeable // "unknown") (merge state \(.mergeStateStatus // "unknown"))",
      "checks: " + (if ($checks | length) == 0 then "none reported"
        else "\($checks | count("passing")) passing, \($checks | count("failing")) failing, \($checks | count("pending")) pending"
          + ([$checks[] | select(.verdict != "passing") | "\(.name) \(.verdict)"]
             | if length > 0 then " (" + join(", ") + ")" else "" end) end),
      "reviews: " + (if (.reviewDecision // "") == "" then "no review decision" else .reviewDecision end)
        + ([(.latestReviews // [])[] | "\(.author.login // "unknown") \((.state // "") | ascii_downcase)"]
           | if length > 0 then "; " + join(", ") else "; no reviews" end)' 2>/dev/null
}

# The same lines from Forgejo's pull request, combined commit status, and review
# list, read through the one tea login that serves the pull request's host
# (fm_pr_forgejo_login). An unconfigured status reads as no statuses at all.
forgejo_state_lines() {
  local login pr head statuses reviews
  login=$(fm_pr_forgejo_login "$FM_PR_HOST") || login=
  [ -n "$login" ] || return 1
  pr=$(tea api --login "$login" --repo "$FM_PR_PATH" "/repos/{owner}/{repo}/pulls/$FM_PR_NUMBER" 2>/dev/null \
    | jq -c 'if type == "object" and (.head.sha | type) == "string" then . else error("not a pull request") end' \
      2>/dev/null) || return 1
  head=$(printf '%s' "$pr" | jq -r '.head.sha // ""')
  fm_pr_head_valid "$head" || return 1
  statuses=$(tea api --login "$login" --repo "$FM_PR_PATH" "/repos/{owner}/{repo}/commits/$head/status?limit=50" 2>/dev/null \
    | jq -c 'if type == "object" and .statuses == null and .total_count == 0 then .statuses = [] else . end
      | if type == "object" and (.statuses | type == "array") and ((.total_count // 0) == (.statuses | length))
        then .statuses else error("incomplete") end' 2>/dev/null) || statuses=null
  reviews=$(tea api --login "$login" --repo "$FM_PR_PATH" "/repos/{owner}/{repo}/pulls/$FM_PR_NUMBER/reviews" 2>/dev/null \
    | jq -c 'if type == "array" then . else error("unreadable") end' 2>/dev/null) || reviews=null
  jq -rn --argjson pr "$pr" --argjson statuses "$statuses" --argjson reviews "$reviews" '
    def count($v): [.[] | select(.verdict == $v)] | length;
    "head=\($pr.head.sha)",
    "base: \($pr.base.ref // "unknown")",
    "state: \(if $pr.merged == true then "merged" else ($pr.state // "unknown") end), \(if $pr.draft == true then "draft" elif $pr.draft == false then "not a draft" else "draft unknown" end)",
    "mergeable: \(if $pr.mergeable == null then "unknown" else $pr.mergeable end)",
    "checks: " + (if $statuses == null then "could not be read"
      else [$statuses[] | { name: ((.context // "") | tostring),
                            verdict: (if .status == "success" then "passing" elif .status == "pending" then "pending" else "failing" end) }]
        | if length == 0 then "none reported"
          else "\(count("passing")) passing, \(count("failing")) failing, \(count("pending")) pending"
            + ([.[] | select(.verdict != "passing") | "\(.name) \(.verdict)"]
               | if length > 0 then " (" + join(", ") + ")" else "" end) end end),
    "reviews: " + (if $reviews == null then "could not be read"
      else [$reviews[] | select(.state != "PENDING" and .state != "REQUEST_REVIEW" and .dismissed != true)]
        | group_by(.user.login) | map(max_by(.submitted_at // ""))
        | map("\(.user.login // "unknown") \((.state // "") | ascii_downcase)")
        | if length > 0 then join(", ") else "no reviews" end end)' 2>/dev/null
}

# The PR state block firstmate presents with every merge ask.
print_pr_state() {
  local head lines forge_head forge_base line
  head=$(git -C "$WT" rev-parse --verify "$COMPARE_REF^{commit}")
  echo
  echo "pr state:"
  echo "  pr: ${PR_URL:-none recorded}"
  echo "  head: $head"
  print_guard_findings "$head"
  [ -n "$PR_URL" ] || return 0
  if ! fm_pr_url_parse "$PR_URL"; then
    echo "  forge state: not read (pr= is not a full pull request URL)"
    return 0
  fi
  case "$FM_PR_PROVIDER" in
    github) lines=$(github_state_lines) || lines= ;;
    forgejo) lines=$(forgejo_state_lines) || lines= ;;
    *)
      echo "  forge state: not read for $FM_PR_PROVIDER, where the content guard does not run"
      return 0
      ;;
  esac
  if [ -z "$lines" ]; then
    echo "  forge state: could not be read from $FM_PR_HOST"
    return 0
  fi
  forge_head=$(printf '%s\n' "$lines" | sed -n 's/^head=//p' | head -1)
  forge_base=$(printf '%s\n' "$lines" | sed -n 's/^base: //p' | head -1)
  printf '%s\n' "$lines" | while IFS= read -r line; do
    case "$line" in
      head=*) ;;
      *) printf '  %s\n' "$line" ;;
    esac
  done
  if [ "$forge_head" != "$head" ]; then
    echo "  warning: the forge reports head ${forge_head:-unknown}, not the $head shown here; fetch again before asking"
  fi
  case "$forge_base" in
    unknown|"$DEFAULT") ;;
    *) echo "  warning: the pull request targets $forge_base, but the diff and guard findings above compare against $BASE" ;;
  esac
}

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if "$STAT_ONLY"; then
  print_pr_state
else
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
