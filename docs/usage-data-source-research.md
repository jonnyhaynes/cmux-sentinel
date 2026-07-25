# Machine-Readable AI Usage Sources

**Audited:** 2026-07-25.

## Codex

Codex exposes a structured app-server RPC, `account/rateLimits/read`, with normalized `rateLimits`,
optional `rateLimitsByLimitId`, and windows containing `usedPercent`, optional
`windowDurationMins`, and optional `resetsAt`. The Codex TUI uses this same typed interface.

Under the hood, the normal ChatGPT configuration reads quota from `GET /backend-api/wham/usage`
(`/api/codex/usage` for the Codex API base). That source is first-party and account-server-side but
is an internal backend route rather than a documented public OpenAI API. The app-server interface
adds the supported ownership boundary: Codex resolves file/keyring auth, proactively refreshes
managed ChatGPT tokens, supplies account headers, chooses the backend route, and normalizes the
response. `codex login status` only reports the stored auth mode; it does not validate token health.

Local rollout JSONL and SQLite are not reliable quota stores for `codex exec`: SQLite stores thread
metadata/token totals, rate-limit snapshots are optional response events, and stale interactive
rollouts can outlive current account state.

**Decision:** use `account/rateLimits/read` through one short-lived stdio app server per poll. A
FIFO keeps stdin open until the correlated response arrives, then the process exits; no daemon or
new runtime dependency is required. Keep strict schema validation, duration-based routing, and
explicit unknown/offline states. Never fall back to reading OAuth material or calling WHAM directly.

This replaced the direct request after a live expired-token incident on Codex 0.145.0: direct WHAM
and the app-server RPC both correctly returned 401, while `codex login status` still said ChatGPT
was logged in. A normal model request exposed the actionable cause—its refresh token had already
been used and re-login was required. The RPC cannot repair an invalidated refresh token, but it can
perform normal refreshes and surfaces the same honest offline state without duplicating auth logic.

Fixtures cover the JSONL handshake, interleaved notifications, RPC errors, classic, swapped,
weekly-only, short-only, malformed duration/percentage, and expanded responses carrying unrelated
credits/spend/additional limits.

Authoritative source references in <https://github.com/openai/codex>:

- `codex-rs/backend-client/src/client/rate_limit_resets.rs`
- `codex-rs/app-server/README.md` (`account/rateLimits/read`)
- `codex-rs/app-server-protocol/src/protocol/v2/account.rs`
- `codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs`
- `codex-rs/codex-backend-openapi-models/src/models/rate_limit_window_snapshot.rs`

## Amp

`amp usage --help` exposes no command-specific structured option. Global `--stream-json` applies to
`--execute` agent events, not subscription quota. `amp usage --json` remains unsupported.

`amp plugins show-docs` and the public plugin type reference expose lifecycle events, commands,
tools, identity, status items, and AI helpers, but no subscription quota, billing allowance, credit
balance, or usage-change event. A plugin can shell out, but that only wraps the same prose command.

**Decision:** keep narrowly anchored `amp usage` prose parsing. Match the number immediately before
`other usage` / `orb usage`, invert remaining to used, and treat unparseable output as unknown—never
0%. Keep sanitized normal, reordered/reworded, decimal, missing-subscription, and command-error
fixtures.

Public references:

- <https://ampcode.com/manual#pricing>
- <https://ampcode.com/manual#streaming-json>
- <https://ampcode.com/manual/plugin-api>
