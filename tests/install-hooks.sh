#!/bin/bash
# install-hooks.sh — offline test for install.sh's Claude-hook auto-registration
# (register_hooks). This is the onboarding step that used to be a manual "see
# README" note; a regression here silently leaves new users with no live row
# states, so it's worth a real end-to-end test.
#
# Runs the ACTUAL install.sh against a throwaway $HOME (its main flow makes no
# cmux/launchctl/security/network calls, only file copies), then asserts the hook
# merge: every event wired, pre-existing user hooks preserved, idempotent on
# re-run, and a graceful no-op when jq is unavailable.
#
# Run:  make test   (or:  bash tests/install-hooks.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${INSTALL:-$HERE/../install.sh}"
[ -f "$INSTALL" ] || { echo "install.sh not found: $INSTALL" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required for this test" >&2; exit 2; }

EVENTS="SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact Stop StopFailure Notification PostToolUseFailure SessionEnd"
# Literal ~ on purpose: this is the exact command string install.sh writes into
# settings.json (Claude Code expands it at hook-exec time), so we match it verbatim.
# shellcheck disable=SC2088
BRIDGE='~/.claude/hooks/cmux-bridge.sh'

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-install-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
SBX="$ROOT/home"; mkdir -p "$SBX/.claude"
SETTINGS="$SBX/.claude/settings.json"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
# count cmux-bridge references registered for one event
bridgecount() { jq --arg e "$1" --arg c "$BRIDGE" \
  '[(.hooks[$e] // [])[].hooks[]? | select(.command == $c)] | length' "$SETTINGS" 2>/dev/null; }
runinstall() { ( cd "$ROOT" && WITH_BRIDGE=1 HOME="$SBX" bash "$INSTALL" ) >/dev/null 2>&1; }

# Pre-seed settings.json: an UNRELATED user hook on PreToolUse (must survive) and a
# cmux-bridge already on Stop (must NOT be duplicated).
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/my/other-hook.sh" }] }],
    "Stop":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }]
  }
}
JSON

echo "T1: first run wires every hook event to cmux-bridge"
runinstall; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh exited 0"; else bad "install.sh exited $rc"; fi
miss=""
for ev in $EVENTS; do
  n="$(bridgecount "$ev")"
  case "$n" in ''|0) miss="$miss $ev" ;; esac
done
if [ -z "$miss" ]; then ok "all events reference cmux-bridge"; else bad "events NOT wired:$miss"; fi

echo "T2: pre-existing user hook preserved, existing cmux-bridge not duplicated"
if jq -e '[.hooks.PreToolUse[].hooks[]? | select(.command == "~/my/other-hook.sh")] | length == 1' "$SETTINGS" >/dev/null 2>&1; then
  ok "unrelated PreToolUse hook still present"
else bad "unrelated PreToolUse hook was lost"; fi
if [ "$(bridgecount Stop)" = 1 ]; then ok "Stop's existing cmux-bridge not duplicated"
else bad "Stop cmux-bridge count = $(bridgecount Stop) (want 1)"; fi

echo "T3: idempotent — a second run adds no duplicates"
runinstall
dups=""
for ev in $EVENTS; do
  [ "$(bridgecount "$ev")" = 1 ] || dups="$dups $ev=$(bridgecount "$ev")"
done
if [ -z "$dups" ]; then ok "every event has exactly one cmux-bridge after re-run"; else bad "duplicate registrations:$dups"; fi

echo "T4: jq unavailable → graceful no-op, settings.json untouched"
# Build a bin with symlinks to ONLY the tools install.sh needs — deliberately no
# jq — and run with PATH pointed there. (Trimming PATH to /usr/bin:/bin isn't
# enough: some systems ship /usr/bin/jq.)
NOJQ="$ROOT/nojqbin"; mkdir -p "$NOJQ"
for t in bash cat cp date dirname install mkdir mktemp rm sed; do
  p="$(command -v "$t")" && ln -sf "$p" "$NOJQ/$t"
done
if [ ! -e "$NOJQ/jq" ]; then ok "test bin has no jq (precondition)"; else bad "could not build a jq-less bin"; fi
# Fresh settings with only the unrelated hook.
printf '{"hooks":{"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/my/other-hook.sh"}]}]}}\n' > "$SETTINGS"
before="$(cat "$SETTINGS")"
( cd "$ROOT" && WITH_BRIDGE=1 HOME="$SBX" PATH="$NOJQ" bash "$INSTALL" ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh still exited 0 without jq"; else bad "install.sh exited $rc without jq"; fi
if [ "$(cat "$SETTINGS")" = "$before" ]; then ok "settings.json left untouched (no clobber)"; else bad "settings.json was modified without jq"; fi

# ---- Zed integration (opt-in via --with-zed / WITH_ZED=1) --------------------
# zed-bridge handles 8 of the 10 events (no StopFailure / PostToolUseFailure), so we
# also assert it stays OFF those two — proves the event list, not just "wired".
ZED_EVENTS="SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact Notification Stop SessionEnd"
# shellcheck disable=SC2088
ZED='~/.claude/hooks/zed-bridge.sh'
zedcount() { jq --arg e "$1" --arg c "$ZED" \
  '[(.hooks[$e] // [])[].hooks[]? | select(.command == $c)] | length' "$SETTINGS" 2>/dev/null; }

echo "T5: --with-zed (flag) wires zed-bridge for its 8 events + installs the helpers"
( cd "$ROOT" && HOME="$SBX" bash "$INSTALL" --with-zed ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh --with-zed exited 0"; else bad "install.sh --with-zed exited $rc"; fi
zmiss=""
for ev in $ZED_EVENTS; do
  n="$(zedcount "$ev")"; case "$n" in ''|0) zmiss="$zmiss $ev" ;; esac
done
if [ -z "$zmiss" ]; then ok "all zed events reference zed-bridge"; else bad "zed events NOT wired:$zmiss"; fi
zno=""
for ev in StopFailure PostToolUseFailure; do
  [ "$(zedcount "$ev")" = 0 ] || zno="$zno $ev=$(zedcount "$ev")"
done
if [ -z "$zno" ]; then ok "zed-bridge absent from cmux-only events"; else bad "zed-bridge wrongly on:$zno"; fi
for f in .claude/hooks/zed-bridge.sh bin/cmux-open-in-zed.sh bin/zed-usage-tui.sh; do
  if [ -x "$SBX/$f" ]; then ok "installed $f"; else bad "missing $f"; fi
done

echo "T6: WITH_ZED=1 (env form) re-run is idempotent; cmux path unaffected"
( cd "$ROOT" && WITH_ZED=1 HOME="$SBX" bash "$INSTALL" ) >/dev/null 2>&1
zdups=""
for ev in $ZED_EVENTS; do
  [ "$(zedcount "$ev")" = 1 ] || zdups="$zdups $ev=$(zedcount "$ev")"
done
if [ -z "$zdups" ]; then ok "every zed event has exactly one zed-bridge after re-run"; else bad "duplicate zed registrations:$zdups"; fi
if [ "$(bridgecount SessionStart)" = 1 ]; then ok "cmux-bridge path unaffected by --with-zed"; else bad "cmux-bridge SessionStart count = $(bridgecount SessionStart)"; fi

echo "T7: a default install (no flags/env) stays Zed-free; unknown flag rejected"
SBX2="$ROOT/home2"; mkdir -p "$SBX2/.claude"
( cd "$ROOT" && HOME="$SBX2" bash "$INSTALL" ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "default install exited 0"; else bad "default install exited $rc"; fi
if [ ! -e "$SBX2/.claude/hooks/zed-bridge.sh" ]; then ok "no zed-bridge.sh on default install"; else bad "zed-bridge.sh installed by default"; fi
if [ ! -e "$SBX2/.claude/hooks/cmux-bridge.sh" ]; then ok "no cmux-bridge.sh on default install"; else bad "cmux-bridge.sh installed by default"; fi
S2="$SBX2/.claude/settings.json"
if [ ! -f "$S2" ] || ! grep -q -e cmux-bridge -e zed-bridge "$S2" 2>/dev/null; then ok "default settings carries no bridge hooks"; else bad "default install wrote bridge hooks"; fi
( cd "$ROOT" && HOME="$SBX2" bash "$INSTALL" --bogus ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "unknown flag → exit 2"; else bad "unknown flag exit $rc (want 2)"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
