#!/bin/bash
# usage-tui.sh — offline test for bin/zed-usage-tui.sh.
#
# Stubs all three pollers (via CLAUDE_USAGE_BIN / CODEX_USAGE_BIN / AMP_USAGE_BIN) to emit canned
# `--print` output, "gated" (exit 0, no stdout), or "offline" (exit non-zero), then
# asserts the --once frame: section headers, parsed %, bar extremes, severity dots,
# gating, and the offline notice. No real pollers, no network.
#
# Run:  make test   (or:  bash tests/usage-tui.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$HERE/../bin/zed-usage-tui.sh}"
[ -f "$SUT" ] || { echo "script not found: $SUT" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/usage-tui-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# Parametric stub: reads its OWN mode var ($3) so providers can differ.
# mode ∈ print|disabled|offline; $2 = "line1|line2" for print.
mk_stub() { # $1 = path   $2 = "l1|l2"   $3 = mode-var-name
  cat > "$1" <<STUB
#!/bin/bash
case "\${$3:-print}" in
  print)    [ "\$1" = --print ] && { printf '%s\n' "${2%%|*}"; printf '%s\n' "${2##*|}"; }; exit 0 ;;
  disabled) exit 0 ;;
  offline)  exit 1 ;;
esac
STUB
  chmod +x "$1"
}
CL="$ROOT/claude"; CX="$ROOT/codex"; AM="$ROOT/amp"
export CLAUDE_USAGE_BIN="$CL" CODEX_USAGE_BIN="$CX" AMP_USAGE_BIN="$AM"

pass=0; fail=0
strip() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }             # drop ANSI
run() { bash "$SUT" --once 2>/dev/null | strip; }
line() { printf '%s\n' "$1" | grep -E "(^|[[:space:]])$2[[:space:]]"; }
ckq() { if printf '%s' "$2" | grep -qE "$3"; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
        else fail=$((fail + 1)); printf '  ✗ %s — /%s/ not found\n' "$1" "$3"; fi; }
ckn() { if printf '%s' "$2" | grep -qE "$3"; then fail=$((fail + 1)); printf '  ✗ %s — /%s/ unexpectedly present\n' "$1" "$3"
        else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }

echo "A: all providers render"
mk_stub "$CL" "5h  39%  · resets 4h35m  (2026-01-01T00:00:00Z)|7d  12%  · resets 2d3h" CL_MODE
mk_stub "$CX" "cx5h  8%  · resets 4h50m|cx7d  6%  · resets now" CX_MODE
mk_stub "$AM" "ampu: 77% used (23% remaining), resets in 12 days|ampo: 29% used (71% remaining), resets in 12 days" AM_MODE
out=$(run)
ckq "Claude header"     "$out" "CLAUDE USAGE"
ckq "Codex header"      "$out" "CODEX USAGE"
ckq "Amp header"        "$out" "AMP USAGE"
ckq "5h parsed %"       "$out" "5h.*39%"
ckq "5h has a bar"      "$out" "5h[[:space:]]+[█░▏▎▍▌▋▊▉]"
ckq "7d reset shown"    "$out" "7d.*2d3h"
ckq "cx5h parsed %"     "$out" "cx5h.*8%"
ckq "Amp thread usage parsed" "$out" "ampu.*77%.*\(12 days\)"
ckn "compact rows omit resets prose" "$out" "resets"

echo "B: bar extremes"
mk_stub "$CL" "5h  0%  · resets now|7d  100%  · resets now" CL_MODE
out=$(run)
ckq "0% → empty track"     "$(line "$out" 5h)" "░"
ckn "0% → no full cell"    "$(line "$out" 5h)" "█"
ckq "100% → full bar"      "$(line "$out" 7d)" "█"
ckn "100% → no track"      "$(line "$out" 7d)" "░"

echo "C: severity is conveyed by colour, not emoji dots"
mk_stub "$CL" "5h  95%  · resets 1h0m|7d  75%  · resets 1d0h" CL_MODE
out=$(run)
ckn "≥90% → no red emoji"    "$out" "🔴"
ckn "≥70% → no amber emoji"  "$out" "🟡"

echo "D: gating + offline"
mk_stub "$CL" "x|y" CL_MODE
out=$(CL_MODE=disabled run)
ckn "disabled Claude → no section" "$out" "CLAUDE USAGE"
ckq "Codex still renders"          "$out" "CODEX USAGE"
ckq "Amp still renders"            "$out" "AMP USAGE"
out=$(CL_MODE=offline run)
ckq "offline Claude → notice"      "$out" "⚠ offline"
out=$(AM_MODE=disabled run)
ckn "disabled Amp → no section"    "$out" "AMP USAGE"
out=$(AM_MODE=offline run)
ckq "offline Amp → section"        "$out" "AMP USAGE"
ckq "offline Amp → notice"         "$out" "⚠ offline"

echo "E: options"
rc=0; bash "$SUT" --bogus >/dev/null 2>&1 || rc=$?
ckq "unknown option → exit 2"      "$rc" "^2$"

echo
echo "usage-tui: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
