#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_MERGE_GUARD_* are public results for sourcing callers.
# The content guard bin/fm-pr-merge.sh runs on a GitHub or Gitea pull request before it
# merges: what the pull request would change, read from git objects rather than
# from the forge's mergeability verdict, which is blind to content.
#
# fm_merge_guard_fetch fetches the base branch into refs/remotes/origin/<base>
# and the verified head into a private ref of the task's worktree, and refuses a
# fetched head that is not the verified one. Every comparison below is against
# that freshly fetched origin/<base>, never a local base branch, which goes
# stale in a pooled clone.
#
# fm_merge_guard_analyze computes the diff stat against origin/<base> (the
# three-dot diff from the merge base, which is the pull request's own diff) and
# one hit per guard below that fires. Guard names are what an attended
# --allow-content <guard> override in bin/fm-pr-merge.sh names:
#   stale-tree          a changed file whose head content (or absence) equals
#                       that file's content at an older commit of the base
#                       branch while differing from the base now, so merging
#                       would put old bytes back. The window starts at the
#                       oldest of the merge base, the task branch's fork point
#                       read from its reflog, and 50 first-parent commits back,
#                       because a stale tree grafted onto the current base makes
#                       the merge base the base itself. FM_MERGE_GUARD_REVERTED
#                       then lists the base commits whose changes to those files
#                       merging would undo (_fm_merge_guard_reverted).
#   deleted-migrations  the diff deletes a file under a migrations directory.
#   deleted-tests       the diff deletes a test file.
#   mass-deletion       the diff deletes at least 50 lines and more than twice
#                       the lines the pull request's own non-merge commits
#                       delete, excluding commits equivalent to ones already on
#                       the base, so the extra deletions came from somewhere else.
#   unavailable         the guard could not run, so nothing above was checked.
# fm_merge_guard_record writes state/<task-id>.merge-guard: what was checked,
# the verdict, the reverted commits, and the full diff stat.
#
# Sourced by bin/fm-pr-merge.sh, by bin/fm-review-diff.sh to present the same
# findings before a merge is asked for, and by tests. No side effects on source.

FM_MERGE_GUARD_NAMES="stale-tree deleted-migrations deleted-tests mass-deletion unavailable"
FM_MERGE_GUARD_LOOKBACK=50
FM_MERGE_GUARD_MASS_FLOOR=50

FM_MERGE_GUARD_ERROR=
FM_MERGE_GUARD_BASE_SHA=
FM_MERGE_GUARD_MERGE_BASE=
FM_MERGE_GUARD_TREE=
FM_MERGE_GUARD_SHORTSTAT=
FM_MERGE_GUARD_STAT=
FM_MERGE_GUARD_HITS=
FM_MERGE_GUARD_REVERTED=

fm_merge_guard_name_valid() {  # <name>
  case " $FM_MERGE_GUARD_NAMES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

_fm_merge_guard_git() {  # <wt> <git args>...
  local wt=$1
  shift
  git -C "$wt" -c core.quotePath=false "$@"
}

# Fetch origin/<base> and the head. Returns 1 with FM_MERGE_GUARD_ERROR set
# when either cannot be had or the fetched head is not <head>.
fm_merge_guard_fetch() {  # <wt> <base> <head> <forge-head-ref> <private-ref>
  local wt=$1 base=$2 head=$3 forge_ref=$4 private_ref=$5 fetched
  FM_MERGE_GUARD_ERROR=
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! _fm_merge_guard_git "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    FM_MERGE_GUARD_ERROR="the task's worktree ${wt:-<unrecorded>} is not a git checkout"
    return 1
  fi
  if ! git check-ref-format --branch "$base" >/dev/null 2>&1; then
    FM_MERGE_GUARD_ERROR="base branch '$base' is not a valid branch name"
    return 1
  fi
  if ! _fm_merge_guard_git "$wt" remote get-url origin >/dev/null 2>&1; then
    FM_MERGE_GUARD_ERROR="the task's worktree has no origin remote"
    return 1
  fi
  if ! _fm_merge_guard_git "$wt" fetch --no-tags --quiet origin \
      "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1; then
    FM_MERGE_GUARD_ERROR="origin/$base could not be fetched"
    return 1
  fi
  if ! _fm_merge_guard_git "$wt" cat-file -e "$head^{commit}" 2>/dev/null; then
    _fm_merge_guard_git "$wt" fetch --no-tags --quiet origin "+$head:$private_ref" >/dev/null 2>&1 \
      || _fm_merge_guard_git "$wt" fetch --no-tags --quiet origin "+$forge_ref:$private_ref" >/dev/null 2>&1 \
      || true
  fi
  fetched=$(_fm_merge_guard_git "$wt" rev-parse --verify --quiet "$head^{commit}" 2>/dev/null || true)
  if [ "$fetched" != "$head" ]; then
    FM_MERGE_GUARD_ERROR="the verified head $head could not be fetched"
    return 1
  fi
}

# The commit the task's ship branch was created from, read from the oldest
# entry of its reflog. Prints nothing when there is none.
fm_merge_guard_branch_origin() {  # <wt> <branch>
  local wt=$1 branch=$2
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 0
  _fm_merge_guard_git "$wt" reflog show --format=%H "refs/heads/$branch" -- 2>/dev/null | tail -1
}

_fm_merge_guard_ancestor() {  # <wt> <ancestor> <descendant>
  _fm_merge_guard_git "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null
}

# "<n> file(s): a, b, c, d, e, ..." for a newline-separated path list.
_fm_merge_guard_list() {  # <paths>
  printf '%s\n' "$1" | awk 'NF { n++; if (n <= 5) list = list (n > 1 ? ", " : "") $0 }
    END { printf "%d file(s): %s%s", n, list, (n > 5 ? ", ..." : "") }'
}

_fm_merge_guard_add_hit() {  # <name> <detail>
  FM_MERGE_GUARD_HITS="${FM_MERGE_GUARD_HITS:+$FM_MERGE_GUARD_HITS
}$1: $2"
}

# The base commits whose work on the stale <paths> merging <head> would undo.
# Walking <start>..<base-sha> newest first, a path's walk stops at the newest
# commit whose result for it is the head's content (or absence); every
# non-merge commit that changed the path after that point is undone. Prints one
# line per commit, newest first: "<short> <author-date> <subject> (<paths>)".
_fm_merge_guard_reverted() {  # <wt> <start> <base-sha> <head> <paths>
  local wt=$1 start=$2 base_sha=$3 head=$4 paths=$5 path sha files line
  local -a args=()
  while IFS= read -r path; do
    [ -z "$path" ] || args+=("$path")
  done <<PATHS
$paths
PATHS
  [ "${#args[@]}" -gt 0 ] || return 0
  {
    _fm_merge_guard_git "$wt" ls-tree -r --full-tree "$head" 2>/dev/null \
      | awk -F'\t' '{ split($1, m, " "); print "H\t" $2 "\t" m[3] }'
    _fm_merge_guard_git "$wt" --literal-pathspecs log -m --no-renames --raw --no-abbrev \
      --format='C%x09%H%x09%P' "$start..$base_sha" -- "${args[@]}" 2>/dev/null
  } | awk -F'\t' '
    $1 == "H" { h[$2] = $3; next }
    $1 == "C" {
      c = $2
      merge = (split($3, parents, " ") > 1)
      if (!(c in seen)) { seen[c] = 1; order[++n] = c }
      next
    }
    /^:/ {
      split($1, m, " ")
      p = $2
      if (p in done) next
      blob = (m[4] ~ /^0+$/) ? "-" : m[4]
      if (blob == ((p in h) ? h[p] : "-")) { done[p] = 1; next }
      if (merge || ((c SUBSEP p) in got)) next
      got[c SUBSEP p] = 1
      files[c] = files[c] (files[c] == "" ? "" : ", ") p
    }
    END { for (i = 1; i <= n; i++) if (files[order[i]] != "") print order[i] "\t" files[order[i]] }
  ' | while IFS=$'\t' read -r sha files; do
    line=$(_fm_merge_guard_git "$wt" show -s --format='%h %as %s' "$sha" -- 2>/dev/null) || line=$sha
    printf '%s (%s)\n' "$line" "$files"
  done
}

# Analyse <head> against origin/<base>. Returns 1 with FM_MERGE_GUARD_ERROR set
# when the analysis itself cannot run; hits are reported in FM_MERGE_GUARD_HITS.
fm_merge_guard_analyze() {  # <wt> <base> <head> [<fork-point-hint>]
  local wt=$1 base=$2 head=$3 hint=${4:-} base_sha mb tree start candidate
  local changed head_tree base_tree start_tree raw stale deleted migrations tests
  local pr_deleted task_deleted
  FM_MERGE_GUARD_ERROR=
  FM_MERGE_GUARD_BASE_SHA=
  FM_MERGE_GUARD_MERGE_BASE=
  FM_MERGE_GUARD_TREE=
  FM_MERGE_GUARD_SHORTSTAT=
  FM_MERGE_GUARD_STAT=
  FM_MERGE_GUARD_HITS=
  FM_MERGE_GUARD_REVERTED=
  if ! base_sha=$(_fm_merge_guard_git "$wt" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" 2>/dev/null) \
    || ! tree=$(_fm_merge_guard_git "$wt" rev-parse --verify --quiet "$head^{tree}" 2>/dev/null); then
    FM_MERGE_GUARD_ERROR="origin/$base or the head could not be read after the fetch"
    return 1
  fi
  if ! mb=$(_fm_merge_guard_git "$wt" merge-base "$base_sha" "$head" 2>/dev/null) || [ -z "$mb" ]; then
    FM_MERGE_GUARD_ERROR="the head shares no history with origin/$base"
    return 1
  fi
  FM_MERGE_GUARD_BASE_SHA=$base_sha
  FM_MERGE_GUARD_MERGE_BASE=$mb
  FM_MERGE_GUARD_TREE=$tree
  if ! FM_MERGE_GUARD_STAT=$(_fm_merge_guard_git "$wt" diff --no-ext-diff --no-color -M --stat=200 "$mb" "$head" -- 2>/dev/null) \
    || ! FM_MERGE_GUARD_SHORTSTAT=$(_fm_merge_guard_git "$wt" diff --no-ext-diff -M --shortstat "$mb" "$head" -- 2>/dev/null) \
    || ! changed=$(_fm_merge_guard_git "$wt" diff --no-ext-diff --no-renames --name-only "$mb" "$head" -- 2>/dev/null) \
    || ! deleted=$(_fm_merge_guard_git "$wt" diff --no-ext-diff -M --diff-filter=D --name-only "$mb" "$head" -- 2>/dev/null) \
    || ! pr_deleted=$(_fm_merge_guard_git "$wt" diff --no-ext-diff -M --numstat "$mb" "$head" -- 2>/dev/null \
      | awk -F'\t' '$2 ~ /^[0-9]+$/ { n += $2 } END { print n + 0 }') \
    || ! task_deleted=$(_fm_merge_guard_git "$wt" log --no-merges --cherry-pick --right-only --numstat --format= \
      "$base_sha...$head" -- 2>/dev/null \
      | awk -F'\t' '$2 ~ /^[0-9]+$/ { n += $2 } END { print n + 0 }'); then
    FM_MERGE_GUARD_ERROR="the diff against origin/$base could not be read"
    return 1
  fi
  FM_MERGE_GUARD_SHORTSTAT=$(printf '%s' "$FM_MERGE_GUARD_SHORTSTAT" | sed 's/^ *//')
  [ -n "$FM_MERGE_GUARD_SHORTSTAT" ] || FM_MERGE_GUARD_SHORTSTAT="no changes"

  # The stale-tree window starts at the oldest comparable candidate.
  start=$mb
  candidate=$(_fm_merge_guard_git "$wt" rev-list --first-parent -n "$((FM_MERGE_GUARD_LOOKBACK + 1))" "$base_sha" -- 2>/dev/null | tail -1)
  for candidate in "$hint" "$candidate"; do
    [ -n "$candidate" ] || continue
    _fm_merge_guard_ancestor "$wt" "$candidate" "$base_sha" || continue
    _fm_merge_guard_ancestor "$wt" "$candidate" "$start" && start=$candidate
  done
  if [ -n "$changed" ]; then
    if ! head_tree=$(_fm_merge_guard_git "$wt" ls-tree -r --full-tree "$head" 2>/dev/null) \
      || ! base_tree=$(_fm_merge_guard_git "$wt" ls-tree -r --full-tree "$base_sha" 2>/dev/null) \
      || ! start_tree=$(_fm_merge_guard_git "$wt" ls-tree -r --full-tree "$start" 2>/dev/null) \
      || ! raw=$(_fm_merge_guard_git "$wt" log -m --no-renames --raw --no-abbrev --format= "$start..$base_sha" -- 2>/dev/null); then
      FM_MERGE_GUARD_ERROR="the history of origin/$base could not be read"
      return 1
    fi
    stale=$(
      {
        printf '%s\n' "$changed" | awk '{ print "C\t" $0 }'
        printf '%s\n' "$head_tree" | awk -F'\t' '{ split($1, m, " "); print "H\t" $2 "\t" m[3] }'
        printf '%s\n' "$base_tree" | awk -F'\t' '{ split($1, m, " "); print "B\t" $2 "\t" m[3] }'
        printf '%s\n' "$start_tree" | awk -F'\t' '{ split($1, m, " "); print "S\t" $2 "\t" m[3] }'
        printf '%s\n' "$raw" | awk -F'\t' '/^:/ { split($1, m, " "); print "W\t" $2 "\t" m[4] }'
      } | awk -F'\t' '
        $1 == "C" { if ($2 != "") { changed[$2] = 1; order[++n] = $2 } next }
        $1 == "H" { h[$2] = $3; next }
        $1 == "B" { b[$2] = $3; next }
        $1 == "S" { s[$2] = $3; next }
        $1 == "W" {
          blob = ($3 ~ /^0+$/) ? "-" : $3
          w[$2 SUBSEP blob] = 1
          next
        }
        END {
          for (i = 1; i <= n; i++) {
            p = order[i]
            hb = (p in h) ? h[p] : "-"
            bb = (p in b) ? b[p] : "-"
            sb = (p in s) ? s[p] : "-"
            if (hb == bb) continue
            if (hb == sb || ((p SUBSEP hb) in w)) print p
          }
        }')
    if [ -n "$stale" ]; then
      FM_MERGE_GUARD_REVERTED=$(_fm_merge_guard_reverted "$wt" "$start" "$base_sha" "$head" "$stale")
      _fm_merge_guard_add_hit stale-tree "$(_fm_merge_guard_list "$stale") would return to bytes origin/$base already replaced$(
        [ -z "$FM_MERGE_GUARD_REVERTED" ] || printf '%s' "$FM_MERGE_GUARD_REVERTED" \
          | awk '{ n++; list = list (n > 1 ? ", " : "") $1 } END { printf ", reverting work from %d commit(s): %s", n, list }')"
    fi
  fi

  migrations=$(printf '%s\n' "$deleted" | awk '
    { n = split(tolower($0), part, "/")
      for (i = 1; i < n; i++)
        if (part[i] ~ /^(migrations?|migrate|drizzle|alembic|flyway|liquibase)$/) { print; next } }')
  tests=$(printf '%s\n' "$deleted" | awk '
    { n = split($0, part, "/"); name = part[n]; low = tolower($0)
      split(low, lpart, "/")
      for (i = 1; i < n; i++)
        if (lpart[i] ~ /^(test|tests|__tests__|spec|specs)$/) { print; next }
      if (name ~ /[._-](test|spec)s?\.[A-Za-z0-9]+$/ || name ~ /^test_.*\.py$/ || name ~ /Tests?\.[A-Za-z0-9]+$/) print }')
  if [ -n "$migrations" ]; then
    _fm_merge_guard_add_hit deleted-migrations "deletes $(_fm_merge_guard_list "$migrations")"
  fi
  if [ -n "$tests" ]; then
    _fm_merge_guard_add_hit deleted-tests "deletes $(_fm_merge_guard_list "$tests")"
  fi
  if [ "$pr_deleted" -ge "$FM_MERGE_GUARD_MASS_FLOOR" ] && [ "$pr_deleted" -gt $((2 * task_deleted)) ]; then
    _fm_merge_guard_add_hit mass-deletion "deletes $pr_deleted lines against origin/$base, more than twice the $task_deleted its own commits delete"
  fi
}

# Record what was checked. Fields are one line each; the stat follows "stat:".
fm_merge_guard_record() {  # <state> <task-id> <url> <head> <base> <verdict> <hits> <waived>
  local state=$1 id=$2 url=$3 head=$4 base=$5 verdict=$6 hits=$7 waived=$8 record tmp line status=0
  record="$state/$id.merge-guard"
  [ ! -L "$record" ] || return 1
  [ ! -e "$record" ] || [ -f "$record" ] || return 1
  tmp=$(umask 077 && mktemp "$state/.fm-merge-guard.XXXXXX") || return 1
  {
    printf 'fm-merge-guard-v1\n'
    printf 'pr=%s\nhead=%s\ntree=%s\nbase=%s\nbase_sha=%s\nmerge_base=%s\n' \
      "$url" "$head" "$FM_MERGE_GUARD_TREE" "$base" "$FM_MERGE_GUARD_BASE_SHA" "$FM_MERGE_GUARD_MERGE_BASE"
    printf 'shortstat=%s\n' "$FM_MERGE_GUARD_SHORTSTAT"
    while IFS= read -r line; do
      [ -z "$line" ] || printf 'hit=%s\n' "$line"
    done <<HITS
$hits
HITS
    for line in $waived; do
      printf 'waived=%s\n' "$line"
    done
    while IFS= read -r line; do
      [ -z "$line" ] || printf 'reverted=%s\n' "$line"
    done <<REVERTED
$FM_MERGE_GUARD_REVERTED
REVERTED
    printf 'verdict=%s\nchecked_epoch=%s\nstat:\n%s\n' "$verdict" "$(date +%s)" "$FM_MERGE_GUARD_STAT"
  } > "$tmp" || status=1
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" && mv -f -- "$tmp" "$record" || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  return "$status"
}
