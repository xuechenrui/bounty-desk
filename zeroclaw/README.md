# ZeroClaw deployment notes

This bundle targets stock ZeroClaw v0.8.3 and uses only an instruction skill, an SOP, and the built-in `shell` tool. It does not require a plugin or a patched ZeroClaw build.

1. Build `bounty-desk` with `cargo build --release`.
2. Install the binary in an operator-controlled path allowed by ZeroClaw's shell policy.
3. Copy `skills/bounty-desk` and `sops/reconcile-payments` into the configured bundle directories.
4. Set `BOUNTY_DESK_BIN` and `BOUNTY_DESK_DB` in the ZeroClaw daemon's service environment. Do not put wallet keys there.
5. If the configured parent agent alias is not `default`, update the `agent` field in `SOP.toml`.
6. Run `zeroclaw skills audit <skills/bounty-desk>` and `zeroclaw sop validate reconcile-payments` before starting the daemon.

The cron expression polls every five minutes. Manual execution remains available through the `sop_execute` tool. Coalescing prevents an overlapping poll from creating duplicate work.
