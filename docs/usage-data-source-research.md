# Machine-Readable AI Usage Sources

**Audited:** 2026-07-24.

## Codex

Codex reads ChatGPT-plan quota from `GET /backend-api/wham/usage` (or `/api/codex/usage` for the
Codex API base). This source is first-party and account-server-side, but it is an internal backend
route rather than a documented public OpenAI API.

Current Codex also exposes a structured app-server RPC, `account/rateLimits/read`, with normalized
`rateLimits`, optional `rateLimitsByLimitId`, and windows containing `usedPercent`, optional
`windowDurationMins`, and optional `resetsAt`. It is the strongest structured contract, but using it
from this dependency-light shell poller would require starting and managing an app-server process
and speaking its protocol around the same backend account request.

Local rollout JSONL and SQLite are not reliable quota stores for `codex exec`: SQLite stores thread
metadata/token totals, rate-limit snapshots are optional response events, and stale interactive
rollouts can outlive current account state.

**Decision:** keep the direct server-side request, strict schema validation, duration-based routing,
and explicit unknown/offline states. Reconsider the app-server RPC only if cmux-sentinel adopts a
long-lived integration process for another reason.

Fixtures cover classic, swapped, weekly-only, short-only, malformed duration/percentage, relative
reset, and expanded responses carrying unrelated credits/spend/additional limits.

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
