#!/bin/bash
# cmux-bridge-commandcode.sh — adapt Command Code's hooks to the shared cmux bridge.
#
# Command Code fires only FOUR lifecycle events (SessionStart, PreToolUse,
# PostToolUse, Stop) and names its event on stdin as `hook_event_name`. The shared
# bridge (cmux-bridge.sh) is agent-agnostic: it keys agent identity off three env
# vars and derives the event from arg $1 or the stdin field. So this wrapper
#   1. sets Command Code's identity (label / log source / session pid),
#   2. forwards the event name + the original stdin to the shared bridge, and
#   3. adds the two things Command Code's event set CANNOT express.
#
# WHAT LIGHTS UP WITHOUT (3): ⚡ working (PreToolUse/PostToolUse) and idle (Stop).
# Command Code has no compact or permission-prompt events, so ⏳ compacting and
# ❓ waiting-when-blocked never fire from the event stream alone — that is a
# Command Code limitation, not a bridge one (its own hook docs list the same four
# events: dist/bundled/command-code-knowledge/reference/hooks.md).
#
# (3a) THE PANE WATCHER — where ❓ comes from. Command Code renders every
# blocking decision as TEXT ON THE VISIBLE PANE and emits no event for any of
# them: the shell-command permission, the plan/act mode prompts, and the plan
# review card. So a detached watcher samples the LIVE VIEWPORT and reports the
# `Blocked` event to the shared bridge. Two properties make this sound:
#
#   * The viewport is AUTHORITATIVE. We are looking at the prompt the user is
#     looking at, right now — so unlike a Notification-derived guess there is
#     nothing to gate against, and it works even before a turn exists (the
#     plan-mode prompt appears at launch, before the first pid file is written).
#   * We NEVER read scrollback. A resolved prompt stays in history forever; a
#     scrollback read would re-report it and strand the row at ❓ for the rest of
#     the session. `surface.read_text` returns the visible screen and drops what
#     has scrolled off, which is exactly the contract this needs. (Verified: a
#     second sample after scrolling no longer contains the first sample's lines.)
#
# The watcher is polled, detached and self-healing rather than hook-driven,
# because Command Code has no "prompt appeared" event to hang it on. It exits
# when the session pid dies, so it cannot outlive its terminal, and `ensure`
# re-asserts it on every hook event so a crashed/killed watcher comes back on the
# next tool call instead of going quietly dead. All failure modes here are
# SILENT (no watcher = no ❓ and no error), which is why the debug gate exists.
#
# (3b) SESSION RESTORE. Command Code's SessionStart carries both `session_id` and
# `transcript_path`, and `cmd --session <path|id>` resumes either — the same
# thing the herdr integration reports for its own session restore. Publishing it
# to cmux as a surface resume binding gets the terminal a real restart command
# (manual Restore + the Resume button). NOTE: this is deliberately the PUBLIC
# binding path, which cmux stores for inspection/manual restore. Auto-restore on
# relaunch needs a user-approved command prefix in Settings > Terminal > Resume
# Commands — a process cannot make its own command sticky, and claiming the
# `agent-hook` source to force it would be a lie about who is publishing.
#
# CMUX_WORKSPACE_ID / CMUX_SURFACE_ID are exported by cmux into the terminal, so
# they reach Command Code and this hook for free — the one hard requirement, and
# cmux provides it.
#
# Tunables:
#   CMUX_SENTINEL_CC_POLL_INTERVAL      watcher sample period, seconds (default 2)
#   CMUX_SENTINEL_CC_MAX_READ_FAILURES  consecutive socket failures before giving up (default 5)
#   CMUX_SENTINEL_CC_MAX_SCANS          stop after N samples (default: until the session exits)
#   CMUX_SENTINEL_CC_RESUME=0           don't publish the resume binding
#   CMUX_SENTINEL_CC_DEBUG=1            append watcher transitions to a debug log

BRIDGE="$HOME/.claude/hooks/cmux-bridge.sh"
[ -x "$BRIDGE" ] || exit 0

# cmux prints a one-time deprecation notice for legacy verbs on STDERR. Anything
# that parses cmux output as JSON must keep the streams apart or the notice lands
# in front of the JSON and reads as the failure — it buried a real "Command timed
# out" once (see cmux-sentinel-doctor.sh). cmux documents this switch for it.
export CMUX_QUIET=1

# Read Command Code's JSON payload once; the shared bridge re-reads it from stdin.
input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
[ -n "$event" ] || event="${COMMANDCODE_HOOK_EVENT:-}"
[ -n "$event" ] || exit 0

# Command Code identity for the shared bridge. Its own $PPID is the session process
# (one CLI process per session), which is the correct liveness/reap key — and the
# same pid the shared bridge uses to decide whether this session is still alive.
# LOG_SOURCE is distinct from Claude Code's default ("cc") so co-tenant sessions
# in one workspace keep separate log streams and error-status keys. The ⚡ working
# marker is shared/ref-counted across both agents by design — that's WORKROOT, not
# this tag.
export CMUX_SENTINEL_AGENT_LABEL="Command Code"
export CMUX_SENTINEL_LOG_SOURCE="cmdc"
export CMUX_SENTINEL_SESSION_PID="${COMMANDCODE_SESSION_PID:-$PPID}"

WS="${CMUX_WORKSPACE_ID:-}"
SURFACE="${CMUX_SURFACE_ID:-}"
SESS="$CMUX_SENTINEL_SESSION_PID"

# Resolved ONCE, as plain variables, on purpose: `ensure_watcher` runs on every
# PreToolUse (Command Code fires thousands), so its already-running path must fork
# NOTHING. Command substitution would fork a subshell per call and quietly undo
# the bridge's own effort to keep that path cheap.
WATCHROOT="${TMPDIR:-/tmp}/cmux-sentinel-cc-watch"
LOCKDIR="$WATCHROOT/$SESS.lock"

dbg() { # $1 = message — debug is OFF unless asked for; silently a no-op otherwise
  [ "${CMUX_SENTINEL_CC_DEBUG:-0}" = 1 ] || return 0
  printf '%s cc-watch[%s] %s\n' "$(date '+%H:%M:%S')" "$SESS" "$1" >> "$WATCHROOT/debug.log" 2>/dev/null
  return 0
}

# ── the pane watcher ─────────────────────────────────────────────────────────

# Command Code's blocking prompts, verbatim from its own TUI. These are its
# strings, not ours, so they are the contract to watch — a reworded prompt is a
# silent ❓ regression, which is why they are stated once, here, as literals.
#
# Shell-command permission is TWO lines and both are required, so a stray match
# on either alone can't fire it.
BLOCKING_SHELL_PERMISSION='Execute Shell Command
Command Code needs to execute'
BLOCKING_PLAN_MODE='Enter plan mode for read-only exploration and planning?'
# Prefix match on purpose: the act-mode prompt's tail is not stable across
# versions, the stem is.
BLOCKING_ACT_MODE='Enter act mode for'
# The plan review card needs BOTH of these in ONE sample (see is_blocked).
BLOCKING_REVIEW_HEADING='REVIEW'
BLOCKING_REVIEW_APPROVAL='Approve ctrl+a'

# Sample the LIVE VIEWPORT of our own surface. Prints the text and returns 0, or
# prints nothing and returns 1 — the distinction matters: a failed read must NOT
# be mistaken for "no prompt on screen" (that would clear ❓ on a socket hiccup).
read_pane() {
  local raw params
  if [ -n "$SURFACE" ]; then
    params=$(jq -nc --arg s "$SURFACE" '{surface_id:$s}' 2>/dev/null)
  else
    params='{}'
  fi
  raw=$(cmux rpc surface.read_text "$params" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -e '.text | type == "string"' >/dev/null 2>&1 || return 1
  printf '%s' "$raw" | jq -r '.text'
}

is_blocked() { # $1 = pane text
  case "$1" in
    *"$BLOCKING_SHELL_PERMISSION"*) return 0 ;;
    *"$BLOCKING_PLAN_MODE"*) return 0 ;;
    *"$BLOCKING_ACT_MODE"*) return 0 ;;
  esac
  # The review card must be matched as a WHOLE: "Approve ctrl+a" alone is a
  # control that also appears in unrelated cards, and "REVIEW" alone appears in
  # ordinary output. Both, in one sample, is the card.
  case "$1" in
    *"$BLOCKING_REVIEW_HEADING"*"$BLOCKING_REVIEW_APPROVAL"*) return 0 ;;
  esac
  return 1
}

report_blocked() {
  # Only meaningful on a bridge that advertises the event; an older bridge
  # ignores it silently, which would look exactly like a working watcher.
  printf '%s' "$CAPS" | grep -q 'blocked' || return 0
  printf '{}' | "$BRIDGE" Blocked
}

watch_blocking_prompt() {
  local text seen=0 fails=0 scans=0
  local max_scans="${CMUX_SENTINEL_CC_MAX_SCANS:-}"
  local interval="${CMUX_SENTINEL_CC_POLL_INTERVAL:-2}"
  local max_fails="${CMUX_SENTINEL_CC_MAX_READ_FAILURES:-5}"

  # Capability probe once per watcher (it is long-lived, so this is not a hot
  # path) — the shared bridge's --capabilities runs before its cmux gates.
  CAPS="$("$BRIDGE" --capabilities 2>/dev/null)"
  dbg "watcher up caps=[$CAPS]"

  while :; do
    # The session is the only reason we exist. When `cmd` exits, so do we — this
    # is also what stops the poll loop from leaking past its terminal.
    kill -0 "$SESS" 2>/dev/null || { dbg "session pid gone, exiting"; break; }

    if text=$(read_pane); then
      fails=0
      if is_blocked "$text"; then
        # Re-report on EVERY scan — deliberately NO "already reported" latch.
        # A latch (what the herdr integration uses, where nothing else can lower
        # the state) loses a race it cannot win here: ANY event can drop ❓ back to
        # ⚡ while the prompt is still on screen — PostToolUse for the tool that was
        # approved, another PreToolUse — and a latched watcher would never put it
        # back, leaving a genuinely blocked session displayed as working until the
        # user acted on a row that looked fine. Re-asserting is cheap, because
        # _set_waiting reads the title and returns immediately when it already
        # carries ❓: a sustained prompt costs one metadata read per poll interval
        # and produces NO title churn. The bridge stays the single writer, so a
        # repeat can never double-apply.
        report_blocked
        if [ "$seen" = 0 ]; then seen=1; dbg "blocked reported"; fi
      else
        if [ "$seen" = 1 ]; then dbg "prompt gone"; fi
        seen=0
      fi
    else
      # Transient socket failure. Keep the last known state (do NOT treat it as
      # "no prompt") and give up only after a run of them.
      fails=$((fails + 1))
      [ "$fails" -lt "$max_fails" ] || { dbg "reads failing, exiting"; break; }
    fi

    scans=$((scans + 1))
    [ -z "$max_scans" ] || [ "$scans" -lt "$max_scans" ] || { dbg "scan cap hit"; break; }
    sleep "$interval"
  done
}

watcher_running() {
  local pid=""
  [ -d "$LOCKDIR" ] || return 1
  # NOT `IFS= read -r pid < file || return 1`: read returns NON-ZERO when it hits
  # EOF without a trailing newline, even though it filled the variable — so that
  # idiom reports "not running" for a perfectly good pid file and re-spawns a
  # watcher on every single hook event. (Cost a real duplicate-watcher bug.) Tolerate
  # the status and validate the VALUE instead.
  IFS= read -r pid < "$LOCKDIR/pid" 2>/dev/null || true
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# Start the watcher if it isn't already up. Called on every hook event, so the
# common path is two builtins (`[ -d ]` + `kill -0`) and no subprocess: the state
# this defends against is a watcher killed by a crash or a logout, which would
# otherwise leave Command Code permanently without ❓ and say nothing about it.
ensure_watcher() {
  [ -n "$WS" ] && [ -n "$SURFACE" ] || return 0   # not in a cmux terminal → nothing to watch
  [ -n "$SESS" ] || return 0
  watcher_running && return 0

  mkdir -p "$WATCHROOT" 2>/dev/null
  # A lock whose pid is dead (or unreadable) is stale — clear it and re-mint.
  rm -rf "$LOCKDIR" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || return 0        # lost the race to another hook: fine, it started one
  (
    # TWO traps, and they must stay two. `trap 'rm -rf "$LOCKDIR"' EXIT HUP INT TERM`
    # is the tempting one-liner and it is a trap in both senses: a handler bound to
    # TERM that does not EXIT merely runs and returns, so the watcher becomes
    # IMMUNE to being stopped and loops on — leaving orphans that can only be
    # SIGKILLed and that keep polling the socket forever. Bind the cleanup to EXIT
    # alone (which also covers the signal cases below), and make the signals exit
    # so they reach it.
    trap 'rm -rf "$LOCKDIR"' EXIT
    trap 'exit 0' HUP INT TERM
    watch_blocking_prompt
  ) </dev/null >/dev/null 2>&1 &
  # $! is the subshell's pid. Write it from HERE, not from inside: bash does not
  # update $$ in a subshell (and $BASHPID is absent on macOS's 3.2), so the parent
  # is the only portable place that knows the child's real pid. The trailing
  # newline is load-bearing — see watcher_running.
  printf '%s\n' "$!" > "$LOCKDIR/pid"
  dbg "watcher started pid=$!"
  return 0
}

# ── session restore ──────────────────────────────────────────────────────────

# Publish a restart binding for this terminal: `cmd --session <id>` resumes the
# exact conversation the hook reported. Verified end to end — the payload's
# session_id is the transcript's basename under
# ~/.commandcode/projects/<cwd-slug>/<session_id>.jsonl, which is what
# --session resolves. --kind is our own label so this never collides with a
# cmux-managed agent binding on the same surface.
publish_resume() {
  [ "${CMUX_SENTINEL_CC_RESUME:-1}" = 1 ] || return 0
  [ -n "$SURFACE" ] || return 0
  local session cwd
  local -a cwd_arg=()
  session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$session" ] || return 0
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  # Array, not ${cwd:+--cwd "$cwd"}: the latter is an unquoted expansion that
  # word-splits a cwd containing spaces.
  [ -n "$cwd" ] && cwd_arg=(--cwd "$cwd")
  cmux surface resume set \
    --kind commandcode \
    --checkpoint "$session" \
    --name "Command Code" \
    "${cwd_arg[@]}" \
    -- cmd --session "$session" >/dev/null 2>&1
  dbg "resume binding published for $session"
  return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────

case "$event" in
  SessionStart)
    # A fresh pid reuses no state: drop any watcher lock left by a dead session
    # whose pid we inherited, then re-assert ours.
    ensure_watcher
    publish_resume
    ;;
  PreToolUse)
    # Self-heal point: tools fire constantly, so a dead watcher is back within
    # one tool call. Cheap when it is already running.
    ensure_watcher
    ;;
esac

# Forward LAST so the state transition is never delayed by our side effects, and
# so a hiccup in the cmux RPC above can't suppress the marker update. Command
# Code's `tool_name` values are its canonical ids (shell_command, read_file,
# write_file, edit_file); the shared bridge only promotes a tool to ❓ for the
# tools that INTRINSICALLY block, and none of Command Code's do — its prompts are
# all pane-visible, which is the watcher's job. So PreToolUse here is always ⚡.
printf '%s' "$input" | "$BRIDGE" "$event"
exit 0
