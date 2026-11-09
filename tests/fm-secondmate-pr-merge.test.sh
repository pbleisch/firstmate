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
# exits 0 even on an HTTP error, so every branch exits 0.
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
push_pr_head() {  # <case-dir> <label> -> sha
  local case_dir=$1 label=$2 sha
  printf '%s\n' "$label" > "$case_dir/src/pr-$label.txt"
  git -C "$case_dir/src" checkout -q -B "pr-$label" main
  git -C "$case_dir/src" add "pr-$label.txt"
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

fm_test_run \
  test_arm_refuses_a_url_the_mate_did_not_report \
  test_no_merge_without_a_recorded_instruction \
  test_armed_check_waits_then_merges_when_green \
  test_red_checks_refuse_and_disarm \
  test_missing_checks_refuse_an_immediate_merge \
  test_head_move_refuses_and_disarms \
  test_unmergeable_pull_request_is_refused_by_the_merge_gate \
  test_disarm_withdraws_the_instruction \
  test_pr_check_still_refuses_the_secondmate_record
