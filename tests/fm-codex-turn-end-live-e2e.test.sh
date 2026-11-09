#!/usr/bin/env bash
# tests/fm-codex-turn-end-live-e2e.test.sh - live guard for the Codex turn-end
# marker (bin/fm-busy-lib.sh "Codex turn-end marker"; live-harness-optin family).
#
# The marker's verdict comes from what the INSTALLED codex emits through its
# `-c notify=` program: an agent-turn-complete payload per completed turn of
# every thread, UUIDv7 turn ids, the main thread's first input message, steers
# folded into a running turn, and no payload for an interrupted turn. A stub
# can only repeat those assumptions, so this guard replays the exact notify
# argv a fake-pane fm-spawn builds against the real codex TUI in an isolated
# tmux server, answered by a loopback Responses fixture with fixed text and no
# tool calls. Nothing reaches a model provider, so no tokens are spent and the
# gate is default-on wherever codex, tmux, python3, jq, and perl are installed;
# FM_CODEX_TURN_END_LIVE=1 forces it (a missing tool then fails) and =0 skips.
#
# Verified per run, failing with the codex version on any miss:
#   1. the launch-brief turn binds the main thread and reads idle codex-notify,
#      while codex's own title side thread neither binds nor reads idle;
#   2. a Firstmate input clears the marker, and the turn it starts sets it again;
#   3. a steer typed into a running turn is absorbed and the marker returns;
#   4. an Escape interrupt emits no payload, so the marker stays cleared.
# Refresh docs/verification/supervision.md "Semantic busy state" from this
# guard's output after any codex upgrade.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_TURN_END_LIVE codex tmux python3 jq perl

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

VERSION=$(codex --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='codex version-unknown'
TMP_ROOT=$(fm_test_tmproot fm-codex-turn-end-live)
SOCKET="fm-codex-turn-end-$$"
FIXTURE_PID=

cleanup_live() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$FIXTURE_PID" ] || kill "$FIXTURE_PID" 2>/dev/null || true
}
trap 'cleanup_live; fm_test_cleanup' EXIT

die() {
  printf '# codex pane tail at failure:\n' >&2
  tmux -L "$SOCKET" capture-pane -p -t live:0 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  printf '# busy record: %s\n' "$(cat "$STATE/$ID.busy-state" 2>/dev/null)" >&2
  cleanup_live
  fail "$VERSION: $1"
}

# --- the fm-spawn launch, captured through a fake pane ---------------------
ID=codex-turn-end-live
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/wt"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$HOME_DIR" codex
fm_test_spawn_brief "$HOME_DIR" "$ID"
fm_git_worktree "$TMP_ROOT/project" "$WT" wt-live
: > "$TMP_ROOT/launch.log"
FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" \
  "$ID" "$TMP_ROOT/project" --mode local-only --yolo off >/dev/null 2>&1 \
  || fail "$VERSION: fm-spawn could not build a codex crewmate launch"
STATE=$(cd "$HOME_DIR/state" && pwd -P)
NOTIFY=$(python3 -I - "$(cat "$TMP_ROOT/launch.log")" <<'PY'
import shlex, sys
lines = [line for line in sys.argv[1].splitlines() if "notify=" in line]
words = shlex.split(lines[0]) if len(lines) == 1 else []
notify = [w for w in words if w.startswith("notify=")]
print(notify[0] if len(notify) == 1 else "")
PY
)
case "$NOTIFY" in *fm-codex-notify.sh*) ;; *) fail "$VERSION: the captured launch carries no notify program" ;; esac
"$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$ID/launch-brief.md" > "$TMP_ROOT/brief.enc" \
  || fail "$VERSION: could not encode the launch brief"

# --- loopback model: fixed answer, slow for the worker, fast for titles -----
python3 -I - "$TMP_ROOT/port" <<'PY' >/dev/null 2>&1 &
import http.server, json, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        title = b'Generate a concise' in body
        time.sleep(0.3 if title else 4)
        msg = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'status': 'completed',
               'phase': 'final_answer', 'content': [{'type': 'output_text', 'text': 'fixture complete', 'annotations': []}]}
        ev = [{'type': 'response.created', 'response': {'id': 'resp', 'status': 'in_progress', 'output': []}},
              {'type': 'response.output_item.added', 'output_index': 0, 'item': {**msg, 'status': 'in_progress', 'content': []}},
              {'type': 'response.output_item.done', 'output_index': 0, 'item': msg},
              {'type': 'response.completed', 'response': {'id': 'resp', 'status': 'completed', 'output': [msg],
               'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        data = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in ev).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(server.server_port))
server.serve_forever()
PY
FIXTURE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP_ROOT/port" ] && break; sleep 0.3; done
[ -s "$TMP_ROOT/port" ] || fail "$VERSION: the loopback model fixture did not start"

CODEX_DIR="$TMP_ROOT/codex-home"
mkdir -p "$CODEX_DIR" "$TMP_ROOT/login"
cat > "$CODEX_DIR/config.toml" <<EOF
model = "fixture"
model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
[model_providers.fixture]
name = "Loopback turn-end fixture"
base_url = "http://127.0.0.1:$(cat "$TMP_ROOT/port")/v1"
wire_api = "responses"
requires_openai_auth = false
[analytics]
enabled = false
[projects."$WT"]
trust_level = "trusted"
EOF
{
  printf '#!/usr/bin/env bash\n'
  # shellcheck disable=SC2016 # the launcher expands the brief when it runs
  printf 'exec codex --disable hooks -c %q "$(cat %q)"\n' "$NOTIFY" "$TMP_ROOT/brief.enc"
} > "$TMP_ROOT/launch.sh"
chmod +x "$TMP_ROOT/launch.sh"
env -i PATH="$PATH" HOME="$TMP_ROOT/login" CODEX_HOME="$CODEX_DIR" TERM=xterm-256color LANG=en_US.UTF-8 \
  tmux -L "$SOCKET" -f /dev/null new-session -d -s live -x 180 -y 45 -c "$WT" "$TMP_ROOT/launch.sh" \
  || fail "$VERSION: could not launch codex in the isolated tmux server"

verdict() { fm_busy_classify tmux live:0 codex "$ID" "$STATE"; }
wait_verdict() {  # <want> <seconds>
  local i=0
  while [ "$i" -lt $(($2 * 4)) ]; do
    [ "$(verdict)" = "$1" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
type_input() {  # <text|key> <keys...>: one Firstmate-bracketed delivery
  local kind=$1 token
  shift
  token=$(fm_busy_input_begin "$STATE" "$ID" codex "$kind" "${1-}") || die "the input stamp failed"
  if [ "$kind" = text ]; then
    tmux -L "$SOCKET" send-keys -t live:0 -l "$1"
    sleep 0.4
    tmux -L "$SOCKET" send-keys -t live:0 Enter
  else
    tmux -L "$SOCKET" send-keys -t live:0 "$@"
  fi
  fm_busy_input_end "$STATE" "$ID" codex "$token"
}

# 1. Launch-brief turn binds the main thread; the title side thread does not.
wait_verdict 'idle codex-notify' 45 || die "the launch-brief turn end never read idle codex-notify"
thread=$(sed -n 's/.* thread=//p' "$STATE/$ID.codex-thread")
[ -n "$thread" ] || die "the launch-brief turn did not bind a thread"
pass "$VERSION: the launch-brief turn binds its thread and reads idle codex-notify"

# 2. Input clears the marker; the turn it starts sets it again.
type_input text 'second fixture prompt'
case "$(verdict)" in 'unknown codex-unverified') ;; *) die "input did not clear the marker" ;; esac
sleep 2
[ "$(verdict)" = 'unknown codex-unverified' ] || die "the marker returned while the second turn was still running"
wait_verdict 'idle codex-notify' 30 || die "the turn started by the input never set the marker again"
[ "$(sed -n 's/.* thread=//p' "$STATE/$ID.codex-thread")" = "$thread" ] || die "the bound thread changed"
pass "$VERSION: input clears the marker and the turn it starts sets it again, title threads ignored"

# 3. A steer typed into a running turn is absorbed into it.
type_input text 'third fixture prompt'
sleep 1.5
type_input text 'mid-turn fixture steer'
sleep 1
[ "$(verdict)" = 'unknown codex-unverified' ] || die "the marker returned during the steered turn"
wait_verdict 'idle codex-notify' 45 || die "the turn that absorbed the steer never set the marker"
pass "$VERSION: a steer absorbed into a running turn still lets that turn's end set the marker"

# 4. An interrupt emits no payload, so the marker stays cleared.
type_input text 'fourth fixture prompt'
sleep 1.5
type_input key Escape
sleep 8
[ "$(verdict)" = 'unknown codex-unverified' ] || die "an interrupted turn set the marker"
pass "$VERSION: an interrupted turn leaves the marker cleared"

echo "# all fm-codex-turn-end-live-e2e checks passed on $VERSION"
