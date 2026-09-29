#!/usr/bin/env bash
# Tests for bin/fm-remote-liveness.sh: installing and removing the per-home
# systemd --user timer, and the probe's quiet paths. The probe's down and
# recovery episodes run against a real launched endpoint in
# tests/fm-remote-secondmate-lifecycle-e2e.test.sh.
#
# Every case uses a fixture HOME and a fake systemctl that records its calls, so
# no case can reach the invoking account's real user manager.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVENESS="$ROOT/bin/fm-remote-liveness.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-liveness-tests)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# new_case <name> [manager=this|other|none]: a seeded remote home for mate "ios"
# plus a fake systemctl whose user manager serves this HOME, another HOME, or
# is unreachable.
new_case() {
  local name=$1 manager=${2:-this}
  CASE="$TMP_ROOT/$name"
  CASE_HOME="$CASE/account"
  CASE_MATE="$CASE/mate-home"
  mkdir -p "$CASE/bin" "$CASE_HOME" "$CASE_MATE/state"
  printf 'ios\n' > "$CASE_MATE/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$CASE_MATE/.fm-secondmate-parent"
  : > "$CASE/systemctl.log"
  cat > "$CASE/bin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$CASE/systemctl.log'
case '$manager' in none) exit 1 ;; esac
[ "\${1:-}" = --user ] || exit 1
case "\${2:-}" in
  show-environment)
    if [ '$manager' = other ]; then printf 'HOME=/elsewhere\n'; else printf 'HOME=%s\n' "\$HOME"; fi
    ;;
esac
exit 0
SH
  chmod +x "$CASE/bin/systemctl"
}

run_liveness() { # <args...>; captures OUT, ERR, RC
  set +e
  OUT=$(HOME="$CASE_HOME" FM_HOME="$CASE_MATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_STATE_ROOT="$CASE/remote-jobs" PATH="$CASE/bin:$PATH" \
    "$LIVENESS" "$@" 2> "$CASE/err")
  RC=$?
  set -e
  ERR=$(cat "$CASE/err")
}

set -e

new_case install
run_liveness install ios
expect_code 0 "$RC" "install failed with a user manager serving this HOME: $ERR"
UNIT_DIR="$CASE_HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/dev.firstmate.remote-liveness-ios.service"
TIMER="$UNIT_DIR/dev.firstmate.remote-liveness-ios.timer"
assert_present "$SERVICE" "install wrote no service unit"
assert_present "$TIMER" "install wrote no timer unit"
assert_grep "Environment=\"HOME=$CASE_HOME\" \"FM_HOME=$CASE_MATE\" \"FM_ROOT_OVERRIDE=$ROOT\"" "$SERVICE" \
  "the service does not carry the account home, the mate home, and the code root"
assert_grep "ExecStart=\"$ROOT/bin/fm-remote-liveness.sh\" probe --textfile \"$CASE_HOME/.firstmate/metrics/ios.prom\"" "$SERVICE" \
  "the service does not run the probe with its textfile"
assert_grep 'OnUnitActiveSec=120s' "$TIMER" "the timer does not repeat at the default interval"
assert_grep 'WantedBy=timers.target' "$TIMER" "the timer is not started at boot"
assert_grep '--user enable --now dev.firstmate.remote-liveness-ios.timer' "$CASE/systemctl.log" \
  "install did not enable and start the timer"
assert_contains "$ERR" 'installed: dev.firstmate.remote-liveness-ios.timer' "install did not report what it did"
[ -z "$OUT" ] || fail "install wrote to stdout, which a launch route reply would carry: $OUT"
run_liveness remove ios
expect_code 0 "$RC" "remove failed: $ERR"
assert_absent "$SERVICE" "remove left the service unit"
assert_absent "$TIMER" "remove left the timer unit"
assert_grep '--user disable --now dev.firstmate.remote-liveness-ios.timer' "$CASE/systemctl.log" \
  "remove did not stop and disable the timer"
pass "install writes and enables the per-home liveness timer, and remove takes it away"

for manager in none other; do
  new_case "no-manager-$manager" "$manager"
  run_liveness install ios
  expect_code 0 "$RC" "install failed instead of stepping aside with manager=$manager"
  assert_contains "$ERR" 'the liveness timer is not installed' "install did not say it stepped aside (manager=$manager)"
  assert_absent "$CASE_HOME/.config/systemd" "install wrote units no manager for this HOME reads (manager=$manager)"
  ! grep -q 'enable' "$CASE/systemctl.log" || fail "install enabled a unit in a manager for another HOME (manager=$manager)"
done
pass "install changes nothing when no user manager serves this HOME"

new_case wrong-id
run_liveness install other
expect_code 1 "$RC" "install accepted an id this home does not hold"
assert_absent "$CASE_HOME/.config/systemd" "a refused install wrote units"
new_case not-a-home
rm -f "$CASE_MATE/.fm-secondmate-home"
run_liveness probe
expect_code 1 "$RC" "the probe ran in a directory that is not a secondmate home"
pass "the liveness tool refuses a home that is not this secondmate's"

new_case unlaunched
run_liveness probe --textfile "$CASE/metrics/ios.prom"
expect_code 0 "$RC" "the probe failed on a home with no launched endpoint: $ERR"
assert_contains "$OUT" 'state=unlaunched' "a home with no endpoint record was not reported unlaunched"
assert_grep 'firstmate_remote_secondmate_up{id="ios",state="unlaunched"} 0' "$CASE/metrics/ios.prom" \
  "the textfile did not report the unlaunched home"
run_liveness probe
assert_absent "$CASE_MATE/state/parent-replies.status" "an unlaunched home published a liveness line"
assert_absent "$CASE_MATE/state/.remote-liveness" "an unlaunched home opened a down episode"
pass "a home with no launched endpoint reports unlaunched and publishes nothing"
