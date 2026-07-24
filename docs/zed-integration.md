# Zed integration — OFF by default, opt-in per user

This repo's Zed pieces (cmux→Zed handoff, agent-state bridge, usage TUI) are **disabled by default**
so anyone who clones cmux-sentinel and runs `install.sh` gets **zero** Zed behavior. Enable them for
**yourself only** — none of it is enabled by `install.sh`'s default path or wired into the shared
`sidebars/workspaces.swift`, and you should keep it that way (don't make it the default for other
users of the repo).

## What's opt-in

| Piece | How it activates | Off-by-default guarantee |
| --- | --- | --- |
| `hooks/zed-bridge.sh` | Runs only if YOU register it as a Claude Code hook | Also gated on `ZED_SENTINEL=1` — silent no-op unless set, even if hooked |
| `bin/cmux-open-in-zed.sh` (`ze`) | Runs only when you invoke it (alias/keybind) | Invoke-only; never fires on its own |
| `bin/zed-usage-tui.sh` | Runs only when you launch it in a terminal pane | Invoke-only |

A **default** `install.sh` (bare, or the curl one-liner) installs no agent-state bridge or hook — it
never installs or registers the Zed bridge. Claude state uses the separate `--with-bridge` opt-in.
The Zed pieces are installed **only** when you opt in with `--with-zed` / `WITH_ZED=1` (below), and
even then stay inert until `ZED_SENTINEL=1`.

## Easy path — `install.sh --with-zed`

One command installs all three Zed helpers and wires `hooks/zed-bridge.sh` into your
`~/.claude/settings.json` (its 8 events), then prints the exact `~/.zshrc` lines to finish:

```sh
./install.sh --with-zed          # or: WITH_ZED=1 ./install.sh
```

`WITH_ZED=1` (env form) is honored too, so it also works through the curl bootstrap
(`curl … | WITH_ZED=1 bash`), which forwards env but not argv. This installs files and registers
hooks; **nothing activates** until you set the master switch and restart Claude Code:

```sh
# add to ~/.zshrc, then RESTART Claude Code and open a new shell
export ZED_SENTINEL=1
eval "$(~/bin/cmux-open-in-zed.sh --shell-init)"
```

A re-run of a plain `install.sh` (no flag) still refreshes an already-installed Zed bridge — same
"update on re-run" behavior as the cmux bridge — but never installs it fresh without the flag.

## Manual path — enable it piece by piece

1. **Master switch** — in your `~/.zshrc` (so Claude Code, launched from your shell, inherits it):

   ```sh
   export ZED_SENTINEL=1
   ```

   Without this, `zed-bridge.sh` exits immediately as a no-op.

2. **cmux→Zed handoff** — add the `ze` alias + a `Ctrl-O` keybind that opens Zed on the current
   worktree straight from the shell prompt:

   ```sh
   eval "$(/path/to/cmux-sentinel/bin/cmux-open-in-zed.sh --shell-init)"
   ```

   (Change the key with `--key '^E'`. The keybind fires only at the shell prompt — never mid-agent.)

3. **Agent-state markers in Zed** (optional) — register `hooks/zed-bridge.sh` for the Claude Code
   events in your **personal** `~/.claude/settings.json` (SessionStart, UserPromptSubmit, PreToolUse,
   PreCompact, PostCompact, Notification, Stop, SessionEnd). With `ZED_SENTINEL=1` it writes
   ⚡/⏳/❓ to OSC-2 terminal metadata and a per-session JSON status file
   (`ZED_SENTINEL_STATE_DIR`). Stock Zed records OSC-2 as `breadcrumb_text` but keeps its native tab
   label process-derived, so the JSON is the durable input for a future panel/status consumer.

4. **Usage meters while in Zed** (optional) — run `bin/zed-usage-tui.sh` in a dedicated Zed terminal
   pane. It renders each enabled Claude, Codex, or Amp provider whose local credential source is
   present; every poller keeps its normal `USAGE_PROVIDERS` gate, so disabled providers stay absent
   and transient failures show `⚠ offline`.

## Disable

Unset `ZED_SENTINEL` (or set it to `0`), remove the `eval` line and the `~/.claude` hook entries.
Nothing in the committed repo changes.

## Do NOT make it default for the repo

Keep the Zed pieces out of `install.sh`'s **default** path and out of the shared sidebar. The
one-command enable exists (`install.sh --with-zed` / `WITH_ZED=1`) but is gated behind that explicit
flag and stays inert until `ZED_SENTINEL=1` — a bare `install.sh` and the curl one-liner remain
Zed-free, so other users of the repo are unaffected. Don't flip that default. See
`docs/zed-fork-research.md` for the full background.
