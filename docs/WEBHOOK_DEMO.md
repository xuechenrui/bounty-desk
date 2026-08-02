# ZeroClaw webhook channel demo

The stock ZeroClaw webhook channel is a real HTTP ingress for the BountyDesk agent. It rejects unauthenticated messages and requires HMAC-SHA256 over the exact request body.

This runbook deliberately keeps the webhook secret and model credentials outside the repository.

## 0. Credential-free pre-flight

Before importing any model credential, run the checked pre-flight against a dedicated config directory outside the repository:

```sh
export ZEROCLAW_BIN=/absolute/path/to/zeroclaw
export ZEROCLAW_DEMO_CONFIG_DIR="$HOME/.zeroclaw-bounty-desk-demo"
./examples/prepare-zeroclaw-demo.sh
```

This verifies ZeroClaw 0.8.3, the release build, all tests, the skill audit, the SOP, and a disabled webhook on port 8090 at `/payments`. It neither reads nor imports `~/.codex/auth.json`.

## 1. Configure a model and agent

Use a model provider supported by your ZeroClaw installation. The parent agent alias must match `agent = "default"` in the reconciliation SOP, or the SOP field must be changed to your alias.

For an existing Codex subscription login, follow ZeroClaw's official OAuth import instructions and be aware that subscription allowance or flexible credits may be consumed:

```sh
zeroclaw auth login --model-provider openai-codex --import ~/.codex/auth.json
zeroclaw quickstart --model-provider openai-codex --model gpt-5.4-mini --agent default
```

Do not copy `auth.json`, ZeroClaw auth profiles, API keys, or webhook secrets into this repository.

## 2. Configure the authenticated channel

Initialize the aliased channel and set its non-secret fields:

```sh
zeroclaw config set channels.webhook.payments.enabled false
zeroclaw config set channels.webhook.payments.port 8090
zeroclaw config set channels.webhook.payments.listen_path /payments
```

Set the secret with masked input by omitting its value:

```sh
zeroclaw config set channels.webhook.payments.secret
```

Then enable it:

```sh
zeroclaw config set channels.webhook.payments.enabled true
```

Install the BountyDesk binary, skill, and SOP as described in the root README. Set `BOUNTY_DESK_BIN` and `BOUNTY_DESK_DB` in the daemon's trusted service environment, then start `zeroclaw daemon`.

## 3. Send an authenticated reconciliation request

Put the same webhook secret into a temporary local environment variable without saving it to shell history. Construct one compact JSON body and sign its exact bytes:

```sh
body='{"sender":"bounty-operator","content":"Use the bounty-desk skill to reconcile pending invoices. Do not create or modify invoice terms.","thread_id":"reconcile-demo-1"}'
signature=$(printf %s "$body" | openssl dgst -sha256 -hmac "$ZEROCLAW_WEBHOOK_SECRET" -hex | awk '{print $2}')

curl --fail-with-body \
  -H 'Content-Type: application/json' \
  -H "X-Webhook-Signature: sha256=$signature" \
  --data-binary "$body" \
  http://127.0.0.1:8090/payments
```

Expected evidence:

1. Missing or incorrect signatures return HTTP 401.
2. A valid signature returns HTTP 200 and enters the agent loop.
3. The skill runs only the pinned reconciliation command.
4. Reconciliation output reports `checked` and `newly_paid`; no wallet approval appears because the path cannot sign.
5. The SOP audit records the run and its step results.

## Security note

The webhook authenticates the producer, but its message content is still untrusted data. The skill and SOP forbid content from changing the binary path, database path, RPC endpoint, recipient, mint, amount, or reference. The Rust verifier ignores all memo/instruction text and makes the final settlement decision.
