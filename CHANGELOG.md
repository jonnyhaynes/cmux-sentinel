# Changelog

Re-run the installer to update; it re-deploys every file, re-runs setup so a release that adds a
meter gets its workspace, re-parks the sentinels out of ⌘1…⌘9, repaints and reloads the sidebar.

```bash
curl -fsSL https://raw.githubusercontent.com/jonnyhaynes/cmux-sentinel/main/install.sh | bash
```

`~/bin/cmux-sentinel-doctor.sh` reports the version you actually have.

## Unreleased

### Added

- **Working rows for every agent cmux knows, no bridge required (cmux ≥ 0.64.23).** cmux now hands
  custom sidebars its own per-agent state, so Codex, opencode, Amp and Claude sessions show
  `Working…` even without `--with-bridge` — and `Working… ×2` when two agents work in one
  workspace. The bridge still adds `⏳ compacting` and Claude's `❓`. cmux's own "needs input" is
  ignored for Claude: cmux raises it about a minute after every finished Claude turn, which would
  turn every resting workspace orange.
- **Group headers show the group's name (cmux ≥ 0.64.23)** with a stack icon, read straight from
  cmux — no `GROUP_NAME_SYNC` needed.
- **The doctor spots a `workspaces.js` that hides this sidebar.** cmux 0.64.23 added JavaScript
  sidebars and loads `.js` ahead of `.swift` for the same name — and cmux's own example file is
  called `workspaces.js`. The doctor also prints the cmux version, says when the deployed sidebar
  predates native agent/group data, and stops warning about a missing bridge or group sync when
  cmux already covers it.
- **Command Code sessions now show `❓ waiting-on-you` (`--with-commandcode`).** Command Code fires
  only four hook events and none of them reports a permission prompt — its shell-command permission,
  plan/act mode prompts and plan review card are drawn as text on the visible pane and emit no event
  at all. So the adapter runs a detached watcher that samples the **live viewport** and reports a new
  `blocked` event to the shared bridge. The viewport is authoritative (it is the prompt you are
  looking at, and it works before a turn exists, which the launch-time plan prompt needs) and
  scrollback is never read — a resolved prompt stays in history forever and would pin the row at `❓`
  for the rest of the session. The bridge keeps the state; the adapter only ever raises it.
- **Command Code session restore.** The adapter publishes a `cmd --session <id>` binding from the
  hook payload's `session_id`, so a restored terminal has a restart command cmux can offer. It uses
  cmux's public binding path (stored for manual restore), not a forged `agent-hook` binding —
  auto-restore stays a user approval in Settings, and `cmux surface resume show` confirms it.
- **The doctor checks the Command Code adapter**: installed and matching this repo, whether the
  shared bridge is new enough to accept its event (an older bridge ignores an unknown event *and*
  exits 0, so this one mismatch fails in complete silence), whether all four hook events are
  registered, and whether any pane watcher has been left behind by a dead session.

### Fixed

- **`cmux-sentinel update` fetched upstream's installer instead of this fork's.** The dispatcher
  still pointed at the upstream repo while `install.sh` cloned the fork, so updating a fork install
  would have replaced it with upstream's files — dropping every integration that lives only here —
  and the doctor's version probe compared against upstream's `VERSION`, so it could nag about a
  release you cannot install while staying quiet about the one you can. The install URL is now the
  fork everywhere (dispatcher, `install.sh`, the doctor's probe and its advice, and the CHANGELOG
  one-liner; the README already pointed here). The Homebrew formula and `docs/release.md` still
  reference the upstream tap — that needs a tap of its own, which is a separate decision.
- **The shared bridge ignored `PostToolUse` — it had no handler for it at all.** Claude Code never
  needed one (its `UserPromptSubmit` and the next `PreToolUse` both re-assert `⚡`), but Command Code
  has no `UserPromptSubmit`, which makes `PostToolUse` the only signal that a permission prompt was
  answered and the tool actually ran. Without it a watcher-raised `❓` had nothing to clear its
  `.waiting.<pid>` flag until the next tool call or the end of the turn. It now maps to `⚡`, which
  also means the event is correct for any future adapter that emits it.
- **Amp meters went `⚠ no data` after Amp reworded `amp usage`** (`agent usage $5.27 of $20
  remaining (26%)`, where it used to print `74% other usage … remaining`). Both wordings parse; a
  percentage that isn't explicitly *remaining* is still refused rather than guessed.
- **`⌘N` hints next to group rows were off.** Since cmux 0.64.22 a group's header row and the
  members of a collapsed group take no digit, which shifts every row below them; the sidebar now
  numbers rows the same way cmux does.
- **The doctor no longer asks you to re-park meters when that can't help.** With fewer than nine
  real workspaces some meter has to take a ⌘ key however the rows are ordered; that is now reported
  as a note instead of a warning that re-running setup could never clear.

## 0.2.2 — 2026-08-31

### Fixed

- **One rate-limited request no longer blanks the Claude meters.** Every row went to
  `⚠ rate limit` — losing the number *and* the bar — while Claude Code's own `/usage` still showed
  real values. For 30 minutes after a failed fetch each row now keeps its last good value and shows
  the data's age in place of the reset countdown (`4% · 12m old`), so a stale number can't pass for
  a live one; past that it falls back to the `⚠` marker as before. The poller still exits non-zero
  and records no freshness throughout, so `cmux-sentinel doctor` keeps telling the truth.
  `CMUX_SENTINEL_STALE_GRACE=0` restores the old behaviour.
- **A 429 now backs off instead of asking again on the same cadence that caused it.** 10, then 20,
  then 40 minutes, cleared by the first success (`CMUX_SENTINEL_BACKOFF_BASE`/`_MAX`). Expired
  tokens and network errors are deliberately *not* backed off — they cost the endpoint nothing to
  retry and recover the moment you fix them.
- **The response cache read cold on Linux,** so CI failed one assertion for ten commits. The mtime
  probe tried BSD `stat -f` before GNU `stat -c`, and on Linux `-f` means `--file-system`. macOS was
  never affected.

## 0.2.1 — 2026-08-25

### Added

- **Homebrew tap.** `brew install oliver-kriska/tap/cmux-sentinel`, then `cmux-sentinel deploy`.
  The second step is not optional and is needed after every `brew upgrade`: Homebrew owns the files
  under its own prefix, while the sidebar, the pollers and four launchd agents live in `$HOME`.

### Fixed

- **`cmux-sentinel version` no longer reports a sha from an unrelated repository.** The installer
  asked git for the commit of the tree it was installing from, and `git -C` walks up — so a
  Homebrew install (unpacked under `/opt/homebrew`, itself a git repo) recorded *Homebrew's* HEAD.
  It now records `commit=unknown` rather than a confident wrong answer.
- **`version` on a Homebrew install shows what is deployed AND what brew has,** and says so when
  they differ. Reporting one number is how "I upgraded" and "it's still broken" stay true at once.

## 0.2.0 — 2026-08-25

### Added

- **Per-model weekly meter (`m7d`, opt-in).** Anthropic publishes a model-scoped weekly cap
  ("Fable" today) next to the account-wide windows. Enable with `CLAUDE_MODEL_METER=1` and re-run
  setup. The model's name comes from the payload and is drawn as the row's label, so it follows
  Anthropic if they re-scope the cap. `cmux-claude-usage.sh --print` shows the row whether or not
  it is metered.
- **Extra-usage spend meter (`spend`).** Meters money against your overage budget. The row is
  hidden while the balance is zero and appears by itself on the first charge, so it costs nothing
  to carry and needs no opt-in switch. Skipped entirely if your account has no such budget.
- **One command: `cmux-sentinel`.** A single entry point at `~/bin/cmux-sentinel` —
  `setup`, `doctor`, `version`, `usage`, `paint`, `update`, `group-sync`, `zed` — instead of nine
  script names. It dispatches to the existing `cmux-*.sh` scripts, which stay exactly where they
  are and keep working when called directly (the LaunchAgents reference them by absolute path).
- **`cmux-sentinel deploy` and Homebrew packaging.** `deploy` re-runs the installer from whatever
  tree the command was installed from, which is what makes a `brew`-managed copy possible: the
  formula owns the files under its prefix, and `deploy` puts them where launchd and cmux expect
  them. `update` now refuses on a Homebrew-managed copy and points at `brew upgrade` instead.
  Publishing the tap is documented in `docs/release.md`.
- **`cmux-sentinel version` and a version stamp.** The installer records the version, install date
  and commit under `~/.config/cmux-sentinel/VERSION`; the doctor header prints it and tells you
  when a newer release is published (`CMUX_SENTINEL_UPDATE_CHECK=0` turns the check off).
- **Alert when an agent needs you.** Set `CMUX_SENTINEL_NOTIFY_CMD` to run a command on the ❓
  transition — the one state worth interrupting you for. Nothing else is notifiable by design.

### Fixed

- **A closed sentinel no longer freezes the other meters.** The pollers used to write sentinels in
  sequence and abort on the first failure, so one closed workspace could leave every meter after it
  stale for days. They now paint every sentinel they can resolve and report the rest at the end.
- **Usage-fetch failures say what to do.** 401/403 shows `⚠ auth`, 429 shows `⚠ rate limit`, 5xx
  shows `⚠ api down`, and the launchd log gets the matching recovery. The doctor surfaces the
  newest error under a stale provider.
- **The tool no longer rate-limits itself.** `--print` followed by `--update` was two API calls
  seconds apart on top of the 5-minute poll — the burst that triggered 429s. Successful responses
  are cached for 60s (`CMUX_SENTINEL_USAGE_CACHE_TTL`); failures are never cached.
- **Installing now finishes the job.** The installer runs setup, paints the meters and reloads the
  sidebar instead of printing six manual steps. An update that adds a meter now shows it. Pass
  `--no-setup` for files only.
- **An opt-in meter you could be using announces itself.** Setup and the doctor name the switch
  when your account has a per-model cap, instead of skipping in silence.
- **Stale work markers are reaped.** A `⚡` whose session ended without a `Stop` used to persist
  indefinitely; markers now expire after `CMUX_SENTINEL_WORK_TTL` (default 1h).
- Installer backups are content-aware and bounded instead of one dead file per run.

## 0.1.0 — 2026-08-24

First tagged release: the sidebar, the Claude/Codex/Amp usage meters, the agent-state bridge, the
setup and doctor scripts, and the opt-in Zed integration.
