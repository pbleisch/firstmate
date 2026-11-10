#!/usr/bin/env bash
# Tests for bin/fm-secondmate-pr-merge.sh: the main home's captain-bound path
# for merging a Forgejo pull request a registered second mate reported, through
# bin/fm-pr-merge.sh --secondmate-pr. Forgejo is a tea mock; the pull request's
# head is a real commit in a local bare repository the content guard fetches
# from through a url.insteadOf rewrite of the forge's https URL.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SM_MERGE="$ROOT/bin/fm-secondmate-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-pr-merge-tests)
JQ_BIN=$(command -v jq) || fail "these tests read tea's JSON with the real jq, which was not found"

FJ_HOST=forgejo.example
FJ_OWNER=fixture
FJ_REPO=fixture-repo
FJ_LOGIN=fm-fixture
FJ_URL="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/9"
MATE=agent-dev
RID="$MATE-pr-$FJ_REPO-9"
INSTRUCTION="merge PR 9 when CI is green"

# A tea mock: "login list" answers from tea-logins.json, a pull request read
# from pr.json (pr-post.json once a merge landed), a commit status read from
# tea-status.json, the repository read with a merge default style, and a merge
# POST lands only when head_commit_id matches tea-expected-head. "tea api"
# exits 0 even on an HTTP error, so every branch exits 0, except that with
# tea-down present every api call fails the way tea reports an unreachable
# host, and with tea-error-body present it answers with a Forgejo error body.
add_tea_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
set -u
log_dir=$(dirname "$FM_TEST_TEA_LOG")
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"
if [ "${1:-} ${2:-}" = "login list" ]; then
  cat "$log_dir/tea-logins.json"
  exit 0
fi
[ "${1:-}" = api ] || exit 0
if [ -e "$log_dir/tea-down" ]; then
  printf 'Error: request failed: Get "https://forgejo.example/api/v1/repos/fixture/fixture-repo/pulls/9": dial tcp 192.0.2.10:443: connect: no route to host\n' >&2
  exit 1
fi
if [ -e "$log_dir/tea-error-body" ]; then
  printf '{"message":"token is required","url":"https://forgejo.example/api/swagger"}\n'
  exit 0
fi
shift
endpoint= head_commit_id=
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--login|--repo) shift 2 ;;
    -f)
      case "$2" in head_commit_id=*) head_commit_id=${2#head_commit_id=} ;; esac
      shift 2
      ;;
    /repos/*) endpoint=$1; shift ;;
    *) shift ;;
  esac
done
case "$endpoint" in
  */status\?*)
    case "$endpoint" in
      *page=1|*page=1\&*) cat "$log_dir/tea-status.json" ;;
      *) printf '{"state":"","total_count":0,"statuses":[]}\n' ;;
    esac
    ;;
  "/repos/{owner}/{repo}") printf '{"default_merge_style":"merge"}\n' ;;
  */merge)
    if [ "$head_commit_id" = "$(cat "$log_dir/tea-expected-head")" ]; then
      : > "$log_dir/tea-merged"
      printf '{}\n'
    else
      printf '{"message":"head out of date"}\n'
    fi
    ;;
  *)
    if [ -e "$log_dir/tea-merged" ]; then cat "$log_dir/pr-post.json"; else cat "$log_dir/pr.json"; fi
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tea"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

write_pr_json() {  # <file> <head> [state] [mergeable] [merged]
  printf '{"state":"%s","mergeable":%s,"merged":%s,"draft":false,"head":{"sha":"%s"},"base":{"ref":"main"}}\n' \
    "${3:-open}" "${4:-true}" "${5:-false}" "$2" > "$1"
}

write_status_json() {  # <file> <state|none>
  if [ "$2" = none ]; then
    printf '{"state":"","total_count":0,"statuses":[]}\n' > "$1"
  else
    printf '{"state":"%s","total_count":1,"statuses":[{"context":"ci","status":"%s"}]}\n' "$2" "$2" > "$1"
  fi
}

# A commit on top of origin's main, published as the pull request's head ref.
# [<extra-file>] is also added, and [<deleted-file>] removed, in that commit.
push_pr_head() {  # <case-dir> <label> [<extra-file>] [<deleted-file>] -> sha
  local case_dir=$1 label=$2 extra=${3:-} deleted=${4:-} sha
  git -C "$case_dir/src" checkout -q -B "pr-$label" main
  printf '%s\n' "$label" > "$case_dir/src/pr-$label.txt"
  git -C "$case_dir/src" add "pr-$label.txt"
  if [ -n "$extra" ]; then
    mkdir -p "$(dirname "$case_dir/src/$extra")"
    printf '%s\n' "$label" > "$case_dir/src/$extra"
    git -C "$case_dir/src" add "$extra"
  fi
  [ -z "$deleted" ] || git -C "$case_dir/src" rm -q "$deleted"
  git -C "$case_dir/src" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "pr $label"
  sha=$(git -C "$case_dir/src" rev-parse HEAD)
  git -C "$case_dir/src" push -q -f origin "$sha:refs/pull/9/head"
  git -C "$case_dir/src" checkout -q main
  printf '%s\n' "$sha"
}

# make_case <name> [status-line]: a main home that records second mate agent-dev
# with a routed status line reporting the pull request, a Forgejo whose pull
# request is open, mergeable, and green, and a local bare repository standing in
# for its git remote. Echoes the case dir.
make_case() {
  local name=$1 case_dir head
  local report=${2:-"done [key=child-pr-unforced-x] [at=1794224938]: child unforced-x PR ready: $FJ_URL mode=direct-PR yolo=off"}
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/fakebin" "$case_dir/user-home"
  fm_test_tasks_toml "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
  fm_write_secondmate_meta "$case_dir/home/state/$MATE.meta" /home/agent/fm-agent-dev
  printf '%s\n' "working [at=1794223550]: worker dispatched" "$report" > "$case_dir/home/state/$MATE.status"
  fm_git_init_commit "$case_dir/src"
  git clone -q --bare "$case_dir/src" "$case_dir/origin.git"
  git -C "$case_dir/src" remote add origin "file://$case_dir/origin.git"
  printf '[url "file://%s/origin.git"]\n\tinsteadOf = https://%s/%s/%s.git\n' \
    "$case_dir" "$FJ_HOST" "$FJ_OWNER" "$FJ_REPO" > "$case_dir/gitconfig"
  add_tea_mock "$case_dir"
  : > "$case_dir/tea.log"
  printf '[{"name":"%s","url":"https://%s","ssh_host":"","user":"","default":"false"}]\n' \
    "$FJ_LOGIN" "$FJ_HOST" > "$case_dir/tea-logins.json"
  head=$(push_pr_head "$case_dir" first)
  printf '%s\n' "$head" > "$case_dir/head"
  printf '%s\n' "$head" > "$case_dir/tea-expected-head"
  write_pr_json "$case_dir/pr.json" "$head"
  write_pr_json "$case_dir/pr-post.json" "$head" closed false true
  write_status_json "$case_dir/tea-status.json" success
  printf '%s\n' "$case_dir"
}

run_sm() {  # <case-dir> <args>...
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" \
  FM_TEST_TEA_LOG="$case_dir/tea.log" \
  GIT_CONFIG_GLOBAL="$case_dir/gitconfig" \
  HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SM_MERGE" "$@"
}

# The armed check exactly as the watcher would run it.
run_check() {  # <case-dir>
  local case_dir=$1
  FM_TEST_TEA_LOG="$case_dir/tea.log" \
  GIT_CONFIG_GLOBAL="$case_dir/gitconfig" \
  HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" \
    bash "$case_dir/home/state/$RID.check.sh"
}

arm() {  # <case-dir> [extra arm args]...
  local case_dir=$1
  shift
  run_sm "$case_dir" arm "$MATE" "$FJ_URL" --instruction "$INSTRUCTION" "$@" \
    > "$case_dir/arm.out" 2> "$case_dir/arm.err"
}

merge_attempted() {  # <case-dir>
  grep -F '/merge' "$1/tea.log" >/dev/null 2>&1
}

mate_records_digest() {  # <case-dir>
  cat "$1/home/state/$MATE.meta" "$1/home/state/$MATE.status" | cksum
}

closed_meta() {  # <case-dir> -> path of the one closed record meta
  local found
  found=$(find "$1/home/state/secondmate-prs/closed" -name "$RID.meta" 2>/dev/null | head -1)
  printf '%s\n' "$found"
}

test_arm_refuses_a_url_the_mate_did_not_report() {
  local case_dir rc
  case_dir=$(make_case unreported \
    "done [at=1794224938]: child x PR ready: https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/8")
  rc=0
  arm "$case_dir" || rc=$?
  expect_code 1 "$rc" "unreported: arming a URL the mate never reported"
  assert_grep "was not reported in a done line on second mate $MATE's status channel" "$case_dir/arm.err" \
    "unreported: the refusal did not name the missing report"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "unreported: a record was written"
  assert_absent "$case_dir/home/state/$RID.check.sh" "unreported: a watcher check was armed"

  # A working line that merely mentions the URL is not a report either.
  case_dir=$(make_case unreported-working "working [at=1794224938]: opening $FJ_URL soon")
  rc=0
  arm "$case_dir" || rc=$?
  expect_code 1 "$rc" "unreported-working: a non-done mention must not count as a report"
  merge_attempted "$case_dir" && fail "unreported: a merge was attempted"
  pass "arm refuses a pull request the second mate did not report on its status channel"
}

test_no_merge_without_a_recorded_instruction() {
  local case_dir rc
  case_dir=$(make_case no-instruction)
  rc=0
  run_sm "$case_dir" arm "$MATE" "$FJ_URL" > "$case_dir/arm.out" 2> "$case_dir/arm.err" || rc=$?
  expect_code 1 "$rc" "no-instruction: arming without the captain's words"
  assert_grep "no captain instruction recorded" "$case_dir/arm.err" "no-instruction: refusal was not explained"

  rc=0
  run_sm "$case_dir" arm "$MATE" "$FJ_URL" --instruction "merge PR 90 when green" \
    > "$case_dir/arm.out" 2> "$case_dir/arm.err" || rc=$?
  expect_code 1 "$rc" "no-instruction: an instruction naming another pull request"
  assert_grep "does not name $FJ_URL" "$case_dir/arm.err" "no-instruction: wrong-PR refusal was not explained"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "no-instruction: a record was written"

  rc=0
  run_sm "$case_dir" merge "$RID" > /dev/null 2> "$case_dir/merge.err" || rc=$?
  expect_code 1 "$rc" "no-instruction: merge with nothing armed"
  rc=0
  FM_HOME="$case_dir/home" FM_TEST_TEA_LOG="$case_dir/tea.log" PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" "$RID" "$FJ_URL" --secondmate-pr > /dev/null 2> "$case_dir/direct.err" || rc=$?
  expect_code 1 "$rc" "no-instruction: the merge entrypoint with no record"
  assert_grep "no second mate PR record is armed for $RID" "$case_dir/direct.err" \
    "no-instruction: the merge entrypoint did not name the missing record"

  # A record whose instruction was emptied by hand is refused by the merge
  # entrypoint itself, not only by this script.
  arm "$case_dir" || fail "no-instruction: arming with the captain's words failed: $(cat "$case_dir/arm.err")"
  sed 's/^instruction=.*/instruction=/' "$case_dir/home/state/secondmate-prs/$RID.meta" > "$case_dir/meta.tmp"
  cat "$case_dir/meta.tmp" > "$case_dir/home/state/secondmate-prs/$RID.meta"
  rc=0
  FM_HOME="$case_dir/home" FM_TEST_TEA_LOG="$case_dir/tea.log" GIT_CONFIG_GLOBAL="$case_dir/gitconfig" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" "$RID" "$FJ_URL" --secondmate-pr > /dev/null 2> "$case_dir/direct.err" || rc=$?
  expect_code 1 "$rc" "no-instruction: the merge entrypoint with an emptied instruction"
  assert_grep "holds no recorded captain instruction naming $FJ_URL" "$case_dir/direct.err" \
    "no-instruction: the emptied instruction was not named"
  merge_attempted "$case_dir" && fail "no-instruction: a merge was attempted"
  pass "no merge happens without a recorded captain instruction naming that exact pull request"
}

test_armed_check_waits_then_merges_when_green() {
  local case_dir rc out digest meta head
  case_dir=$(make_case merges)
  head=$(cat "$case_dir/head")
  digest=$(mate_records_digest "$case_dir")
  write_status_json "$case_dir/tea-status.json" pending
  arm "$case_dir" || fail "merges: arm failed: $(cat "$case_dir/arm.err")"
  assert_grep "armed: $RID merges $FJ_URL, reported by second mate $MATE, once its checks are green at head $head" \
    "$case_dir/arm.out" "merges: arm did not report the bound head"
  assert_present "$case_dir/home/state/$RID.check-trust" "merges: the watcher check was not registered"
  assert_grep "instruction=$INSTRUCTION" "$case_dir/home/state/secondmate-prs/$RID.meta" \
    "merges: the captain's words were not recorded"
  [ ! -e "$case_dir/home/state/$RID.meta" ] || fail "merges: a task record appeared in the home's task namespace"

  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "merges: a pending poll should be silent, got: $out"
  merge_attempted "$case_dir" && fail "merges: merged while checks were pending"
  assert_present "$case_dir/home/state/secondmate-prs/$RID.meta" "merges: a pending poll closed the record"

  write_status_json "$case_dir/tea-status.json" success
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "second mate $MATE PR $FJ_URL merged at head $head" "merges: the green poll did not report the merge"
  assert_grep "/repos/{owner}/{repo}/pulls/9/merge -f Do=merge -f head_commit_id=$head" "$case_dir/tea.log" \
    "merges: the merge was not bound to the presented head"
  meta=$(closed_meta "$case_dir")
  [ -n "$meta" ] || fail "merges: the record was not closed"
  assert_grep "outcome=merged" "$meta" "merges: the closed record does not say merged"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "merges: the armed record is still present"
  assert_absent "$case_dir/home/state/$RID.check.sh" "merges: the watcher check was not retired"
  assert_grep "check: merge landed: $RID $FJ_URL" "$case_dir/home/state/.wake-queue" \
    "merges: the merge outcome did not reach the home's wake queue"
  assert_equals "$digest" "$(mate_records_digest "$case_dir")" "merges: the mate's records were changed"

  rc=0
  out=$(run_sm "$case_dir" merge "$RID" 2>/dev/null) || rc=$?
  expect_code 1 "$rc" "merges: a closed record must never merge again"
  pass "an armed instruction waits while checks are pending and merges through fm-pr-merge.sh once green"
}

test_red_checks_refuse_and_disarm() {
  local case_dir out meta
  case_dir=$(make_case red)
  arm "$case_dir" || fail "red: arm failed: $(cat "$case_dir/arm.err")"
  write_status_json "$case_dir/tea-status.json" failure
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "merge refused and disarmed, its checks are \"failure\"" "red: the red poll was not reported"
  merge_attempted "$case_dir" && fail "red: merged with red checks"
  meta=$(closed_meta "$case_dir")
  assert_grep "outcome=checks-red" "$meta" "red: the closed record does not say red"
  assert_absent "$case_dir/home/state/$RID.check.sh" "red: the watcher check was not retired"
  [ -z "$(run_check "$case_dir" 2>/dev/null || true)" ] || fail "red: a retired record kept reporting"
  pass "red checks refuse the armed merge, report it, and disarm the record"
}

test_missing_checks_refuse_an_immediate_merge() {
  local case_dir rc
  case_dir=$(make_case missing)
  write_status_json "$case_dir/tea-status.json" none
  arm "$case_dir" || fail "missing: arm failed: $(cat "$case_dir/arm.err")"
  rc=0
  run_sm "$case_dir" merge "$RID" > /dev/null 2> "$case_dir/merge.err" || rc=$?
  expect_code 3 "$rc" "missing: merging with no reported checks"
  assert_grep 'combined status "none"' "$case_dir/merge.err" "missing: the missing checks were not named"
  merge_attempted "$case_dir" && fail "missing: merged with no reported checks"
  assert_present "$case_dir/home/state/secondmate-prs/$RID.meta" "missing: the instruction should stay armed"

  # The merge entrypoint itself refuses a head with no statuses too.
  rc=0
  FM_HOME="$case_dir/home" FM_TEST_TEA_LOG="$case_dir/tea.log" GIT_CONFIG_GLOBAL="$case_dir/gitconfig" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" "$RID" "$FJ_URL" --secondmate-pr > /dev/null 2> "$case_dir/direct.err" || rc=$?
  expect_code 1 "$rc" "missing: the merge entrypoint with no reported checks"
  assert_grep 'the combined commit status is "none", not success' "$case_dir/direct.err" \
    "missing: the merge entrypoint did not refuse on missing checks"
  merge_attempted "$case_dir" && fail "missing: the merge entrypoint merged with no reported checks"
  pass "missing checks refuse the merge and keep the instruction armed"
}

test_head_move_refuses_and_disarms() {
  local case_dir rc out meta old new
  case_dir=$(make_case head-move)
  old=$(cat "$case_dir/head")
  arm "$case_dir" || fail "head-move: arm failed: $(cat "$case_dir/arm.err")"
  new=$(push_pr_head "$case_dir" second)
  write_pr_json "$case_dir/pr.json" "$new"
  printf '%s\n' "$new" > "$case_dir/tea-expected-head"
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "its head moved from the presented $old to $new" "head-move: the move was not reported"
  merge_attempted "$case_dir" && fail "head-move: merged a head nobody presented"
  meta=$(closed_meta "$case_dir")
  assert_grep "outcome=head-moved" "$meta" "head-move: the closed record does not say the head moved"

  # Arming against a presented head that is no longer the live one is refused.
  case_dir=$(make_case head-presented)
  rc=0
  arm "$case_dir" --head "$old" || rc=$?
  expect_code 1 "$rc" "head-presented: arming a head that is not the live one"
  assert_grep "not the presented $old" "$case_dir/arm.err" "head-presented: the stale presented head was not named"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "head-presented: a record was written"
  pass "a head that moved from the presented one refuses the merge and disarms the record"
}

test_unmergeable_pull_request_is_refused_by_the_merge_gate() {
  local case_dir out meta
  case_dir=$(make_case unmergeable)
  arm "$case_dir" || fail "unmergeable: arm failed: $(cat "$case_dir/arm.err")"
  write_pr_json "$case_dir/pr.json" "$(cat "$case_dir/head")" open false
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "merge refused and disarmed by the merge gate" "unmergeable: the refusal was not reported"
  assert_contains "$out" 'mergeable is "false", not true' "unmergeable: the merge gate's reason was not relayed"
  merge_attempted "$case_dir" && fail "unmergeable: merged an unmergeable pull request"
  meta=$(closed_meta "$case_dir")
  assert_grep "outcome=merge-refused" "$meta" "unmergeable: the closed record does not say refused"
  pass "an unmergeable pull request is refused by fm-pr-merge.sh's own gate and the record disarms"
}

test_disarm_withdraws_the_instruction() {
  local case_dir rc
  case_dir=$(make_case disarm)
  arm "$case_dir" || fail "disarm: arm failed: $(cat "$case_dir/arm.err")"
  run_sm "$case_dir" disarm "$RID" --reason "captain withdrew" > "$case_dir/disarm.out" 2>&1 \
    || fail "disarm: disarm failed: $(cat "$case_dir/disarm.out")"
  assert_grep "disarmed: $RID; $FJ_URL will not be merged by this record" "$case_dir/disarm.out" \
    "disarm: the withdrawal was not reported"
  assert_absent "$case_dir/home/state/$RID.check.sh" "disarm: the watcher check was not retired"
  rc=0
  run_sm "$case_dir" merge "$RID" > /dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "disarm: merging a withdrawn instruction"
  merge_attempted "$case_dir" && fail "disarm: merged after the instruction was withdrawn"
  pass "disarm withdraws an armed instruction so nothing merges"
}

test_pr_check_still_refuses_the_secondmate_record() {
  local case_dir rc
  case_dir=$(make_case pr-check-secondmate)
  rc=0
  FM_HOME="$case_dir/home" FM_TEST_TEA_LOG="$case_dir/tea.log" PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" "$MATE" "$FJ_URL" > /dev/null 2> "$case_dir/check.err" || rc=$?
  expect_code 1 "$rc" "pr-check-secondmate: recording a mate's PR against the mate"
  assert_grep "use bin/fm-secondmate-pr-merge.sh" "$case_dir/check.err" \
    "pr-check-secondmate: the refusal did not point at the second mate merge path"
  assert_no_grep "pr=" "$case_dir/home/state/$MATE.meta" "pr-check-secondmate: the mate's record was bound"
  pass "fm-pr-check.sh still refuses to bind a second mate's PR to the mate and points at the merge path"
}

FJ_REPO_URL="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO"
GRANT_WORDS="merge agent-dev's PRs automatically once green"
REPORTS=0

write_grants() {  # <case-dir> <grant-line>...
  local case_dir=$1 file
  shift
  file="$case_dir/home/config/secondmate-pr-auto-merge"
  printf '%s\n' '# standing second mate PR merge grants' "$@" > "$file"
  chmod 0600 "$file"
}

# The mate reports the pull request done at <head> on its routed status channel.
report_done() {  # <case-dir> <head>
  REPORTS=$((REPORTS + 1))
  printf 'done [key=child-pr-%s] [at=%s]: child PR ready: %s head %s mode=direct-PR yolo=off\n' \
    "$REPORTS" "$((1794224938 + REPORTS))" "$FJ_URL" "$2" >> "$1/home/state/$MATE.status"
}

# Publish a new pull request head and make the forge report it.
move_head() {  # <case-dir> <label> [<extra-file>] [<deleted-file>] -> sha
  local case_dir=$1 head
  head=$(push_pr_head "$@")
  write_pr_json "$case_dir/pr.json" "$head"
  write_pr_json "$case_dir/pr-post.json" "$head" closed false true
  printf '%s\n' "$head" > "$case_dir/tea-expected-head"
  printf '%s\n' "$head"
}

run_auto() {  # <case-dir>
  run_sm "$1" auto > "$1/auto.out" 2> "$1/auto.err" \
    || fail "auto: the sweep exited nonzero: $(cat "$1/auto.err")"
}

test_grant_arms_automatically_and_merges_when_green() {
  local case_dir head out meta
  case_dir=$(make_case grant-merges)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  write_status_json "$case_dir/tea-status.json" pending
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-merges: arming under the grant should be silent, got: $(cat "$case_dir/auto.out")"
  meta="$case_dir/home/state/secondmate-prs/$RID.meta"
  assert_present "$meta" "grant-merges: the sweep did not arm the reported pull request"
  assert_grep "authority=grant" "$meta" "grant-merges: the record does not name the grant as its authority"
  assert_grep "instruction=$GRANT_WORDS" "$meta" "grant-merges: the grant's words were not recorded as the instruction"
  assert_grep "grant_repo=$FJ_REPO_URL" "$meta" "grant-merges: the granted repository was not recorded"
  assert_present "$case_dir/home/state/$RID.check-trust" "grant-merges: the watcher check was not registered"

  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "grant-merges: a pending poll should be silent, got: $out"
  merge_attempted "$case_dir" && fail "grant-merges: merged while checks were pending"

  write_status_json "$case_dir/tea-status.json" success
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "second mate $MATE PR $FJ_URL merged automatically at head $head under the captain's standing grant for $FJ_REPO_URL" \
    "grant-merges: the automatic merge was not reported with the full URL"
  assert_grep "/repos/{owner}/{repo}/pulls/9/merge -f Do=merge -f head_commit_id=$head" "$case_dir/tea.log" \
    "grant-merges: the merge was not bound to the reported head"
  assert_grep "check: merge landed: $RID $FJ_URL" "$case_dir/home/state/.wake-queue" \
    "grant-merges: the merge outcome did not reach the home's wake queue"

  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-merges: a later sweep reported again: $(cat "$case_dir/auto.out")"
  assert_absent "$meta" "grant-merges: a later sweep armed the merged pull request again"
  pass "a standing grant arms a reported pull request without a per-PR word and merges it once green"
}

test_no_arm_without_a_matching_grant() {
  local case_dir head rc
  # No grant file at all.
  case_dir=$(make_case grant-absent)
  head=$(cat "$case_dir/head")
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-absent: armed without any grant"

  # A grant for another repository, and one for another second mate.
  case_dir=$(make_case grant-other)
  head=$(cat "$case_dir/head")
  fm_write_secondmate_meta "$case_dir/home/state/other-dev.meta" /home/agent/fm-other-dev
  write_grants "$case_dir" \
    "$MATE https://$FJ_HOST/$FJ_OWNER/other-repo $GRANT_WORDS" \
    "other-dev $FJ_REPO_URL merge other-dev's PRs once green"
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-other: an ungranted report produced output: $(cat "$case_dir/auto.out")"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-other: armed under a grant for another repository or mate"
  rc=0
  run_sm "$case_dir" arm "$MATE" "$FJ_URL" --grant > "$case_dir/arm.out" 2> "$case_dir/arm.err" || rc=$?
  expect_code 1 "$rc" "grant-other: arm --grant with no grant naming this mate and repository"
  assert_grep "no standing captain grant in config/secondmate-pr-auto-merge names second mate $MATE for $FJ_REPO_URL" \
    "$case_dir/arm.err" "grant-other: the missing grant was not named"

  # A grant file others could write grants nothing, and says so once.
  case_dir=$(make_case grant-untrusted)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  chmod 0666 "$case_dir/home/config/secondmate-pr-auto-merge"
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  assert_grep "grants nothing: it must be a regular, single-link file only its owner can write" "$case_dir/auto.out" \
    "grant-untrusted: the untrusted grant file was not reported"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-untrusted: armed under an untrusted grant file"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-untrusted: the untrusted file was reported again unchanged"
  merge_attempted "$case_dir" && fail "grant: a merge was attempted without a matching grant"
  pass "nothing arms without a trusted grant naming that second mate and repository"
}

test_dependency_change_escalates_instead_of_arming() {
  local case_dir head out
  case_dir=$(make_case grant-deps)
  head=$(move_head "$case_dir" deps go.mod)
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  out=$(cat "$case_dir/auto.out")
  assert_contains "$out" "second mate $MATE PR $FJ_URL is not merged automatically: $FJ_URL changes dependency files (go.mod)" \
    "grant-deps: the dependency change was not escalated with the PR and its files"
  assert_contains "$out" "waits for the captain's per-PR word" "grant-deps: the escalation did not say it waits for the captain"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-deps: a dependency change was armed"
  assert_absent "$case_dir/home/state/$RID.check.sh" "grant-deps: a watcher check was armed"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-deps: the same report was escalated twice"

  # Lockfiles anywhere in the tree count too.
  case_dir=$(make_case grant-deps-nested)
  head=$(move_head "$case_dir" lock web/package-lock.json)
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  assert_grep "changes dependency files (web/package-lock.json)" "$case_dir/auto.out" \
    "grant-deps-nested: a nested lockfile was not escalated"

  # The captain's per-PR word still arms it through the unchanged path.
  arm "$case_dir" || fail "grant-deps: the per-PR instruction path refused a dependency change: $(cat "$case_dir/arm.err")"
  assert_grep "authority=instruction" "$case_dir/home/state/secondmate-prs/$RID.meta" \
    "grant-deps: the per-PR arm did not record the captain's instruction as its authority"
  merge_attempted "$case_dir" && fail "grant-deps: a merge was attempted by the sweep"
  pass "a dependency change is escalated to the captain instead of armed under the grant"
}

test_red_checks_disarm_then_a_new_head_rearms() {
  local case_dir head new out
  case_dir=$(make_case grant-rearm)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  write_status_json "$case_dir/tea-status.json" failure
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "merge refused and disarmed, its checks are \"failure\" at head $head" \
    "grant-rearm: the red checks were not reported"
  assert_contains "$out" "re-arms under the standing grant when the second mate reports done again" \
    "grant-rearm: the red report did not say how it re-arms"
  run_auto "$case_dir"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-rearm: the same report re-armed a red head"

  new=$(move_head "$case_dir" fixed)
  report_done "$case_dir" "$new"
  write_status_json "$case_dir/tea-status.json" success
  run_auto "$case_dir"
  assert_grep "pr_head=$new" "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-rearm: the new head was not armed"
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "merged automatically at head $new" "grant-rearm: the new head was not merged"

  # A report naming a head that is no longer live is refused, not armed.
  case_dir=$(make_case grant-stale-report)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  new=$(move_head "$case_dir" later)
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  assert_grep "could not be armed under the standing grant: the head of $FJ_URL is now $new, not the presented $head" \
    "$case_dir/auto.out" "grant-stale-report: a stale reported head was not refused"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-stale-report: a stale report was armed"
  assert_grep "outcome=arm-refused" "$case_dir/home/state/secondmate-prs/auto/$RID.seen" \
    "grant-stale-report: a genuine refusal was not marked seen"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-stale-report: a genuine refusal was retried: $(cat "$case_dir/auto.out")"
  pass "red checks disarm a granted pull request and the mate's report of a new head re-arms it"
}

# Point the forge's git URL at a repository that does not exist, or back.
break_forge_git() {  # <case-dir>
  printf '[url "file://%s/missing.git"]\n\tinsteadOf = https://%s/%s/%s.git\n' \
    "$1" "$FJ_HOST" "$FJ_OWNER" "$FJ_REPO" > "$1/gitconfig"
}
mend_forge_git() {  # <case-dir>
  printf '[url "file://%s/origin.git"]\n\tinsteadOf = https://%s/%s/%s.git\n' \
    "$1" "$FJ_HOST" "$FJ_OWNER" "$FJ_REPO" > "$1/gitconfig"
}

test_transient_fetch_failure_is_retried_on_the_next_sweep() {
  local case_dir head retry seen
  case_dir=$(make_case grant-transient)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  retry="$case_dir/home/state/secondmate-prs/auto/$RID.retry"
  seen="$case_dir/home/state/secondmate-prs/auto/$RID.seen"
  break_forge_git "$case_dir"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-transient: one failed fetch was reported: $(cat "$case_dir/auto.out")"
  assert_absent "$seen" "grant-transient: a failed fetch marked the done line seen"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-transient: armed without the content guard's head"
  run_auto "$case_dir"
  assert_grep "second mate $MATE PR $FJ_URL could not be armed under the standing grant on 2 sweeps in a row and is retried on every sweep: could not fetch the head of $FJ_URL" \
    "$case_dir/auto.out" "grant-transient: a persistent fetch failure was not reported once"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-transient: the same failure was reported again: $(cat "$case_dir/auto.out")"
  assert_absent "$seen" "grant-transient: a persistent fetch failure marked the done line seen"
  mend_forge_git "$case_dir"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-transient: the recovered arm was not silent: $(cat "$case_dir/auto.out")"
  assert_grep "pr_head=$head" "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-transient: the next sweep did not arm"
  assert_grep "outcome=armed" "$seen" "grant-transient: the armed line was not marked seen"
  assert_absent "$retry" "grant-transient: the retry count outlived the arm"

  # A first fetch that fails and a second that succeeds arms in one sweep.
  case_dir=$(make_case grant-flaky-fetch)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*refs/pull/*)
    if [ ! -e "$case_dir/fetch-failed-once" ]; then
      : > "$case_dir/fetch-failed-once"
      echo "fatal: unable to access 'https://$FJ_HOST/': transient" >&2
      exit 128
    fi
    ;;
esac
exec $(command -v git) "\$@"
SH
  chmod +x "$case_dir/fakebin/git"
  run_auto "$case_dir"
  assert_present "$case_dir/fetch-failed-once" "grant-flaky-fetch: the first fetch was not failed"
  [ ! -s "$case_dir/auto.out" ] || fail "grant-flaky-fetch: a retried fetch was reported: $(cat "$case_dir/auto.out")"
  assert_grep "pr_head=$head" "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-flaky-fetch: arm did not retry the fetch"
  pass "a transient fetch failure leaves the report for the next sweep, is reported once if it persists, and then arms"
}

test_unreadable_forge_is_reported_once_and_the_arm_kept() {
  local case_dir out head meta
  case_dir=$(make_case forge-down)
  head=$(cat "$case_dir/head")
  arm "$case_dir" || fail "forge-down: arm failed: $(cat "$case_dir/arm.err")"
  meta="$case_dir/home/state/secondmate-prs/$RID.meta"
  : > "$case_dir/tea-down"
  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "forge-down: one unreadable sweep was reported: $out"
  assert_present "$meta" "forge-down: an unreadable read disarmed the record"
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "second mate $MATE PR $FJ_URL stays armed but could not be read on 2 sweeps in a row: cannot reach $FJ_HOST: dial tcp 192.0.2.10:443: connect: no route to host" \
    "forge-down: the persistent unreadable read was not reported with the host and the forge's error"
  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "forge-down: the same episode was reported again: $out"
  assert_present "$meta" "forge-down: a persistent unreadable read disarmed the record"
  assert_present "$case_dir/home/state/$RID.check.sh" "forge-down: the watcher check was retired"

  # A read that succeeds ends the episode, so the next one is reported again.
  rm -f "$case_dir/tea-down"
  write_status_json "$case_dir/tea-status.json" pending
  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "forge-down: a readable pending sweep was not silent: $out"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.read-wait" "forge-down: a successful read did not end the episode"
  : > "$case_dir/tea-error-body"
  run_check "$case_dir" > /dev/null 2>&1
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "could not be read on 2 sweeps in a row: $FJ_HOST answered: token is required" \
    "forge-down: an error body was not reported in the forge's own words"
  rm -f "$case_dir/tea-error-body"
  merge_attempted "$case_dir" && fail "forge-down: a merge was attempted while the forge was unreadable"

  write_status_json "$case_dir/tea-status.json" success
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "second mate $MATE PR $FJ_URL merged at head $head" "forge-down: the recovered record did not merge"

  # The auto sweep names the forge's error when it cannot read a reported PR.
  case_dir=$(make_case forge-down-auto)
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$(cat "$case_dir/head")"
  : > "$case_dir/tea-down"
  run_auto "$case_dir"
  [ ! -s "$case_dir/auto.out" ] || fail "forge-down-auto: one unreadable sweep was reported: $(cat "$case_dir/auto.out")"
  run_auto "$case_dir"
  assert_grep "could not be armed under the standing grant on 2 sweeps in a row and is retried on every sweep: could not read $FJ_URL: cannot reach $FJ_HOST: dial tcp 192.0.2.10:443: connect: no route to host" \
    "$case_dir/auto.out" "forge-down-auto: the sweep did not name the forge's error"
  pass "an unreadable forge keeps the arm and is reported once per episode with the host and the forge's own error"
}

test_guard_fetch_failure_keeps_the_arm_and_merges_later() {
  local case_dir out head rc meta
  case_dir=$(make_case guard-unavailable)
  head=$(cat "$case_dir/head")
  arm "$case_dir" || fail "guard-unavailable: arm failed: $(cat "$case_dir/arm.err")"
  meta="$case_dir/home/state/secondmate-prs/$RID.meta"
  break_forge_git "$case_dir"
  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "guard-unavailable: one failed guard fetch was reported: $out"
  assert_present "$meta" "guard-unavailable: a failed guard fetch disarmed the record"
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "second mate $MATE PR $FJ_URL stays armed but was not merged because the content guard could not fetch from the forge on 2 sweeps in a row: origin/main could not be fetched" \
    "guard-unavailable: the persistent guard fetch failure was not reported once"
  out=$(run_check "$case_dir" 2>/dev/null)
  [ -z "$out" ] || fail "guard-unavailable: the same episode was reported again: $out"
  rc=0
  run_sm "$case_dir" merge "$RID" > /dev/null 2> "$case_dir/merge.err" || rc=$?
  expect_code 1 "$rc" "guard-unavailable: an immediate merge while the guard cannot fetch"
  assert_grep "not merged: the content guard could not fetch from the forge (origin/main could not be fetched); $RID stays armed" \
    "$case_dir/merge.err" "guard-unavailable: the immediate merge did not say the record stays armed"
  assert_present "$meta" "guard-unavailable: the immediate merge disarmed the record"
  assert_present "$case_dir/home/state/$RID.check.sh" "guard-unavailable: the watcher check was retired"
  merge_attempted "$case_dir" && fail "guard-unavailable: merged without the content guard"

  mend_forge_git "$case_dir"
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "second mate $MATE PR $FJ_URL merged at head $head" \
    "guard-unavailable: the record did not merge once the fetch worked"
  pass "a content guard that cannot fetch keeps the arm, is reported once, and merges once the fetch works"
}

test_content_guard_still_refuses_under_a_grant() {
  local case_dir head out meta
  case_dir=$(make_case grant-guard)
  mkdir -p "$case_dir/src/tests"
  printf 'keep\n' > "$case_dir/src/tests/keep.test.sh"
  git -C "$case_dir/src" add tests/keep.test.sh
  git -C "$case_dir/src" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add a test'
  git -C "$case_dir/src" push -q origin main
  head=$(move_head "$case_dir" drop-test "" tests/keep.test.sh)
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  run_auto "$case_dir"
  assert_present "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-guard: the sweep did not arm the pull request"
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "automatic merge refused and disarmed by the merge gate" "grant-guard: the guard refusal was not reported"
  assert_contains "$out" "deleted-tests" "grant-guard: the content guard's finding was not relayed"
  assert_contains "$out" "without the captain's per-PR word" "grant-guard: the refusal did not leave the call to the captain"
  assert_not_contains "$out" "stays armed" "grant-guard: a real finding was treated as a fetch failure"
  assert_absent "$case_dir/home/state/$RID.check.sh" "grant-guard: the watcher check was not retired"
  merge_attempted "$case_dir" && fail "grant-guard: merged past a content-guard finding"
  meta=$(closed_meta "$case_dir")
  assert_grep "outcome=merge-refused" "$meta" "grant-guard: the closed record does not say refused"
  run_auto "$case_dir"
  assert_absent "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-guard: the sweep re-armed past the refusal"
  pass "the content guard still refuses an automatic merge and nothing overrides it"
}

test_withdrawn_grant_stops_an_armed_merge() {
  local case_dir head out
  case_dir=$(make_case grant-withdrawn)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  write_status_json "$case_dir/tea-status.json" pending
  run_auto "$case_dir"
  assert_present "$case_dir/home/state/secondmate-prs/$RID.meta" "grant-withdrawn: the sweep did not arm the pull request"
  write_grants "$case_dir"
  write_status_json "$case_dir/tea-status.json" success
  out=$(run_check "$case_dir" 2>/dev/null)
  assert_contains "$out" "the standing grant for $FJ_REPO_URL is gone, so the automatic merge is withdrawn and nothing was merged" \
    "grant-withdrawn: the withdrawal was not reported"
  merge_attempted "$case_dir" && fail "grant-withdrawn: merged after the grant was withdrawn"
  pass "withdrawing a grant stops a merge armed under it"
}

# The watcher's check sweep runs the auto sweep while the grant file exists, so
# a granted, green pull request merges in that same sweep with no turn at all.
test_watcher_sweep_merges_a_granted_pull_request() {
  local case_dir head rc stop
  case_dir=$(make_case grant-watcher)
  head=$(cat "$case_dir/head")
  write_grants "$case_dir" "$MATE $FJ_REPO_URL $GRANT_WORDS"
  report_done "$case_dir" "$head"
  stop="$case_dir/home/state/z-stop.check.sh"
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$stop"
  chmod 0700 "$stop"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null \
    || fail "grant-watcher: could not register the stop check"
  rc=0
  FM_TEST_TEA_LOG="$case_dir/tea.log" GIT_CONFIG_GLOBAL="$case_dir/gitconfig" HOME="$case_dir/user-home" \
    perl -MPOSIX=WNOHANG -MTime::HiRes=sleep -e 'my $left=60; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } while (waitpid($pid, WNOHANG) == 0) { $left -= 0.05; if ($left <= 0) { kill "TERM", $pid; waitpid $pid, 0; exit 124 } sleep 0.05 } exit($? >> 8)' \
    env -u FM_CHECK_TIMEOUT FM_HOME="$case_dir/home" FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 \
      FM_SIGNAL_GRACE=0 PATH="$case_dir/fakebin:$PATH" "$ROOT/bin/fm-watch.sh" \
    > "$case_dir/watch.out" 2> "$case_dir/watch.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "grant-watcher: the watcher failed ($rc): $(cat "$case_dir/watch.err")"
  assert_grep "/repos/{owner}/{repo}/pulls/9/merge -f Do=merge -f head_commit_id=$head" "$case_dir/tea.log" \
    "grant-watcher: the watcher sweep did not merge the granted pull request"
  assert_grep "merged automatically at head $head" "$case_dir/home/state/.wake-queue" \
    "grant-watcher: the automatic merge did not reach the wake queue"
  pass "the watcher's check sweep arms and merges a granted pull request in one sweep"
}

fm_test_run \
  test_grant_arms_automatically_and_merges_when_green \
  test_no_arm_without_a_matching_grant \
  test_dependency_change_escalates_instead_of_arming \
  test_red_checks_disarm_then_a_new_head_rearms \
  test_transient_fetch_failure_is_retried_on_the_next_sweep \
  test_unreadable_forge_is_reported_once_and_the_arm_kept \
  test_guard_fetch_failure_keeps_the_arm_and_merges_later \
  test_content_guard_still_refuses_under_a_grant \
  test_withdrawn_grant_stops_an_armed_merge \
  test_watcher_sweep_merges_a_granted_pull_request \
  test_arm_refuses_a_url_the_mate_did_not_report \
  test_no_merge_without_a_recorded_instruction \
  test_armed_check_waits_then_merges_when_green \
  test_red_checks_refuse_and_disarm \
  test_missing_checks_refuse_an_immediate_merge \
  test_head_move_refuses_and_disarms \
  test_unmergeable_pull_request_is_refused_by_the_merge_gate \
  test_disarm_withdraws_the_instruction \
  test_pr_check_still_refuses_the_secondmate_record
