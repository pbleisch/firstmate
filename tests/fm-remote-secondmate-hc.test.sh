#!/usr/bin/env bash
# tests/fm-remote-secondmate-hc.test.sh - a remote second mate on the hc
# backend, driven through bin/fm-remote-secondmate-control.sh the way the
# remote job worker runs it: env -i with only PATH, HOME, FM_HOME,
# FM_ROOT_OVERRIDE, and FM_REMOTE_JOB_ACTIVE.
#
#   A) launch runs the host-local --secondmate spawn in the account's default
#      core, and state, route, capture, observe, a steer's doorbell, and a key
#      all reach that terminal under the launch's own identity.
#   B) an endpoint recorded in another hc session is refused by every verb.
#   C) with no running core every verb refuses without calling hc, so nothing
#      here can start a second core.
#   D) a core whose socket sits in the login runtime directory is found even
#      though the job carries no XDG_RUNTIME_DIR.
#   E) relaunch restarts the mate in its own terminal.
#   F) launch closes a dead endpoint and replaces it, and retirement closes the
#      mate's terminal and removes its home.
#
# The core is tests/hc-fake-fixture.sh's file-backed fake, installed as both
# herdr-core and hc ahead of a PATH that holds no other copy, and omp is a fake
# that answers `models --json`; nothing here contacts a real herdr-core.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/hc-fake-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/hc-fake-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-hc)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

# A real process alone in its own process group stands in for a terminal's
# shell, so the adapter's process-group scan can complete and prove an agent
# gone. It is stopped by the pid recorded here.
perl -e 'setpgrp(0, 0); sleep 600' &
SHELL_PID=$!
trap 'kill "$SHELL_PID" 2>/dev/null || true; fm_test_cleanup || true' EXIT

FAKEBIN="$TMP_ROOT/fakebin"
HC="$TMP_ROOT/hc"
mkdir -p "$FAKEBIN" "$HC"
write_hc_fake_cli "$FAKEBIN/herdr-core" "$HC"
ln -sf herdr-core "$FAKEBIN/hc"
printf '%s\n' "$SHELL_PID" > "$HC/shell-pid"
printf 'omp\n' > "$HC/harness"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v node)" "$FAKEBIN/node"
ln -sf "$(command -v python3)" "$FAKEBIN/python3"
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[{"provider":"anthropic","id":"claude-test","selector":"anthropic/claude-test"}]}'
exit 0
SH
chmod +x "$FAKEBIN/omp"

# The account's own HOME, so the core's state-directory socket lives here. It
# sits under a short path because a unix socket path is limited to about 100
# bytes.
ACCOUNT=$(mktemp -d /tmp/fmhc.XXXXXX) || fail "could not create the account home"
ACCOUNT=$(cd "$ACCOUNT" && pwd -P)
FM_TEST_CLEANUP_DIRS+=("$ACCOUNT")
CORE_SOCK="$ACCOUNT/.local/state/herdr-core/default/default.sock"
hc_fake_socket "$CORE_SOCK"

ID=sm-hc
HOME_DIR="$TMP_ROOT/home-$ID"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/data"
printf '# Firstmate\n' > "$HOME_DIR/AGENTS.md"
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf '# Charter\n\nStand by until steering arrives.\n' > "$HOME_DIR/data/charter.md"
printf '%s\n' 'state/' 'data/' 'config/' 'projects/' > "$HOME_DIR/.gitignore"
git -C "$HOME_DIR" init -q -b main
git -C "$HOME_DIR" add AGENTS.md .gitignore
git -C "$HOME_DIR" -c user.email=t@example.com -c user.name=T commit -qm init
META="$HOME_DIR/state/parent-route/$ID.meta"

CTL_EXTRA=()
ctl() {
  env -i PATH="$FAKEBIN:$BASE_PATH" HOME="$ACCOUNT" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REMOTE_JOB_ACTIVE=1 FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=2 FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    ${CTL_EXTRA[@]+"${CTL_EXTRA[@]}"} \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

hc_calls() { wc -l < "$HC/log" | tr -d ' '; }

# The tags the launch's identity and the mate home derive.
# shellcheck disable=SC2016 # the $0 root expands in the child shell.
LAUNCH_TAG=$(FM_HOME="$ROOT" FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source hc >/dev/null 2>&1; fm_backend_hometag' "$ROOT")
# shellcheck disable=SC2016 # the $0 root expands in the child shell.
MATE_TAG=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source hc >/dev/null 2>&1; fm_backend_hometag' "$ROOT")
[ -n "$LAUNCH_TAG" ] && [ -n "$MATE_TAG" ] || fail "could not resolve the home tags"

# --- A) launch and every endpoint verb -----------------------------------------

ctl launch "$ID" omp anthropic/claude-test high hc > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err"
expect_code 0 "$?" "a host-local remote secondmate launch on hc failed"$'\n'"$(cat "$TMP_ROOT/launch.err")"
grep -qx -- 'backend=hc' "$TMP_ROOT/launch.out" || fail "the printed route did not name hc: $(cat "$TMP_ROOT/launch.out" "$TMP_ROOT/launch.err")"
grep -qx -- 'target=default:t1' "$TMP_ROOT/launch.out" || fail "the endpoint is not in the default core"
grep -qx -- 'hc_session=default' "$TMP_ROOT/launch.out" || fail "the printed route did not name the default session"
grep -qx -- 'backend=hc' "$META" || fail "the endpoint record did not record hc"
grep -qx -- 'hc_session=default' "$META" || fail "the endpoint record did not record the default session"
[ "$(jq -r '.labels["firstmate.home"]' "$HC/t1.json")" = "$LAUNCH_TAG" ] \
  || fail "the mate's terminal does not carry the launch identity"
[ "$(jq -r '.labels["herdr.space"]' "$HC/t1.json")" = "fm-$MATE_TAG" ] \
  || fail "the mate's terminal is not in its own Herdr.app space"
[ -z "$(grep -v $'\x1f--version' "$HC/log" | grep -v '^HC_SESSION=default ')" ] \
  || fail "an hc call ran outside the default session: $(grep -v $'\x1f--version' "$HC/log" | grep -v '^HC_SESSION=default ')"
[ "$(ctl state "$ID")" = alive ] || fail "the hc endpoint did not read alive from its host"
ctl route "$ID" > "$TMP_ROOT/route.out" || fail "route refused the hc endpoint"
grep -qx -- 'hc_session=default' "$TMP_ROOT/route.out" || fail "route did not report the hc session"
printf 'mate screen line\n\342\235\257\n' > "$HC/screen"
CAPTURE=$(ctl capture "$ID" 5 2>&1) || fail "capture of the hc endpoint failed: $CAPTURE"
assert_contains "$CAPTURE" 'mate screen line' "capture did not read the mate's screen"
OBSERVE=$(ctl observe "$ID" 2>&1) || fail "observe of the hc endpoint failed: $OBSERVE"
case "$OBSERVE" in busy|idle|fallback-idle) ;; *) fail "observe returned no busy verdict for the hc endpoint: $OBSERVE" ;; esac
rm -f "$HC/screen"
sent_before=$(wc -l < "$HC/sent" | tr -d ' ')
ctl send "$ID" 'remote steer for the hc mate' > "$TMP_ROOT/send.out" 2>&1 \
  || fail "a steer to the hc mate failed: $(cat "$TMP_ROOT/send.out")"
assert_no_grep 'doorbell' "$TMP_ROOT/send.out" "the steer's doorbell did not reach the hc mate"
[ "$(wc -l < "$HC/sent" | tr -d ' ')" -gt "$sent_before" ] || fail "no doorbell was typed into the hc mate"
ls "$HOME_DIR/state/parent-route/$ID.inbox/"*.msg >/dev/null 2>&1 || fail "the steer left no durable inbox record"
ctl key "$ID" Escape > "$TMP_ROOT/key.out" 2>&1 || fail "a key to the hc mate failed: $(cat "$TMP_ROOT/key.out")"
grep -qx esc "$HC/keys" || fail "the hc mate never received the Escape key"
pass "A launch runs the mate in the default core and every endpoint verb reaches it under the launch identity"

# --- B) a recorded endpoint outside the default session ------------------------

cp "$META" "$TMP_ROOT/meta-good"
sed -e 's/^hc_session=default$/hc_session=work/' -e 's/^window=default:/window=work:/' "$TMP_ROOT/meta-good" > "$META"
[ "$(ctl state "$ID" 2>/dev/null)" = unverified ] || fail "an hc endpoint outside the default session was not unverified"
for verb in route capture observe; do
  if ctl "$verb" "$ID" > "$TMP_ROOT/b-$verb.out" 2>&1; then
    fail "$verb accepted an hc endpoint outside the default session"
  fi
  assert_grep "expected 'default'" "$TMP_ROOT/b-$verb.out" "$verb refused without naming the session contract"
done
cp "$TMP_ROOT/meta-good" "$META"
pass "B an endpoint recorded in another hc session is refused"

# --- C) no running core --------------------------------------------------------

rm -f "$CORE_SOCK"
calls_before=$(hc_calls)
[ "$(ctl state "$ID" 2>/dev/null)" = unverified ] || fail "a missing core did not leave the endpoint unverified"
for verb in route capture observe; do
  if ctl "$verb" "$ID" > "$TMP_ROOT/c-$verb.out" 2>&1; then
    fail "$verb ran with no running core"
  fi
  assert_grep 'no core for that session is running' "$TMP_ROOT/c-$verb.out" "$verb refused without naming the missing core"
done
if ctl launch "$ID" omp anthropic/claude-test high hc > "$TMP_ROOT/c-launch.out" 2>&1; then
  fail "launch ran with no running core"
fi
assert_grep 'refusing to launch rather than starting one' "$TMP_ROOT/c-launch.out" "launch refused without naming the missing core"
[ "$(hc_calls)" = "$calls_before" ] || fail "a verb called hc while no core was running: $(tail -n +"$((calls_before + 1))" "$HC/log")"
pass "C with no running core every verb refuses before calling hc"

# --- D) a core in the login runtime directory -----------------------------------

LOGIN_BASE="$ACCOUNT/run"
hc_fake_socket "$LOGIN_BASE/$(id -u)/herdr-core/default.sock"
CTL_EXTRA=("FM_BACKEND_HC_LOGIN_RUNTIME_BASE=$LOGIN_BASE")
[ "$(ctl state "$ID")" = alive ] || fail "the core in the login runtime directory was not found"
tail -1 "$HC/log" | grep -q "XDG_RUNTIME_DIR=$LOGIN_BASE/$(id -u)" \
  || fail "hc ran without the login runtime directory: $(tail -1 "$HC/log")"
CTL_EXTRA=()
rm -rf "$LOGIN_BASE"
hc_fake_socket "$CORE_SOCK"
pass "D a job with no XDG_RUNTIME_DIR reaches a core in the login runtime directory"

# --- E) relaunch ---------------------------------------------------------------

runs_before=$(grep -c $'\x1frun\x1f' "$HC/log")
ctl relaunch "$ID" omp anthropic/claude-test high > "$TMP_ROOT/relaunch.out" 2>&1 \
  || fail "relaunch of the hc mate failed: $(cat "$TMP_ROOT/relaunch.out")"
grep -qx -- 'target=default:t1' "$TMP_ROOT/relaunch.out" || fail "relaunch moved the mate out of its terminal"
grep -Eqx '/(quit|exit)' "$HC/sent" || fail "relaunch never stopped the running agent"
[ "$(grep -c $'\x1frun\x1f' "$HC/log")" = "$runs_before" ] || fail "relaunch created a terminal instead of adopting the mate's"
[ "$(ctl state "$ID")" = alive ] || fail "the relaunched hc mate did not read alive"
pass "E relaunch restarts the mate in its own terminal"

# --- F) a dead endpoint on launch, then retirement ------------------------------

jq --argjson pid "$SHELL_PID" '.foreground = {name:"sh", argv:["sh"], pid:$pid, cwd:.cwd}' "$HC/t1.json" > "$HC/.t1" \
  && mv "$HC/.t1" "$HC/t1.json"
[ "$(ctl state "$ID")" = dead ] || fail "an agent-less hc terminal did not read dead"
ctl launch "$ID" omp anthropic/claude-test high hc > "$TMP_ROOT/f-launch.out" 2>&1 \
  || fail "launch over a dead hc endpoint failed: $(cat "$TMP_ROOT/f-launch.out")"
assert_absent "$HC/t1.json" "the dead terminal was not closed before the replacement"
grep -qx -- 'target=default:t2' "$TMP_ROOT/f-launch.out" || fail "the replacement did not bind a fresh terminal"
[ "$(ctl state "$ID")" = alive ] || fail "the replacement hc mate did not read alive"
ctl retire "$ID" > "$TMP_ROOT/retire.out" 2>&1
expect_code 0 "$?" "retirement of an hc mate failed"$'\n'"$(cat "$TMP_ROOT/retire.out")"
assert_absent "$HC/t2.json" "retirement left the mate's terminal in the core"
assert_absent "$HOME_DIR" "retirement left the hc mate's home behind"
pass "F launch replaces a dead endpoint and retirement closes the terminal and removes the home"

echo "ALL TESTS PASSED"
