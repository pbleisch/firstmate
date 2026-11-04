#!/usr/bin/env bash
# tests/hc-fake-fixture.sh - a stateful, file-backed fake herdr-core CLI for the
# remote second-mate suites. It never contacts a core.
#
# Terminals live as <dir>/<address>.json in the shape `hc get --json` reports.
# Every call is appended to <dir>/log as one line: the HC_SESSION and
# XDG_RUNTIME_DIR it ran under, then each argument after a \x1f separator.
# Control files under <dir>:
#   version     the version `--version` reports (default 0.1.17)
#   harness     the program a sent launch line starts (default omp)
#   shell-pid   the foreground pid of a terminal's shell (default 1)
#   screen      what `read` prints (default an empty composer)
#   down        every call except --version fails as an unavailable core
# `send` of the spawn's launch line (". '<script>'") hands the foreground to the
# harness, and `/exit` or `/quit` hands it back to the shell.

# write_hc_fake_cli <path> <fake-dir>: install the CLI at <path> with <fake-dir>
# baked in, so a caller running under env -i still reaches its state.
write_hc_fake_cli() {
  local path=$1 dir=$2
  mkdir -p "$(dirname "$path")" "$dir"
  {
    printf '#!/usr/bin/env bash\nset -u\nD=%q\n' "$dir"
    cat <<'SH'
mkdir -p "$D"
{
  printf 'HC_SESSION=%s XDG_RUNTIME_DIR=%s' "${HC_SESSION:-}" "${XDG_RUNTIME_DIR:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$D/log"
cmd=${1:-}
if [ "$cmd" != --version ] && [ -e "$D/down" ]; then
  printf '{"error":{"kind":"unavailable"}}\n' >&2
  exit 7
fi
last=''
for a in "$@"; do last=$a; done
shell_pid=$(cat "$D/shell-pid" 2>/dev/null || echo 1)
to_shell() {  # <address>
  jq --argjson pid "$shell_pid" '.foreground = {name:"sh", argv:["sh"], pid:$pid, cwd:.cwd}' "$D/$1.json" > "$D/.new" \
    && mv "$D/.new" "$D/$1.json"
}
case "$cmd" in
  --version) printf 'hc %s\n' "$(cat "$D/version" 2>/dev/null || echo 0.1.17)" ;;
  server) printf '{"core":{"id":"fakecore","name":"fake"},"version":"0.1.17"}\n' ;;
  connect)
    IFS= read -r _ || true
    printf '{"jsonrpc":"2.0","id":1,"result":{"generation":1}}\n'
    ;;
  ls)
    shift
    all=0
    labels=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --all) all=1 ;;
        --label) labels+=("$2"); shift ;;
      esac
      shift
    done
    cat "$D"/t*.json 2>/dev/null | jq -s -c --argjson all "$all" --args '
      [ .[] | select($all == 1 or .state == "live")
        | . as $t
        | select(all($ARGS.positional[]; (index("=") as $i | $t.labels[.[:$i]] == .[$i + 1:]))) ]
      | {terminals: .}' ${labels[@]+"${labels[@]}"}
    ;;
  run)
    shift
    name=''
    cwd=''
    labels='{}'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) name=$2; shift ;;
        --cwd) cwd=$2; shift ;;
        --label) labels=$(printf '%s' "$labels" | jq -c --arg kv "$2" '. + {($kv | split("=")[0]): ($kv | sub("^[^=]*="; ""))}'); shift ;;
      esac
      shift
    done
    n=$(cat "$D/next" 2>/dev/null || echo 1)
    printf '%s\n' "$((n + 1))" > "$D/next"
    jq -n --arg a "t$n" --arg n "$name" --arg c "$cwd" --argjson l "$labels" --argjson pid "$shell_pid" \
      '{address:$a, state:"live", name:$n, cwd:$c, labels:$l, foreground:{name:"sh", argv:["sh"], pid:$pid, cwd:$c}}' \
      > "$D/t$n.json"
    printf '{"address":"t%s"}\n' "$n"
    ;;
  get)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  send)
    addr=${3:-}
    [ -f "$D/$addr.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    [ "$(jq -r .state "$D/$addr.json")" = live ] || { printf '{"error":{"kind":"finished"}}\n' >&2; exit 11; }
    printf '%s\n' "$last" >> "$D/sent"
    case "$last" in
      ". '"*)
        jq --arg h "$(cat "$D/harness" 2>/dev/null || echo omp)" '.foreground.name = $h | .foreground.argv = [$h]' \
          "$D/$addr.json" > "$D/.new" && mv "$D/.new" "$D/$addr.json"
        ;;
      /exit|/quit) to_shell "$addr" ;;
    esac
    printf '{"started":true,"wait":{"status":"working"}}\n'
    ;;
  keys)
    printf '%s\n' "$last" >> "$D/keys"
    printf '{}\n'
    ;;
  read)
    [ -f "$D/$last.json" ] || exit 3
    if [ -f "$D/screen" ]; then cat "$D/screen"; else printf '\342\235\257\n'; fi
    ;;
  kill)
    [ -f "$D/$last.json" ] || exit 3
    jq '.state = "finished" | .foreground = null' "$D/$last.json" > "$D/.new" && mv "$D/.new" "$D/$last.json"
    printf '{}\n'
    ;;
  rm)
    rm -f "$D/$last.json"
    printf '{}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  } > "$path"
  chmod +x "$path"
}

# hc_fake_socket <path>: a unix socket file where a running core's socket would
# be, so a presence check sees one; nothing listens on it.
hc_fake_socket() {
  mkdir -p "$(dirname "$1")"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
}
