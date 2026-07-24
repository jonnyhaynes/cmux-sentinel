#!/bin/bash
# amp-bridge.sh — offline test for the Amp integration (hooks/amp-bridge.ts +
# the agent-agnostic knobs it drives in hooks/cmux-bridge.sh).
#
# Two halves, because the two sides fail differently:
#
#  A. BEHAVIOUR — drives the real bash bridge with the exact env the amp plugin
#     sets (CMUX_SENTINEL_SESSION_PID / _AGENT_LABEL / _LOG_SOURCE) against a
#     stubbed cmux, and asserts the markers, the "Amp" notification title, the
#     `amp` log source, and — the one that actually matters — CO-TENANCY: an Amp
#     session and a Claude session in the SAME workspace must ref-count against
#     each other, so one ending must not clear the other's ⚡. That property is
#     the whole reason the plugin shells out instead of reimplementing state.
#
#  B. STRUCTURE — asserts the .ts adapter maps the right Amp events and keeps its
#     invariants. Amp/Bun are NOT on the CI runner, so this half is static: it
#     cannot execute the plugin. When `amp` IS present locally, one extra live
#     check runs `amp plugins exec` to prove the file actually loads.
#
# No real cmux, amp or bun needed for the required checks, so this runs in CI on
# Linux too.
#
# Run:  make test   (or:  bash tests/amp-bridge.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-$HERE/../hooks/cmux-bridge.sh}"
PLUGIN="${PLUGIN:-$HERE/../hooks/amp-bridge.ts}"
[ -f "$BRIDGE" ] || { echo "bridge not found: $BRIDGE" >&2; exit 2; }
[ -f "$PLUGIN" ] || { echo "plugin not found: $PLUGIN" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-amp-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# UUID-shaped, but BUILT AT RUNTIME so no literal id sits in the source for the
# secret guard to flag (same idiom as tests/bridge-state.sh). The bridge treats
# this as an opaque $WORKROOT dir name, so the actual value is irrelevant.
WS="$(printf '%08d-%04d-%04d-%04d-%012d' 0 0 0 0 1)"
echo "workspace" > "$ROOT/title"

# Fake cmux: ping ok; list-workspaces serves "<id>  <title>" from $ROOT/title;
# rename writes it back; notify/log/set-status/clear-status append to a ledger.
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
    printf '%s' "$1" > "$ROOT/title"; exit 0 ;;
  notify|log|set-status|clear-status)
    printf '%s\n' "$*" >> "$ROOT/ledger"; exit 0 ;;
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
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
title(){ cat "$ROOT/title"; }

# Drive the bridge exactly as hooks/amp-bridge.ts does.
amp_event() {
  local event="$1" pid="$2" payload="${3:-{\}}"
  printf '%s' "$payload" | \
  CMUX_WORKSPACE_ID="$WS" \
  TMPDIR="$ROOT" \
  CMUX_SENTINEL_SESSION_PID="$pid" \
  CMUX_SENTINEL_AGENT_LABEL="Amp" \
  CMUX_SENTINEL_LOG_SOURCE="amp" \
  bash "$BRIDGE" "$event" >/dev/null 2>&1
}

# Drive it as the Claude bridge does (default identity) — the co-tenant.
cc_event() {
  local event="$1" pid="$2" payload="${3:-{\}}"
  printf '%s' "$payload" | \
  CMUX_WORKSPACE_ID="$WS" \
  TMPDIR="$ROOT" \
  CMUX_SENTINEL_SESSION_PID="$pid" \
  bash "$BRIDGE" "$event" >/dev/null 2>&1
}

echo "amp-bridge: behaviour (stubbed cmux)"

# A live pid to own sessions with: this shell always passes kill -0.
LIVE=$$

# ── turn lifecycle ────────────────────────────────────────────────────────
amp_event UserPromptSubmit "$LIVE"
is "agent.start → ⚡ working" "$(title)" "⚡workspace"

amp_event PreToolUse "$LIVE" '{"tool_name":"Bash"}'
is "tool.call keeps ⚡ (no double marker)" "$(title)" "⚡workspace"

amp_event Stop "$LIVE"
is "agent.end(done) → idle" "$(title)" "workspace"
has "agent.end notifies as Amp" "$(cat "$ROOT/ledger" 2>/dev/null)" "--title Amp"
hasnt "agent.end never says Claude Code" "$(cat "$ROOT/ledger" 2>/dev/null)" "Claude Code"
has "log source is amp" "$(cat "$ROOT/ledger" 2>/dev/null)" "--source amp"

# ── agent.end(error) is transient: surfaces, does NOT decrement ───────────
: > "$ROOT/ledger"
amp_event UserPromptSubmit "$LIVE"
amp_event StopFailure "$LIVE" '{"error":"boom"}'
is "agent.end(error) keeps ⚡ (transient)" "$(title)" "⚡workspace"
has "agent.end(error) uses amp status key" "$(cat "$ROOT/ledger")" "amp_error"
has "agent.end(error) notifies as Amp Error" "$(cat "$ROOT/ledger")" "--title Amp Error"
amp_event Stop "$LIVE"
is "…and a later agent.end still clears" "$(title)" "workspace"

# ── opt-in ❓ waiting ─────────────────────────────────────────────────────
amp_event UserPromptSubmit "$LIVE"
amp_event PreToolUse "$LIVE" '{"tool_name":"AskUserQuestion"}'
is "ASK path → ❓ waiting outranks ⚡" "$(title)" "❓workspace"
amp_event PreToolUse "$LIVE" '{"tool_name":"Bash"}'
is "…answered → back to ⚡" "$(title)" "⚡workspace"
amp_event Stop "$LIVE"
is "…then idle" "$(title)" "workspace"

# ── CO-TENANCY: the reason the plugin shells out at all ──────────────────
# Amp and Claude Code in ONE workspace, each with its own session pid. Neither
# ending may clear the other's marker.
amp_event UserPromptSubmit "$LIVE"
cc_event  UserPromptSubmit "$LIVE"   # same pid would collide; use a distinct one
# Use a second genuinely-live pid: a background sleep we control.
sleep 30 & CO=$!
cc_event  UserPromptSubmit "$CO"
is "two agents, one workspace → ⚡" "$(title)" "⚡workspace"
amp_event Stop "$LIVE"
is "Amp ends, Claude still working → ⚡ SURVIVES" "$(title)" "⚡workspace"
cc_event  Stop "$CO"
is "last agent ends → idle" "$(title)" "workspace"
kill "$CO" 2>/dev/null; wait "$CO" 2>/dev/null

# ── dead-session reaping ─────────────────────────────────────────────────
sleep 30 & DEAD=$!
kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null   # now a dead pid
amp_event UserPromptSubmit "$DEAD"
amp_event SessionStart "$LIVE" '{"source":"startup"}'
is "crashed Amp session is reaped by SessionStart" "$(title)" "workspace"

# ── not in a cmux workspace → total no-op ────────────────────────────────
printf '%s' "workspace" > "$ROOT/title"
printf '{}' | TMPDIR="$ROOT" CMUX_SENTINEL_SESSION_PID="$LIVE" \
  bash "$BRIDGE" UserPromptSubmit >/dev/null 2>&1
is "no CMUX_WORKSPACE_ID → title untouched" "$(title)" "workspace"

# ── default identity is unchanged (no regression for Claude Code) ────────
: > "$ROOT/ledger"
cc_event Stop "$LIVE"
has "default label still Claude Code" "$(cat "$ROOT/ledger")" "--title Claude Code"
has "default log source still cc" "$(cat "$ROOT/ledger")" "--source cc"

echo "amp-bridge: structure (static)"

SRC="$(cat "$PLUGIN")"
has "maps session.start"  "$SRC" 'amp.on("session.start"'
has "maps agent.start"    "$SRC" 'amp.on("agent.start"'
has "maps agent.end"      "$SRC" 'amp.on("agent.end"'
has "maps tool.call"      "$SRC" 'amp.on("tool.call"'
has "sets Amp label"      "$SRC" 'CMUX_SENTINEL_AGENT_LABEL: "Amp"'
has "sets amp log source" "$SRC" 'CMUX_SENTINEL_LOG_SOURCE: "amp"'
has "passes own pid"      "$SRC" "CMUX_SENTINEL_SESSION_PID"
has "gates on workspace"  "$SRC" "CMUX_WORKSPACE_ID"
has "❓ ask is opt-in"     "$SRC" "CMUX_SENTINEL_AMP_ASK"
has "detached spawn"      "$SRC" "detached: true"
# Amp emits no compaction event — the adapter must not invent one.
hasnt "never fakes PreCompact"  "$SRC" "PreCompact"
hasnt "never fakes PostCompact" "$SRC" "PostCompact"
# cmux owns cmux-session.ts and upgrades it in place; we must never target it.
hasnt "never writes cmux-session.ts" "$SRC" "cmux-session.ts\""
# tool.call is a request event: every path must return an action or amp stalls.
is "tool.call always returns an action" \
  "$(printf '%s' "$SRC" | grep -c 'return { action:')" "3"

# Installer must ship it under a name that cannot collide with cmux's plugin.
INSTALL="$HERE/../install.sh"
if [ -f "$INSTALL" ]; then
  ISRC="$(cat "$INSTALL")"
  has "installer targets amp plugin dir" "$ISRC" ".config/amp/plugins/cmux-sentinel-amp.ts"
  hasnt "installer never touches cmux-session.ts" "$ISRC" "plugins/cmux-session.ts"
fi

# ── live check, only when amp is actually installed ──────────────────────
# Drives the REAL amp runtime through the REAL plugin into a recorder standing in
# for the bridge, so this proves the whole chain: amp loads the TypeScript, fires
# the handler, and the handler spawns the bridge with the right event, identity
# and stdin payload. Nothing static can prove that.
#
# It must use `session.start`, and that is not arbitrary: `amp plugins exec` only
# actually INVOKES session.start. agent.start / agent.end / tool.call / tool.result
# all exit cleanly WITHOUT running the handler (they need a real thread context) —
# verified 2026-07-20 across all five events. An earlier version of this check used
# agent.start and passed by only looking for error text in the output, which made it
# a false positive: it proved the file parsed, not that anything ran.
if command -v amp >/dev/null 2>&1; then
  echo "amp-bridge: live (amp present)"
  REC="$ROOT/.recorded"
  cat > "$ROOT/bin/recorder" <<EOF
#!/bin/bash
{ echo "EVENT=\$1 LABEL=\$CMUX_SENTINEL_AGENT_LABEL SRC=\$CMUX_SENTINEL_LOG_SOURCE PID=\$CMUX_SENTINEL_SESSION_PID"; cat; } >> "$REC"
EOF
  chmod +x "$ROOT/bin/recorder"
  rm -f "$REC"
  ( cd "$ROOT" && CMUX_WORKSPACE_ID="$WS" CMUX_SENTINEL_BRIDGE="$ROOT/bin/recorder" \
      amp plugins exec "$PLUGIN" session.start --data '{"thread":{"id":"T-live"}}' ) >/dev/null 2>&1
  # The bridge spawn is detached and fire-and-forget, so give it a moment to land.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$REC" ] && break; sleep 0.3; done
  rec="$(cat "$REC" 2>/dev/null)"
  if [ -z "$rec" ]; then
    bad "live: amp never invoked the plugin handler"
  else
    has "live: amp → plugin → bridge fires"    "$rec" "EVENT=SessionStart"
    has "live: identity is Amp"                "$rec" "LABEL=Amp"
    has "live: log source is amp"              "$rec" "SRC=amp"
    has "live: payload is the hook JSON"       "$rec" '"hook_event_name":"SessionStart"'
  fi
else
  echo "amp-bridge: live checks skipped (amp not on PATH)"
fi

echo
printf 'amp-bridge: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
