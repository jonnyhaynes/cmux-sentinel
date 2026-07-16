# CLAUDE.md — guidance for AI assistants working on cmux-sentinel

cmux-sentinel is an opinionated [cmux](https://cmux.com) **custom sidebar** (a runtime-interpreted
SwiftUI-style file) plus background pollers that show workspace/agent states and **AI usage
meters**. Read this before editing — it encodes traps that cost real hours and that you cannot
discover from the code alone, because the failure mode is a **silently blank sidebar**.

## ⚠️ The sidebar interpreter is a SUBSET of SwiftUI — these WILL bite you

`cmux sidebar validate` only **parses**. It passes on files that render **completely blank** at
runtime, and the interpreter swallows the error (no log). So an edit that "validates" can still
break everything. Confirmed traps:

- **String ops `.hasPrefix` / `.contains` / `.hasSuffix` / `.split` DO work** on the current build
  (proven by probe: `hasPrefix=Y contains=Y hasSuffix=Y`; the live sidebar detects the working/
  compacting title markers via `.hasPrefix` and strips them with `.split`). An earlier note here
  claimed they render blank — that was WRONG on this build. `==` works too; use whichever is clearest.
- **Avoid `||`** (unproven). Use an `if`-chain returning early. `&&` is fine and short-circuits.
- **`progress` DOES reach the sidebar on cmux 0.64.17 — `description`/`color` still don't.** Earlier
  probes concluded "`progress` never reaches" but every one checked an IDLE sentinel on which
  `set-progress` was never called — so of course it read `null`. It's **null-until-set**: after
  `cmux set-progress <0..1> --label <t>` the interpreter sees `w.progress.value` AND
  `w.progress.label` (verified 2026-07-06 by an in-sidebar render probe — see
  `.claude/research/2026-07-06-conductor-sidebar-analysis.md`). So the usage meters now draw a
  **native `ProgressView`** off the progress channel, and the **title** stays the meter's
  restart-proof ANCHOR (`resolve_ref`/`isClaudeMeter` key on it) AND the fallback the sidebar renders
  whenever progress is absent — bootstrap, offline-cleared, a dropped write, or the window right
  after an app restart before the next poll re-asserts it. The poller writes BOTH every run
  (`_meter_write`), so the title path is never "ripped out" and restart-persistence of `progress` is
  a non-issue (it self-heals within one poll). **Agent working/compacting/waiting state still rides
  the title** (static markers, stripped for display) — a persistence + precedence choice, not a
  channel limit. **CAVEAT — the snapshot RPC is the WRONG instrument for this:**
  `cmux rpc extension.sidebar.snapshot '{}'` omits the `progress` key entirely even right after a
  successful `set-progress` (that's how the old re-probe "confirmed" the wrong answer), and
  `cmux sidebar-state` diverges too — only an in-sidebar `Text(...)`/render probe is authoritative,
  so eyeball it. `description`/`color` remain untested/unreached on 0.64.17 (retest before relying).
- **Sentinel resolution is multi-window + title-anchored.** `cmux workspace list` is window-scoped and
  launchd has no window context, so the pollers' `resolve_ref` tries the default window then scans
  `list-windows`, returning `ref⇥window` and renaming with `--window` (unambiguous positional ref).
  `bin/cmux-sentinel-setup.sh` creates the sentinels idempotently; both it and the doctor probe
  `workspace.set_auto_title '{}'` (empty params = no mutation) to warn if global auto-naming could
  clobber a title prefix.
- **`cmux sidebar-state` DIVERGES from what the sidebar sees** (it reads the canonical store). Never
  use it to predict the sidebar — verify with an in-sidebar `Text(...)` probe.
- **cmux 0.64.15 REMOVED stable workspace UUIDs.** `cmux workspace list --json` now returns
  `id: null`; the only handle is a positional `ref` (`workspace:N`) that **rotates across app
  restarts and reorders**. The old scheme stored sentinel UUIDs in the env file and the sidebar —
  that broke on the first restart (silent "offline" meters in the normal list). Both sides now anchor
  on the **title label** instead: the poller `resolve_ref()`s each sentinel by the workspace whose
  title starts with the `5h`/`7d` label (plus a space) and renames by the live ref; the sidebar's
  `isClaudeMeter()` matches the same prefix. This is restart-proof because it re-resolves every run —
  the same reason the bridge
  reads a LIVE `$CMUX_WORKSPACE_ID` (still a UUID, set per-shell) instead of storing one. Don't
  reintroduce a stored id. The committed and deployed sidebars are now byte-identical (no id
  substitution at install).
- **Meters use a native value bar now.** `ProgressView(value:)` needs a numeric `progress`; the
  poller supplies it via `set-progress` (see the progress bullet above), so a meter row renders a
  native `ProgressView` tinted from the value (red ≥90%, amber ≥70%, else blue) with
  `w.progress.label` for the text. The Unicode block bar (`▏▎▍▌▋▊▉█`) baked into the title is the
  FALLBACK the sidebar draws when `progress` is absent. The title's severity emoji (🟡/🔴) stays
  because title **color** still can't come from data.
- **Workspace-GROUP data NEVER reaches the sidebar interpreter** (probed 2026-06-19, see
  `.claude/research/2026-06-19-workspace-group-names-in-sidebar.md`). There is no `groups` binding and
  no per-workspace group field — referencing `groups` renders empty (the interpreter is lenient, it
  does NOT blank), and `extension.sidebar.snapshot` carries no group fields either. A cmux group's
  display name (`group.name`, via `cmux workspace-group list`) lives ONLY on the group object; the
  group header IS its ANCHOR workspace's row, and the anchor's `title` does NOT track `group.name`
  (they diverge on rename). So the sidebar shows the anchor's stale/generic "Group N". Same fix shape
  as the meters: `bin/cmux-group-sync.sh` (opt-in `GROUP_NAME_SYNC=1`) renames each anchor's title to
  `group.name` via the **title channel** (preserving any ⚡/⏳ marker, writing only on change). Don't
  try to read group data in the sidebar — it isn't there.
- **No modifier-key state reaches the interpreter — ⌘-hold hints are impossible.** The live
  bindings are only `workspaces` / `tabs` / `workspaceCount` / `selectedTitle` / `selectedId` /
  `unreadTotal` / `clock`; there's no keyboard/modifier binding (and no `@State`, no
  `.keyboardShortcut`). cmux's NATIVE sidebar does draw ⌘-hold digit badges
  (`modifierKeyMonitor.isModifierPressed`), but that's internal to it. Even given a binding, the
  ~1s re-eval would lag a held key. Needs an upstream feature — don't try to fake it.
- **The ⌘N gutter digit keys on `w.index`, mirroring cmux's `WorkspaceShortcutMapper`.** Two traps a
  naive 1..N counter gets wrong: **⌘9 is NOT the 9th** — it always selects the LAST workspace
  (`count-1`), so indices 8…count-2 have no key at all; and the digit indexes cmux's FULL tab list,
  which **includes the sentinels** (cmux has no "sentinel" concept — that's only this file's
  predicates). So the meters really do eat ⌘ slots and the visible rows show honest gaps
  (verified 2026-07-15 by a real ⌘1…⌘9 sweep: ⌘6→`cx7d`, ⌘7→`cx5h`, ⌘9→`7d`). There's no way to
  make a sentinel weightless — `TabManager.tabs` is the raw array, no hidden/archived concept — so
  the fix is ORDER, which is free because sentinel index doesn't affect what renders (the meter
  panel sorts by label; the list filters meters out). **Layout invariant: sentinels live in the
  keyless band (indices 8…count-2) and the LAST workspace is a real one** — that's 9/9 keys on real
  workspaces. Sentinels at the very bottom costs ⌘9; at the top costs ⌘1–⌘4. Enforced by the layout
  pass in `bin/cmux-sentinel-setup.sh` (re-run it anytime; `--no-layout` / `SENTINEL_LAYOUT=0` opts
  out). It only pushes meters down and re-parks the workspace that was ALREADY last, so relative
  order of real workspaces is preserved and nothing visible moves. Deliberately NOT in the pollers —
  re-asserting order every 5min would fight manual drag-reordering.
  **That pass is one-shot, so the invariant DECAYS: closing a workspace above a meter shifts the
  meter up, and once fewer than 8 reals sit above it, it eats ⌘8** — silently, since the only symptom
  is a ⌘ key doing something odd. So `bin/cmux-sentinel-doctor.sh` reports which digits (if any) the
  meters are eating and warns when headroom is down to one close; the fix is always "re-run setup".
  Read-only, for the same reason it's not in the pollers. The mapper was re-verified UNCHANGED on
  0.64.19 (0.64.18's "Fix workspace number shortcut rebinding" touched settings rebinding, not the
  index math) — the source is fetchable, `cmux docs shortcuts` names the raw URLs.
  See `.claude/research/2026-07-15-workspace-shortcut-digits.md` and
  `.claude/research/2026-07-16-cmux-0.64.19-pre-restart-check.md`.
- **Greedy modifiers that wreck row height:** `Divider().background("#hex")`,
  `.frame(maxHeight: .infinity)`, `.overlay { Rectangle().frame(height:1) }`. Use plain `Divider()` +
  a single `.padding(n)`. `.contentShape(Rectangle())` is a no-op. Custom fonts aren't honored —
  use `.system(size:, design: .monospaced)`.

**When the sidebar goes blank, DON'T guess.** Replace the whole file with a one-line
`Text("HELLO")`, confirm it renders, then add helpers/views back one at a time (`cmux sidebar
reload` after each) until it blanks. That isolates the bad construct in ~3 steps.

## Testing loop

```bash
# sidebar
cp sidebars/workspaces.swift ~/.config/cmux/sidebars/workspaces.swift
cmux sidebar validate workspaces && cmux sidebar reload   # validate only PARSES — also eyeball it

# pollers (no cmux writes unless --update)
./bin/cmux-claude-usage.sh --print     # parsed values
./bin/cmux-claude-usage.sh --raw       # raw API JSON (no token)
./bin/cmux-claude-usage.sh --update    # actually renames the sentinels
./bin/cmux-codex-usage.sh --print      # Codex: live utilization from ChatGPT wham/usage
./bin/cmux-codex-usage.sh --raw        # raw wham/usage JSON (token NOT included)
./bin/cmux-codex-usage.sh --update     # renames cx5h/cx7d (needs USAGE_PROVIDERS to list codex)
./bin/cmux-sentinel-setup.sh           # create sentinels + park them out of ⌘1…⌘9 (--no-layout skips)
./bin/cmux-group-sync.sh --list        # workspace-GROUP names: which anchors are out of sync (read-only)
./bin/cmux-group-sync.sh --update      # rename group anchors to the group name (needs GROUP_NAME_SYNC=1)

# offline tests (stub cmux/security/curl/$HOME — run in CI too)
make test   # bridge-state(36) poller-gate(21) codex-poller(33) install-hooks(21) sentinel-setup(36)
            # group-sync(24) zed-bridge(24) open-in-zed(14) usage-tui(16)
```

## Architecture / where things live

```text
sidebars/workspaces.swift  the sidebar. isClaudeMeter()/isCodexMeter() = title-label `.hasPrefix` per provider; isUsageMeter() = any.
bin/cmux-claude-usage.sh    Claude usage poller. make_bar / sev_dot / mark_offline / bucket_field / to_pct / resolve_ref(+_paint, multi-window).
bin/cmux-codex-usage.sh     Codex usage poller (ChatGPT wham/usage endpoint; token from ~/.codex/auth.json). read_token / fetch_usage / make_bar / sev_dot / mark_offline / to_pct / resolve_ref(+_paint).
bin/cmux-sentinel-setup.sh  idempotent sentinel creation (per USAGE_PROVIDERS) + auto-naming guard probe + ⌘N shortcut layout (layout/sentinel_window, --no-layout).
bin/cmux-sentinel-doctor.sh READ-ONLY wiring report: cmux/sidebar/bridge/auto-refresh, installed × enabled × sentinel per provider, ⌘N layout drift, snapshot data.
bin/cmux-group-sync.sh      workspace-GROUP name → anchor-title sync (opt-in GROUP_NAME_SYNC). split-marker / multi-window / --list|--raw|--update.
hooks/cmux-bridge.sh        Claude Code → cmux agent-state bridge (⚡ working / ⏳ compacting / ❓ waiting-on-you rows).
hooks/zed-bridge.sh         OPT-IN (ZED_SENTINEL=1) cmux-free Zed bridge: same ⚡/⏳/❓ markers to OSC terminal-title + JSON sink.
bin/cmux-open-in-zed.sh     OPT-IN cmux→Zed worktree handoff (`ze` alias / Ctrl-O via --shell-init). git-toplevel-aware; switch/--add/--new/--print.
bin/zed-usage-tui.sh        OPT-IN usage meters rendered in a Zed terminal pane (reuses the pollers). No cmux writes.
tests/                      bridge-state + poller-gate + codex-poller + install-hooks + sentinel-setup + group-sync + zed-bridge + open-in-zed + usage-tui. `make test`.
examples/                   usage-sentinels.env + launchd plist templates (com.cmux-claude-usage / com.cmux-codex-usage / com.cmux-group-sync).
```

- **Agent state rides STATIC title markers** the bridge keeps at the FRONT of the title — `⚡` =
  working, `⏳` = compacting, `❓` = waiting-on-you (the session asked a question via
  `AskUserQuestion`/`ExitPlanMode`, or hit a MID-TURN permission `Notification` — it's alive but
  parked, so it shows the orange needs-you treatment, NOT green "Working…"). The idle "waiting for
  input" Notification that fires ~60s after a turn ENDS is gated out (`_notify_waiting` checks for a
  live pid) so a finished workspace never flips to ❓. Precedence: compacting
  > waiting > working > needs-you(unread) > idle. The sidebar
  detects them with `.hasPrefix` and strips them for display. STATIC is mandatory: an animated /
  frame-by-frame marker in the title floods cmux's title coalescer and freezes the sidebar
  (upstream cmux #6291). The bridge ref-counts live sessions per workspace as files under
  `$TMPDIR/cmux-sentinel-work/<ws>/` and reaps dead PIDs (`kill -0`), so multiple agents and crashes
  are handled; a `.marked` flag (30s TTL) keeps the per-tool-call hot path off the ~44ms title read.
  Test the state machine offline with the stubbed-cmux harness (see `.claude/` working docs).

- **Usage meters group by provider:** each provider gets its own labelled panel section
  (`CLAUDE USAGE`, `CODEX USAGE`, …) — same component reused. A meter is just an idle "sentinel"
  workspace whose title a poller keeps updated. **Two providers ship:** Claude
  (`bin/cmux-claude-usage.sh`, OAuth usage endpoint) and Codex (`bin/cmux-codex-usage.sh`). BOTH now
  hit a provider **usage endpoint** with a locally-stored OAuth token: Codex reads ChatGPT's
  `wham/usage` (the same endpoint the Codex CLI's own 60s poller hits — openai/codex#10869), token
  read fresh from `~/.codex/auth.json` (`auth_mode=chatgpt`); `primary_window`=5h /
  `secondary_window`=weekly → labels `cx5h`/`cx7d`. The OLD local-rollout source
  (`~/.codex/sessions/**/rollout-*.jsonl`) is DEAD on codex-cli 0.142.x — `codex exec` (how Claude
  Code drives Codex) doesn't write `rate_limits` (openai/codex#14880) and fresh data moved to
  non-queryable sqlite, so the meter went weeks-stale; the endpoint is account-server-side, so it's
  correct for any usage pattern. `wham/usage` is unofficial → parse defensively; API-key logins
  aren't covered (no panel). Decision/research:
  `.claude/research/2026-07-06-codex-usage-api-source.md`. To add a THIRD provider: create a
  sentinel, add an `isXMeter()` predicate + an `if isXMeter(w)` line to `isUsageMeter()` + an
  `X USAGE` panel section, and copy a poller with a new data source.
- **Provider selection is gated, not configured in the sidebar** (it can't read config — only
  workspace data). A provider's panel shows IFF its sentinels exist, and the sidebar auto-hides any
  provider with a zero `count`. So selection lives in setup: which pollers run + which sentinels
  exist. Each poller **self-gates** — `provider_available()` (creds/CLI detection) + a `PROVIDER_ID`
  checked against `USAGE_PROVIDERS` (env, default `claude`) — and **exits 0 silently** when its
  provider is disabled or not installed (NOT installed ≠ expired token: an expired token still
  carries creds, so it stays the transient `⚠ offline`). This is why a missing/uninstalled provider
  never crashes or spams: keep that pattern when adding one. Gates are covered by
  `tests/poller-gate.sh`; `bin/cmux-sentinel-doctor.sh` reports installed × enabled × sentinel.
  Decision record: `.claude/research/2026-06-19-usage-provider-selection.md`.
- **Auto-refresh** needs `"automation": { "socketControlMode": "automation" }` in `cmux.json`. On the
  current build `reload-config` applies this **live** (proven: an external launchd kick landed its
  renames with no restart) — the earlier "needs a full cmux restart" note was outdated. If external
  (launchd) socket commands start getting rejected, the automation mode regressed → restart cmux.

## Conventions & security

- **Never commit secrets.** The OAuth token is read from the macOS Keychain at runtime — keep it
  that way. No tokens, no real workspace UUIDs, no usernames in committed files. (The sidebar carries
  no ids at all now — it matches sentinels by title label — so there's nothing to placeholder.)
- Dependency-light: bash + `jq` + `curl` + macOS `date`. Terse comments about *why*.
- **Run `make check` before proposing a commit** — shellcheck + the secret guard
  (`scripts/check-secrets.sh`) + markdownlint + sidebar parse. `lefthook install` wires the same
  gates into git hooks; CI runs `make ci`. The secret guard is the load-bearing one (blocks real
  UUIDs / tokens / `/Users/<name>` paths and asserts the sidebar keeps its title-label meter anchors).
- See `CONTRIBUTING.md` for the dev loop and PR norms. (Maintainers may keep gitignored working
  docs under `.claude/` — e.g. `.claude/NOTES.local.md` with the full debugging history and
  `.claude/HANDOFF.md` for resuming a session — never committed.)
