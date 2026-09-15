#!/bin/bash
# commandcode-bridge.sh — offline test for the Command Code integration
# (hooks/cmux-bridge-commandcode.sh + the `Blocked` event it drives in
# hooks/cmux-bridge.sh).
#
# WHY the odd shape: Command Code's whole hook surface is four events and NONE of
# them reports a permission prompt, so ❓ "blocked on you" is supplied by a
# detached watcher that samples the LIVE VIEWPORT. That makes the interesting
# failure modes ones a single hook invocation cannot show:
#
#   * does the watcher outlive the hook that started it?      (else ❓ never fires)
#   * does it start ONE per session, or one per hook event?   (else thousands)
#   * does it re-arm after a prompt, or latch forever?        (else one ❓ per session)
#   * is a socket failure "no prompt" or "don't know"?        (else ❓ flickers off)
#
# So this harness runs the REAL adapter and the REAL bridge against a stubbed
# cmux whose `surface.read_text` serves a pane file the test controls, and asserts
# the resulting workspace TITLE plus what the watcher did. The blocking strings
# are Command Code's own, so the matrix below IS the contract: a reworded prompt
# fails here rather than silently costing the ❓ row.
#
# No real cmux or Command Code needed, so this runs in CI on Linux too.
#
# Run:  make test   (or:  bash tests/commandcode-bridge.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-$HERE/../hooks/cmux-bridge.sh}"
ADAPTER="${ADAPTER:-$HERE/../hooks/cmux-bridge-commandcode.sh}"
[ -f "$BRIDGE" ]  || { echo "bridge not found: $BRIDGE" >&2; exit 2; }
[ -f "$ADAPTER" ] || { echo "adapter not found: $ADAPTER" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cc-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.claude/hooks" "$ROOT/home-old/.claude/hooks"

# The adapter resolves the shared bridge from $HOME, so deploy the real one into a
# throwaway HOME (and a second HOME whose bridge claims an OLDER protocol, for the
# capability-gating case).
install -m 0755 "$BRIDGE" "$ROOT/home/.claude/hooks/cmux-bridge.sh"
sed 's/protocol=3 stop-failure-final blocked/protocol=2 stop-failure-final/' \
  "$BRIDGE" > "$ROOT/home-old/.claude/hooks/cmux-bridge.sh"
chmod +x "$ROOT/home-old/.claude/hooks/cmux-bridge.sh"

# UUID-shaped ids, BUILT AT RUNTIME so no literal id sits in the source for the
# secret guard to flag (same idiom as tests/bridge-state.sh and tests/amp-bridge.sh).
WS="$(printf '%08d-%04d-%04d-%04d-%012d' 0 0 0 0 2)"
SURF="$(printf '%08d-%04d-%04d-%04d-%012d' 0 0 0 0 3)"
SESSION="$(printf '%08d-%04d-%04d-%04d-%012d' 0 0 0 0 4)"

printf 'workspace' > "$ROOT/title"
: > "$ROOT/pane"

# Fake cmux. read_text serves the pane file as .text — or FAILS when pane.fail
# exists, which is how the "a socket error is not 'no prompt'" case is driven.
cat > "$ROOT/bin/cmux" <<FAKE
#!/bin/bash
ROOT="$ROOT"
WS="$WS"
FAKE
cat >> "$ROOT/bin/cmux" <<'FAKE'
case "$1" in
  ping) exit 0 ;;
  list-workspaces) printf '%s  %s\n' "$WS" "$(cat "$ROOT/title")"; exit 0 ;;
  rename-workspace)
    shift
    while [ $# -gt 1 ]; do shift; done
    printf '%s\n' "$1" >> "$ROOT/renames"
    printf '%s' "$1" > "$ROOT/title"; exit 0 ;;
  rpc)
    if [ "${2:-}" = "surface.read_text" ]; then
      [ -f "$ROOT/pane.fail" ] && { echo "Error: not_found: Workspace not found" >&2; exit 1; }
      jq -nc --arg t "$(cat "$ROOT/pane" 2>/dev/null)" '{text:$t}'; exit 0
    fi
    exit 0 ;;
  surface) printf '%s\n' "$*" >> "$ROOT/surface"; exit 0 ;;
  notify|log|set-status|clear-status) printf '%s\n' "$*" >> "$ROOT/ledger"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$ROOT/bin/cmux"
PATH="$ROOT/bin:$PATH"
export PATH

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3' in: $2)"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
title(){ cat "$ROOT/title"; }
ledger(){ cat "$ROOT/ledger" 2>/dev/null; }

# A session is a real, killable pid: the watcher reaps on liveness, so a test
# needs a process it can end (and one the harness can end for it).
boot_session() { sleep 300 & CC_PID=$!; }
end_session()  { kill "$CC_PID" 2>/dev/null; wait "$CC_PID" 2>/dev/null; }

# Drive the adapter exactly as a Command Code hook does: JSON payload on stdin,
# event name INSIDE the payload (Command Code never passes argv).
# CC_SURFACE is '-' for the default and '' to simulate running OUTSIDE cmux; it
# must be read with `${VAR-default}` (not `:-`) so an explicit empty value is
# honoured rather than silently replaced by the default.
cc_hook() { # $1 = payload ; honours CC_PID / CC_HOME / CC_SURFACE / CC_INTERVAL / CC_MAX_SCANS
  printf '%s' "$1" | \
    HOME="${CC_HOME:-$ROOT/home}" \
    TMPDIR="$ROOT" \
    CMUX_WORKSPACE_ID="$WS" \
    CMUX_SURFACE_ID="${CC_SURFACE-$SURF}" \
    COMMANDCODE_SESSION_PID="${CC_PID:-$$}" \
    CMUX_SENTINEL_CC_POLL_INTERVAL="${CC_INTERVAL:-0.15}" \
    CMUX_SENTINEL_CC_MAX_SCANS="${CC_MAX_SCANS:-60}" \
    CMUX_SENTINEL_CC_MAX_READ_FAILURES="${CC_MAX_FAILS:-3}" \
    CMUX_SENTINEL_CC_RESUME="${CC_RESUME:-1}" \
    bash "$ADAPTER" >/dev/null 2>&1
}
payload() { printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","tool_name":"%s"}' "$1" "$SESSION" "$ROOT" "${2:-shell_command}"; }

# Between scenarios: stop every watcher from the last one (a stray watcher would
# rename the title mid-assertion and make this suite flaky), then reset state.
reset_scenario() {
  local d p
  for d in "$ROOT"/cmux-sentinel-cc-watch/*.lock; do
    [ -d "$d" ] || continue
    p=$(cat "$d/pid" 2>/dev/null)
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  sleep 0.25
  rm -rf "$ROOT/cmux-sentinel-cc-watch" "$ROOT/cmux-sentinel-work"
  rm -f "$ROOT/renames" "$ROOT/surface" "$ROOT/ledger" "$ROOT/pane.fail"
  : > "$ROOT/pane"
  printf 'workspace' > "$ROOT/title"
}

# Wait for the title to settle on $2 (tenths of a second). The watcher reports on
# its first scan, so a positive is fast; a negative just has to outlast a couple
# of scans.
wait_title() {
  local i=0
  while [ "$i" -lt "${2:-25}" ]; do
    [ "$(title)" = "$1" ] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}
expect_title() { if wait_title "$2" "${3:-25}"; then ok "$1"; else bad "$1 (want '$2', got '$(title)')"; fi; }
expect_stays() { if wait_title "$2" "${3:-12}"; then bad "$1 (unexpectedly became '$2')"; else ok "$1"; fi; }

pane() { printf '%s' "$1" > "$ROOT/pane"; }
locked() { [ -d "$ROOT/cmux-sentinel-cc-watch/$CC_PID.lock" ]; }

echo "commandcode-bridge: adapter + watcher"

# ── A. the four events reach the bridge, with Command Code's identity ─────────
reset_scenario; boot_session
cc_hook "$(payload SessionStart)"
has "SessionStart forwards with Command Code's identity (log source cmdc)" "$(ledger)" "cmdc"
has "SessionStart forwards the actual event to the bridge" "$(ledger)" "Session startup"
hasnt "identity is NOT Claude Code's default log source" "$(ledger)" "--source cc "
end_session

reset_scenario; boot_session
cc_hook "$(payload PreToolUse)"
expect_title "PreToolUse → ⚡ working" "⚡workspace"
end_session

# PostToolUse is the event this integration had to ADD: without it, nothing
# clears a watcher-set ❓ until the turn ends. The watcher itself can only ever
# RAISE the state — it reports `blocked` and never reports "fine" — so clearing is
# entirely the event stream's job.
reset_scenario; boot_session
pane 'Enter plan mode for read-only exploration and planning?'
cc_hook "$(payload SessionStart)"
expect_title "a plan-mode prompt seen on the pane → ❓ waiting" "❓workspace"
: > "$ROOT/pane"   # prompt answered → it leaves the screen
sleep 0.6
is "prompt leaving the pane does NOT itself clear ❓ (only the event stream may)" "$(title)" "❓workspace"
cc_hook "$(payload PostToolUse)"
expect_title "PostToolUse CLEARS ❓ back to ⚡ (the reason it is registered)" "⚡workspace"
end_session

reset_scenario; boot_session
cc_hook "$(payload PreToolUse)"
expect_title "PreToolUse → ⚡ (setup for Stop)" "⚡workspace"
cc_hook "$(payload Stop)"
expect_title "Stop → idle: marker removed" "workspace"
end_session

# ── B. the blocking-signal matrix (Command Code's own strings) ────────────────
declare -a SIGNALS=(
  "shell-command permission (both lines)|Execute Shell Command
Command Code needs to execute"
  "plan-mode entry prompt|Enter plan mode for read-only exploration and planning?"
  "act-mode entry prompt (prefix match)|Enter act mode for implementation?"
  "plan review card (heading + approval)|REVIEW
Approve ctrl+a"
)
for entry in "${SIGNALS[@]}"; do
  label="${entry%%|*}"; text="${entry#*|}"
  reset_scenario; boot_session
  pane "$text"
  cc_hook "$(payload SessionStart)"
  expect_title "blocked: $label → ❓" "❓workspace"
  end_session
done

# The review card is TWO strings and must be matched as a whole, and the shell
# permission is two lines for the same reason: halves appear in ordinary output.
declare -a NEAR_MISSES=(
  "review heading alone|REVIEW\n"
  "review approval alone|Approve ctrl+a\n"
  "shell permission first line alone|Execute Shell Command\n"
  "shell permission second line alone|Command Code needs to execute\n"
  "ordinary prompt|Ask your question...\n"
)
for entry in "${NEAR_MISSES[@]}"; do
  label="${entry%%|*}"; text="${entry#*|}"
  reset_scenario; boot_session
  printf '%b' "$text" > "$ROOT/pane"
  cc_hook "$(payload SessionStart)"
  expect_stays "near miss: $label does NOT set ❓" "❓workspace"
  end_session
done

# ── C. sustained prompts, the lowering race, and re-arming ───────────────────
reset_scenario; boot_session
pane 'Enter act mode for implementation?'
cc_hook "$(payload SessionStart)"
expect_title "sustained prompt → ❓" "❓workspace"
sleep 1
# The watcher re-reports every scan, so this is really an assertion that the
# BRIDGE absorbs the repeats: many reports, exactly one title write.
is "a sustained prompt re-reported every scan produces ONE rename (no title churn)" \
  "$(grep -c '❓workspace' "$ROOT/renames")" "1"

# THE RACE this design exists to survive: an event lowers ❓ back to ⚡ while the
# prompt is STILL on screen. A latched watcher would never re-assert it, and a
# genuinely blocked session would read as working until the user acted on it.
cc_hook "$(payload PostToolUse)"
expect_title "❓ is re-asserted after an event lowered it with the prompt still up" "❓workspace"

# Answered and the turn ended → idle. The watcher must ARM AGAIN afterwards, or
# one ❓ is the most a session ever gets.
: > "$ROOT/pane"
cc_hook "$(payload Stop)"
expect_title "prompt answered + Stop → idle marker removed" "workspace"
pane 'Execute Shell Command
Command Code needs to execute'
expect_title "a SECOND, different prompt → ❓ again (watcher re-armed)" "❓workspace"
end_session

# ── D. capability gating against an older bridge ─────────────────────────────
# A protocol=2 bridge ignores `Blocked` and exits 0, which is indistinguishable
# from success — so the adapter must not rely on the event at all.
reset_scenario; boot_session
pane 'Enter act mode for implementation?'
CC_HOME="$ROOT/home-old" cc_hook "$(payload SessionStart)"
expect_stays "old bridge (no 'blocked' capability) → no ❓, no false report" "❓workspace" 20
end_session

# ── E. guards: outside cmux, and an unreadable pane ─────────────────────────
reset_scenario; boot_session
CC_SURFACE="" cc_hook "$(payload SessionStart)"
sleep 0.5   # give a (wrongly-started) watcher time to appear before we look
if locked; then bad "no CMUX_SURFACE_ID → no watcher (nothing to watch)"; else ok "no CMUX_SURFACE_ID → no watcher (nothing to watch)"; fi
end_session

# A socket failure must NOT read as "no prompt on screen": that would clear a real
# ❓ on a hiccup. The watcher keeps its last known state and gives up only after a
# run of failures.
reset_scenario; boot_session
pane 'Enter act mode for implementation?'
cc_hook "$(payload SessionStart)"
expect_title "prompt → ❓" "❓workspace"
: > "$ROOT/pane.fail"
sleep 1
is "a failing read_text does NOT clear the ❓" "$(title)" "❓workspace"
end_session

# ── F. session restore ───────────────────────────────────────────────────────
reset_scenario; boot_session
cc_hook "$(payload SessionStart)"
bind="$(cat "$ROOT/surface" 2>/dev/null)"
has "resume binding is published on SessionStart" "$bind" "surface resume set"
has "binding is labelled with our own --kind" "$bind" "--kind commandcode"
has "binding carries the session id as --checkpoint" "$bind" "--checkpoint $SESSION"
has "binding resumes with cmd --session <id>" "$bind" "cmd --session $SESSION"
end_session

reset_scenario; boot_session
CC_RESUME=0 cc_hook "$(payload SessionStart)"
if [ -s "$ROOT/surface" ]; then bad "CMUX_SENTINEL_CC_RESUME=0 suppresses the binding"; else ok "CMUX_SENTINEL_CC_RESUME=0 suppresses the binding"; fi
end_session

# ── G. the watcher does not outlive its session, and CAN be stopped ──────────
reset_scenario; boot_session
cc_hook "$(payload SessionStart)"
sleep 0.3
[ -d "$ROOT/cmux-sentinel-cc-watch/$CC_PID.lock" ] || bad "watcher started for the session"
end_session
sleep 0.8
if [ -d "$ROOT/cmux-sentinel-cc-watch/$CC_PID.lock" ]; then
  bad "watcher exits and cleans its lock when the session pid dies"
else
  ok "watcher exits and cleans its lock when the session pid dies"
fi

# A watcher that cannot be killed is a watcher that accumulates forever: an
# unbounded poll loop on a live pid would just keep running. This is the
# regression test for `trap cleanup EXIT HUP INT TERM`, where the TERM handler
# cleans up and RETURNS instead of exiting.
reset_scenario; boot_session
CC_MAX_SCANS=100000 cc_hook "$(payload SessionStart)"   # effectively unbounded
sleep 0.5
WPID=$(cat "$ROOT/cmux-sentinel-cc-watch/$CC_PID.lock/pid" 2>/dev/null)
if [ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null; then
  kill -TERM "$WPID" 2>/dev/null
  sleep 0.7
  if kill -0 "$WPID" 2>/dev/null; then
    bad "SIGTERM stops the watcher (it is immune, so orphans can only be SIGKILLed)"
  else
    ok "SIGTERM stops the watcher and the EXIT trap removes its lock"
  fi
else
  bad "no live watcher to signal"
fi
end_session

echo
if [ "$fail" -gt 0 ]; then
  printf 'commandcode-bridge: %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
printf 'commandcode-bridge: %d passed, 0 failed\n' "$pass"
