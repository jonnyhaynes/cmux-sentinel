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
# utilization for the two windows our sentinels model:
#   { "rate_limit": {
#       "primary_window":   { "used_percent": 7, "limit_window_seconds": 18000,  "reset_at": <epoch> },
#       "secondary_window": { "used_percent": 3, "limit_window_seconds": 604800, "reset_at": <epoch> } } }
#   primary = 18000s = 5h; secondary = 604800s = weekly.
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
#
# Provider gating: this is the CODEX provider; it SELF-GATES so it never errors or
# shows a panel when Codex is absent/disabled (the sidebar hides a provider whose
# sentinels are missing):
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

# access token + account id, read FRESH each run (Codex refreshes auth.json).
# Never printed/persisted. Sets CODEX_TOKEN / CODEX_ACCOUNT.
read_token() {
  [ -f "$AUTH_JSON" ] || die "no Codex auth (~/.codex/auth.json — run: codex login)"
  CODEX_TOKEN=$(jq -r '.tokens.access_token // empty' "$AUTH_JSON" 2>/dev/null)
  CODEX_ACCOUNT=$(jq -r '.tokens.account_id // empty' "$AUTH_JSON" 2>/dev/null)
  [ -n "$CODEX_TOKEN" ] || die "no access_token in ~/.codex/auth.json (run: codex login)"
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

# epoch -> compact "in" duration: "now" | "37m" | "4h12m" | "2d3h"
humanize_until() {
  local target="$1" now diff d h m
  [ -n "$target" ] || { echo "?"; return; }
  case "$target" in '' | *[!0-9]*) echo "?"; return ;; esac
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
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

# Coerce an arbitrary value to a clamped integer percent (0-100), rounded, entirely
# in jq — the response is an unofficial endpoint, so a missing/null/string
# used_percent must clamp to 0 rather than break or inject the shell.
to_pct() { # $1 = raw value (may be empty, null, or non-numeric)
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

# Amber/red dot only when a limit is getting close (TRAILS the bar so the title
# still starts with the label that resolve_ref + the sidebar anchor on).
sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then printf ' 🔴'
  elif [ "$p" -ge 70 ]; then printf ' 🟡'; fi
}

# Best-effort: stamp both sentinels offline so a frozen bar is obvious. Needs the
# socket; no-ops if it can't reach cmux or resolve a sentinel. The marker still
# starts with the label, so the sidebar keeps recognising it and resolve_ref still
# finds it.
mark_offline() {
  local reason="${1:-offline}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_CX5H" "$LABEL_CX5H  ⚠ ${reason}" >/dev/null 2>&1 || true
  _paint "$LABEL_CX7D" "$LABEL_CX7D  ⚠ ${reason}" >/dev/null 2>&1 || true
}

main() {
  local mode="${1:---print}" json

  # Provider gate (robustness): a disabled or not-logged-in provider is a clean
  # no-op — no error spam, no broken panel. The sidebar hides a provider whose
  # sentinels are absent, so exit 0 here = no panel. An EXPIRED token is NOT caught
  # here (auth.json still exists) — it falls through to the transient '⚠ offline'.
  if ! provider_enabled; then
    echo "codex disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    echo "Codex not logged in on a ChatGPT plan (no ~/.codex/auth.json chatgpt token) — nothing to meter" >&2
    exit 0
  fi

  read_token || { [ "$mode" = "--update" ] && mark_offline "no token"; exit 1; }
  json=$(fetch_usage) || {
    [ "$mode" = "--update" ] && mark_offline "offline"
    die "wham/usage request failed (token expired? endpoint changed? offline?)"
  }

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    return
  fi

  local p5 p7 e5 e7 pct5 pct7 h5 h7
  p5=$(printf '%s' "$json" | jq -c '.rate_limit.primary_window // empty' 2>/dev/null)
  p7=$(printf '%s' "$json" | jq -c '.rate_limit.secondary_window // empty' 2>/dev/null)
  if [ -z "$p5" ] && [ -z "$p7" ]; then
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "wham/usage returned no rate_limit windows (endpoint schema changed?)"
  fi
  pct5=$(to_pct "$(printf '%s' "$p5" | jq -r '.used_percent // empty' 2>/dev/null)")
  pct7=$(to_pct "$(printf '%s' "$p7" | jq -r '.used_percent // empty' 2>/dev/null)")
  e5=$(reset_epoch "$p5"); e7=$(reset_epoch "$p7")
  h5=$(humanize_until "$e5"); h7=$(humanize_until "$e7")

  if [ "$mode" = "--print" ]; then
    echo "cx5h  ${pct5}%  · resets ${h5}"
    echo "cx7d  ${pct7}%  · resets ${h7}"
    return
  fi

  if [ "$mode" = "--update" ]; then
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    local bar5 bar7 dot5 dot7 err rc
    bar5=$(make_bar "$pct5" 10); bar7=$(make_bar "$pct7" 10)
    dot5=$(sev_dot "$pct5"); dot7=$(sev_dot "$pct7")
    # _paint resolves each sentinel by label (across windows) and writes the title;
    # rc 10 = sentinel missing (tell the user to create it), rc 11 = cmux rejected.
    err=$(_paint "$LABEL_CX5H" "$LABEL_CX5H ${bar5} ${pct5}% ${h5}${dot5}"); rc=$?
    [ "$rc" = 10 ] && die "no '$LABEL_CX5H' sentinel workspace (title \"$LABEL_CX5H\" or starting \"$LABEL_CX5H \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
    [ "$rc" = 11 ] && die "rename rejected for $LABEL_CX5H sentinel: ${err:-no detail}"
    err=$(_paint "$LABEL_CX7D" "$LABEL_CX7D ${bar7} ${pct7}% ${h7}${dot7}"); rc=$?
    [ "$rc" = 10 ] && die "no '$LABEL_CX7D' sentinel workspace (title \"$LABEL_CX7D\" or starting \"$LABEL_CX7D \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
    [ "$rc" = 11 ] && die "rename rejected for $LABEL_CX7D sentinel: ${err:-no detail}"
    echo "updated: ${LABEL_CX5H}=${pct5}% (${h5})  ${LABEL_CX7D}=${pct7}% (${h7})"
    return
  fi

  die "unknown mode: $mode (use --print | --raw | --update)"
}

main "$@"
