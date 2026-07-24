#!/bin/bash
# cmux-sentinel-doctor.sh — verify the whole cmux-sentinel pipeline is wired.
# READ-ONLY: it changes nothing, just reports. The project's failure modes are
# all SILENT (blank sidebar, stale marker, hooks that never fire), so this turns
# "why isn't it updating?" into one diagnostic. Run: `make doctor` or directly.
#
# No secrets here: sentinels are resolved by their title label at runtime.
set -u

CFG="$HOME/.config/cmux"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }
note() { printf '  \033[2m•\033[0m %s\n' "$1"; }   # neutral info, doesn't affect status
have() { command -v "$1" >/dev/null 2>&1; }
check_launchd_job() { # $1=provider  $2=job label
  local provider="$1" job="$2"
  if launchctl list 2>/dev/null | grep -qF -- "$job"; then
    ok "$provider poller loaded ($job)"
  else
    warn "$provider poller not loaded — launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$job.plist"
  fi
}

echo "cmux-sentinel doctor"

echo "• cmux"
if have cmux; then
  if cmux ping &>/dev/null; then ok "cmux present and responding"
  else bad "cmux installed but 'cmux ping' failed — is the app running?"; fi
else bad "cmux not on PATH"; fi

echo "• sidebar"
if [ -f "$CFG/sidebars/workspaces.swift" ]; then
  ok "sidebar deployed at ~/.config/cmux/sidebars/workspaces.swift"
  if have cmux && cmux sidebar validate workspaces &>/dev/null; then ok "sidebar interprets against validate's synthetic data"
  else warn "sidebar did not validate — run: cmux sidebar validate workspaces"; fi
  if grep -Eq 'w\.title\.hasPrefix\("(5h|7d) "\)' "$CFG/sidebars/workspaces.swift"; then :
  else warn "deployed sidebar is missing its isClaudeMeter title anchors — usage panel won't render"; fi
else bad "sidebar not deployed (run ./install.sh)"; fi

echo "• working-state bridge"
inst="$HOME/.claude/hooks/cmux-bridge.sh"
amp_bridge_file="$HOME/.config/cmux-sentinel/cmux-bridge.sh"
amp_plugin="$HOME/.config/amp/plugins/cmux-sentinel-amp.ts"
repo="$HERE/../hooks/cmux-bridge.sh"
if [ -f "$inst" ]; then
  ok "bridge installed at ~/.claude/hooks/cmux-bridge.sh"
  if [ -f "$repo" ]; then
    if diff -q "$repo" "$inst" >/dev/null 2>&1; then ok "installed bridge matches this repo"
    else warn "installed bridge differs from repo — re-run: WITH_BRIDGE=1 ./install.sh"; fi
  elif grep -q '_sweep_orphan_marks' "$inst"; then ok "installed bridge looks current"
  else warn "installed bridge is an older version (no restart self-heal)"; fi
  settings="$HOME/.claude/settings.json"
  if [ -f "$settings" ] && have jq; then
    missing=""
    # Notification drives the ❓ "waiting on a permission prompt" state, so it's a
    # key event too — without it a blocked session never shows "asking…".
    for ev in SessionStart UserPromptSubmit PreToolUse Notification PreCompact PostCompact Stop; do
      jq -e --arg e "$ev" '(.hooks[$e] // []) | tostring | contains("cmux-bridge")' "$settings" >/dev/null 2>&1 \
        || missing="$missing $ev"
    done
    if [ -z "$missing" ]; then ok "bridge registered for all key hook events"
    else warn "bridge NOT registered for:$missing — re-run 'WITH_BRIDGE=1 ./install.sh' to auto-wire it (or paste README's hooks block), then RESTART Claude Code"; fi
  else warn "can't check hook registration (need ~/.claude/settings.json + jq)"; fi
elif [ -f "$amp_bridge_file" ]; then
  note "Claude bridge not installed — expected for an Amp-only setup"
else
  warn "no agent-state bridge installed — working/compacting rows are off (use --with-bridge or --with-amp)"
fi
if [ -f "$amp_bridge_file" ]; then
  ok "Amp shared bridge installed at ~/.config/cmux-sentinel/cmux-bridge.sh"
  if [ -f "$repo" ] && ! diff -q "$repo" "$amp_bridge_file" >/dev/null 2>&1; then
    warn "Amp shared bridge differs from repo — re-run: WITH_AMP=1 ./install.sh"
  fi
elif [ -f "$amp_plugin" ] && [ -f "$inst" ]; then
  warn "Amp still uses the legacy Claude bridge path — re-run: WITH_AMP=1 ./install.sh"
elif [ -f "$amp_plugin" ]; then
  warn "Amp plugin is installed but its shared bridge is missing — re-run: WITH_AMP=1 ./install.sh"
fi

echo "• auto-refresh"
# cmux.json is JSONC (comments), so grep rather than jq-parse it.
if [ -f "$CFG/cmux.json" ]; then
  if grep -Eq '"socketControlMode"[[:space:]]*:[[:space:]]*"automation"' "$CFG/cmux.json"; then
    ok "socketControlMode: automation (external renames allowed)"
  else warn "cmux.json has no socketControlMode: automation — auto-refresh renames may be rejected"; fi
else warn "no ~/.config/cmux/cmux.json — can't confirm automation mode"; fi

# Usage meters are provider-gated: a provider's panel shows IFF its sentinels
# exist, the poller only maintains them when the provider is installed + enabled
# (USAGE_PROVIDERS), and the sidebar hides any provider with no sentinels. So this
# section cross-checks installed × enabled × sentinel-present and flags only the
# states that are actually wrong (e.g. a leftover panel for an uninstalled
# provider). Sentinels are resolved by TITLE LABEL (cmux 0.64.15 dropped stable
# UUIDs — see the poller's resolve_ref); labels + provider set are env-overridable.
echo "• usage meters (providers)"
envf="$CFG/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$envf" ] && . "$envf"
lbl5="${SENTINEL_5H_LABEL:-5h}"; lbl7="${SENTINEL_7D_LABEL:-7d}"
providers="${USAGE_PROVIDERS:-claude}"

# Match the pollers/setup: workspace lists are window-scoped, while launchd and
# the doctor may have no default-window context. Return "ref<TAB>window" and keep
# the window empty when the default lookup found it.
resolve_ref() { # $1 = title label
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

close_hint() { # $1 = ref  $2 = window (empty for the caller/default window)
  if [ -n "${2:-}" ]; then
    printf 'cmux workspace close %q --window %q' "$1" "$2"
  else
    printf 'cmux workspace close %q' "$1"
  fi
}

claude_installed() {
  security find-generic-password -s "Claude Code-credentials" -w &>/dev/null && return 0
  [ -f "$HOME/.claude/.credentials.json" ] && return 0
  return 1
}
case " $providers " in *" claude "*) claude_on=1 ;; *) claude_on=0 ;; esac
if claude_installed; then claude_inst=1; else claude_inst=0; fi

if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then
  ok "claude: installed + enabled → meters active"
  check_launchd_job "claude" "com.cmux-claude-usage"
elif [ "$claude_on" = 1 ]; then
  warn "claude: enabled but NOT installed here — poller exits cleanly; any existing sentinels remain until closed"
else
  warn "claude: disabled via USAGE_PROVIDERS=\"$providers\" — poller skips it"
fi

if have cmux && have jq; then
  for lbl in "$lbl5" "$lbl7"; do
    rw="$(resolve_ref "$lbl")"; IFS=$'\t' read -r ref ref_win <<<"$rw"
    where="$ref"; [ -n "$ref_win" ] && where="$where in window $ref_win"
    close_cmd="$(close_hint "$ref" "$ref_win")"
    if [ -n "$ref" ]; then
      if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then ok "'$lbl' sentinel present ($where)"
      else warn "'$lbl' sentinel present ($where) but claude is off/uninstalled — close it to hide the panel: $close_cmd"; fi
    else
      if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it (see install.sh)"
      else ok "no '$lbl' sentinel — panel hidden by design (claude off/uninstalled)"; fi
    fi
  done
else warn "cmux or jq unavailable — can't check sentinels"; fi

# Codex provider — same installed × enabled × sentinel cross-check. The wham/usage
# endpoint requires a ChatGPT-mode auth.json; API-key mode has no account allowance.
lblcx5="${SENTINEL_CX5H_LABEL:-cx5h}"; lblcx7="${SENTINEL_CX7D_LABEL:-cx7d}"
codex_installed() {
  [ -f "$HOME/.codex/auth.json" ] || return 1
  jq -e '.auth_mode == "chatgpt" and ((.tokens.access_token // "") != "")' "$HOME/.codex/auth.json" >/dev/null 2>&1
}
case " $providers " in *" codex "*) codex_on=1 ;; *) codex_on=0 ;; esac
if codex_installed; then codex_inst=1; else codex_inst=0; fi

if [ "$codex_on" = 1 ] && [ "$codex_inst" = 1 ]; then
  ok "codex: installed + enabled → meters active"
  check_launchd_job "codex" "com.cmux-codex-usage"
elif [ "$codex_on" = 1 ]; then
  warn "codex: enabled but NOT installed here — poller exits cleanly; any existing sentinels remain until closed"
elif [ "$codex_inst" = 1 ]; then
  ok "codex: installed but not enabled — add it to USAGE_PROVIDERS (\"claude codex\") to show its meters"
else
  ok "codex: not installed and not enabled — nothing to do"
fi

if have cmux && have jq; then
  # A sentinel is only MISSING if the account actually has that window: setup
  # deliberately skips one OpenAI doesn't return (it dropped 5h for Codex Pro), so
  # nagging to "create it" would be a permanent false alarm — and a doctor that cries
  # wolf gets ignored, which costs us the real warnings. Ask the poller's structured
  # status mode: available carries a KNOWN bucket set; unknown means offline/expired/
  # schema drift and must RETAIN the current layout without suggesting creation or
  # removal. `--buckets` intentionally cannot make that distinction because setup
  # needs its older fail-open empty-output contract.
  cx_cap=""; cx_status="unknown"; cx_reason="status unavailable"; cx_live=""
  if [ "$codex_on" != 1 ]; then
    cx_status="disabled"; cx_reason="provider disabled"
  elif [ "$codex_inst" != 1 ]; then
    cx_status="uninstalled"; cx_reason="ChatGPT-plan login unavailable"
  else
    [ -x "$HERE/cmux-codex-usage.sh" ] && cx_cap=$("$HERE/cmux-codex-usage.sh" --status 2>/dev/null)
    if printf '%s' "$cx_cap" | jq -e '.status | type == "string"' >/dev/null 2>&1; then
      cx_status=$(printf '%s' "$cx_cap" | jq -r '.status')
      cx_reason=$(printf '%s' "$cx_cap" | jq -r '.reason // ""')
      [ "$cx_status" = "available" ] && cx_live=$(printf '%s' "$cx_cap" | jq -r '.buckets[]?')
    fi
  fi
  if [ "$codex_inst" = 1 ] && [ "$cx_status" = "unknown" ]; then
    note "codex capability unknown (${cx_reason:-offline or schema changed}) — retaining the current sentinel layout"
  fi
  for lbl in "$lblcx5" "$lblcx7"; do
    rw="$(resolve_ref "$lbl")"; IFS=$'\t' read -r ref ref_win <<<"$rw"
    where="$ref"; [ -n "$ref_win" ] && where="$where in window $ref_win"
    close_cmd="$(close_hint "$ref" "$ref_win")"
    lbl_live=1
    [ "$cx_status" = "available" ] && ! printf '%s\n' "$cx_live" | grep -qxF -- "$lbl" && lbl_live=0
    if [ -n "$ref" ]; then
      if [ "$codex_on" != 1 ]; then warn "'$lbl' sentinel present ($where) but codex is disabled — close it to hide the panel: $close_cmd"
      elif [ "$codex_inst" != 1 ]; then warn "'$lbl' sentinel present ($where) but codex is uninstalled — close it to hide the panel: $close_cmd"
      elif [ "$lbl_live" = 0 ]; then warn "'$lbl' sentinel present ($where) but your plan has no such window — it'll read 'n/a' forever and still eats a ⌘ key: $close_cmd"
      else ok "'$lbl' sentinel present ($where)"; fi
    elif [ "$codex_on" = 1 ] && [ "$codex_inst" = 1 ]; then
      if [ "$cx_status" = "unknown" ]; then note "no '$lbl' sentinel — capability unknown, so the doctor is retaining this layout"
      elif [ "$lbl_live" = 0 ]; then ok "no '$lbl' sentinel — correct, your plan has no such window"
      else warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it (see install.sh)"; fi
    fi
  done
fi

# Amp provider — same installed × enabled × sentinel cross-check. "Installed" is
# the CLI plus a credentials file (existence only, never read): an expired login
# still has the file, so it stays a transient offline rather than a false
# "uninstalled". Amp meters a MONTHLY allowance, not rolling windows, and the orb
# meter only exists when AMP_ORB_METER=1. Keep that local policy even when
# --buckets returns empty/can't-tell; fail-open must never enable an optional meter.
lblampu="${SENTINEL_AMPU_LABEL:-ampu}"; lblampo="${SENTINEL_AMPO_LABEL:-ampo}"
amp_installed() { command -v amp >/dev/null 2>&1 && [ -s "$HOME/.local/share/amp/secrets.json" ]; }
case " $providers " in *" amp "*) amp_on=1 ;; *) amp_on=0 ;; esac
if amp_installed; then amp_inst=1; else amp_inst=0; fi

if [ "$amp_on" = 1 ] && [ "$amp_inst" = 1 ]; then
  ok "amp: installed + enabled → meters active"
  check_launchd_job "amp" "com.cmux-amp-usage"
elif [ "$amp_on" = 1 ]; then
  warn "amp: enabled but NOT installed/logged in here — poller exits cleanly; any existing sentinels remain until closed"
elif [ "$amp_inst" = 1 ]; then
  ok "amp: installed but not enabled — add it to USAGE_PROVIDERS (\"claude amp\") to show its meters"
else
  ok "amp: not installed and not enabled — nothing to do"
fi

if have cmux && have jq; then
  amp_live=""
  if [ "$amp_on" = 1 ] && [ "$amp_inst" = 1 ] && [ -x "$HERE/cmux-amp-usage.sh" ]; then
    amp_live=$("$HERE/cmux-amp-usage.sh" --buckets 2>/dev/null)
  fi
  for lbl in "$lblampu" "$lblampo"; do
    rw="$(resolve_ref "$lbl")"; IFS=$'\t' read -r ref ref_win <<<"$rw"
    where="$ref"; [ -n "$ref_win" ] && where="$where in window $ref_win"
    close_cmd="$(close_hint "$ref" "$ref_win")"
    lbl_live=1
    [ -n "$amp_live" ] && ! printf '%s\n' "$amp_live" | grep -qxF -- "$lbl" && lbl_live=0
    [ "$lbl" = "$lblampo" ] && [ "${AMP_ORB_METER:-0}" != 1 ] && lbl_live=0
    if [ -n "$ref" ]; then
      if [ "$amp_on" != 1 ]; then warn "'$lbl' sentinel present ($where) but amp is disabled — close it to hide the panel: $close_cmd"
      elif [ "$amp_inst" != 1 ]; then warn "'$lbl' sentinel present ($where) but amp is uninstalled — close it to hide the panel: $close_cmd"
      elif [ "$lbl_live" = 0 ]; then warn "'$lbl' sentinel present ($where) but it isn't metered (orb meter off, or no such allowance) — it'll read 'n/a' forever and still eats a ⌘ key: $close_cmd"
      else ok "'$lbl' sentinel present ($where)"; fi
    elif [ "$amp_on" = 1 ] && [ "$amp_inst" = 1 ]; then
      if [ "$lbl_live" = 0 ]; then ok "no '$lbl' sentinel — correct, it isn't metered"
      else warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it (see install.sh)"; fi
    fi
  done
fi

# ── ⌘N shortcut layout ────────────────────────────────────────────────────────
# Mirrors cmux's WorkspaceShortcutMapper (Sources/App/TerminalDirectoryOpenSupport.swift;
# re-verified unchanged on 0.64.19): ⌘1…⌘8 select indices 0…7, and ⌘9 ALWAYS selects
# the LAST workspace (count-1) — so indices 8…count-2 are the "keyless band".
#
# A sentinel is an ordinary workspace to cmux ("sentinel" only exists in our sidebar's
# predicates), so a meter on a keyed index silently EATS that ⌘ key.
# bin/cmux-sentinel-setup.sh parks them in the band, but that's a one-shot pass: CLOSING
# workspaces above a meter shifts it up, and the invariant decays with no symptom beyond
# a ⌘ key doing something unexpected. Hence a check — this is exactly the class of silent
# failure the doctor exists for. Read-only by design: we report, setup fixes. (Deliberately
# NOT auto-repaired in the pollers — re-asserting order every 5min would fight manual
# drag-reordering; see CLAUDE.md.)
echo "• ⌘N shortcut layout"
if have cmux && have jq; then
  lay_labels="$(printf '%s\n' "$lbl5" "$lbl7" "$lblcx5" "$lblcx7" "$lblampu" "$lblampo" | jq -R . | jq -s .)"
  check_layout() { # $1 = window id; empty means default-window fallback
    local win="$1" ctx="" lay eaten n_ws n_meters first_meter slack
    if [ -n "$win" ]; then
      lay="$(cmux workspace list --window "$win" --json 2>/dev/null)"; ctx=" in window $win"
    else
      lay="$(cmux workspace list --json 2>/dev/null)"
    fi
    # Digits eaten by a meter, computed straight off .index — never off the ref,
    # which is an insertion-order handle and does NOT equal display position.
    eaten="$(printf '%s' "$lay" | jq -r --argjson ls "$lay_labels" '
        (.workspaces | length) as $n
        | [ .workspaces[]
            | select(.title as $t | $ls | any(. as $l | $t == $l or ($t | startswith($l + " "))))
            | .index
            | if . == $n - 1 then "⌘9" elif . <= 7 then "⌘\(. + 1)" else empty end ]
        | unique | join(", ")' 2>/dev/null)"
    n_ws="$(printf '%s' "$lay" | jq -r '.workspaces | length' 2>/dev/null)"
    n_meters="$(printf '%s' "$lay" | jq -r --argjson ls "$lay_labels" '
        [ .workspaces[] | select(.title as $t | $ls | any(. as $l | $t == $l or ($t | startswith($l + " ")))) ] | length' 2>/dev/null)"

    if [ -z "${lay:-}" ] || [ -z "${n_ws:-}" ]; then
      warn "couldn't read the workspace list$ctx — skipping layout check"
    elif [ "${n_meters:-0}" = 0 ]; then
      note "no meters$ctx — nothing to park"
    elif [ -n "$eaten" ]; then
      warn "meters$ctx are eating $eaten — re-park them: $HERE/cmux-sentinel-setup.sh"
    else
      # A meter needs 8 reals above it to clear ⌘1…⌘8. Closing rows consumes
      # the difference between the first meter index and 8.
      first_meter="$(printf '%s' "$lay" | jq -r --argjson ls "$lay_labels" '
          [ .workspaces[] | select(.title as $t | $ls | any(. as $l | $t == $l or ($t | startswith($l + " ")))) | .index ] | min' 2>/dev/null)"
      slack=$(( first_meter - 8 ))
      ok "all 9 ⌘ keys$ctx are on real workspaces (meters parked in the keyless band)"
      if [ "$slack" -le 1 ]; then
        note "headroom$ctx is thin — closing $((slack + 1)) more workspace(s) above the meters will eat ⌘8; re-run cmux-sentinel-setup.sh after a cleanup"
      fi
    fi
  }

  windows="$(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)"
  if [ -n "$windows" ]; then
    while IFS= read -r window; do [ -n "$window" ] && check_layout "$window"; done <<<"$windows"
  else
    check_layout ""
  fi
else warn "cmux or jq unavailable — can't check the ⌘N layout"; fi

# Sidebar DATA snapshot (cmux 0.64.16+ exposes extension.sidebar.snapshot). This is
# the closest read-only view of what cmux actually projects to the sidebar — handy
# when a meter looks wrong. NB: the snapshot is the DATA MODEL, not the rendered
# tree, so it can confirm the inputs are present but CANNOT prove the interpreter
# rendered them (parse-passes/render-blank is this project's classic failure) — that
# still needs an eyeball. Also auto-naming guard: if cmux's global auto-naming is on
# it could rename a sentinel and blank its meter (we can only detect it).
echo "• sidebar data (snapshot, read-only)"
if have cmux && have jq; then
  snap="$(cmux rpc extension.sidebar.snapshot '{}' 2>/dev/null)"
  if [ -n "$snap" ] && printf '%s' "$snap" | jq -e . >/dev/null 2>&1; then
    # all meter labels for enabled providers
    labels=""
    [ "$claude_on" = 1 ] && labels="$labels $lbl5 $lbl7"
    if [ "$codex_on" = 1 ]; then
      if [ "${cx_status:-unknown}" = "available" ]; then
        printf '%s\n' "$cx_live" | grep -qxF -- "$lblcx5" && labels="$labels $lblcx5"
        printf '%s\n' "$cx_live" | grep -qxF -- "$lblcx7" && labels="$labels $lblcx7"
      else
        # Unknown capability means retain the CURRENT layout. Snapshot only the
        # Codex sentinels that actually exist; otherwise this final section would
        # contradict the earlier no-create/no-remove diagnostic with a false miss.
        for cx_lbl in "$lblcx5" "$lblcx7"; do
          rw="$(resolve_ref "$cx_lbl")"; IFS=$'\t' read -r cx_ref _ <<<"$rw"
          [ -n "$cx_ref" ] && labels="$labels $cx_lbl"
        done
      fi
    fi
    if [ "$amp_on" = 1 ]; then
      labels="$labels $lblampu"
      [ "${AMP_ORB_METER:-0}" = 1 ] && labels="$labels $lblampo"
    fi
    for lbl in $labels; do
      row="$(printf '%s' "$snap" | jq -r --arg l "$lbl" \
        'first(.workspaces[] | select(.title == $l or (.title|startswith($l+" ")))) | .title // empty' 2>/dev/null)"
      if [ -n "$row" ]; then ok "snapshot sees '$lbl' → \"$row\""
      else warn "snapshot has no '$lbl' sentinel in this window (sidebar renders per-window — keep sentinels in the window the sidebar is shown in)"; fi
    done
    note "snapshot proves DATA, not RENDER; validate uses synthetic data and does not mount/layout — eyeball the panel after changes"
  else
    note "extension.sidebar.snapshot unavailable (older cmux?) — skipping; using workspace list above"
  fi
  # auto-naming guard (same probe the setup script uses; empty params = no mutation)
  probe="$(cmux rpc workspace.set_auto_title '{}' 2>&1 || true)"
  case "$probe" in
    *[Dd]isabled*[Ss]ettings*) ok "cmux auto-naming OFF globally — sentinel title prefixes are safe" ;;
    *) warn "cmux auto-naming may be ON — it could rename a sentinel and blank its meter; disable it in Settings" ;;
  esac
else
  note "cmux or jq unavailable — skipping snapshot check"
fi

# Workspace-group names (opt-in). cmux passes custom sidebars NO group data, so a
# group renders its anchor workspace's title (often a generic "Group N") instead of
# the group name. cmux-group-sync.sh keeps anchor titles in sync when
# GROUP_NAME_SYNC=1. This cross-checks groups-present × enabled × in-sync and only
# nags when something is actually off. See
# .claude/research/2026-06-19-workspace-group-names-in-sidebar.md.
echo "• workspace-group names (opt-in)"
gsync="${GROUP_NAME_SYNC:-0}"
if have cmux && have jq; then
  ngroups=0; ndiverged=0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    while IFS=$'\t' read -r gname ganchor; do
      [ -n "$gname" ] && [ -n "$ganchor" ] || continue
      ngroups=$((ngroups + 1))
      gtitle="$(cmux workspace list --window "$w" --json 2>/dev/null \
        | jq -r --arg r "$ganchor" '.workspaces[] | select(.ref == $r) | .title' 2>/dev/null | head -1)"
      gbase="$gtitle"
      case "$gbase" in ⚡*) gbase="${gbase#⚡}" ;; ⏳*) gbase="${gbase#⏳}" ;; ❓*) gbase="${gbase#❓}" ;; esac
      gbase="${gbase# }"
      [ "$gbase" = "$gname" ] || ndiverged=$((ndiverged + 1))
    done < <(cmux workspace-group list --window "$w" --json 2>/dev/null \
      | jq -r '.groups[]? | select(.name != null and .name != "") | "\(.name)\t\(.anchor_workspace_ref)"' 2>/dev/null)
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
  if [ "$ngroups" = 0 ]; then
    note "no workspace groups — nothing to sync"
  elif [ "$gsync" = 1 ]; then
    if launchctl list 2>/dev/null | grep -q com.cmux-group-sync; then ok "group-name sync ON, launchd loaded ($ngroups group(s))"
    else warn "GROUP_NAME_SYNC=1 but launchd job not loaded — launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.cmux-group-sync.plist"; fi
    if [ "$ndiverged" = 0 ]; then ok "all $ngroups anchor title(s) match their group name"
    else warn "$ndiverged of $ngroups group anchor(s) out of sync — run: ~/bin/cmux-group-sync.sh --update"; fi
  else
    warn "$ngroups workspace group(s) present but GROUP_NAME_SYNC is off — sidebar shows anchor titles, not group names (set GROUP_NAME_SYNC=1)"
  fi
else
  note "cmux or jq unavailable — skipping group-name check"
fi

echo
if [ "$fails" -gt 0 ]; then printf '\033[31m%d problem(s), %d warning(s).\033[0m\n' "$fails" "$warns"; exit 1
elif [ "$warns" -gt 0 ]; then printf '\033[33mAll critical checks passed, %d warning(s).\033[0m\n' "$warns"; exit 0
else printf '\033[32mEverything wired. \033[0m\n'; exit 0; fi
