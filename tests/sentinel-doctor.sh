#!/bin/bash
# sentinel-doctor.sh — offline regression test for multi-window diagnostics.
#
# launchd has no default-window context. The doctor must scan every cmux window
# before reporting a sentinel missing or checking whether meters consume ⌘ keys.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="${DOCTOR:-$HERE/../bin/cmux-sentinel-doctor.sh}"
[ -f "$DOCTOR" ] || { echo "doctor not found: $DOCTOR" >&2; exit 2; }
JQ="$(command -v jq)" || { echo "jq required" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-doctor-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
HOME="$ROOT/home"; export HOME
mkdir -p "$ROOT/bin" "$HOME/.config/cmux/sidebars" "$HOME/.local/share/amp"
ln -s "$JQ" "$ROOT/bin/jq"
mkdir -p "$HOME/.config/cmux-sentinel"
cp "$HERE/../hooks/cmux-bridge.sh" "$HOME/.config/cmux-sentinel/cmux-bridge.sh"

cat > "$HOME/.config/cmux/sidebars/workspaces.swift" <<'SWIFT'
func isClaudeMeter(_ w: Workspace) -> Bool {
    if w.title.hasPrefix("5h ") { return true }
    if w.title.hasPrefix("7d ") { return true }
    return false
}
SWIFT
cat > "$HOME/.config/cmux/cmux.json" <<'JSON'
{"automation":{"socketControlMode":"automation"}}
JSON
cat > "$HOME/.config/cmux/usage-sentinels.env" <<'ENV'
USAGE_PROVIDERS="claude codex amp"
ENV
printf '{"present":true}\n' > "$HOME/.local/share/amp/secrets.json"

# The default list intentionally has no meters. Both sentinels live in win-b,
# where they are safely parked at indices 8–9 and a real workspace owns ⌘9.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
window_list() {
  cat <<'JSON'
{"workspaces":[
  {"ref":"w1","index":0,"title":"one"},
  {"ref":"w2","index":1,"title":"two"},
  {"ref":"w3","index":2,"title":"three"},
  {"ref":"w4","index":3,"title":"four"},
  {"ref":"w5","index":4,"title":"five"},
  {"ref":"w6","index":5,"title":"six"},
  {"ref":"w7","index":6,"title":"seven"},
  {"ref":"w8","index":7,"title":"eight"},
  {"ref":"w9","index":8,"title":"5h █ 24% · resets 2h"},
  {"ref":"w10","index":9,"title":"7d ██ 48% · resets 3d"},
  {"ref":"w11","index":10,"title":"cx7d |8% (3d)|█░"},
  {"ref":"w12","index":11,"title":"ampu |12% (1 month)|█░"},
  {"ref":"w13","index":12,"title":"last-real"}
]}
JSON
}

case "$1" in
  ping) exit 0 ;;
  sidebar) [ "$2" = validate ] && exit 0 ;;
  list-windows) printf '[{"id":"win-b"}]\n' ;;
  workspace)
    if [ "$2" = list ]; then
      case " $* " in *" --window win-b "*) window_list ;; *) printf '{"workspaces":[{"ref":"d1","index":0,"title":"default-real"}]}\n' ;; esac
    fi
    ;;
  workspace-group) printf '{"groups":[]}\n' ;;
  rpc)
    if [ "$2" = extension.sidebar.snapshot ]; then window_list
    else echo "Error: disabled: Workspace auto-naming is disabled in Settings" >&2; exit 1; fi
    ;;
esac
FAKE
cat > "$ROOT/bin/security" <<'FAKE'
#!/bin/bash
exit 0
FAKE
cat > "$ROOT/bin/launchctl" <<'FAKE'
#!/bin/bash
printf '%s\n' "${STUB_LAUNCHD_JOBS:-com.cmux-claude-usage}"
exit 0
FAKE
cat > "$ROOT/bin/codex" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  [ "${STUB_CODEX_AUTH:-chatgpt}" = chatgpt ] || { echo "Not logged in" >&2; exit 1; }
  echo "Logged in using ChatGPT" >&2; exit 0
fi
[ "${1:-}" = app-server ] || exit 2
# Codex capability intentionally unknown: doctor must retain the current layout.
while IFS= read -r line; do
  case "$(printf '%s' "$line" | jq -r '.id // empty')" in
    0) printf '{"id":0,"result":{"userAgent":"fake","codexHome":"/tmp/fake","platformFamily":"unix","platformOs":"linux"}}\n' ;;
    1) printf '{"id":1,"error":{"code":-32603,"message":"offline"}}\n' ;;
  esac
done
FAKE
cat > "$ROOT/bin/amp" <<'FAKE'
#!/bin/bash
[ "$1" = usage ] || exit 0
printf '%s\n' 'Subscription Test: 88% other usage and 100% orb usage remaining - resets upon renewal in 1 month'
FAKE
chmod +x "$ROOT/bin/cmux" "$ROOT/bin/security" "$ROOT/bin/launchctl" "$ROOT/bin/codex" "$ROOT/bin/amp"

PATH="$ROOT/bin:/usr/bin:/bin"; export PATH
out="$(bash "$DOCTOR" 2>&1)"; rc=$?

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
has() { case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

echo "T1: sentinels outside the default window are found"
if [ "$rc" = 0 ]; then ok "doctor exited 0"; else bad "doctor exited $rc"; fi
if has "'5h' sentinel present (w9 in window win-b)"; then ok "found 5h in win-b"; else bad "did not find 5h in win-b"; fi
if has "'7d' sentinel present (w10 in window win-b)"; then ok "found 7d in win-b"; else bad "did not find 7d in win-b"; fi
if has "no '5h' sentinel"; then bad "reported a false missing 5h sentinel"; else ok "no false missing 5h warning"; fi
if has "no '7d' sentinel"; then bad "reported a false missing 7d sentinel"; else ok "no false missing 7d warning"; fi

echo "T2: shortcut layout is checked in the meter's window"
if has "all 9 ⌘ keys in window win-b are on real workspaces"; then ok "validated win-b layout"; else bad "did not validate win-b layout"; fi
if has "meters in window win-b are eating"; then bad "reported false shortcut theft"; else ok "no false shortcut warning"; fi

echo "T3: Amp-only neutral bridge is reported accurately"
if has "Amp shared bridge installed"; then ok "neutral Amp bridge detected"; else bad "neutral Amp bridge not detected"; fi
if has "no agent-state bridge installed"; then bad "Amp-only setup reported as bridge-less"; else ok "no false bridge-missing warning"; fi

echo "T4: Codex unknown capability retains layout without false creation advice"
if has "codex capability unknown"; then ok "unknown Codex capability is explicit"; else bad "unknown Codex capability not reported"; fi
if has "no 'cx5h' sentinel — capability unknown"; then ok "missing cx5h layout retained"; else bad "missing cx5h retention not reported"; fi
if has "no 'cx5h' sentinel (title"; then bad "unknown capability suggested creating cx5h"; else ok "no false cx5h creation warning"; fi
if has "snapshot has no 'cx5h'"; then bad "snapshot contradicted unknown-layout retention"; else ok "snapshot retains unknown Codex layout"; fi

echo "T5: launchd is checked per enabled/installed provider"
if has "claude poller loaded (com.cmux-claude-usage)"; then ok "Claude launchd loaded"; else bad "Claude launchd not detected"; fi
if has "codex poller not loaded — launchctl bootstrap"; then ok "Codex launchd guidance"; else bad "Codex launchd guidance missing"; fi
if has "com.cmux-codex-usage.plist"; then ok "Codex bootstrap path"; else bad "Codex bootstrap path missing"; fi
if has "amp poller not loaded — launchctl bootstrap"; then ok "Amp launchd guidance"; else bad "Amp launchd guidance missing"; fi
if has "com.cmux-amp-usage.plist"; then ok "Amp bootstrap path"; else bad "Amp bootstrap path missing"; fi

echo "T6: disabled/uninstalled providers do not produce launchd warnings"
printf 'USAGE_PROVIDERS="claude"\n' > "$HOME/.config/cmux/usage-sentinels.env"
rm -f "$HOME/.local/share/amp/secrets.json"
out2="$(STUB_CODEX_AUTH=none bash "$DOCTOR" 2>&1)"
if lacks "$out2" "codex poller not loaded"; then ok "disabled Codex has no launchd warning"; else bad "disabled Codex got launchd warning"; fi
if lacks "$out2" "amp poller not loaded"; then ok "disabled Amp has no launchd warning"; else bad "disabled Amp got launchd warning"; fi
case "$out2" in
  *"'cx7d' sentinel present (w11 in window win-b) but codex is disabled"*) ok "disabled Codex leftover is reported" ;;
  *) bad "disabled Codex leftover was missed" ;;
esac
case "$out2" in
  *"'ampu' sentinel present (w12 in window win-b) but amp is disabled"*) ok "disabled Amp leftover is reported" ;;
  *) bad "disabled Amp leftover was missed" ;;
esac
case "$out2" in
  *"cmux workspace close w11 --window win-b"*) ok "cross-window close guidance keeps its window" ;;
  *) bad "cross-window close guidance omitted its window" ;;
esac

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
