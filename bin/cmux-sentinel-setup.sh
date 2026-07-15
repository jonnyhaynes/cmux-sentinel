#!/bin/bash
# cmux-sentinel-setup.sh — idempotently create the usage-meter "sentinel" workspaces.
#
# Creating + naming the sentinels by hand is the most error-prone install step (a
# typo'd label = a silently blank panel). This does it for you: for each ENABLED
# provider (USAGE_PROVIDERS, default "claude") it creates an idle workspace titled
# with the right label and a "managed by …" description — but only if one doesn't
# already exist (resolved by title across ALL windows), so re-running is safe.
#
# It also PARKS the sentinels so they don't steal ⌘1…⌘9 (see "shortcut layout"
# below). It does NOT update the bars (that's the poller's job) and never closes
# anything. Run it once after install, then run the poller(s) + reload the sidebar.
#
# Config: ~/.config/cmux/usage-sentinels.env (labels + USAGE_PROVIDERS).
#         SENTINEL_LAYOUT=0 (or --no-layout) skips the shortcut layout pass.
set -uo pipefail

LAYOUT="${SENTINEL_LAYOUT:-1}"
for a in "$@"; do
  case "$a" in
    --no-layout) LAYOUT=0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;   # the header block above
    *) echo "unknown flag: $a (try --no-layout)" >&2; exit 2 ;;
  esac
done

CFG="$HOME/.config/cmux"
SENTINELS_ENV="$CFG/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && . "$SENTINELS_ENV"
LABEL_5H="${SENTINEL_5H_LABEL:-5h}";   LABEL_7D="${SENTINEL_7D_LABEL:-7d}"
LABEL_CX5H="${SENTINEL_CX5H_LABEL:-cx5h}"; LABEL_CX7D="${SENTINEL_CX7D_LABEL:-cx7d}"
PROVIDERS="${USAGE_PROVIDERS:-claude}"

have() { command -v "$1" >/dev/null 2>&1; }
have cmux || { echo "cmux not on PATH" >&2; exit 1; }
have jq   || { echo "jq is required" >&2; exit 1; }
cmux ping &>/dev/null || { echo "cmux isn't responding — is the app running?" >&2; exit 1; }

# Does a sentinel titled with this label already exist in ANY window? (Same
# title-label match the pollers + sidebar use; launchd-less, window-agnostic.)
exists() { # $1 = label
  local w
  cmux workspace list --json 2>/dev/null \
    | jq -e --arg l "$1" 'any(.workspaces[]; .title == $l or (.title | startswith($l + " ")))' >/dev/null 2>&1 && return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    cmux workspace list --window "$w" --json 2>/dev/null \
      | jq -e --arg l "$1" 'any(.workspaces[]; .title == $l or (.title | startswith($l + " ")))' >/dev/null 2>&1 && return 0
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
  return 1
}

rc=0
ensure() { # $1 = label  $2 = description
  if exists "$1"; then echo "  = '$1' already exists — leaving it"; return 0; fi
  if cmux workspace create --name "$1" --description "$2" --cwd "$HOME" --focus false >/dev/null 2>&1; then
    echo "  + created '$1' sentinel"
  else
    echo "  ✗ failed to create '$1' sentinel" >&2; rc=1
  fi
}

echo "cmux-sentinel setup — providers: $PROVIDERS"
case " $PROVIDERS " in *" claude "*)
  ensure "$LABEL_5H" "Claude 5-hour rate meter — managed by cmux-claude-usage.sh; leave idle"
  ensure "$LABEL_7D" "Claude weekly rate meter — managed by cmux-claude-usage.sh; leave idle"
  ;; esac
case " $PROVIDERS " in *" codex "*)
  ensure "$LABEL_CX5H" "Codex 5-hour rate meter — managed by cmux-codex-usage.sh; leave idle"
  ensure "$LABEL_CX7D" "Codex weekly rate meter — managed by cmux-codex-usage.sh; leave idle"
  ;; esac

# ── shortcut layout ───────────────────────────────────────────────────────────
# A sentinel is an ORDINARY workspace to cmux — "sentinel" is a concept that only
# exists in our sidebar's predicates — so every meter silently eats one of the
# ⌘1…⌘9 workspace keys (verified: ⌘6→cx7d, ⌘7→cx5h, ⌘9→7d). There's no way to make
# one weightless (cmux's TabManager.tabs is the raw array — no hidden/archived
# concept), so the only lever is ORDER. That lever is free: sentinel index has zero
# effect on what renders (the sidebar's meter panel sorts by title label, and the
# workspace list filters meters out), so this reorders nothing the user can see.
#
# cmux maps ⌘1…⌘8 to indices 0…7 and ⌘9 to the LAST workspace (count-1) — indices
# 8…count-2 are the "keyless band". Hence the invariant:
#
#   sentinels live in the keyless band, and the LAST workspace is a real one.
#
# That puts 9/9 keys on real workspaces. Sentinels at the very bottom would cost
# ⌘9; at the top they'd cost ⌘1…⌘4. Relative order of real workspaces is PRESERVED:
# we only push meters down and then re-park the workspace that was already last.
#
# Refs are positional handles with no stable UUID behind them (0.64.15 removed
# those), so re-resolve by TITLE before every move rather than caching a ref.

# Every label the sidebar hides — including disabled providers' leftovers, which
# still exist as workspaces and still eat ⌘ keys. Array, not a string: a label is
# user-configurable and could contain a space.
ALL_LABELS=("$LABEL_5H" "$LABEL_7D" "$LABEL_CX5H" "$LABEL_CX7D")
labels_json() { printf '%s\n' "${ALL_LABELS[@]}" | jq -R . | jq -s .; }

ws_json() { # $1 = window ("" = default)
  if [ -n "${1:-}" ]; then cmux workspace list --window "$1" --json 2>/dev/null
  else cmux workspace list --json 2>/dev/null; fi
}
ws_reorder() { # $1 = ref  $2 = index  $3 = window ("")
  if [ -n "${3:-}" ]; then cmux reorder-workspace --workspace "$1" --index "$2" --window "$3" >/dev/null 2>&1
  else cmux reorder-workspace --workspace "$1" --index "$2" >/dev/null 2>&1; fi
}

# jq: does a title belong to a sentinel? Exact label ("5h", pre-first-poll) or
# label + " " + bar ("5h ███ 41%") — the same match the sidebar and pollers use, so
# a real workspace named e.g. "5h-notes" is correctly NOT a meter.
# shellcheck disable=SC2016  # jq program — $ls/$t/$l are jq vars, must NOT expand in bash
JQ_IS_SENT='def is_sent($ls): . as $t | any($ls[]; . as $l | $t == $l or ($t | startswith($l + " ")));'

# Which window holds the sentinels? Echoes "" for the default window (a bare ref
# suffices) or the window id; returns 1 when there are none anywhere.
sentinel_window() {
  local w
  ws_json "" | jq -e --argjson ls "$(labels_json)" \
    "$JQ_IS_SENT"' any(.workspaces[]; .title | is_sent($ls))' >/dev/null 2>&1 && { printf ''; return 0; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    ws_json "$w" | jq -e --argjson ls "$(labels_json)" \
      "$JQ_IS_SENT"' any(.workspaces[]; .title | is_sent($ls))' >/dev/null 2>&1 && { printf '%s' "$w"; return 0; }
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
  return 1
}

layout() {
  local win json total ref lbl reals last_real
  win=$(sentinel_window) || { echo "  = no sentinels to park"; return 0; }

  # Push every sentinel to the end, re-resolving its ref by title each time (a
  # move renumbers refs). Label order is deterministic; order AMONG meters is
  # irrelevant — the panel sorts them by label.
  for lbl in "${ALL_LABELS[@]}"; do
    json=$(ws_json "$win"); [ -n "$json" ] || return 0
    ref=$(printf '%s' "$json" | jq -r --arg l "$lbl" \
      '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
    [ -n "$ref" ] || continue
    total=$(printf '%s' "$json" | jq -r '.workspaces | length' 2>/dev/null)
    [ "${total:-0}" -gt 1 ] || continue
    ws_reorder "$ref" "$((total - 1))" "$win" && echo "  ↓ parked '$lbl' below the workspace list"
  done

  # Re-park the workspace that was already last so it takes count-1 and answers ⌘9.
  # Needs 2+ real workspaces: with 0 there's nothing to anchor, and with 1 we'd be
  # pushing the user's only workspace below the meters to buy nothing.
  json=$(ws_json "$win"); [ -n "$json" ] || return 0
  reals=$(printf '%s' "$json" | jq -r --argjson ls "$(labels_json)" \
    "$JQ_IS_SENT"' [.workspaces[] | select(.title | is_sent($ls) | not)] | length' 2>/dev/null)
  if [ "${reals:-0}" -lt 2 ]; then
    echo "  = too few workspaces to anchor ⌘9 — meters still take some keys"
    return 0
  fi
  last_real=$(printf '%s' "$json" | jq -r --argjson ls "$(labels_json)" \
    "$JQ_IS_SENT"' [.workspaces[] | select(.title | is_sent($ls) | not)] | sort_by(.index) | last | .ref' 2>/dev/null)
  total=$(printf '%s' "$json" | jq -r '.workspaces | length' 2>/dev/null)
  [ -n "$last_real" ] && [ "${total:-0}" -gt 1 ] || return 0
  ws_reorder "$last_real" "$((total - 1))" "$win" && echo "  ✓ ⌘9 anchored on your last workspace"
}

if [ "$LAYOUT" = 1 ]; then
  echo
  echo "shortcut layout — keeping the meters out of ⌘1…⌘9:"
  layout
fi

# Auto-naming guard: cmux can auto-generate workspace titles; if that's ON it could
# rename a sentinel and break its label prefix (→ silently blank meter). There's no
# readable per-workspace auto-title state and the setter is gated by the global
# setting, so we can only DETECT + warn: an empty-params probe reports the global
# state without mutating anything.
probe=$(cmux rpc workspace.set_auto_title '{}' 2>&1 || true)
case "$probe" in
  *[Dd]isabled*[Ss]ettings*) echo "  ✓ cmux auto-naming is OFF globally — sentinel titles are safe" ;;
  *) echo "  ⚠ cmux auto-naming may be ON — disable it in Settings so it can't rename a sentinel and blank its meter" ;;
esac

echo
echo "Next — paint the bars and reload:"
case " $PROVIDERS " in *" claude "*) echo "  ~/bin/cmux-claude-usage.sh --update"; esac
case " $PROVIDERS " in *" codex "*)  echo "  ~/bin/cmux-codex-usage.sh --update"; esac
echo "  cmux sidebar reload"
exit "$rc"
