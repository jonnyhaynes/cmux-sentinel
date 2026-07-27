#!/bin/bash
# Mount the repo sidebar through cmux's REAL live-data render path for inspection.
# This proves staging, interpretation, and `sidebar open` succeeded; cmux exposes
# no rendered-tree/pixel API, so visible output still requires a human verdict.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-$HERE/../sidebars/workspaces.swift}"
SIDEBAR_DIR="${CMUX_SIDEBAR_DIR:-$HOME/.config/cmux/sidebars}"
NAME="cmux-sentinel-live-smoke-$$"
STAGED="$SIDEBAR_DIR/$NAME.swift"
SURFACE=""

die() { echo "ERR: $*" >&2; exit 1; }

cleanup() {
  if [ -n "$SURFACE" ]; then
    cmux close-surface --surface "$SURFACE" >/dev/null 2>&1 || true
  fi
  rm -f "$STAGED"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(uname -s)" = Darwin ] || die "live sidebar smoke requires macOS"
command -v cmux >/dev/null 2>&1 || die "cmux not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[ -f "$SOURCE" ] || die "sidebar source not found: $SOURCE"
cmux ping >/dev/null 2>&1 || die "cmux is not responding"

mkdir -p "$SIDEBAR_DIR" || die "couldn't create $SIDEBAR_DIR"
cp "$SOURCE" "$STAGED" || die "couldn't stage $SOURCE"

echo "live sidebar smoke"
echo "• staged: $SOURCE → $STAGED"
cmux sidebar validate "$NAME" >/dev/null 2>&1 \
  || { cmux sidebar validate "$NAME" || true; die "synthetic interpretation failed"; }
echo "• synthetic interpretation: ok"

opened=$(cmux sidebar open "$NAME" --json) || die "cmux failed to open the live sidebar"
if ! printf '%s' "$opened" | jq -e \
    '.type == "customSidebar" and .valid_count == 1 and .error_count == 0' >/dev/null 2>&1; then
  printf '%s\n' "$opened" >&2
  die "sidebar open returned an unexpected result"
fi
SURFACE=$(printf '%s' "$opened" | jq -r '.surface_id // empty')
[ -n "$SURFACE" ] || die "sidebar opened without a surface id"

echo "• live mount command: ok"
echo "• inspect the opened panel now: usage sections and workspace rows must be visible"
echo "• note: this is a HUMAN render check; command success does not prove pixels"

if [ -t 0 ]; then
  printf 'Press Return after inspection to close the smoke panel... '
  IFS= read -r _
else
  hold="${SIDEBAR_SMOKE_HOLD_SECONDS:-5}"
  case "$hold" in ''|*[!0-9]*) hold=5 ;; esac
  echo "• non-interactive run: holding the panel for ${hold}s"
  sleep "$hold"
fi

echo "live sidebar smoke: mount path passed; visual verdict remains manual"
