#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched refs/pull/<n>/head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, fall back to
# the local branch with a warning. Without pr=, compare the local branch.
#
# --stat prints the stat summary and then the PR state block firstmate presents
# with every merge ask: the compared head, the content guard's findings from
# bin/fm-merge-guard-lib.sh against origin/<default> with the earlier base
# commits whose work the head would revert (or "none"), and, for a recorded
# GitHub or Gitea pull request, its state, draft flag, mergeability, forge head,
# reported checks, and reviews read live from the forge. Each part that cannot
# be read says so instead of being left out. The block is read-only: it never
# records, waives, or merges anything, and bin/fm-pr-merge.sh still runs the
# guard itself at merge time.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints the stat summary and the PR state block; default prints the
#   stat summary plus the full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
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
    # Gitea's plural route, which serves refs/pull/<n>/head exactly as GitHub
    # does, so fetch_pull_head below needs nothing further.
    *"/pulls/"*)
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

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
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
# bin/fm-pr-merge.sh compares a GitHub or Gitea merge against.
print_guard_findings() {  # <head>
  local head=$1 hint
  if [ "$BASE" != "origin/$DEFAULT" ]; then
    echo "  guard findings: not run (the project has no origin remote)"
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

# The same lines from Gitea's pull request, combined commit status, and review
# list, read through the one tea login that serves the pull request's host.
gitea_state_lines() {
  local login pr head statuses reviews
  login=$(fm_pr_gitea_login "$FM_PR_HOST") || login=
  [ -n "$login" ] || return 1
  pr=$(tea api --login "$login" "/repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER" 2>/dev/null \
    | jq -c --arg url "$FM_PR_URL" 'if type == "object" and .html_url == $url then . else error("wrong pull request") end' \
      2>/dev/null) || return 1
  head=$(printf '%s' "$pr" | jq -r '.head.sha // ""')
  fm_pr_head_valid "$head" || return 1
  statuses=$(tea api --login "$login" "/repos/$FM_PR_OWNER/$FM_PR_REPO/commits/$head/status?limit=50" 2>/dev/null \
    | jq -c 'if type == "object" and .statuses == null and .total_count == 0 then .statuses = [] else . end
      | if type == "object" and (.statuses | type == "array") and ((.total_count // 0) == (.statuses | length))
        then .statuses else error("incomplete") end' 2>/dev/null) || statuses=null
  reviews=$(tea api --login "$login" "/repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/reviews" 2>/dev/null \
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
    gitea) lines=$(gitea_state_lines) || lines= ;;
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
