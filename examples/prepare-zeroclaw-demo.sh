#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zeroclaw_bin=${ZEROCLAW_BIN:-zeroclaw}

if [ -z "${ZEROCLAW_DEMO_CONFIG_DIR:-}" ]; then
  echo 'ERROR: set ZEROCLAW_DEMO_CONFIG_DIR to a dedicated directory outside this repository.' >&2
  echo 'Example: export ZEROCLAW_DEMO_CONFIG_DIR="$HOME/.zeroclaw-bounty-desk-demo"' >&2
  exit 2
fi

config_dir=$ZEROCLAW_DEMO_CONFIG_DIR
case "$config_dir" in
  /|"$HOME"|"$project_root"|"$project_root"/*)
    echo 'ERROR: the demo config directory must be dedicated and outside the repository.' >&2
    exit 2
    ;;
esac

if ! command -v "$zeroclaw_bin" >/dev/null 2>&1 && [ ! -x "$zeroclaw_bin" ]; then
  echo "ERROR: ZeroClaw binary is not executable: $zeroclaw_bin" >&2
  exit 2
fi

version=$($zeroclaw_bin --version)
case "$version" in
  *'0.8.3'*) ;;
  *)
    echo "ERROR: expected ZeroClaw 0.8.3, found: $version" >&2
    exit 2
    ;;
esac

cd "$project_root"
cargo build --release --locked
cargo test --all-targets

$zeroclaw_bin skills audit zeroclaw/skills/bounty-desk
$zeroclaw_bin --config-dir "$config_dir" config set \
  sop.sops_dir "$project_root/zeroclaw/sops" --no-interactive
$zeroclaw_bin --config-dir "$config_dir" config set \
  channels.webhook.payments.enabled false --no-interactive
$zeroclaw_bin --config-dir "$config_dir" config set \
  channels.webhook.payments.port 8090 --no-interactive
$zeroclaw_bin --config-dir "$config_dir" config set \
  channels.webhook.payments.listen_path /payments --no-interactive
$zeroclaw_bin --config-dir "$config_dir" sop validate reconcile-payments

configured_enabled=$($zeroclaw_bin --config-dir "$config_dir" config get \
  channels.webhook.payments.enabled)
configured_port=$($zeroclaw_bin --config-dir "$config_dir" config get \
  channels.webhook.payments.port)
configured_path=$($zeroclaw_bin --config-dir "$config_dir" config get \
  channels.webhook.payments.listen_path)

if [ "$configured_enabled" != 'false' ] || \
   [ "$configured_port" != '8090' ] || \
   [ "$configured_path" != '/payments' ]; then
  echo 'ERROR: ZeroClaw did not persist the expected disabled webhook configuration.' >&2
  exit 1
fi

cat <<EOF

PRE-FLIGHT PASSED

Config directory: $config_dir
BountyDesk binary: $project_root/target/release/bounty-desk
Webhook: disabled, port 8090, path /payments
SOP: reconcile-payments valid

No model credential, wallet key, webhook secret, or paid model call was used.

After the operator explicitly approves Codex subscription use, continue manually:

  $zeroclaw_bin --config-dir "$config_dir" auth login --model-provider openai-codex --import ~/.codex/auth.json
  $zeroclaw_bin --config-dir "$config_dir" quickstart --model-provider openai-codex --model gpt-5.4-mini --agent bounty_desk
  $zeroclaw_bin --config-dir "$config_dir" skills install --agent bounty_desk "$project_root/zeroclaw/skills/bounty-desk"
  $zeroclaw_bin --config-dir "$config_dir" config set channels.webhook.payments.secret
  $zeroclaw_bin --config-dir "$config_dir" config set channels.webhook.payments.enabled true

The auth import can consume Codex subscription allowance. The secret command uses
masked input. A human must review both steps; this script deliberately stops here.
If the direct Codex transport fails before the model request, follow the checked
subprocess-provider fallback in docs/WEBHOOK_DEMO.md.
EOF
