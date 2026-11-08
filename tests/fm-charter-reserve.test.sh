#!/usr/bin/env bash
# Charter reserve admission through fm-capacity and the public spawn interface.
# quota-axi and the pane are stubs; no account quota or real agent is contacted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-charter-reserve)
CAPACITY="$ROOT/bin/fm-capacity.sh"

make_case() { # <name> <harness>
  local dir="$TMP_ROOT/$1" home fakebin
  home="$dir/home"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" "$2"
  fm_git_worktree "$dir/project" "$dir/wt" "wt-$1"
  fm_test_spawn_brief "$home" "$1"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$FM_TEST_QUOTA_CALLS"
printf 'root=%s\n' "${CLAUDE_CONFIG_DIR-unset}" >> "$FM_TEST_QUOTA_CALLS"
cat "$FM_TEST_QUOTA_FILE"
SH
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
echo Darwin
SH
  cat > "$fakebin/ioreg" <<'SH'
#!/usr/bin/env bash
printf 'HIDIdleTime = %s\n' "${FM_TEST_IDLE_NS:-0}"
SH
  chmod +x "$fakebin/quota-axi" "$fakebin/uname" "$fakebin/ioreg"
  printf '%s\n' "$dir|$home|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR <<EOF
$1
EOF
  QUOTA_FILE="$CASE_DIR/quota.json"
  QUOTA_CALLS="$CASE_DIR/quota.calls"
}

set_quota() { # <five-hour-left> <weekly-left> <weekly-pace>
  jq -cn --argjson five "$1" --argjson week "$2" --arg pace "$3" '
    {schemaVersion: 5, providers: [{provider: "claude", windows: [
      {id: "five_hour", kind: "session", percentRemaining: $five, pace: {status: "behind"}},
      {id: "seven_day", kind: "weekly", percentRemaining: $week, pace: {status: $pace}},
      {id: "model:fable", kind: "model", percentRemaining: 0, pace: {status: "ahead"}}
    ]}]}' > "$QUOTA_FILE"
}

run_admit() {
  FM_TEST_QUOTA_FILE="$QUOTA_FILE" FM_TEST_QUOTA_CALLS="$QUOTA_CALLS" \
    FM_TEST_IDLE_NS="${TEST_IDLE_NS:-0}" FM_HOME="$HOME_DIR" \
    FM_TIMEOUT_MECHANISM_OVERRIDE=bash PATH="$FAKEBIN_DIR:$PATH" \
    "$CAPACITY" --admit-charter 2>&1
}

# The task id is the case name; its project path is the same fixture in every case.
spawn_case() {
  FM_TEST_QUOTA_FILE="$QUOTA_FILE" FM_TEST_QUOTA_CALLS="$QUOTA_CALLS" \
    FM_TEST_IDLE_NS="${TEST_IDLE_NS:-0}" \
    FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$CASE_DIR/wt" "$FAKEBIN_DIR" \
      "$(basename "$CASE_DIR")" "$CASE_DIR/project" "$@"
}

test_reserve_verdicts() {
  local out rc
  read_case "$(make_case reserves claude)"
  cat > "$HOME_DIR/config/lane-capacity" <<'CFG'
8
quota-reserve-5h 20
quota-reserve-weekly 20
quota-pace-ignore-above 60
captain-present-claude-max 1
CFG
  set_quota 19 75 on_pace
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'five-hour reserve'
  assert_contains "$out" 'deferred: Claude charter 5h reserve' 'five-hour refusal reason'
  set_quota 50 19 on_pace
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'weekly reserve'
  assert_contains "$out" 'deferred: Claude charter weekly reserve' 'weekly refusal reason'
  set_quota 50 60 ahead
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'pace band'
  assert_contains "$out" 'deferred: Claude charter pace band' 'pace refusal reason'
  set_quota 50 60 unknown
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'unreadable weekly pace'
  assert_contains "$out" 'deferred: Claude charter quota unreadable' 'unknown pace is unreadable'
  printf '%s\n' '{broken' > "$QUOTA_FILE"
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'unreadable quota'
  assert_contains "$out" 'deferred: Claude charter quota unreadable' 'unreadable refusal reason'
  set_quota 20 61 ahead
  out=$(run_admit); rc=$?
  expect_code 0 "$rc" 'above 60% ignores pace, at 20% meets five-hour floor'
  set_quota 50 60 on_pace
  out=$(run_admit); rc=$?
  expect_code 0 "$rc" 'at 60% with a healthy pace'
  set_quota 50 20 ahead
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'at weekly reserve floor, ahead of pace'
  assert_contains "$out" 'deferred: Claude charter pace band' 'weekly floor is allowed but pace still applies'
  set_quota 50 80 on_pace
  jq '.providers[0].state = {status: "fresh", stale: true}' "$QUOTA_FILE" > "$CASE_DIR/stale.json"
  cp "$CASE_DIR/stale.json" "$QUOTA_FILE"
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'stale Claude quota'
  assert_contains "$out" 'deferred: Claude charter quota unreadable' 'stale quota is unreadable for reserve admission'
  pass 'Claude quota floors, pace band, unreadability, and boundary behavior'
}

test_present_cap_and_absent_keys() {
  local out rc
  read_case "$(make_case presence claude)"
  printf '8\ncaptain-present-claude-max 1\n' > "$HOME_DIR/config/lane-capacity"
  printf 'kind=ship\nharness=codex\ncharter=project\n' > "$HOME_DIR/state/codex.meta"
  printf 'kind=ship\nharness=claude\n' > "$HOME_DIR/state/unmarked.meta"
  printf '%s\n' '{broken' > "$QUOTA_FILE"
  out=$(run_admit); rc=$?
  expect_code 0 "$rc" 'other worker records do not consume the Claude charter cap'
  printf 'kind=ship\nharness=claude\ncharter=project\n' > "$HOME_DIR/state/existing.meta"
  out=$(run_admit); rc=$?
  expect_code 75 "$rc" 'captain-present cap'
  assert_contains "$out" 'deferred: Claude charter captain-present cap' 'present cap refusal reason'
  assert_absent "$QUOTA_CALLS" 'the present cap alone must not read quota'
  TEST_IDLE_NS=400000000000
  out=$(run_admit); rc=$?
  expect_code 0 "$rc" 'idle captain admits another worker'
  unset TEST_IDLE_NS
  printf '8\n' > "$HOME_DIR/config/lane-capacity"
  out=$(run_admit); rc=$?
  expect_code 0 "$rc" 'absent reserve keys'
  assert_absent "$QUOTA_CALLS" 'absent reserve keys never read quota'
  pass 'captain presence cap and absent-key no-op'
}

test_invalid_keys() {
  local key bad bad_values out rc
  read_case "$(make_case invalid claude)"
  for key in quota-reserve-5h quota-reserve-weekly quota-pace-ignore-above captain-present-claude-max; do
    if [ "$key" = captain-present-claude-max ]; then
      bad_values='invalid -1'
    else
      bad_values='invalid 101'
    fi
    for bad in $bad_values; do
      printf '8\n%s %s\n' "$key" "$bad" > "$HOME_DIR/config/lane-capacity"
      out=$(run_admit); rc=$?
      expect_code 1 "$rc" "invalid $key=$bad"
      assert_contains "$out" 'config/lane-capacity: line 2:' 'invalid key names its line'
    done
  done
  pass 'malformed reserve values invalidate the lane-capacity file'
}

test_spawn_selection_and_metadata() {
  local out rc
  read_case "$(make_case unmarked-claude claude)"
  printf '8\nquota-reserve-5h 20\n' > "$HOME_DIR/config/lane-capacity"
  printf '%s\n' '{broken' > "$QUOTA_FILE"
  out=$(spawn_case --mode local-only --yolo off --harness claude); rc=$?
  expect_code 0 "$rc" "unmarked Claude spawn: $out"
  assert_absent "$QUOTA_CALLS" 'unmarked Claude spawn does not read quota'
  assert_not_contains "$(cat "$HOME_DIR/state/unmarked-claude.meta")" 'charter=' 'unmarked task has no charter metadata'

  read_case "$(make_case codex-charter codex)"
  printf '8\nquota-reserve-5h 20\n' > "$HOME_DIR/config/lane-capacity"
  printf '%s\n' '{broken' > "$QUOTA_FILE"
  out=$(spawn_case --mode local-only --yolo off --charter project --harness codex); rc=$?
  expect_code 0 "$rc" "Codex charter spawn: $out"
  assert_grep 'charter=project' "$HOME_DIR/state/codex-charter.meta" 'Codex charter identity is recorded'
  assert_absent "$QUOTA_CALLS" 'Codex charter does not read Claude quota'

  read_case "$(make_case claude-deferred claude)"
  printf '8\nquota-reserve-5h 20\n' > "$HOME_DIR/config/lane-capacity"
  set_quota 19 80 on_pace
  out=$(spawn_case --mode local-only --yolo off --charter project --harness claude); rc=$?
  expect_code 75 "$rc" 'Claude charter spawn reserve refusal'
  assert_contains "$out" 'deferred: Claude charter 5h reserve' 'spawn relays the reserve reason'
  assert_absent "$HOME_DIR/state/claude-deferred.meta" 'deferred spawn creates no metadata'
  assert_absent "$CASE_DIR/launch.log" 'deferred spawn sends no launch'

  read_case "$(make_case claude-allowed claude)"
  printf '8\nquota-reserve-5h 20\n' > "$HOME_DIR/config/lane-capacity"
  set_quota 80 80 on_pace
  out=$(spawn_case --mode local-only --yolo off --charter project --harness claude); rc=$?
  expect_code 0 "$rc" "Claude charter admitted: $out"
  assert_grep 'charter=project' "$HOME_DIR/state/claude-allowed.meta" 'admitted Claude charter identity is recorded'

  read_case "$(make_case claude-account claude)"
  printf '8\nquota-reserve-5h 20\n' > "$HOME_DIR/config/lane-capacity"
  mkdir -p "$CASE_DIR/selected-account"
  printf '%s\n' "$CASE_DIR/selected-account" > "$HOME_DIR/config/claude-account"
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN_DIR/claude"
  set_quota 80 80 on_pace
  out=$(spawn_case --mode local-only --yolo off --charter project --harness claude); rc=$?
  expect_code 0 "$rc" "pinned Claude charter admitted: $out"
  assert_grep "root=$CASE_DIR/selected-account" "$QUOTA_CALLS" 'quota reads the worker account selected for launch'
  pass 'spawn gates Claude charter work and leaves Codex charter spawns unaffected'
}

test_reserve_verdicts
test_present_cap_and_absent_keys
test_invalid_keys
test_spawn_selection_and_metadata
echo '# all charter reserve tests passed'
