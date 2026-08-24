#!/bin/bash
# cmux-commandcode-usage.sh — feed Command Code (commandcode.ai) rate-limit
# utilization into the cmux custom sidebar via two "sentinel" workspaces' progress
# bars (5h + weekly). Fourth provider, sibling of cmux-claude-usage.sh /
# cmux-codex-usage.sh / cmux-amp-usage.sh; same display channel and gating contract.
#
# Data source: Command Code's billing endpoint
#   GET https://api.commandcode.ai/alpha/billing/credits
#   Authorization: Bearer <apiKey>
# which returns `windowLimits.fiveHour {used,cap,resetAt}` and
# `windowLimits.weekly {used,cap,resetAt}` — an explicit used/cap pair per rolling
# window plus a reset timestamp (epoch MILLISECONDS; 0 when the window is empty).
# util% = round(100 * used / cap). This is the same 5h/weekly shape as Claude, so
# the two meters mirror the Claude panel exactly. The endpoint is the same one the
# `commandcode` CLI itself calls (buildUsageEndpoint → /alpha/billing/credits); it
# is unofficial/alpha, so the shape may change and is validated before use.
#
# The API key is read FRESH from ~/.commandcode/auth.json each run (the CLI writes
# it there on `commandcode login`). It is never printed or persisted by this poller.
#
# Display channel (identical to the other pollers): each metric rides a dedicated
# idle "sentinel" workspace. Every --update writes a native `progress` value + a
# compact label AND renames the TITLE to a restart-proof fallback such as
# "cc5h |39% (4h 35m)|█████░░░░░░░░░". The sidebar matches "cc5h "/"cc7d " via
# `.hasPrefix`, draws human labels + native bars in the top panel, and hides the
# sentinels from the normal list. `|` separates fallback detail from fallback bar.
#
# Identity: cmux dropped stable workspace UUIDs (0.64.15), so each sentinel is
# re-resolved every run by its title label — the one stable anchor the sidebar also
# keys on. See resolve_ref(). Nothing is ever stored.
#
# Modes:
#   --print     fetch + print parsed values (verification; no cmux writes)
#   --raw       fetch + print raw JSON (the API key is NOT included)
#   --update    fetch + paint both sentinel workspaces (for launchd)
#   --buckets   print the labels this account HAS a live window for (one per line);
#               prints NOTHING when it can't tell. For cmux-sentinel-setup.sh.
#
# Provider gating: this is the COMMANDCODE provider and SELF-GATES so an uninstalled
# or disabled Command Code never crashes or spams the launchd .err. Existing
# sentinels are a separate concern: they keep a panel visible until closed, and
# doctor flags them.
#   * disabled (USAGE_PROVIDERS doesn't list "commandcode") → exit 0, do nothing.
#   * not installed (no ~/.commandcode/auth.json) → exit 0, do nothing. "Not
#     installed" ≠ "key rejected": a REVOKED key (auth.json exists but the fetch
#     401s) is a TRANSIENT state and still stamps "⚠ offline".
#
# Config (overridable): ~/.config/cmux/usage-sentinels.env
#   SENTINEL_CC5H_LABEL=cc5h   SENTINEL_CC7D_LABEL=cc7d
#   USAGE_PROVIDERS="commandcode claude"   # add "commandcode" to enable this one

set -uo pipefail

API_BASE="${COMMANDCODE_API_BASE:-https://api.commandcode.ai}"
CREDITS_PATH="/alpha/billing/credits"
AUTH_JSON="${COMMANDCODE_AUTH_JSON:-$HOME/.commandcode/auth.json}"
SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"

# Title-label anchors for the two Command Code sentinels (the poller writes each
# title starting with its label, and the sidebar matches the same prefix).
# Overridable via the env file; sane defaults so the poller works zero-config.
# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
LABEL_CC5H="${SENTINEL_CC5H_LABEL:-cc5h}"
LABEL_CC7D="${SENTINEL_CC7D_LABEL:-cc7d}"

PROVIDER_ID="commandcode"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"
USAGE_STATE_DIR="${CMUX_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-sentinel}/usage"

die() { echo "ERR: $*" >&2; exit 1; }

# Record only a COMPLETE successful --update. Best-effort: a freshness-stamp failure
# must never turn an already-painted meter into a failed poll.
record_success() {
  local tmp
  mkdir -p "$USAGE_STATE_DIR" || return 1
  tmp=$(mktemp "$USAGE_STATE_DIR/.${PROVIDER_ID}.XXXXXX") || return 1
  printf '%s\n' "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$USAGE_STATE_DIR/$PROVIDER_ID.last-success" || { rm -f "$tmp"; return 1; }
}

# Is THIS provider enabled in the configured set? (space-padded substring match)
provider_enabled() {
  case " $USAGE_PROVIDERS " in *" $PROVIDER_ID "*) return 0 ;; *) return 1 ;; esac
}

# Is Command Code installed/logged in HERE? True iff auth.json exists and carries a
# non-empty apiKey — regardless of whether the key is currently valid. No key
# source ⇒ Command Code was never set up here ⇒ nothing to meter (distinct from a
# REVOKED key, which is a transient 'offline').
provider_available() {
  [ -f "$AUTH_JSON" ] || return 1
  local k; k=$(jq -r '.apiKey // empty' "$AUTH_JSON" 2>/dev/null)
  [ -n "$k" ]
}

# ── sentinel plumbing (identical contract to the other pollers) ──────────────

# Resolve a sentinel's CURRENT ref by its title label — refs (workspace:N) rotate
# across cmux restarts, so this re-resolves every run and nothing is ever stored.
# Matches the BARE label too so a freshly-created sentinel ("cc5h", no bar yet) can
# bootstrap. Multi-window: `workspace list` is window-scoped and launchd has no
# window context, so try the default window, then scan every window. Prints
# "<ref>\t<window>" — window EMPTY for the default window.
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

# Resolve by label (across windows) and rename. Return: 0 ok, 10 not-found, 11 rejected.
_paint() { # $1 = label  $2 = new title
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  # ${wargs[@]+"${wargs[@]}"} expands to nothing when empty — required under `set -u`
  # on bash 3.2 (macOS /bin/bash), where a bare "${wargs[@]}" errors.
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  return 0
}

# Resolve ONCE, then write BOTH the title (restart-proof anchor + unicode-bar
# fallback) and the native progress bar the sidebar draws a ProgressView from.
_meter_write() { # $1=label $2=title $3=progress_value(0..1) $4=progress_label
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  cmux set-progress "$3" --label "$4" --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
  return 0
}

# Drop a sentinel's progress bar so the sidebar falls back to its TITLE text.
_clear_progress() { # $1 = label
  local rw ref win wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 0
  [ -n "$win" ] && wargs=(--window "$win")
  cmux clear-progress --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
}

# Paint ONE meter, recording WHY it failed instead of exiting on the spot, so one
# closed sentinel can't freeze the other meter (see the Claude poller's note).
MISSING=(); REJECTED=()
paint_meter() { # $1=label $2=title $3=progress_value(0..1) $4=progress_label
  local err rc
  err=$(_meter_write "$1" "$2" "$3" "$4"); rc=$?
  case "$rc" in
    0)  return 0 ;;
    10) MISSING+=("$1") ;;
    *)  REJECTED+=("$1 (${err:-no detail})") ;;
  esac
  return 1
}

read_key() {
  [ -f "$AUTH_JSON" ] || die "no Command Code credentials ($AUTH_JSON)"
  local k; k=$(jq -r '.apiKey // empty' "$AUTH_JSON" 2>/dev/null)
  [ -n "$k" ] || die "could not extract apiKey from $AUTH_JSON"
  printf '%s' "$k"
}

# fetch_credits's EXIT STATUS is the failure class (same design as the Claude
# poller): it rides the status because the caller runs it in a command
# substitution, from which no variable assignment escapes.
FETCH_OK=0; FETCH_AUTH=2; FETCH_RATE=3; FETCH_SERVER=4; FETCH_NET=5; FETCH_HTTP=6

fetch_credits() { # $1 = api key. Prints body on success; else returns a FETCH_* class.
  local out rc code body
  out=$(curl -sS --max-time 15 -w '\n%{http_code}' \
    -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" \
    "$API_BASE$CREDITS_PATH" 2>/dev/null); rc=$?
  code="${out##*$'\n'}"
  case "$code" in
    [0-9][0-9][0-9]) body="${out%$'\n'*}" ;;
    *) code=""; body="$out" ;;
  esac
  case "$code" in
    ''|000)  [ "$rc" -eq 0 ] && { printf '%s' "$body"; return "$FETCH_OK"; }
             return "$FETCH_NET" ;;
    2??)     printf '%s' "$body"; return "$FETCH_OK" ;;
  esac
  # The status is useful in the launchd log; the response BODY never is (could carry
  # account detail), so only the code is ever emitted.
  echo "credits endpoint returned HTTP $code" >&2
  case "$code" in
    401|403) return "$FETCH_AUTH" ;;
    429)     return "$FETCH_RATE" ;;
    5??)     return "$FETCH_SERVER" ;;
    *)       return "$FETCH_HTTP" ;;
  esac
}

# epoch MILLISECONDS -> compact "in" duration: "now" | "37m" | "4h 12m" | "2d 3h".
# 0/empty/null means "no active window" (fresh, nothing used) → "—".
humanize_ms() {
  local ms="$1" now diff d h m target
  [ -n "$ms" ] && [ "$ms" != "null" ] || { echo "—"; return; }
  [ "$ms" -gt 0 ] 2>/dev/null || { echo "—"; return; }
  target=$(( ms / 1000 )); now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
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

# Severity is now conveyed by COLOURING the sidebar label text (red ≥90%, amber
# ≥70%) — see meterLabelColor() in sidebars/workspaces.swift — so the poller no
# longer appends a 🔴/🟡 emoji dot. Kept as a no-op so callers/interpolation are
# unchanged and the label stays clean text ("94% (2d 19h)").
sev_dot() { :; }

# used/cap -> clamped integer percent (0-100), rounded, entirely in jq so untrusted
# API numbers are never interpolated into a shell/awk program. cap<=0 → 0 (an empty
# window is 0% used, never a divide-by-zero or a fabricated bar).
pct_of() { # $1=used $2=cap
  jq -rn --arg u "${1:-0}" --arg c "${2:-0}" '
    (($u | tonumber?) // 0) as $used
    | (($c | tonumber?) // 0) as $cap
    | (if $cap > 0 then 100 * $used / $cap else 0 end)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

to_frac() { jq -rn --argjson p "${1:-0}" '$p / 100' 2>/dev/null || printf '0'; }

# Best-effort: stamp both sentinels offline so a frozen bar is obvious, and drop the
# native bar so the "⚠ offline" title shows through.
mark_offline() {
  local reason="${1:-offline}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_CC5H" "$LABEL_CC5H |⚠ ${reason}|" >/dev/null 2>&1 || true
  _paint "$LABEL_CC7D" "$LABEL_CC7D |⚠ ${reason}|" >/dev/null 2>&1 || true
  _clear_progress "$LABEL_CC5H"; _clear_progress "$LABEL_CC7D"
}

main() {
  local mode="${1:---print}" key json

  # Provider gate (robustness): never crash or error-spam for a provider that's
  # turned off or not installed. A clean exit does not remove existing sentinels.
  if ! provider_enabled; then
    echo "commandcode disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    echo "Command Code not installed here (no $AUTH_JSON with an apiKey) — nothing to meter" >&2
    exit 0
  fi

  key=$(read_key) || { [ "$mode" = "--update" ] && mark_offline "no key"; exit 1; }

  local marker why frc
  json=$(fetch_credits "$key"); frc=$?
  if [ "$frc" -ne "$FETCH_OK" ]; then
    case "$frc" in
      "$FETCH_AUTH")   marker="auth"; why="the billing endpoint rejected the API key (401/403) — re-authenticate with \`commandcode login\`. If it persists, the alpha endpoint may have changed." ;;
      "$FETCH_RATE")   marker="rate limit"; why="the billing endpoint is throttling (429) — raise StartInterval in ~/Library/LaunchAgents/com.cmux-commandcode-usage.plist and reload the job" ;;
      "$FETCH_SERVER") marker="api down"; why="api.commandcode.ai returned a server error — transient, the next poll retries" ;;
      "$FETCH_NET")    marker="offline"; why="couldn't reach api.commandcode.ai (offline, DNS, or timeout)" ;;
      *)               marker="offline"; why="the billing endpoint returned an unexpected HTTP status (logged above)" ;;
    esac
    [ "$mode" = "--update" ] && mark_offline "$marker"
    die "credits request failed: $why"
  fi

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    return
  fi

  # The endpoint is alpha. Validate the shape before converting anything: require
  # windowLimits with numeric caps for both windows, so a renamed/missing field
  # degrades to an honest "offline" rather than a believable 0% meter.
  if ! printf '%s' "$json" | jq -e '
      def valid_window($k):
        (.windowLimits[$k]) as $w
        | (($w | type) == "object")
          and (($w.cap | type) == "number")
          and (($w.used | type) == "number");
      valid_window("fiveHour") and valid_window("weekly")
    ' >/dev/null 2>&1; then
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "credits response is missing windowLimits.fiveHour/weekly (endpoint schema changed?)"
  fi

  local fh_used fh_cap fh_reset sd_used sd_cap sd_reset fh_pct sd_pct fh_human sd_human
  fh_used=$(printf '%s' "$json" | jq -r '.windowLimits.fiveHour.used // 0')
  fh_cap=$(printf '%s' "$json"  | jq -r '.windowLimits.fiveHour.cap // 0')
  fh_reset=$(printf '%s' "$json" | jq -r '.windowLimits.fiveHour.resetAt // 0')
  sd_used=$(printf '%s' "$json" | jq -r '.windowLimits.weekly.used // 0')
  sd_cap=$(printf '%s' "$json"  | jq -r '.windowLimits.weekly.cap // 0')
  sd_reset=$(printf '%s' "$json" | jq -r '.windowLimits.weekly.resetAt // 0')
  fh_pct=$(pct_of "$fh_used" "$fh_cap"); sd_pct=$(pct_of "$sd_used" "$sd_cap")
  fh_human=$(humanize_ms "$fh_reset"); sd_human=$(humanize_ms "$sd_reset")

  # Both windows always exist on this plan, so both sentinels should exist.
  if [ "$mode" = "--buckets" ]; then
    echo "$LABEL_CC5H"
    echo "$LABEL_CC7D"
    return
  fi

  if [ "$mode" = "--print" ]; then
    echo "cc5h  ${fh_pct}%  · ${fh_used}/${fh_cap} · resets ${fh_human}"
    echo "cc7d  ${sd_pct}%  · ${sd_used}/${sd_cap} · resets ${sd_human}"
    return
  fi

  if [ "$mode" = "--update" ]; then
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    local fh_bar sd_bar fh_dot sd_dot fh_frac sd_frac fh_lbl sd_lbl
    fh_bar=$(make_bar "$fh_pct" 14); fh_dot=$(sev_dot "$fh_pct"); fh_frac=$(to_frac "$fh_pct")
    sd_bar=$(make_bar "$sd_pct" 14); sd_dot=$(sev_dot "$sd_pct"); sd_frac=$(to_frac "$sd_pct")
    fh_lbl="${fh_pct}% (${fh_human})${fh_dot}"
    sd_lbl="${sd_pct}% (${sd_human})${sd_dot}"
    local painted=0 wrote=""
    paint_meter "$LABEL_CC5H" "$LABEL_CC5H |${fh_lbl}|${fh_bar}" "$fh_frac" "$fh_lbl" \
      && { painted=$((painted + 1)); wrote="${wrote}${LABEL_CC5H}=${fh_pct}% (${fh_human})  "; }
    paint_meter "$LABEL_CC7D" "$LABEL_CC7D |${sd_lbl}|${sd_bar}" "$sd_frac" "$sd_lbl" \
      && { painted=$((painted + 1)); wrote="${wrote}${LABEL_CC7D}=${sd_pct}% (${sd_human})  "; }
    [ "${#REJECTED[@]}" -gt 0 ] && die "cmux rejected the rename for: ${REJECTED[*]}"
    [ "$painted" -gt 0 ] || die "no Command Code sentinel workspace exists in any window — create them: ~/bin/cmux-sentinel-setup.sh"
    record_success || echo "WARN: meters updated, but couldn't record Command Code freshness in $USAGE_STATE_DIR" >&2
    echo "updated: ${wrote%  }"
    [ "${#MISSING[@]}" -gt 0 ] && die "no sentinel workspace for: ${MISSING[*]} — create it: ~/bin/cmux-sentinel-setup.sh (a sentinel is titled with its label, e.g. \"${MISSING[0]}\")"
    return 0
  fi

  die "unknown mode '$mode' (use --print | --raw | --update | --buckets)"
}

main "$@"
