# Agent install guide — cmux-sentinel

This guide is written for an **AI coding agent** (Claude Code, Codex, Amp, Cursor, …) to execute on
the user's behalf. It automates the two steps people fumble by hand: wiring only the requested
agent integrations and creating usage sentinels with titles the pollers can find.

If you are a human, you can follow it too — but the one-line installer in the
[README](../README.md) plus these steps is usually faster.

**Agent contract:** every step is idempotent and backs up what it changes. Do the
file edits yourself — never ask the user to hand-edit JSON. Run shell commands
directly. Stop and ask only if a **Preflight** check fails. At the end, run the
doctor and loop until it is clean.

## Preflight (stop only if a required check fails)

```bash
command -v cmux >/dev/null && cmux ping >/dev/null 2>&1 && echo "cmux OK"   # cmux installed + app running
command -v jq   >/dev/null && command -v curl >/dev/null && echo "jq/curl OK"
{ security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1 \
  || test -f ~/.claude/.credentials.json; } \
  && echo "Claude creds OK" || echo "Claude not logged in (Claude poller will be a clean no-op)"
```

- No `cmux` / `cmux ping` fails → tell the user to install cmux and open the app. Stop.
- No `jq`/`curl` → ask the user to install them (`brew install jq`). Stop.
- No Claude creds → continue. The Claude poller is a no-op; any created sentinels remain in their
  waiting/fallback state until the user logs in and runs an update.

## Step 1 — run the installer (files + bridge + hook wiring)

```bash
curl -fsSL https://raw.githubusercontent.com/jonnyhaynes/cmux-sentinel/main/install.sh | WITH_BRIDGE=1 bash
```

`WITH_BRIDGE=1` installs the hooks bridge **and auto-wires** the events into
`~/.claude/settings.json` (idempotent, backed up). This is the part that makes
`⚡ working` / `⏳ compacting` / `❓ waiting-on-you` rows work — without it every row
shows "idle." After this, tell the user they must **restart Claude Code** for the new
hook events to register (the script body is read live, but new event registrations
are read at startup).

Choose integrations explicitly; do not infer one from another:

| Integration | Flag | Installed behavior |
| --- | --- | --- |
| Claude states | `--with-bridge` / `WITH_BRIDGE=1` | Claude hook bridge + event registration |
| Amp states | `--with-amp` / `WITH_AMP=1` | Amp plugin + neutral bridge dependency; no Claude hooks |
| Zed | `--with-zed` / `WITH_ZED=1` | Zed helpers + Zed hook registration |
| Loaded plist refresh | `--reload-agents` / `RELOAD_AGENTS=1` | Reload only changed, already-loaded launchd jobs |

When Amp is requested, also run `cmux hooks amp install` for cmux's separate native-sidebar plugin.
Do not edit its `cmux-session.ts`; cmux maintains that file.

If the installer reports it could not edit `settings.json` automatically (no jq, or
the file was not valid JSON), wire it yourself — see [Appendix: hooks block](#appendix--hooks-block).

On an update, read the launchd messages too. launchd does not reread a changed loaded plist. A
normal install prints exact non-disruptive `bootout` + `bootstrap` commands; re-running with
`--reload-agents` performs only the necessary changed+loaded reloads. It never cycles unchanged jobs.

## Step 2 — create the usage sentinels

Set `USAGE_PROVIDERS` in `~/.config/cmux/usage-sentinels.env` first (default `claude`; valid names
are `claude`, `codex`, and `amp`), then run the idempotent setup:

```bash
~/bin/cmux-sentinel-setup.sh
```

The setup scans all cmux windows, skips Codex windows the account positively does not have, and
never creates Amp's optional orb sentinel unless `AMP_ORB_METER=1`. An offline/unknown provider
fails open only for its normal meters. Then inspect and paint every enabled provider (skip commands
for providers not in `USAGE_PROVIDERS`):

```bash
~/bin/cmux-claude-usage.sh --print     # parsed values, no cmux writes
~/bin/cmux-claude-usage.sh --update    # title fallback + native progress
~/bin/cmux-codex-usage.sh --print      # if codex is enabled
~/bin/cmux-codex-usage.sh --update
~/bin/cmux-amp-usage.sh --print        # if amp is enabled; --raw contains email
~/bin/cmux-amp-usage.sh --update
```

## Step 3 — enable auto-refresh (external socket access)

The launchd poller renames sentinels from outside the app, which needs automation
mode. Add it to `~/.config/cmux/cmux.json` (create the file if absent) and reload:

```jsonc
{
  "automation": { "socketControlMode": "automation" }
}
```

```bash
cmux reload-config    # applies live on current builds; if renames get rejected later, restart cmux
```

If `cmux.json` already exists, merge the `automation` key in rather than overwriting
the file. It is JSONC (comments allowed), so edit it as text, not with jq.

## Step 4 — start enabled pollers (launchd)

```bash
# Run the matching line for each enabled provider unless that job is already loaded.
# If an update changed a loaded plist, use the installer's printed reload commands
# (or re-run install.sh --reload-agents); simply leaving it loaded keeps the old definition.
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-codex-usage.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-amp-usage.plist
```

## Step 5 — load and select the sidebar

```bash
cmux sidebar validate workspaces && cmux sidebar reload && cmux sidebar select workspaces
```

`select` activates the custom sidebar without requiring a manual context-menu step.

## Step 6 — verify (loop until clean)

```bash
~/bin/cmux-sentinel-doctor.sh
```

Fix any non-green check and re-run until it reports `Everything wired.` or only the
expected warnings (e.g. "claude enabled but not installed here" if the user has not
logged in). Common fixes:

- **bridge NOT registered** → re-run Step 1 with `WITH_BRIDGE=1`, then have the user
  restart Claude Code.
- **missing expected sentinel** → redo Step 2; a positively absent Codex window is intentionally
  skipped, while an unknown/offline capability retains the current layout.
- **socketControlMode** warning → redo Step 3.
- **data freshness unknown/stale** → run the provider's printed `~/bin/cmux-*-usage.sh --update`
  command. A successful update creates/refreshes its local state stamp; if it fails, fix the
  accompanying provider/socket diagnostic rather than suppressing the warning.

Report the final doctor output to the user.

## Appendix — hooks block

If the installer could not wire the hooks automatically, merge this into
`~/.claude/settings.json` under `"hooks"` (add each event that is not already there;
do not remove the user's existing hooks). All entries are fire-and-forget
(`async: true`). Then have the user **restart Claude Code**.

```json
{
  "hooks": {
    "SessionStart":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "UserPromptSubmit":   [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PreToolUse":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PreCompact":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PostCompact":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "Stop":               [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "StopFailure":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "Notification":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "SessionEnd":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }]
  }
}
```

`Notification` is what flips a session to **❓ waiting-on-you** when it hits a
permission prompt; `UserPromptSubmit`/`PreToolUse` drive **⚡ working**;
`PreCompact`/`PostCompact` drive **⏳ compacting**; `Stop`/`SessionEnd` clear the
marker. The rest are crash/cleanup self-heal.
