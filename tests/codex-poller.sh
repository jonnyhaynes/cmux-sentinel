#!/bin/bash
# codex-poller.sh — offline test for bin/cmux-codex-usage.sh.
#
# The Codex poller now reads LIVE utilization from the ChatGPT wham/usage endpoint
# (auth token in ~/.codex/auth.json), not the old rollout files. So this stubs
# curl (network), cmux, and a throwaway $HOME holding a fake auth.json, and runs in
# CI on Linux too. PATH is restricted (stubs first, no /opt/homebrew/bin) with jq
# symlinked in. Asserts: disabled / not-logged-in / apikey-mode / offline(⚠) /
# populated(bars) / no-windows(⚠) / clamping / multi-window --window targeting.
#
# Run:  make test   (or:  bash tests/codex-poller.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../bin/cmux-codex-usage.sh}"
[ -f "$POLLER" ] || { echo "poller not found: $POLLER" >&2; exit 2; }

JQ="$(command -v jq)" || { echo "jq required for this test" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-codex-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.config/cmux" "$ROOT/home/.codex"

# Fake cmux: ping ok; workspace list --json serves the two codex sentinels with
# their BARE labels (the real first-run state — no bar appended yet, which the
# poller must still resolve to bootstrap them); rename logs the resulting title.
# STUB_MULTIWIN=1 simulates sentinels living in a NON-default window ("win-b"): the
# default `workspace list` is empty, list-windows offers win-a/win-b, and only
# `workspace list --window win-b` has them — so the poller must scan windows AND
# pass --window on the rename (the stub rejects a rename missing the right window).
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$CODEXTEST/.renames"
PLOG="$CODEXTEST/.progress"
SENT='{"workspaces":[{"title":"cx5h","ref":"workspace:9"},{"title":"cx7d","ref":"workspace:10"}]}'
case "$1" in
  ping) exit 0 ;;
  list-windows) [ -n "${STUB_MULTIWIN:-}" ] && printf '[{"id":"win-a"},{"id":"win-b"}]\n'; exit 0 ;;
  workspace)
    if [ "$2" = "list" ]; then
      win=""; shift 2
      while [ $# -gt 0 ]; do case "$1" in --window) win="$2"; shift 2 ;; *) shift ;; esac; done
      if [ -n "${STUB_MULTIWIN:-}" ]; then
        [ "$win" = "win-b" ] && printf '%s\n' "$SENT" || printf '{"workspaces":[]}\n'
      elif [ -n "${STUB_NO_CX5H:-}" ]; then
        # cx5h deliberately absent — setup skips creating a sentinel for a window the
        # account doesn't have (OpenAI dropped 5h for Pro). The steady state, not a fault.
        printf '{"workspaces":[{"title":"cx7d","ref":"workspace:2"}]}\n'
      else
        printf '{"workspaces":[{"title":"cx5h","ref":"workspace:1"},{"title":"cx7d","ref":"workspace:2"}]}\n'
      fi
    fi
    exit 0 ;;
  rename-workspace)
    shift; title=""; win=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) shift 2 ;; --window) win="$2"; shift 2 ;; *) title="$1"; shift ;; esac; done
    # In multi-window mode the sentinel is in win-b; a rename without that window
    # context would hit the wrong/no workspace, so reject it (forces correct --window).
    [ -n "${STUB_MULTIWIN:-}" ] && [ "$win" != "win-b" ] && exit 1
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

# Fake curl: STUB_CURL=ok → emit a wham/usage-shaped JSON (percentages from
# STUB_P5/STUB_P7, interpolated raw so "abc"/null/150/-5 are all testable);
# STUB_NOWINDOWS=1 → a response with an empty rate_limit (schema-changed case);
# otherwise fail like `curl -f` on a 4xx/5xx (offline / expired token).
cat > "$ROOT/bin/curl" <<'FAKE'
#!/bin/bash
[ "${STUB_CURL:-fail}" = "ok" ] || exit 1
if [ -n "${STUB_NOWINDOWS:-}" ]; then printf '{"plan_type":"pro","rate_limit":{}}\n'; exit 0; fi
# STUB_WEEKLY_ONLY: the shape OpenAI actually returned 2026-07-13 — the WEEKLY window
# (604800s) sits in primary_window with a null secondary. Duration routing must send
# it to cx7d and mark cx5h n/a (position mapping used to mislabel it as the 5h meter).
if [ -n "${STUB_WEEKLY_ONLY:-}" ]; then
  printf '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":604800,"reset_after_seconds":573314},"secondary_window":null}}\n' "${STUB_P7:-1}"; exit 0
fi
if [ -n "${STUB_SHORT_ONLY:-}" ]; then
  printf '{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":null}}\n' "${STUB_P5:-1}"; exit 0
fi
# Expanded current shape: unrelated spend/credits/additional limits must not alter
# the default Codex short/weekly meters.
if [ -n "${STUB_EXPANDED:-}" ]; then
  printf '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":18000,"reset_at":1999999999},"secondary_window":{"used_percent":%s,"limit_window_seconds":604800,"reset_at":2000999999}},"credits":{"balance":"12"},"spend_control":{"individual_limit":{"used_percent":1}},"additional_rate_limits":[{"limit_name":"review","metered_feature":"reviews","rate_limit":{"primary_window":{"used_percent":88,"limit_window_seconds":86400}}}]}\n' "${STUB_P5:-7}" "${STUB_P7:-3}"; exit 0
fi
# Unknown primary duration must be ignored, never coerced to 0 and routed to cx5h.
if [ -n "${STUB_BAD_DURATION:-}" ]; then
  printf '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":91,"reset_after_seconds":100},"secondary_window":{"used_percent":%s,"limit_window_seconds":604800,"reset_after_seconds":573314}}}\n' "${STUB_P7:-1}"; exit 0
fi
# STUB_SWAP: weekly in primary, 5h in secondary — routing must key on
# limit_window_seconds, NOT position, so cx5h still gets the 5h data and cx7d weekly.
if [ -n "${STUB_SWAP:-}" ]; then
  printf '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":604800,"reset_after_seconds":284962},"secondary_window":{"used_percent":%s,"limit_window_seconds":18000,"reset_after_seconds":6933}}}\n' "${STUB_P7:-3}" "${STUB_P5:-7}"; exit 0
fi
P5="${STUB_P5:-7}"; P7="${STUB_P7:-3}"
printf '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":18000,"reset_after_seconds":6933},"secondary_window":{"used_percent":%s,"limit_window_seconds":604800,"reset_after_seconds":284962}}}\n' "$P5" "$P7"
FAKE
chmod +x "$ROOT/bin/curl"
ln -s "$JQ" "$ROOT/bin/jq"   # keep jq reachable under the restricted PATH

export CODEXTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
# Restricted PATH: stubs first, then core dirs — deliberately NOT /opt/homebrew/bin,
# so the machine's real `curl` can't leak in and hit the network.
PATH="$ROOT/bin:/usr/bin:/bin"
RENAMES="$ROOT/.renames"
PROGRESS="$ROOT/.progress"
AUTH="$ROOT/home/.codex/auth.json"

# auth.json variants: a valid ChatGPT-plan login, an API-key login (not covered by
# wham/usage → treated as not-available), and none.
auth_chatgpt() { printf '{"auth_mode":"chatgpt","tokens":{"access_token":"faketoken","account_id":"acct-123"}}\n' > "$AUTH"; }
auth_apikey()  { printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-fake"}\n' > "$AUTH"; }
no_auth()      { rm -f "$AUTH"; }

pass=0; fail=0
ckcode() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s (exit %s)\n' "$1" "$2"
           else fail=$((fail + 1)); printf '  ✗ %s — exit got %s want %s\n' "$1" "$2" "$3"; fi; }
ckno()   { if [ ! -s "$RENAMES" ]; then pass=$((pass + 1)); printf '  ✓ %s (wrote nothing)\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — unexpected renames:\n%s\n' "$1" "$(cat "$RENAMES")"; fi; }
ckhas()  { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"; fi; }
ckprog() { if grep -q -- "$2" "$PROGRESS" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in progress log:\n%s\n' "$1" "$2" "$(cat "$PROGRESS" 2>/dev/null)"; fi; }
ckprognothas() { if grep -q -- "$2" "$PROGRESS" 2>/dev/null; then fail=$((fail + 1)); printf '  ✗ %s — unexpected [%s] in progress log:\n%s\n' "$1" "$2" "$(cat "$PROGRESS" 2>/dev/null)"
                else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }
ckout()  { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — stdout got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }
ckjq()   { if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — jq [%s] failed for:\n%s\n' "$1" "$3" "$2"; fi; }
reset()  { rm -f "$RENAMES" "$PROGRESS"; }

echo "T1: disabled (USAGE_PROVIDERS without codex) → exit 0, writes nothing"
reset; auth_chatgpt
STUB_CURL=ok USAGE_PROVIDERS="claude" bash "$POLLER" --update; ckcode "disabled --update" "$?" 0
ckno "disabled is a no-op"
out=$(STUB_CURL=ok USAGE_PROVIDERS="claude" bash "$POLLER" --status 2>/dev/null)
ckjq "disabled --status is machine-readable" "$out" '.status == "disabled" and .buckets == []'

echo "T2: not logged in (no ~/.codex/auth.json) → exit 0, nothing"
reset; no_auth
STUB_CURL=ok USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "not-logged-in --update" "$?" 0
ckno "not-logged-in is a no-op"
out=$(STUB_CURL=ok USAGE_PROVIDERS="claude codex" bash "$POLLER" --status 2>/dev/null)
ckjq "not-logged-in --status is uninstalled" "$out" '.status == "uninstalled" and .buckets == []'

echo "T2b: API-key auth (auth_mode!=chatgpt, not covered by wham/usage) → exit 0, nothing"
reset; auth_apikey
STUB_CURL=ok USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "apikey --update" "$?" 0
ckno "apikey mode is a no-op"

echo "T3: logged in + fetch fails (offline / expired token) → exit 1, ⚠ offline stamped"
reset; auth_chatgpt
STUB_CURL=fail USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "offline --update" "$?" 1
ckhas "stamps ⚠" "⚠"
ckprog "offline clears the native bar so the ⚠ title shows through" "CLEAR"
out=$(STUB_CURL=fail USAGE_PROVIDERS="claude codex" bash "$POLLER" --status 2>/dev/null)
ckjq "offline --status is unknown, not no-windows" "$out" '.status == "unknown" and .reason == "usage request failed"'

echo "T4: logged in + populated → exit 0, cx5h/cx7d bars + native progress"
reset; auth_chatgpt
STUB_CURL=ok STUB_P5=33 STUB_P7=12 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "populated --update" "$?" 0
ckhas "cx5h sentinel renamed" "cx5h "
ckhas "cx5h pct" "33%"
ckhas "cx7d pct" "12%"
ckprog "cx5h native progress value (33% → 0.33)" "PROG 0.33"
ckprog "cx7d native progress value (12% → 0.12)" "PROG 0.12"
ckprog "native label uses compact parenthesized countdown" "33% ("
ckprognothas "native label does not repeat resets" "resets"
ckhas "fallback title separates detail from its second-row bar" "|"

echo "T5: response missing rate_limit windows (schema changed) → exit 1, ⚠ stamped"
reset; auth_chatgpt
STUB_CURL=ok STUB_NOWINDOWS=1 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "no-windows --update" "$?" 1
ckhas "stamps ⚠ on no data" "⚠"

echo "T6: malformed used_percent (over-100 / negative) → clamped, exit 0, no crash"
reset; auth_chatgpt
STUB_CURL=ok STUB_P5=150 STUB_P7=-5 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "over/under --update" "$?" 0
ckhas "over-100 clamped to 100%" "100%"
ckhas "negative clamped to 0%" "0%"

echo "T6b: non-numeric / null used_percent → no data, never a plausible 0%"
reset; auth_chatgpt
STUB_CURL=ok STUB_P5='"abc"' STUB_P7=null USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "string/null --update" "$?" 1
ckhas "string/null stamps no data" "⚠ no data"
if grep -q "0%" "$RENAMES" 2>/dev/null; then
  fail=$((fail + 1)); printf '  ✗ string/null painted a plausible 0%%\n'
else pass=$((pass + 1)); printf '  ✓ string/null never paints 0%%\n'; fi
ckprog "malformed used_percent clears stale native bars" "CLEAR"
out=$(STUB_CURL=ok STUB_P5='"abc"' STUB_P7=null USAGE_PROVIDERS="claude codex" bash "$POLLER" --status 2>/dev/null)
ckjq "malformed --status is unknown" "$out" '.status == "unknown" and .reason == "invalid used_percent"'

echo "T7: sentinels in a NON-default window → scanned + renamed via --window"
reset; auth_chatgpt
STUB_CURL=ok STUB_P5=55 STUB_P7=5 STUB_MULTIWIN=1 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "multi-window --update" "$?" 0
ckhas "cx5h renamed in other window" "cx5h "
ckhas "cx5h pct via --window" "55%"

echo "T8: weekly-only shape (primary=weekly 604800, secondary=null) → weekly→cx7d, cx5h=n/a"
reset; auth_chatgpt
STUB_CURL=ok STUB_WEEKLY_ONLY=1 STUB_P7=4 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "weekly-only --update" "$?" 0
ckhas "cx5h stamped n/a (no 5h window)" "cx5h |n/a|"
ckhas "cx7d carries the weekly pct" "cx7d.*4%"
ckprog "cx7d native progress (4% → 0.04)" "PROG 0.04"
ckprog "cx5h progress cleared (n/a → no bar)" "CLEAR"

echo "T9: swapped windows (weekly in primary, 5h in secondary) → routed by DURATION, not position"
reset; auth_chatgpt
STUB_CURL=ok STUB_SWAP=1 STUB_P5=22 STUB_P7=8 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "swapped --update" "$?" 0
ckhas "cx5h gets the 5h pct (22%) despite living in secondary_window" "cx5h.*22%"
ckhas "cx7d gets the weekly pct (8%) despite living in primary_window" "cx7d.*8%"

echo "T9b: missing duration is unknown → never misrouted to cx5h"
reset; auth_chatgpt
STUB_CURL=ok STUB_BAD_DURATION=1 STUB_P7=8 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "bad-duration --update" "$?" 0
ckhas "unknown-duration window is not painted as 91% cx5h" "cx5h |n/a|"
ckhas "numeric weekly window still reaches cx7d" "cx7d.*8%"

echo "T9c: expanded backend shape → unrelated limits/credits are ignored safely"
reset; auth_chatgpt
STUB_CURL=ok STUB_EXPANDED=1 STUB_P5=18 STUB_P7=9 USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "expanded shape --update" "$?" 0
ckhas "default short window survives expanded shape" "cx5h.*18%"
ckhas "default weekly window survives expanded shape" "cx7d.*9%"

echo "T10: --buckets reports the windows the account HAS (drives sentinel creation)"
# cmux-sentinel-setup.sh reads this to skip a sentinel for a window that doesn't
# exist (a dead 'n/a' row still eats a ⌘ key). The FAIL-OPEN half matters most:
# every can't-tell path must print NOTHING, because setup reads empty as "create
# both" — so an expired token or a flaky network can never suppress a real meter.
reset; auth_chatgpt
out=$(STUB_CURL=ok STUB_P5=7 STUB_P7=3 USAGE_PROVIDERS="claude codex" bash "$POLLER" --buckets 2>/dev/null)
ckcode "--buckets both windows" "$?" 0
ckout "both windows → both labels" "$out" "cx5h
cx7d"
ckno "--buckets writes no renames (read-only)"

reset; auth_chatgpt
out=$(STUB_CURL=ok STUB_WEEKLY_ONLY=1 STUB_P7=4 USAGE_PROVIDERS="claude codex" bash "$POLLER" --buckets 2>/dev/null)
ckout "weekly-only (today's Pro shape) → cx7d only, no cx5h" "$out" "cx7d"

out=$(STUB_CURL=ok STUB_WEEKLY_ONLY=1 STUB_P7=4 USAGE_PROVIDERS="claude codex" bash "$POLLER" --status 2>/dev/null)
ckjq "known weekly-only capability is explicit" "$out" '.status == "available" and .buckets == ["cx7d"]'

out=$(STUB_CURL=ok STUB_SHORT_ONLY=1 STUB_P5=4 USAGE_PROVIDERS="claude codex" bash "$POLLER" --status 2>/dev/null)
ckjq "known short-only capability is explicit" "$out" '.status == "available" and .buckets == ["cx5h"]'

reset; auth_chatgpt
out=$(STUB_CURL=ok STUB_BAD_DURATION=1 STUB_P7=4 USAGE_PROVIDERS="claude codex" bash "$POLLER" --buckets 2>/dev/null)
ckout "unknown duration is never a positive cx5h bucket" "$out" "cx7d"

reset; auth_chatgpt
out=$(STUB_CURL=fail USAGE_PROVIDERS="claude codex" bash "$POLLER" --buckets 2>/dev/null)
ckout "fail-open: offline/expired prints nothing (setup keeps both)" "$out" ""

reset; no_auth
out=$(STUB_CURL=ok USAGE_PROVIDERS="claude codex" bash "$POLLER" --buckets 2>/dev/null)
ckout "fail-open: not logged in prints nothing" "$out" ""

reset; auth_chatgpt
out=$(STUB_CURL=ok STUB_NOWINDOWS=1 USAGE_PROVIDERS="claude codex" bash "$POLLER" --buckets 2>/dev/null)
ckout "fail-open: schema change (no windows) prints nothing" "$out" ""
out=$(STUB_CURL=ok STUB_NOWINDOWS=1 USAGE_PROVIDERS="claude codex" bash "$POLLER" --status 2>/dev/null)
ckjq "schema change is explicit unknown for diagnostics" "$out" '.status == "unknown" and .buckets == []'

echo "T11: absent window + absent sentinel → quiet no-op (the post-gate steady state)"
# Once setup skips cx5h (no 5h window on Codex Pro), the poller must NOT treat the
# missing sentinel as a misconfiguration — launchd runs this every 5 min and would
# otherwise fail forever over a meter that's correctly absent.
reset; auth_chatgpt
STUB_CURL=ok STUB_WEEKLY_ONLY=1 STUB_P7=6 STUB_NO_CX5H=1 \
  USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "n/a bucket, no sentinel → exit 0" "$?" 0
ckhas "cx7d still painted" "cx7d.*6%"
if grep -q "cx5h" "$RENAMES" 2>/dev/null; then
  fail=$((fail + 1)); printf '  ✗ wrote a cx5h rename despite no cx5h sentinel\n'
else pass=$((pass + 1)); printf '  ✓ no cx5h write attempted\n'; fi

echo "T12: LIVE window + absent sentinel → still a hard error (real misconfiguration)"
# The other half of the rule: tolerating a missing sentinel must not mask a genuinely
# broken install where the window DOES exist and the meter is simply missing.
reset; auth_chatgpt
STUB_CURL=ok STUB_P5=44 STUB_P7=9 STUB_NO_CX5H=1 \
  USAGE_PROVIDERS="claude codex" bash "$POLLER" --update 2>/dev/null; ckcode "live window, no sentinel → dies" "$?" 1

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
