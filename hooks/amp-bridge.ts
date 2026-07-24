// amp-bridge.ts — Bridge Amp (ampcode.com) agent state into the cmux custom sidebar.
//
// WHY THIS EXISTS AT ALL. cmux ships its own amp integration
// (`cmux hooks amp install` → ~/.config/amp/plugins/cmux-session.ts), but that one
// reports state with `cmux set-status`, which renders as pills in cmux's NATIVE
// sidebar tab row and NEVER reaches a custom sidebar — verified by an in-sidebar
// render probe and by cmux's own binding contract in docs/custom-sidebars.md,
// which lists every interpreter-visible workspace field and has no status among
// them. So sentinel's sidebar cannot see amp at all without this file. The two
// plugins are complementary and must BOTH be installed; amp auto-loads every
// *.ts in the plugin dir, so they coexist. NEVER edit cmux-session.ts — it says
// "DO NOT EDIT MANUALLY. cmux upgrades this file in place."
//
// WHY IT SHELLS OUT INSTEAD OF REIMPLEMENTING. The marker state machine
// (ref-counting live sessions per workspace, PID-liveness reaping, the
// compacting > waiting > working precedence, restart self-heal) is subtle and
// already tested in hooks/cmux-bridge.sh. Duplicating it in TypeScript would
// mean two implementations to keep in sync AND would break co-tenancy: when Amp
// and Claude Code run in the SAME workspace they must ref-count against each
// other, which only works if both write the same $WORKROOT. So this file is a
// thin ADAPTER — it maps Amp's lifecycle events onto the bash bridge's event
// names and lets the bridge own all state. Bugs get fixed once, for both agents.
//
// STATE COVERAGE IS 2-OF-3 BY DESIGN, and the gaps are Amp's, not ours:
//   ⚡ working — agent.start (turn begins) + tool.call (keeps the marker fresh)
//   (clear)   — agent.end, whatever the outcome (done | error | cancelled)
//   ⏳ compacting — IMPOSSIBLE: Amp emits no compaction event. Not faked.
//   ❓ waiting — OPT-IN, off by default. Amp does not ask permission by default
//     ("By default, Amp does not ask for approval before running tools"), so
//     there is no blocked-on-user moment to observe. Set CMUX_SENTINEL_AMP_ASK=1
//     and the tool.call handler marks ❓ around tools listed in
//     CMUX_SENTINEL_AMP_ASK_TOOLS while it confirms with you. Left off by default
//     because turning it on CHANGES AMP'S BEHAVIOUR (it starts prompting), which
//     a status bridge has no business doing uninvited.
//
// Every cmux write is fire-and-forget and errors are swallowed: a sidebar marker
// must never break, block, or slow down the agent it is reporting on.

import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// Resolve the bash bridge. Env override first (tests and non-standard checkouts),
// then the repo layout, then the installed location.
function bridgePath(): string | null {
  const candidates = [
    process.env.CMUX_SENTINEL_BRIDGE,
    join(homedir(), ".claude/hooks/cmux-bridge.sh"), // where install.sh puts it
    join(homedir(), ".config/cmux-sentinel/cmux-bridge.sh"),
  ].filter((p): p is string => typeof p === "string" && p.length > 0)
  for (const p of candidates) if (existsSync(p)) return p
  return null
}

const BRIDGE = bridgePath()

// One amp process = one session for ref-counting. The bridge keys liveness on
// this pid (kill -0), so a crashed amp can never strand a ⚡ on the workspace.
const SESSION_PID = String(process.pid)

// Drive the bash bridge with an event name + JSON on stdin, exactly as Claude
// Code's hooks do. Detached and fully ignored: never block the agent's turn.
function drive(event: string, payload: Record<string, unknown> = {}): void {
  if (!BRIDGE) return
  if (!process.env.CMUX_WORKSPACE_ID) return // not inside a cmux workspace
  try {
    const child = spawn("bash", [BRIDGE, event], {
      env: {
        ...process.env,
        CMUX_SENTINEL_SESSION_PID: SESSION_PID,
        CMUX_SENTINEL_AGENT_LABEL: "Amp",
        CMUX_SENTINEL_LOG_SOURCE: "amp",
      },
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    })
    child.on("error", () => {})
    child.stdin?.on("error", () => {}) // bridge may exit before we finish writing
    child.stdin?.end(JSON.stringify({ hook_event_name: event, ...payload }))
    child.unref()
  } catch (_) {}
}

// ── opt-in ❓ waiting ──────────────────────────────────────────────────────
const ASK_ENABLED = process.env.CMUX_SENTINEL_AMP_ASK === "1"
const ASK_TOOLS = (process.env.CMUX_SENTINEL_AMP_ASK_TOOLS || "Bash")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean)

export default function (amp: any) {
  amp.on("session.start", () => {
    // Reconcile markers we still track and strip any stranded by a reboot wiping
    // $TMPDIR. Same self-heal Claude Code's SessionStart does.
    drive("SessionStart", { source: "startup" })
  })

  amp.on("agent.start", (event: any) => {
    drive("UserPromptSubmit", { prompt: typeof event?.message === "string" ? event.message : "" })
  })

  amp.on("tool.call", async (event: any, ctx: any) => {
    const tool = typeof event?.tool === "string" ? event.tool : ""

    if (ASK_ENABLED && ASK_TOOLS.includes(tool)) {
      // Blocked on the user for real → ❓ while the dialog is up, then back to ⚡.
      // PreToolUse with these tool names is how the bash bridge already routes
      // "this call parks on the human" (it does the same for AskUserQuestion).
      drive("PreToolUse", { tool_name: "AskUserQuestion" })
      try {
        const ok = await ctx?.ui?.confirm?.({
          title: `Run ${tool}?`,
          message: "cmux-sentinel: approve this tool call.",
        })
        drive("PreToolUse", { tool_name: tool }) // answered → back to working
        if (ok === false) return { action: "reject-and-continue" }
      } catch (_) {
        drive("PreToolUse", { tool_name: tool }) // dialog unavailable → don't strand ❓
      }
      return { action: "allow" }
    }

    // Normal path: refresh ⚡. The bridge's .marked TTL flag makes this cheap —
    // it skips the ~44ms title read on every call after the first.
    drive("PreToolUse", { tool_name: tool })
    return { action: "allow" }
  })

  amp.on("agent.end", (event: any) => {
    const status = event?.status
    if (status === "error") {
      // Surface it, but do NOT decrement the session: the bridge treats
      // StopFailure as transient and lets PID-liveness reap a truly dead one.
      drive("StopFailure", { error: "Amp turn failed" })
      return
    }
    // done | cancelled — both mean this turn is over and the row goes idle.
    drive("Stop", {})
  })
}
