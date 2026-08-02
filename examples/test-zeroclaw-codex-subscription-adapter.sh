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

approved='bounty-desk --db "$BOUNTY_DESK_DB" create --id adapter-test --recipient 11111111111111111111111111111111 --amount 0.000001 --native-sol --network devnet --message "adapter test"'
valid_response=$(python3 -c 'import json,sys; print(json.dumps({"tool_calls":[{"name":"shell","arguments":{"command":sys.argv[1]}}]}))' "$approved")

calls=$test_root/calls
state=$test_root/state
first=$(printf 'first ZeroClaw prompt' | \
  CODEX_BIN="$fake_codex" \
  FAKE_CODEX_CALLS="$calls" \
  FAKE_CODEX_RESPONSE="$valid_response" \
  ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$state" \
  ZEROCLAW_CODEX_ALLOWED_COMMAND="$approved" \
  "$adapter" --print --model test-model -)

[ "$first" = "$(printf '%s' "$valid_response" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))')" ]

second=$(printf 'summary prompt' | \
  CODEX_BIN="$fake_codex" \
  FAKE_CODEX_CALLS="$calls" \
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
  FAKE_CODEX_RESPONSE='{"tool_calls":[{"name":"shell","arguments":{"command":"uname -a"}}]}' \
  ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$bad_state" \
  ZEROCLAW_CODEX_ALLOWED_COMMAND="$approved" \
  "$adapter" --print --model test-model - >/dev/null 2>&1; then
  echo 'adapter accepted an unapproved command' >&2
  exit 1
fi

[ "$(cat "$bad_state/codex-call.status")" = rejected ]
printf '%s\n' 'Codex subscription adapter tests passed'
