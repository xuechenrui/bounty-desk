#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zeroclaw=${ZEROCLAW_BIN:-}
config_dir=${ZEROCLAW_CONFIG_DIR:-}
run_name=${BOUNTY_DESK_DEMO_RUN_NAME:-video-run}

[ -x "$zeroclaw" ] || { echo 'ZEROCLAW_BIN must name an executable' >&2; exit 1; }
[ -d "$config_dir" ] || { echo 'ZEROCLAW_CONFIG_DIR must name the isolated demo config' >&2; exit 1; }

binary=$project_root/target/release/bounty-desk
private_root=$project_root/target/bounty-desk-live/$run_name
database=$private_root/invoices.json
adapter_state=$private_root/codex-adapter
reply=$private_root/webhook-reply.json
daemon_log=$private_root/zeroclaw-daemon.log
receiver_log=$private_root/reply-receiver.log
allowed_command="$binary --db $database create --id live-video-demo --recipient EhqjzoHQcH41DhrKqyPtqtiEdRCNnkZAUZQzNSt31GY5 --amount 0.000001 --native-sol --network devnet --message 'BountyDesk live ZeroClaw demo'"
secret=$(openssl rand -hex 32)
receiver_pid=
daemon_pid=

cleanup() {
  if [ -n "$daemon_pid" ]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  if [ -n "$receiver_pid" ]; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

test ! -e "$private_root"
mkdir -p "$private_root"

pause() { sleep "${1:-1}"; }
heading() { printf '\n\033[1;36m%s\033[0m\n' "$1"; }
command_label() { printf '\033[1;32m$ %s\033[0m\n' "$1"; }

printf '\033[2J\033[H'
printf '\033[1;35mBountyDesk — real ZeroClaw × Solana live run\033[0m\n'
printf 'Custody tier T1: unsigned request; external human wallet is the only signer.\n'
pause 2

heading '1. Stock runtimes and tested release'
command_label 'zeroclaw --version'
"$zeroclaw" --version
command_label 'bounty-desk --version'
"$binary" --version
pause 2

heading '2. Start the authenticated webhook channel'
"$zeroclaw" --config-dir "$config_dir" config set --no-interactive \
  channels.webhook.payments.secret "$secret" >/dev/null

python3 "$project_root/examples/webhook-reply-receiver.py" \
  --port 8091 \
  --output "$reply" >"$receiver_log" 2>&1 &
receiver_pid=$!

ZEROCLAW_CODEX_ADAPTER_STATE_DIR="$adapter_state" \
ZEROCLAW_CODEX_ALLOWED_COMMAND="$allowed_command" \
ZEROCLAW_CODEX_MODEL=gpt-5.4-mini \
"$zeroclaw" --config-dir "$config_dir" daemon \
  --host 127.0.0.1 \
  --port 42617 >"$daemon_log" 2>&1 &
daemon_pid=$!

body='{"sender":"bounty-operator","content":"Create the single fixed BountyDesk invoice using the installed skill. Do not sign, send, reconcile, or change any term.","thread_id":"live-video-demo"}'
invalid_code=000
attempt=0
while [ "$attempt" -lt 50 ]; do
  invalid_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 1 \
    -H 'Content-Type: application/json' \
    --data-binary "$body" \
    http://127.0.0.1:8090/payments || true)
  [ "$invalid_code" != 000 ] && break
  attempt=$((attempt + 1))
  sleep 0.2
done
printf 'Unsigned request → HTTP %s (expected rejection)\n' "$invalid_code"
[ "$invalid_code" = 401 ]
pause 2

signature=$(printf %s "$body" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $2}')
valid_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --max-time 5 \
  -H 'Content-Type: application/json' \
  -H "X-Webhook-Signature: sha256=$signature" \
  --data-binary "$body" \
  http://127.0.0.1:8090/payments)
printf 'Correct HMAC     → HTTP %s (entered the real agent loop)\n' "$valid_code"
[ "$valid_code" = 200 ]

printf 'Codex → ZeroClaw → one exact allowlisted shell call'
attempt=0
while [ "$attempt" -lt 180 ] && [ ! -s "$reply" ]; do
  printf '.'
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    printf '\n'
    echo 'ZeroClaw exited before producing a reply' >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.2
done
printf ' done\n'
[ -s "$reply" ]
[ "$(cat "$adapter_state/codex-call.status")" = completed ]
[ -s "$database" ]
pause 2

heading '3. The real tool result: a keyless Solana Pay invoice'
command_label 'bounty-desk list'
"$binary" --db "$database" list
pause 4

heading '4. Fail-closed verifier'
command_label './examples/offline-demo.sh'
"$project_root/examples/offline-demo.sh"
pause 3

heading '5. Reproducible public implementation'
printf 'Repo:    https://github.com/xuechenrui/bounty-desk\n'
printf 'Release: https://github.com/xuechenrui/bounty-desk/releases/tag/v0.2.0\n'
printf 'CI:      https://github.com/xuechenrui/bounty-desk/actions/runs/30746262754\n'
printf '\nNo seed phrase, private key, wallet signature, or transaction send capability exists in BountyDesk.\n'
pause 4
