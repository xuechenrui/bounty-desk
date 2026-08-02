#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
demo_dir=$(mktemp -d "${TMPDIR:-/tmp}/bounty-desk-demo.XXXXXX")
trap 'rm -rf "$demo_dir"' EXIT HUP INT TERM

recipient='Vote111111111111111111111111111111111111111'
mint='EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'
reference='11111111111111111111111111111111'
binary="$project_root/target/debug/bounty-desk"

cd "$project_root"
cargo build --quiet

"$binary" \
  --db "$demo_dir/invoices.json" \
  create \
  --id offline-demo \
  --recipient "$recipient" \
  --amount 50 \
  --token-mint "$mint" \
  --decimals 6 \
  --network mainnet-beta \
  --message 'Offline demo only; do not pay this address'

"$binary" verify-fixture \
  --file tests/fixtures/valid_payment.json \
  --recipient "$recipient" \
  --token-mint "$mint" \
  --reference "$reference" \
  --amount-units 50000000

"$binary" verify-fixture \
  --file tests/fixtures/valid_native_sol_payment.json \
  --recipient "$recipient" \
  --native-sol \
  --reference "$reference" \
  --amount-units 100000000

if "$binary" verify-fixture \
  --file tests/fixtures/prompt_injection_attack.json \
  --recipient "$recipient" \
  --token-mint "$mint" \
  --reference "$reference" \
  --amount-units 50000000
then
  echo 'ERROR: hostile transaction was accepted' >&2
  exit 1
else
  echo 'PASS: hostile transaction failed closed' >&2
fi
