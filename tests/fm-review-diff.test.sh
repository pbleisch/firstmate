#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
#   (f) --stat presents the PR state block: guard findings, reverted commits,
#       and the GitHub or Gitea state, checks, and reviews
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

# Gitea serves refs/pull/<n>/head exactly as GitHub does, and its route is the
# plural /pulls/<n>, so only the number extraction in front of the fetch had to
# learn that spelling.
test_gitea_pr_meta_fetches_pull_head() {
  local case_dir out
  case_dir=$(make_case gitea-pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://git.example/example/repo/pulls/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "gitea-pr-fetch: diff should use the fetched PR head"
  assert_not_contains "$out" 'stale-local' \
    "gitea-pr-fetch: diff must not fall back to the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "gitea-pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head for a Gitea pull request URL"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

# Fake gh and tea that serve the files a case writes, plus the real jq.
add_forge_mocks() {
  local case_dir=$1
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "pr view" ] || exit 1
cat "$case_dir/gh-view.json"
SH
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "logins list" ]; then
  printf 'NAME\tURL\tSSHHOST\tUSER\tDEFAULT\n'
  printf 'home\thttps://git.example\tgit.example\tme\ttrue\n'
  exit 0
fi
[ "\$1 \$2 \$3" = "api --login home" ] || exit 1
case "\$4" in
  */pulls/9/reviews) cat "$case_dir/tea-reviews.json" ;;
  */pulls/9) cat "$case_dir/tea-pr.json" ;;
  */commits/*/status*) cat "$case_dir/tea-status.json" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/tea"
}

run_review_diff_with_forge() {
  local case_dir=$1
  shift
  PATH="$case_dir/fakebin:$PATH" run_review_diff "$case_dir" "$@"
}

# main: baseline -> add a and b -> C1 (a=2) -> C2 (a=3) -> C3 (b=2), with the
# task's tree from C1 grafted onto C3 and served as the PR head, so merging
# would revert C2 and C3 but keep C1.
push_two_commit_revert() {
  local case_dir=$1 wt fork task_tree base graft
  wt="$case_dir/wt"
  printf '1\n' > "$wt/a.txt"
  printf '1\n' > "$wt/b.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -qm 'add a and b'
  printf '2\n' > "$wt/a.txt"
  git -C "$wt" commit -qam 'kept change to a'
  git -C "$wt" push -q origin HEAD:main
  fork=$(git -C "$wt" rev-parse HEAD)
  printf 'task\n' > "$wt/task.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -qm 'task work'
  task_tree=$(git -C "$wt" rev-parse 'HEAD^{tree}')
  git -C "$wt" checkout -q --detach "$fork"
  printf '3\n' > "$wt/a.txt"
  git -C "$wt" commit -qam 'reverted change to a'
  printf '2\n' > "$wt/b.txt"
  git -C "$wt" commit -qam 'reverted change to b'
  git -C "$wt" push -q origin HEAD:main
  base=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q fm/task-x1
  graft=$(git -C "$wt" commit-tree "$task_tree" -p "$base" -m 'task work')
  git -C "$wt" push -q origin "$graft:refs/pull/9/head"
  PR_SHA=$graft
}

write_gh_view() {  # <case_dir> <head> [<jq filter>]
  local case_dir=$1 head=$2 filter=${3:-.}
  jq -n --arg head "$head" '{
    state: "OPEN", isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
    headRefOid: $head, baseRefName: "main", reviewDecision: "APPROVED",
    latestReviews: [{author: {login: "alice"}, state: "APPROVED"}],
    statusCheckRollup: [
      {__typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: "FAILURE", startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:01:00Z"},
      {__typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: "SUCCESS", startedAt: "2026-01-01T00:02:00Z", completedAt: "2026-01-01T00:03:00Z"},
      {__typename: "StatusContext", context: "lint", state: "PENDING"}
    ]}' | jq -c "$filter" > "$case_dir/gh-view.json"
}

test_stat_presents_a_clean_github_pr_state() {
  local case_dir out
  case_dir=$(make_case stat-github-clean)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"
  add_forge_mocks "$case_dir"
  write_gh_view "$case_dir" "$PR_SHA"

  out=$(run_review_diff_with_forge "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'feature.txt | 2 +-' "stat-github-clean: the diff stat is missing"
  assert_contains "$out" "  head: $PR_SHA" "stat-github-clean: the compared head is missing"
  assert_contains "$out" '  guard findings: none' "stat-github-clean: a clean PR must report no guard findings"
  assert_contains "$out" '  reverts work from: none' "stat-github-clean: a clean PR must report no reverted commits"
  assert_contains "$out" '  state: open, not a draft' "stat-github-clean: the state and draft flag are missing"
  assert_contains "$out" '  mergeable: MERGEABLE (merge state CLEAN)' "stat-github-clean: mergeability is missing"
  assert_contains "$out" '  checks: 1 passing, 0 failing, 1 pending (lint pending)' \
    "stat-github-clean: checks must count only the newest run per name"
  assert_contains "$out" '  reviews: APPROVED; alice approved' "stat-github-clean: reviews are missing"
  assert_not_contains "$out" 'warning:' "stat-github-clean: an agreeing head and base must not warn"
  assert_not_contains "$out" '+pr-fixed' "stat-github-clean: --stat must not print the full diff"

  write_gh_view "$case_dir" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  out=$(run_review_diff_with_forge "$case_dir" task-x1 --stat 2> "$case_dir/stderr")
  assert_contains "$out" 'warning: the forge reports head deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' \
    "stat-github-clean: a forge head that differs from the compared head must warn"
  pass "fm-review-diff --stat presents a clean GitHub PR's guard, checks, reviews, and mergeability"
}

test_stat_lists_the_commits_a_pr_reverts() {
  local case_dir out
  case_dir=$(make_case stat-reverts)
  push_two_commit_revert "$case_dir"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"
  add_forge_mocks "$case_dir"
  write_gh_view "$case_dir" "$PR_SHA"

  out=$(run_review_diff_with_forge "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" '    - stale-tree: 2 file(s): a.txt, b.txt would return to bytes origin/main already replaced' \
    "stat-reverts: the stale tree was not reported"
  printf '%s\n' "$out" | grep -q '^    - [0-9a-f]\{7,\} [0-9-]\{10\} reverted change to b (b.txt)$' \
    || fail "stat-reverts: the reverted change to b was not listed: $out"
  printf '%s\n' "$out" | grep -q '^    - [0-9a-f]\{7,\} [0-9-]\{10\} reverted change to a (a.txt)$' \
    || fail "stat-reverts: the reverted change to a was not listed: $out"
  assert_not_contains "$out" 'kept change to a' "stat-reverts: a change the PR keeps was listed as reverted"
  assert_not_contains "$out" 'reverts work from: none' "stat-reverts: reverted commits were reported as none"
  pass "fm-review-diff --stat lists both earlier commits whose work a PR reverts"
}

test_stat_presents_a_gitea_pr_state() {
  local case_dir out
  case_dir=$(make_case stat-gitea)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://git.example/example/repo/pulls/9"
  add_forge_mocks "$case_dir"
  printf '{"html_url":"https://git.example/example/repo/pulls/9","state":"open","merged":false,"draft":false,"mergeable":false,"head":{"sha":"%s"},"base":{"ref":"main"}}\n' \
    "$PR_SHA" > "$case_dir/tea-pr.json"
  printf '{"sha":"%s","total_count":2,"statuses":[{"context":"CI / build","status":"success"},{"context":"CI / test","status":"failure"}]}\n' \
    "$PR_SHA" > "$case_dir/tea-status.json"
  printf '%s\n' '[{"user":{"login":"bob"},"state":"REQUEST_CHANGES","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"bob"},"state":"APPROVED","submitted_at":"2026-01-02T00:00:00Z"}]' \
    > "$case_dir/tea-reviews.json"

  out=$(run_review_diff_with_forge "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" '  guard findings: none' "stat-gitea: the guard findings are missing"
  assert_contains "$out" '  state: open, not a draft' "stat-gitea: the state and draft flag are missing"
  assert_contains "$out" '  mergeable: false' "stat-gitea: a false mergeable must be shown, not read as unknown"
  assert_contains "$out" '  checks: 1 passing, 1 failing, 0 pending (CI / test failing)' "stat-gitea: checks are missing"
  assert_contains "$out" '  reviews: bob approved' "stat-gitea: only each reviewer's latest review counts"
  pass "fm-review-diff --stat presents a Gitea pull request's state, checks, and reviews"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_gitea_pr_meta_fetches_pull_head
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_stat_presents_a_clean_github_pr_state
test_stat_lists_the_commits_a_pr_reverts
test_stat_presents_a_gitea_pr_state
