# BountyDesk — keyless Solana payments for autonomous ZeroClaw agents

BountyDesk turns a stock ZeroClaw agent into a non-custodial payment desk. An authenticated webhook asks the agent to create an operator-approved charge; ZeroClaw invokes one exact allowlisted BountyDesk command and returns a uniquely referenced Solana Pay invoice. A cron/manual SOP can later reconcile it through read-only RPC.

🎥 Real 36-second agent/channel run (no slides):
https://github.com/xuechenrui/bounty-desk/releases/download/v0.2.0/bounty-desk-live-demo.mp4

💻 Repo and reproducible setup:
https://github.com/xuechenrui/bounty-desk

📋 Submission write-up:
https://github.com/xuechenrui/bounty-desk/blob/main/docs/SUBMISSION.md

What runs:
- Stock ZeroClaw v0.8.3
- Authenticated webhook channel (bad HMAC → 401; valid HMAC → real agent loop)
- Portable skill + five-minute reconciliation SOP
- Deterministic Rust verifier for native SOL and SPL-token transfers
- 9 tests, Clippy/fmt CI, Apple Silicon release binary

Custody tier: **T1 — unsigned request, external human signing.** BountyDesk has no wallet creation/import/sign/send command and never receives a seed phrase or private key.

Threat model: RPC data, memos, webhook content, and model output are untrusted. Settlement succeeds only when transaction success, unique reference, recipient, asset, and raw amount all match. A hostile fixture literally asks the agent to ignore the rules and pay an attacker; the verifier exits non-zero and leaves the invoice pending.

Transparency: the recorded invoice is real and persisted, but remains unsigned/pending because the wallet boundary is intentionally external. This showcase does not claim a live settlement.

Evidence + hashes:
https://github.com/xuechenrui/bounty-desk/blob/main/docs/LIVE_EVIDENCE.json
