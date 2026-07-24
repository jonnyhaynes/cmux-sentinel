#!/bin/bash
# cmux-codex-usage.sh — feed OpenAI Codex (ChatGPT-plan) rate-limit utilization
# into the cmux custom sidebar via two "sentinel" workspaces (cx5h + cx7d).
# Sibling of cmux-claude-usage.sh; same display channel, HTTP data source.
#
# Data source: Codex's own usage endpoint — the SAME one the CLI's built-in
# 60-second poller hits (openai/codex#10869):
#   GET https://chatgpt.com/backend-api/wham/usage
# Auth is the ChatGPT OAuth token Codex stores (and refreshes) in
# ~/.codex/auth.json (auth_mode="chatgpt"). The response carries LIVE server-side
# utilization for the windows our sentinels model:
#   { "rate_limit": {
#       "primary_window":   { "used_percent": 7, "limit_window_seconds": 18000,  "reset_at": <epoch> },
#       "secondary_window": { "used_percent": 3, "limit_window_seconds": 604800, "reset_at": <epoch> } } }
#   18000s = 5h → cx5h; 604800s = weekly → cx7d. CRITICAL: route each window to a
#   sentinel by its ACTUAL limit_window_seconds, NOT by primary/secondary POSITION.
#   OpenAI reshaped this live (2026-07-13): a Pro account returned the WEEKLY window
#   in primary_window with secondary_window=null, so the old position map dumped
#   weekly data into the 5h meter. A window may be absent for either bucket (renders
#   "n/a", not a fake 0%). Short (<1d) → cx5h; long (>=1d) → cx7d.
#
# WHY HTTP, not the old rollout files: up to codex-cli ~0.140 the CLI wrote a
# per-turn `rate_limits` snapshot into ~/.codex/sessions/**/rollout-*.jsonl and we
# read the newest (see .claude/research/2026-06-19-codex-usage-data-source.md).
# On codex-cli 0.142.x that source is DEAD for real usage: rollouts are only
# written by the interactive TUI (not `codex exec`, which is how Claude Code drives
# Codex — openai/codex#14880), and the fresh data moved into sqlite logs that don't
# expose the payload queryably. So a machine that uses Codex via Claude Code shows a
# weeks-stale bar. The wham/usage endpoint is account-server-side, so it's correct
# for ANY usage pattern. Decision: .claude/research/2026-07-06-codex-usage-api-source.md.
#
# The OAuth token is read FRESH from ~/.codex/auth.json each run (Codex refreshes it
# there). It is never printed or persisted.
#
# Modes:
#   --print     fetch + print parsed values (no cmux writes)
#   --raw       fetch + print the raw wham/usage JSON
#   --update    fetch + paint both sentinel workspaces (title + native progress bar)
#   --buckets   print the labels this account HAS a live window for (one per line);
#               prints NOTHING when it can't tell. For cmux-sentinel-setup.sh.
#   --status    print one stable JSON capability result for diagnostics:
#               available | unknown | disabled | uninstalled. Unlike --buckets,
#               this distinguishes a known bucket set from a can't-tell result.
#
# Provider gating: this is the CODEX provider; it SELF-GATES so Codex being absent
# or disabled never errors. The sidebar hides a provider only when its sentinels
# are absent; an existing sentinel remains visible and doctor flags it.
#   * disabled (USAGE_PROVIDERS doesn't list "codex"; default is "claude") → exit 0.
#   * not logged in on a ChatGPT plan (no ~/.codex/auth.json, or auth_mode != chatgpt,
#     e.g. API-key users whom wham/usage doesn't cover) → exit 0, do nothing.
#   * logged in but the fetch fails (expired token / offline) → transient "⚠ offline".
# Config: ~/.config/cmux/usage-sentinels.env
#   SENTINEL_CX5H_LABEL=cx5h   SENTINEL_CX7D_LABEL=cx7d
#   USAGE_PROVIDERS="claude codex"   # add "codex" to enable this poller

set -uo pipefail

USAGE_ENDPOINT="https://chatgpt.com/backend-api/wham/usage"
AUTH_JSON="${CODEX_AUTH_JSON:-$HOME/.codex/auth.json}"
SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"

# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
LABEL_CX5H="${SENTINEL_CX5H_LABEL:-cx5h}"
LABEL_CX7D="${SENTINEL_CX7D_LABEL:-cx7d}"

PROVIDER_ID="codex"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"

# Token + account id read fresh from auth.json each run (set by read_token).
CODEX_TOKEN=""; CODEX_ACCOUNT=""

die() { echo "ERR: $*" >&2; exit 1; }

status_json() { # $1=status  $2=reason  $3=has-5h(0/1)  $4=has-7d(0/1)
  jq -cn --arg status "$1" --arg reason "$2" \
    --arg b5 "${3:-0}" --arg b7 "${4:-0}" \
    --arg l5 "$LABEL_CX5H" --arg l7 "$LABEL_CX7D" '
      {status: $status,
       buckets: [if $b5 == "1" then $l5 else empty end,
                 if $b7 == "1" then $l7 else empty end],
       reason: $reason}'
}

provider_enabled() {
  case " $USAGE_PROVIDERS " in *" $PROVIDER_ID "*) return 0 ;; *) return 1 ;; esac
}

# Is Codex usable HERE? True iff logged into a ChatGPT plan: auth.json exists with
# auth_mode="chatgpt" and an access token. API-key users (auth_mode="apikey") aren't
# metered by wham/usage, so they're treated as "nothing to meter" (distinct from an
# EXPIRED chatgpt token, which still has creds and falls through to '⚠ offline').
provider_available() {
  [ -f "$AUTH_JSON" ] || return 1
  local mode tok
  mode=$(jq -r '.auth_mode // empty' "$AUTH_JSON" 2>/dev/null)
  tok=$(jq -r '.tokens.access_token // empty' "$AUTH_JSON" 2>/dev/null)
  [ "$mode" = "chatgpt" ] && [ -n "$tok" ]
}

# Resolve a sentinel's current ref by its title label (refs rotate across cmux
# restarts — same scheme as the Claude poller). Matches the BARE label too: a
# freshly-created sentinel is titled just "cx5h" (no bar yet), and
# startswith("cx5h ") alone would never match it, so the first --update could
# never bootstrap it. Multi-window: `workspace list` is window-scoped and launchd
# has no window context, so try the default window first, then scan every window.
# Prints "<ref>\t<window>" — window EMPTY for the default window, else the window
# id so the caller can pass --window (makes the positional ref unambiguous). Empty
# output means no sentinel in any window.
resolve_ref() { # $1 = label
  local lbl="$1" ref w
  ref=$(cmux workspace list --json 2>/dev/null \
    | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
  [ -n "$ref" ] && { printf '%s\t' "$ref"; return; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    ref=$(cmux workspace list --window "$w" --json 2>/dev/null \
      | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
    [ -n "$ref" ] && { printf '%s\t%s' "$ref" "$w"; return; }
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
}

# Resolve a sentinel by label (across windows) and rename it to $2. Echoes cmux's
# stderr on a rejected rename. Return: 0 ok, 10 sentinel-not-found, 11 rejected.
_paint() { # $1 = label  $2 = new title
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  # ${wargs[@]+"${wargs[@]}"} expands to nothing when the array is empty — required
  # under `set -u` on bash 3.2 (macOS /bin/bash), where a bare "${wargs[@]}" errors.
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  return 0
}

# Resolve a sentinel ONCE, then write BOTH its title (restart-proof anchor +
# unicode-bar fallback) and its native progress bar (value 0..1 + clean label),
# which cmux 0.64.17 passes to the sidebar interpreter. The sidebar draws a native
# ProgressView from it. Mirrors cmux-claude-usage.sh; see
# .claude/research/2026-07-06-conductor-sidebar-analysis.md. Return: 0/10/11 as _paint.
_meter_write() { # $1=label  $2=title  $3=progress_value(0..1)  $4=progress_label
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  cmux set-progress "$3" --label "$4" --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
  return 0
}

# Drop a sentinel's progress bar so the sidebar falls back to its TITLE (e.g. the
# "⚠ offline" marker) instead of a stale native bar. Best-effort.
_clear_progress() { # $1 = label
  local rw ref win wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 0
  [ -n "$win" ] && wargs=(--window "$win")
  cmux clear-progress --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
}

# access token + account id, read FRESH each run (Codex refreshes auth.json).
# Never printed/persisted. Sets CODEX_TOKEN / CODEX_ACCOUNT.
read_token() {
  # Return instead of exiting so main can preserve --status's machine-readable
  # contract if auth.json changes between provider_available and this fresh read.
  [ -f "$AUTH_JSON" ] || return 1
  CODEX_TOKEN=$(jq -r '.tokens.access_token // empty' "$AUTH_JSON" 2>/dev/null)
  CODEX_ACCOUNT=$(jq -r '.tokens.account_id // empty' "$AUTH_JSON" 2>/dev/null)
  [ -n "$CODEX_TOKEN" ] || return 1
}

# Hit wham/usage with the same auth shape the Codex CLI uses. -f → curl fails
# (non-zero) on 4xx/5xx so an expired token surfaces as a fetch failure (→ offline).
fetch_usage() {
  curl -fsS --max-time 15 "$USAGE_ENDPOINT" \
    -H "Authorization: Bearer $CODEX_TOKEN" \
    -H "chatgpt-account-id: $CODEX_ACCOUNT" \
    -H "originator: codex_cli_rs" \
    -H "User-Agent: codex_cli_rs" \
    -H "Content-Type: application/json"
}

# epoch -> compact "in" duration: "now" | "37m" | "4h 12m" | "2d 3h"
humanize_until() {
  local target="$1" now diff d h m
  [ -n "$target" ] || { echo "?"; return; }
  case "$target" in '' | *[!0-9]*) echo "?"; return ;; esac
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

# A window's reset epoch: prefer reset_at (absolute), else now + reset_after_seconds.
reset_epoch() { # $1 = window JSON
  local at rel
  at=$(printf '%s' "$1" | jq -r '.reset_at // empty' 2>/dev/null)
  case "$at" in '' | null) : ;; *[!0-9]*) at="" ;; esac
  if [ -n "$at" ]; then printf '%s' "$at"; return; fi
  rel=$(printf '%s' "$1" | jq -r '.reset_after_seconds // empty' 2>/dev/null)
  case "$rel" in '' | *[!0-9]*) printf ''; return ;; esac
  printf '%s' "$(( $(date +%s) + rel ))"
}

# integer percent (0-100) -> unicode block bar with 1/8-cell resolution.
make_bar() {
  local pct="${1:-0}" width="${2:-10}" eighths cell rem i bar="" start
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  eighths=$(( pct * width * 8 / 100 ))
  cell=$(( eighths / 8 )); rem=$(( eighths % 8 ))
  for ((i = 0; i < cell; i++)); do bar+="█"; done
  if [ "$cell" -lt "$width" ]; then
    case "$rem" in
      1) bar+="▏" ;; 2) bar+="▎" ;; 3) bar+="▍" ;; 4) bar+="▌" ;;
      5) bar+="▋" ;; 6) bar+="▊" ;; 7) bar+="▉" ;; *) bar+="░" ;;
    esac
    start=$(( cell + 1 ))
    for ((i = start; i < width; i++)); do bar+="░"; done
  fi
  printf '%s' "$bar"
}

# Coerce a validated numeric value to a clamped integer percent (0-100), rounded.
# main rejects missing/null/string used_percent before this runs, so schema drift
# becomes explicit no-data rather than a believable 0% meter.
to_pct() { # $1 = raw numeric value
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

# clamped integer percent (0-100) -> fraction (0..1) for `set-progress`. $1 is a
# sanitized int from to_pct, so argjson is safe; guard to 0 otherwise.
to_frac() { jq -rn --argjson p "${1:-0}" '$p / 100' 2>/dev/null || printf '0'; }

# Amber/red dot only when a limit is getting close (TRAILS the bar so the title
# still starts with the label that resolve_ref + the sidebar anchor on).
sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then printf ' 🔴'
  elif [ "$p" -ge 70 ]; then printf ' 🟡'; fi
}

# Best-effort: stamp both sentinels offline so a frozen bar is obvious, and drop the
# native bar so the "⚠ offline" title shows through. Needs the socket; no-ops if it
# can't reach cmux or resolve a sentinel. The marker still starts with the label, so
# the sidebar keeps recognising it and resolve_ref still finds it.
mark_offline() {
  local reason="${1:-offline}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_CX5H" "$LABEL_CX5H |⚠ ${reason}|" >/dev/null 2>&1 || true
  _paint "$LABEL_CX7D" "$LABEL_CX7D |⚠ ${reason}|" >/dev/null 2>&1 || true
  _clear_progress "$LABEL_CX5H"; _clear_progress "$LABEL_CX7D"
}

# Write ONE Codex sentinel for --update: a real meter (unicode-bar title fallback +
# native progress) when its window exists, or an honest "n/a" (no bar, progress
# cleared) when OpenAI didn't return that window (e.g. no 5h window on a Pro plan).
# Keeps the label prefix so resolve_ref + the sidebar anchor still match. Dies on a
# missing/rejected sentinel, exactly like the inline path it replaced.
_update_bucket() { # $1=label  $2=na(0/1)  $3=pct  $4=human_reset
  local label="$1" na="$2" pct="${3:-0}" human="${4:-?}" bar dot frac detail err rc
  if [ "$na" = 1 ]; then
    err=$(_paint "$label" "$label |n/a|"); rc=$?
    # No sentinel for a window the account doesn't HAVE is the intended steady state,
    # not a misconfiguration: setup deliberately skips creating one (see its
    # `ensure_live`), and OpenAI dropped the 5h window for Codex Pro. Dying here would
    # make the launchd poller fail every 5 min over a meter nobody asked for. A
    # missing sentinel for a LIVE window still dies below — that one IS a real error.
    [ "$rc" = 10 ] && return 0
    [ "$rc" = 11 ] && die "rename rejected for $label sentinel: ${err:-no detail}"
    _clear_progress "$label"
    return
  fi
  bar=$(make_bar "$pct" 14); dot=$(sev_dot "$pct"); frac=$(to_frac "$pct")
  detail="${pct}% (${human})${dot}"
  err=$(_meter_write "$label" "$label |${detail}|${bar}" "$frac" "$detail"); rc=$?
  [ "$rc" = 10 ] && die "no '$label' sentinel workspace (title \"$label\" or starting \"$label \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
  [ "$rc" = 11 ] && die "rename rejected for $label sentinel: ${err:-no detail}"
}

main() {
  local mode="${1:---print}" json

  # Provider gate (robustness): a disabled or not-logged-in provider is a clean
  # no-op — no error spam. Existing sentinels are not removed here, so panel
  # visibility still follows sentinel presence. An EXPIRED token is NOT caught
  # here (auth.json still exists) — it falls through to the transient '⚠ offline'.
  if ! provider_enabled; then
    if [ "$mode" = "--status" ]; then status_json "disabled" "provider disabled" 0 0; exit 0; fi
    echo "codex disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    if [ "$mode" = "--status" ]; then status_json "uninstalled" "ChatGPT-plan login unavailable" 0 0; exit 0; fi
    echo "Codex not logged in on a ChatGPT plan (no ~/.codex/auth.json chatgpt token) — nothing to meter" >&2
    exit 0
  fi

  read_token || {
    if [ "$mode" = "--status" ]; then status_json "unknown" "token unavailable" 0 0; exit 0; fi
    [ "$mode" = "--update" ] && mark_offline "no token"
    exit 1
  }
  json=$(fetch_usage) || {
    if [ "$mode" = "--status" ]; then status_json "unknown" "usage request failed" 0 0; exit 0; fi
    [ "$mode" = "--update" ] && mark_offline "offline"
    die "wham/usage request failed (token expired? endpoint changed? offline?)"
  }

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    return
  fi

  # Route each rate-limit window to a sentinel by its ACTUAL limit_window_seconds,
  # NOT by primary/secondary POSITION (OpenAI reordered the shape — see the header).
  # Short window (<1 day) → cx5h; long (>=1 day) → cx7d. Either bucket may be empty
  # (that meter renders "n/a"); only both-empty is a hard error.
  local wins win5h win7d pct5 pct7 h5 h7 na5=0 na7=0
  wins=$(printf '%s' "$json" | jq -c '
      [ .rate_limit.primary_window, .rate_limit.secondary_window ] | map(select(. != null))' 2>/dev/null)
  # A missing/malformed duration is unknown, not zero seconds. Coercing it to 0
  # positively misclassified schema drift as cx5h in both --update and --buckets.
  win5h=$(printf '%s' "${wins:-[]}" | jq -c 'map(select((.limit_window_seconds | type) == "number" and .limit_window_seconds <  86400)) | first // empty' 2>/dev/null)
  win7d=$(printf '%s' "${wins:-[]}" | jq -c 'map(select((.limit_window_seconds | type) == "number" and .limit_window_seconds >= 86400)) | first // empty' 2>/dev/null)
  if [ -z "$win5h" ] && [ -z "$win7d" ]; then
    if [ "$mode" = "--status" ]; then status_json "unknown" "no recognized rate-limit windows" 0 0; return; fi
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "wham/usage returned no rate_limit windows (endpoint schema changed?)"
  fi

  # A live, duration-routed window must carry a numeric used_percent. The old
  # permissive conversion mapped string/null/missing values to 0%, turning an
  # upstream schema break into a healthy-looking meter. Treat the whole response
  # as unknown: the two windows are one account snapshot and stale sibling bars
  # are more misleading than an explicit no-data state.
  if { [ -n "$win5h" ] && ! printf '%s' "$win5h" | jq -e '(.used_percent | type) == "number"' >/dev/null 2>&1; } \
    || { [ -n "$win7d" ] && ! printf '%s' "$win7d" | jq -e '(.used_percent | type) == "number"' >/dev/null 2>&1; }; then
    if [ "$mode" = "--status" ]; then status_json "unknown" "invalid used_percent" 0 0; return; fi
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "wham/usage returned a missing or non-numeric used_percent (endpoint schema changed?)"
  fi
  if [ -n "$win5h" ]; then
    pct5=$(to_pct "$(printf '%s' "$win5h" | jq -r '.used_percent // empty' 2>/dev/null)")
    h5=$(humanize_until "$(reset_epoch "$win5h")")
  else na5=1; fi
  if [ -n "$win7d" ]; then
    pct7=$(to_pct "$(printf '%s' "$win7d" | jq -r '.used_percent // empty' 2>/dev/null)")
    h7=$(humanize_until "$(reset_epoch "$win7d")")
  else na7=1; fi

  if [ "$mode" = "--status" ]; then
    status_json "available" "" "$((1 - na5))" "$((1 - na7))"
    return
  fi

  # Which buckets does this account actually HAVE? Consumed by cmux-sentinel-setup.sh
  # so it only creates sentinels for real windows: OpenAI dropped the 5h window for
  # Pro, and a permanently-"n/a" cx5h isn't free — it's an ordinary workspace, so it
  # still eats one of the ⌘1…⌘9 keys to show nothing. Detected, never hardcoded, so
  # setup can recreate the sentinel if OpenAI restores the window.
  #
  # Prints ONLY on the paths that positively parsed a window; every can't-tell path
  # (disabled, not logged in, expired token, offline, schema change) exits earlier
  # with no stdout. That asymmetry IS the contract — the caller reads empty as "don't
  # know, create both", so a bad network can never silently delete a meter.
  if [ "$mode" = "--buckets" ]; then
    [ "$na5" = 1 ] || echo "$LABEL_CX5H"
    [ "$na7" = 1 ] || echo "$LABEL_CX7D"
    return
  fi

  if [ "$mode" = "--print" ]; then
    if [ "$na5" = 1 ]; then echo "cx5h  n/a  · no 5h window"; else echo "cx5h  ${pct5}%  · resets ${h5}"; fi
    if [ "$na7" = 1 ]; then echo "cx7d  n/a  · no weekly window"; else echo "cx7d  ${pct7}%  · resets ${h7}"; fi
    return
  fi

  if [ "$mode" = "--update" ]; then
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    # Each bucket writes a real meter, or an honest "n/a" when its window is absent.
    _update_bucket "$LABEL_CX5H" "$na5" "${pct5:-0}" "${h5:-?}"
    _update_bucket "$LABEL_CX7D" "$na7" "${pct7:-0}" "${h7:-?}"
    local sum5 sum7
    if [ "$na5" = 1 ]; then sum5="n/a"; else sum5="${pct5}% (${h5})"; fi
    if [ "$na7" = 1 ]; then sum7="n/a"; else sum7="${pct7}% (${h7})"; fi
    echo "updated: ${LABEL_CX5H}=${sum5}  ${LABEL_CX7D}=${sum7}"
    return
  fi

  die "unknown mode: $mode (use --print | --raw | --update | --buckets | --status)"
}

main "$@"
