#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
adapter=$project_root/examples/zeroclaw-codex-subscription-adapter.sh
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fake_codex=$test_root/fake-codex
cat >"$fake_codex" <<'SH'
#!/bin/sh
set -eu

printf 'called\n' >>"$FAKE_CODEX_CALLS"
printf '%s\n' "$*" >>"$FAKE_CODEX_ARGS"
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--output-last-message' ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
[ -n "$output" ]
cat >/dev/null
printf '%s\n' "$FAKE_CODEX_RESPONSE" >"$output"
SH
chmod +x "$fake_codex"

approved="/opt/bounty-desk --db /tmp/invoices.json create --id adapter-test --recipient 11111111111111111111111111111111 --amount 0.000001 --native-sol --network devnet --message 'adapter test'"
valid_response=$(python3 -c 'import json,sys; print(json.dumps({"tool_calls":[{"name":"shell","arguments":{"command":sys.argv[1]}}]}))' "$approved")

calls=$test_root/calls
args_log=$test_root/args
state=$test_root/state
first=$(printf 'first ZeroClaw prompt' | \
  CODEX_BIN="$fake_codex" \
  FAKE_CODEX_CALLS="$calls" \
  FAKE_CODEX_ARGS="$args_log" \
  FAKE_CODEX_RESPONSE="$valid_response" \
  ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$state" \
  ZEROCLAW_CODEX_ALLOWED_COMMAND="$approved" \
  "$adapter" --print --model test-model -)

[ "$first" = "$(printf '%s' "$valid_response" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))')" ]
grep -F 'features.remote_plugin=false' "$args_log" >/dev/null
grep -F 'features.plugins=false' "$args_log" >/dev/null
grep -F 'features.shell_tool=false' "$args_log" >/dev/null
grep -F 'features.apps=false' "$args_log" >/dev/null
grep -F 'features.multi_agent=false' "$args_log" >/dev/null

second=$(printf 'summary prompt' | \
  CODEX_BIN="$fake_codex" \
  FAKE_CODEX_CALLS="$calls" \
  FAKE_CODEX_ARGS="$args_log" \
  FAKE_CODEX_RESPONSE='must not be used' \
  ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$state" \
  ZEROCLAW_CODEX_ALLOWED_COMMAND="$approved" \
  "$adapter" --print --model test-model -)

case "$second" in
  *'single authorized Codex call has already been used'*) ;;
  *) echo 'second adapter invocation did not return the deterministic wrap-up' >&2; exit 1 ;;
esac

[ "$(wc -l <"$calls" | tr -d ' ')" = 1 ]

bad_state=$test_root/bad-state
if printf 'bad prompt' | \
  CODEX_BIN="$fake_codex" \
  FAKE_CODEX_CALLS="$calls" \
  FAKE_CODEX_ARGS="$args_log" \
  FAKE_CODEX_RESPONSE='{"tool_calls":[{"name":"shell","arguments":{"command":"uname -a"}}]}' \
  ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$bad_state" \
  ZEROCLAW_CODEX_ALLOWED_COMMAND="$approved" \
  "$adapter" --print --model test-model - >/dev/null 2>&1; then
  echo 'adapter accepted an unapproved command' >&2
  exit 1
fi

[ "$(cat "$bad_state/codex-call.status")" = rejected ]

quoted_state=$test_root/quoted-state
calls_before=$(wc -l <"$calls" | tr -d ' ')
if printf 'quoted command' | \
  CODEX_BIN="$fake_codex" \
  FAKE_CODEX_CALLS="$calls" \
  FAKE_CODEX_ARGS="$args_log" \
  FAKE_CODEX_RESPONSE='must not be used' \
  ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$quoted_state" \
  ZEROCLAW_CODEX_ALLOWED_COMMAND='echo "quoted"' \
  "$adapter" --print --model test-model - >/dev/null 2>&1; then
  echo 'adapter accepted a double quote that Codex strict enums reject' >&2
  exit 1
fi
[ "$(wc -l <"$calls" | tr -d ' ')" = "$calls_before" ]

printf '%s\n' 'Codex subscription adapter tests passed'
