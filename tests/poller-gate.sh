#!/bin/bash
# poller-gate.sh — offline test for bin/cmux-claude-usage.sh PROVIDER GATING.
#
# Stubs security (Keychain), curl (network) and cmux, with a throwaway $HOME, so
# it runs in CI on Linux too. Asserts the four gate outcomes that decide whether
# a usage panel shows — the robustness contract from the README "Usage meters"
# section: a provider that's disabled or not installed must exit 0 cleanly (no
# panel, no error spam), while an installed-but-unreachable provider stamps the
# transient "⚠ offline" so a frozen bar is obvious.
#
# Run:  make test   (or:  bash tests/poller-gate.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../bin/cmux-claude-usage.sh}"
[ -f "$POLLER" ] || { echo "poller not found: $POLLER" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-poller-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.claude" "$ROOT/home/.config/cmux"

# Fake cmux: ping ok; `workspace list --json` serves two sentinels; rename logs
# the resulting title so we can assert what (if anything) the poller wrote.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$POLLERTEST/.renames"
PLOG="$POLLERTEST/.progress"
case "$1" in
  ping) exit 0 ;;
  workspace)
    if [ "$2" = "list" ]; then
      # STUB_BARE=1 → sentinels titled with the BARE label (a freshly-created,
      # never-updated sentinel) to exercise the bootstrap resolve path.
      if [ -n "${STUB_BARE:-}" ]; then
        printf '{"workspaces":[{"title":"5h","ref":"workspace:1"},{"title":"7d","ref":"workspace:2"}]}\n'
      else
        printf '{"workspaces":[{"title":"5h init","ref":"workspace:1"},{"title":"7d init","ref":"workspace:2"}]}\n'
      fi
    fi
    exit 0 ;;
  rename-workspace)
    shift; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s\n' "$title" >> "$LOG"; exit 0 ;;
  set-progress)   # set-progress <value> --label <t> --workspace <ref> [--window <w>]
    shift; val="$1"; shift; label=""
    while [ $# -gt 0 ]; do case "$1" in --label) label="$2"; shift 2 ;; --workspace|--window) shift 2 ;; *) shift ;; esac; done
    printf 'PROG %s | %s\n' "$val" "$label" >> "$PLOG"; exit 0 ;;
  clear-progress) printf 'CLEAR\n' >> "$PLOG"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"

# Fake security: always "not found" — the test controls "installed" via the creds
# file only, so there's no machine-Keychain dependency.
printf '#!/bin/bash\nexit 1\n' > "$ROOT/bin/security"; chmod +x "$ROOT/bin/security"

# Fake curl: STUB_CURL=ok → emit usage JSON; otherwise fail (simulates offline).
# Utilization values are injected RAW via STUB_FH/STUB_SH (default 7/42), so tests
# can feed malformed numbers/strings/null and assert the poller clamps, not crashes.
cat > "$ROOT/bin/curl" <<'FAKE'
#!/bin/bash
[ "${STUB_CURL:-fail}" = "ok" ] || exit 1
if [ -n "${STUB_MISSING_BUCKET:-}" ]; then
  printf '{"five_hour":{"utilization":7,"resets_at":"2026-06-19T20:00:00Z"}}\n'
  exit 0
fi
if [ -n "${STUB_BAD_RESET:-}" ]; then
  printf '{"five_hour":{"utilization":7,"resets_at":null},"seven_day":{"utilization":42,"resets_at":{"unexpected":true}}}\n'
  exit 0
fi
printf '{"five_hour":{"utilization":%s,"resets_at":"2026-06-19T20:00:00Z"},"seven_day":{"utilization":%s,"resets_at":"2026-06-25T00:00:00Z"}}\n' "${STUB_FH:-7}" "${STUB_SH:-42}"
FAKE
chmod +x "$ROOT/bin/curl"

export POLLERTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
PATH="$ROOT/bin:$PATH"
CREDS="$ROOT/home/.claude/.credentials.json"
RENAMES="$ROOT/.renames"
PROGRESS="$ROOT/.progress"
TOKEN_JSON='{"claudeAiOauth":{"accessToken":"faketoken"}}'

pass=0; fail=0
ckcode() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s (exit %s)\n' "$1" "$2"
           else fail=$((fail + 1)); printf '  ✗ %s — exit got %s want %s\n' "$1" "$2" "$3"; fi; }
ckno()   { if [ ! -s "$RENAMES" ]; then pass=$((pass + 1)); printf '  ✓ %s (wrote nothing)\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — unexpected renames:\n%s\n' "$1" "$(cat "$RENAMES")"; fi; }
ckhas()  { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"; fi; }
cknothas(){ if grep -q -- "$2" "$RENAMES" 2>/dev/null; then fail=$((fail + 1)); printf '  ✗ %s — unexpected [%s] in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"
           else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }
ckprog() { if grep -q -- "$2" "$PROGRESS" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in progress log:\n%s\n' "$1" "$2" "$(cat "$PROGRESS" 2>/dev/null)"; fi; }
ckprognothas() { if grep -q -- "$2" "$PROGRESS" 2>/dev/null; then fail=$((fail + 1)); printf '  ✗ %s — unexpected [%s] in progress log:\n%s\n' "$1" "$2" "$(cat "$PROGRESS" 2>/dev/null)"
                else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }
reset()  { rm -f "$RENAMES" "$PROGRESS"; }

echo "T1: disabled (USAGE_PROVIDERS without claude) → exit 0, writes nothing"
reset; printf '%s' "$TOKEN_JSON" > "$CREDS"          # installed, but explicitly disabled
USAGE_PROVIDERS="codex" bash "$POLLER" --update; ckcode "disabled --update" "$?" 0
ckno "disabled is a no-op"

echo "T2: not installed (no creds, no Keychain) → exit 0, writes nothing"
reset; rm -f "$CREDS"
bash "$POLLER" --update; ckcode "not-installed --update" "$?" 0
ckno "not-installed is a no-op"

echo "T3: installed + offline (creds present, fetch fails) → exit 1, ⚠ offline stamped"
reset; printf '%s' "$TOKEN_JSON" > "$CREDS"
STUB_CURL="fail" bash "$POLLER" --update; ckcode "installed+offline --update" "$?" 1
ckhas "offline stamps ⚠" "⚠"
ckprog "offline clears the native bar so the ⚠ title shows through" "CLEAR"

echo "T4: installed + reachable → exit 0, bars + native progress written"
reset
STUB_CURL="ok" bash "$POLLER" --update; ckcode "installed+ok --update" "$?" 0
ckhas "5h sentinel renamed" "5h "
ckhas "5h utilization" "7%"
ckhas "7d utilization" "42%"
ckprog "5h native progress value (7% → 0.07)" "PROG 0.07"
ckprog "7d native progress value (42% → 0.42)" "PROG 0.42"
ckprog "native labels use compact parenthesized countdowns" "% ("
ckprognothas "native labels omit redundant resets wording" "resets"
ckhas "fallback title separates detail from the second-row bar" "|"

echo "T5: malformed utilization (over-100 / negative) → clamped, exit 0, no crash"
reset
STUB_CURL="ok" STUB_FH="150" STUB_SH="-5" bash "$POLLER" --update; ckcode "over/under --update" "$?" 0
ckhas "over-100 clamped to 100%" "100%"
ckhas "negative clamped to 0%" "0%"

echo "T5b: non-numeric / null utilization → no data, never a plausible 0%"
reset
STUB_CURL="ok" STUB_FH='"abc"' STUB_SH="null" bash "$POLLER" --update; ckcode "string/null --update" "$?" 1
ckhas "malformed utilization stamps no data" "⚠ no data"
cknothas "malformed utilization never paints 0%" "0%"
ckprog "malformed utilization clears stale native bars" "CLEAR"

echo "T5c: malformed reset timestamps preserve valid percentages with an honest unknown countdown"
reset
STUB_CURL="ok" STUB_BAD_RESET=1 bash "$POLLER" --update; ckcode "bad-reset --update" "$?" 0
ckhas "bad reset keeps valid 5h percentage" "5h |7% (?)|"
ckhas "bad reset keeps valid 7d percentage" "7d |42% (?)|"
ckprog "bad reset keeps native progress" "PROG 0.07 | 7% (?)"

echo "T5d: missing required bucket → no data, never a plausible 0%"
reset
STUB_CURL="ok" STUB_MISSING_BUCKET=1 bash "$POLLER" --update; ckcode "missing-bucket --update" "$?" 1
ckhas "missing bucket stamps no data" "⚠ no data"
cknothas "missing bucket never paints 0%" "0%"
ckprog "missing bucket clears stale native bars" "CLEAR"

echo "T6: BARE sentinel titles → poller still resolves + renames (bootstrap path)"
reset
STUB_CURL="ok" STUB_BARE="1" bash "$POLLER" --update; ckcode "bare-label --update" "$?" 0
ckhas "bare 5h resolved + renamed" "5h "
ckhas "bare 7d resolved + renamed" "7d "

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
