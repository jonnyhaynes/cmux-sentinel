#!/bin/bash
# cmux-title.sh — give a cmux workspace a MEANINGFUL title: "<brand> repo · branch".
#
# WHY: agents leave the workspace title at their generic default ("Claude Code",
# "Title Placeholder"), so the sidebar can't tell sessions apart. The shared
# status bridge (cmux-bridge.sh) only ever prepends a STATUS GLYPH to whatever the
# base title already is — it never authors a good base title. This hook does that
# one job: set the base from the session's cwd, PRESERVING any glyph the bridge has
# already painted so the two never fight.
#
# TITLE FORMAT — "<brand> repo · branch" (human-readable ON PURPOSE):
#   The macOS window titlebar shows the raw workspace title verbatim, so the title
#   must read cleanly there. We use a leading BRAND glyph (✳/⌘/◇) for the agent and
#   " · " before the branch. The sidebar renderer (workspaces.swift) reverses this:
#   detects the leading brand glyph → agent icon; splits the rest on " · " → repo as
#   the title line + branch on its own ⑂ line. cmux's native w.branch is empty for
#   plain-terminal workspaces, which is why branch is packed into the title at all.
#   Outside a git repo, the title is just "<brand> folder" (no " · ", no branch).
#
# COMPOSES WITH THE BRIDGE (either order):
#   - We strip the SAME three leading glyphs the bridge uses (⚡/⏳/❓), swap the
#     base, then re-attach the glyph. The bridge's _strip_marks only touches the
#     leading glyph, so our brand + " · " + branch survive its rewrites.
#   - Idempotent: if the base already matches we do nothing (avoids churning cmux's
#     title coalescer, which the bridge header warns about).
#
# IDENTITY: CMUX_WORKSPACE_ID is exported by cmux into every terminal, so it reaches
# the agent and this hook for free. cwd comes from the hook's JSON payload (.cwd)
# and falls back to $PWD.
#
# Wire into an agent's SessionStart hook (also fine on UserPromptSubmit — the branch
# can change mid-session via checkout, and re-running is cheap + idempotent).

command -v cmux &>/dev/null || exit 0
cmux ping &>/dev/null || exit 0

WS="${CMUX_WORKSPACE_ID:-}"
[ -n "$WS" ] || exit 0

# Same glyph set as cmux-bridge.sh (_strip_marks). Keep in sync with the bridge.
WORKMARK="⚡"
COMPMARK="⏳"
WAITMARK="❓"

# Branch separator. Human-readable " · " so the workspace title reads cleanly in the
# macOS window titlebar (which shows the raw title verbatim). workspaces.swift splits
# repo/branch on this SAME string. " · " never occurs in a repo dir name or a git
# branch name, so the split is unambiguous.
SEP=" · "

# Agent → BRAND GLYPH prepended to the title (mirrors agentGlyph in workspaces.swift):
# cc=✳ (Claude/Anthropic), cmdc=⌘ (Command Code), codex=◇. The sidebar detects the
# leading brand glyph to pick the agent; the titlebar just shows it. Command Code's
# hook exports CMUX_TITLE_AGENT=cmdc; default is Claude. A PLAIN SHELL sets
# CMUX_TITLE_AGENT=none (or "") → no brand glyph, just "repo · branch".
AGENT="${CMUX_TITLE_AGENT-cc}"
[ "$AGENT" = "none" ] && AGENT=""
case "$AGENT" in
  cc)    BRAND="✳ " ;;
  cmdc)  BRAND="⌘ " ;;
  codex) BRAND="◇ " ;;
  *)     BRAND="" ;;
esac

# cwd: prefer the hook payload's .cwd (agents pipe JSON on stdin), else $PWD (shell
# use). Only read stdin when it's a pipe — an interactive shell has a tty on stdin
# and `cat` would block forever waiting for EOF.
input=""
[ -t 0 ] || input=$(cat 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# Build the HUMAN-READABLE base "<brand>repo · branch" (reads cleanly in the window
# titlebar; workspaces.swift splits it back apart for the sidebar):
#   brand  = leading agent glyph (or none for a plain shell) → sidebar agent icon
#   repo   = git toplevel basename (worktrees read as the repo, not the leaf dir;
#            folder basename outside a repo) → the sidebar TITLE line
#   branch = current branch, short SHA if detached → the sidebar ⑂ line (omitted
#            when absent → no branch line)
if git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
  repo=$(basename "$git_root")
  branch=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
else
  repo=$(basename "$cwd")
  branch=""
fi
[ -n "$repo" ] || exit 0

if [ -n "$branch" ]; then
  base="${BRAND}${repo}${SEP}${branch}"
else
  base="${BRAND}${repo}"
fi

# Current effective title for THIS workspace, matched by id (list-workspaces + id is
# exact; current-workspace resolution is unreliable from async hooks).
cur=$(cmux list-workspaces --id-format uuids 2>/dev/null \
  | grep -F -- "$WS" | head -1 \
  | sed -E "s/^.*${WS}[[:space:]]+//; s/[[:space:]]*\[selected\]\$//")

# Split off a leading STATUS glyph (⚡/⏳/❓) the bridge painted, so we can PRESERVE it
# while swapping the base. The bridge stores "<glyph><base>" with NO separating space,
# so strip/rebuild spacelessly. The status glyph rides the title because the sidebar
# interpreter can ONLY read w.title (color/description/etc. proved unreadable) — it
# strips the glyph from the row for display and points the WINDOW TITLEBAR at
# {activeDirectory} instead, so the glyph never shows there.
glyph=""
rest="$cur"
case "$rest" in
  "$WORKMARK"*) glyph="$WORKMARK"; rest="${rest#"$WORKMARK"}" ;;
  "$COMPMARK"*) glyph="$COMPMARK"; rest="${rest#"$COMPMARK"}" ;;
  "$WAITMARK"*) glyph="$WAITMARK"; rest="${rest#"$WAITMARK"}" ;;
esac

# Idempotent: base already correct → leave the coalescer alone (glyph preserved).
[ "$rest" = "$base" ] && exit 0

cmux rename-workspace --workspace "$WS" "${glyph}${base}" &>/dev/null
exit 0
