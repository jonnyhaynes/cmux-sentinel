// Workspaces sidebar — flat, your manual order (by index). SF Mono.
// Palette: Ayu Mirage (matches the terminal theme).
//   bg #1F2430 · fg #D9D7CE · dim #8A9199 · orange #FFCC66 · blue #73D0FF
//   green #87D96C · red #F28779 · selection #33415E
//
// State is modeled as TWO INDEPENDENT dimensions, each on its own row:
//   1. Agent activity — compacting (purple) / working (green) / needs-you
//      (orange) / idle (dim). Compacting, waiting & working are read from STATIC
//      markers the bridge keeps at the FRONT of the TITLE ("⏳"=compacting,
//      "❓"=waiting-on-you, "⚡"=working); needs-you ALSO triggers on `unread`.
//      Precedence: compacting > waiting > working > needs-you(unread) > idle.
//      "Waiting" is the bridge's way of saying Claude asked a question / hit a
//      permission prompt — the row shows the orange needs-you treatment, not
//      green "Working…", because the session is parked on YOU.
//      (Why the title and not `progress` for agent state: the title is the
//      persistent, restart-proof anchor and encodes the marker-precedence order;
//      `progress` DOES reach the sidebar on 0.64.17 — meters use it — but it's
//      transient. Why STATIC: an animated marker in the title freezes cmux's
//      sidebar — upstream #6291. The bridge ref-counts agents per workspace so
//      multiple Claude/Codex sessions don't stomp the marker — see
//      .claude/STATE-ARCHITECTURE.md.)
//   2. Repo state — branch · uncommitted · PR. Independent of any agent; its
//      own row so it never competes with activity for the line.
// Usage meters ride hidden "sentinel" workspaces (see isUsageMeter).

// ── predicates ────────────────────────────────────────────────────
func hasPR(_ w) -> Bool {
  return w.pr != nil && w.pr.label != nil && w.pr.label != ""
}
// Prefer cmux's native git branch; fall back to the branch packed into the title
// by cmux-title.sh (plain-terminal workspaces have no native w.branch).
func branchOf(_ w) -> String {
  if w.branch != nil && w.branch != "" { return w.branch }
  return branchFromTitle(w)
}
func hasBranch(_ w) -> Bool {
  return branchOf(w) != ""
}
func hasProgress(_ w) -> Bool {
  return w.progress != nil && w.progress.value != nil
}
func hasProgressLabel(_ w) -> Bool {
  return hasProgress(w) && w.progress.label != nil && w.progress.label != ""
}

// ── dimension 1: agent activity ───────────────────────────────────
// "Working" is detected from a marker the bridge injects at the FRONT of the
// TITLE ("⚡ name"). Agent state rides the title (not `progress`) because it must
// be persistent and precedence-ordered; `progress` reaches the sidebar on 0.64.17
// but is transient (meters use it — see meterRow). The interpreter's `.hasPrefix`
// works here (proven), so we detect the marker on the title.
// STATUS SOURCE = the leading glyph on w.title. The sidebar interpreter can ONLY read
// w.title (color/description/progress all proved unreadable in this build), so status
// rides a leading ⚡/⏳/❓ the bridge paints. `titleBase` strips it from the visible
// row; the WINDOW TITLEBAR is pointed at {activeDirectory} so the glyph never shows
// there. Titles are "<glyph?><brand> repo · branch".
func isWorking(_ w) -> Bool {
  return w.title.hasPrefix("⚡")
}
// Compacting is a distinct busy sub-state: the bridge swaps the working marker
// for "⏳" while Claude compacts its context (PreCompact→PostCompact). Static
// glyph on purpose — an animated/spinner marker in the title freezes cmux's
// sidebar (upstream #6291). Precedence: compacting > working > needs-you > idle.
func isCompacting(_ w) -> Bool {
  return w.title.hasPrefix("⏳")
}
// Waiting: the bridge flips the marker to "❓" when Claude is BLOCKED on you —
// it asked a question (AskUserQuestion / ExitPlanMode) or hit a permission/idle
// prompt. The session is alive but parked, so this beats "working" and rides the
// orange needs-you treatment. Markers are mutually exclusive (one leading glyph),
// so isWaiting ⇒ !isWorking && !isCompacting.
func isWaiting(_ w) -> Bool {
  return w.title.hasPrefix("❓")
}
// needs-you = Claude is waiting on you (the ❓ marker) OR there are unread
// messages while no agent is mid-turn. Working/compacting outrank a bare unread.
func needsYou(_ w) -> Bool {
  if isCompacting(w) { return false }
  if isWaiting(w) { return true }
  if isWorking(w) { return false }
  return w.unread > 0
}
// cmux-title.sh writes the HUMAN-READABLE title "<brand> repo · branch" so it reads
// cleanly in the macOS window titlebar (which shows the raw title verbatim). We parse
// it back apart here: leading brand glyph → agent icon; the rest splits on "·" into
// repo (title line) + branch (⑂ line). cmux's native w.branch is empty for plain
// terminals, which is why branch is packed into the title at all.

// Strip the leading activity glyph (⚡/⏳/❓) the bridge paints, returning the raw
// base ("<brand> repo · branch"). `.split` keeps the rest intact (spaces and all);
// cmux trims a leading zero-width space, so a visible marker + strip is the only
// way to get a clean base.
func titleBase(_ w) -> String {
  if w.title.hasPrefix("⏳") {
    let parts = w.title.split(separator: "⏳")
    if parts.count > 0 { return String(parts[0]) }
    return ""
  }
  if w.title.hasPrefix("❓") {
    let parts = w.title.split(separator: "❓")
    if parts.count > 0 { return String(parts[0]) }
    return ""
  }
  if w.title.hasPrefix("⚡") {
    let parts = w.title.split(separator: "⚡")
    if parts.count > 0 { return String(parts[0]) }
    return ""
  }
  return w.title
}

// Brand GLYPH for the agent that owns the workspace; "" = none (plain terminal or a
// cmux-native title). Detected as the LEADING glyph of the base. Claude Code writes
// U+2733 ✳ (the Anthropic mark) into its own titles, so we reuse that exact glyph.
func agentGlyph(_ w) -> String {
  let base = titleBase(w)
  if base.hasPrefix("✳") { return "✳" }   // Claude Code — Anthropic eight-spoked asterisk
  if base.hasPrefix("⌘") { return "⌘" }   // Command Code
  if base.hasPrefix("◇") { return "◇" }   // Codex
  return ""
}

// Base with the leading brand glyph (and its trailing space) removed → "repo · branch".
func titleAfterBrand(_ w) -> String {
  let base = titleBase(w)
  let g = agentGlyph(w)
  if g == "" { return base }
  // Strip glyph, then split on ✳/⌘/◇ dropped a leading space too; rebuild by
  // splitting on the glyph and taking the remainder, trimming one leading space.
  let parts = base.split(separator: g)
  if parts.count > 0 {
    var rest = String(parts[0])
    if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
    return rest
  }
  return base
}

// Repo = the row TITLE = text before the "·". When there's no separator the whole
// (post-brand) string IS the repo name.
func repoFromTitle(_ w) -> String {
  let s = titleAfterBrand(w)
  let parts = s.split(separator: "·")
  if parts.count > 0 {
    var r = String(parts[0])
    if r.hasSuffix(" ") { r = String(r.dropLast()) }
    return r
  }
  return s
}
// Branch = the ⑂ line = text after the "·", or "" when absent.
func branchFromTitle(_ w) -> String {
  let s = titleAfterBrand(w)
  let parts = s.split(separator: "·")
  if parts.count > 1 {
    var b = String(parts[1])
    if b.hasPrefix(" ") { b = String(b.dropFirst()) }
    return b
  }
  return ""
}

// Row title = repo name only. Branch rides its own ⑂ line below (dimension 2).
func displayTitle(_ w) -> String {
  return repoFromTitle(w)
}
func workLabel(_ w) -> String {
  if hasProgressLabel(w) { return w.progress.label }
  return "Working…"
}
func activityText(_ w) -> String {
  if isCompacting(w) { return "Compacting…" }
  if isWaiting(w) { return "asking…" }   // Claude asked a question / needs permission
  if isWorking(w) { return workLabel(w) }
  if needsYou(w) {
    if w.unread > 1 { return "needs you · \(w.unread)" }
    return "needs you"
  }
  return "idle"
}
func activityColor(_ w) -> String {
  if isCompacting(w) { return "#DFBFFF" }
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#8A9199"
}
// SF Symbol for the activity row; "" = no icon (compared with == elsewhere).
// Working shows by colour alone (no icon — Oliver: "icon is too much, just colour").
func activityIcon(_ w) -> String {
  if needsYou(w) { return "bell.fill" }
  return ""
}
// Idle repo rows already communicate useful state below the title; repeating
// literal "idle" makes the list taller without adding information. Keep it only
// for empty rows, while all actionable/active states always get an activity line.
func showsActivity(_ w) -> Bool {
  if isCompacting(w) { return true }
  if isWorking(w) { return true }
  if needsYou(w) { return true }
  if hasRepoInfo(w) { return false }
  return true
}
func titleLineLimit(_ w) -> Int {
  if w.selected { return 2 }
  if isCompacting(w) { return 2 }
  if isWorking(w) { return 2 }
  if needsYou(w) { return 2 }
  return 1
}

// ── dimension 2: repo / git state ─────────────────────────────────
func hasRepoInfo(_ w) -> Bool {
  if hasPR(w) { return true }
  if hasBranch(w) { return true }
  if w.dirty == true { return true }
  return false
}
// Dirty is shown as a compact yellow "*" in the row (native "main*" look), NOT
// spelled out — "uncommitted changes" truncates and eats the narrow line. So
// repoText carries only branch / PR label (+ stale); the "*" is appended below.
func repoText(_ w) -> String {
  if hasPR(w) {
    let stale = w.pr.stale == true ? " · stale" : ""
    return "\(w.pr.label)\(stale)"
  }
  if hasBranch(w) { return branchOf(w) }
  return ""   // dirty-only row: just the branch icon + the yellow "*"
}
// Branch / PR label colour. Dirty no longer tints this (the yellow "*" carries it).
func repoColor(_ w) -> String {
  if hasPR(w) && w.pr.status == "open" { return "#73D0FF" }
  return "#8A9199"
}
// ── usage meters (hidden sentinels) ───────────────────────────────
// ONE predicate per provider, matched by the sentinel's TITLE LABEL (not a
// workspace id). 0.64.15 removed stable workspace UUIDs, leaving only a positional
// ref that rotates on every app restart, so an id hard-coded here would go stale
// each restart and the meters would silently fall back into the normal list.
// 0.64.22 populates `w.id` again, but it is not a proven-durable handle (no public
// `stableId`) and a hard-coded id would still need a reinstall to change — the
// label needs neither. The poller keeps each sentinel's title starting with its
// label ("5h "/"7d "), `.hasPrefix` works in the interpreter (proven), and the
// bridge prefixes real agent workspaces with ⚡/⏳ (never a bare label), so the
// label is a collision-free, restart-proof anchor both sides share.
func isClaudeMeter(_ w) -> Bool {
  if w.title == "5h" { return true }           // bare bootstrap label (before the first poll paints a bar)
  if w.title.hasPrefix("5h ") { return true }  // Claude — 5h session window
  if w.title == "7d" { return true }           // bare bootstrap label (before the first poll paints a bar)
  if w.title.hasPrefix("7d ") { return true }  // Claude — 7d weekly window
  return false
}
// Codex provider — same shape as isClaudeMeter, distinct labels so the two never
// collide. bin/cmux-codex-usage.sh reads ChatGPT account usage and routes windows
// by numeric duration (never by unstable primary/secondary position).
func isCodexMeter(_ w) -> Bool {
  if w.title == "cx5h" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cx5h ") { return true }  // Codex — short/session window
  if w.title == "cx7d" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cx7d ") { return true }  // Codex — weekly window
  return false
}
// Amp provider — fed by bin/cmux-amp-usage.sh, which scrapes `amp usage`.
// Labels are distinct from every other provider's ("ampu"/"ampo" can't collide
// with "5h "/"7d "/"cx5h "/"cx7d "). Unlike the others these are NOT rolling time
// windows but one monthly subscription allowance: "ampu" = agent/thread usage,
// "ampo" = orb (remote machine) usage. "ampo" only exists when the user opted in
// with AMP_ORB_METER=1 — a sentinel costs a ⌘ key, so it isn't created by default.
func isAmpMeter(_ w) -> Bool {
  if w.title == "ampu" { return true }           // bare bootstrap label
  if w.title.hasPrefix("ampu ") { return true }  // Amp — subscription agent usage
  if w.title == "ampo" { return true }           // bare bootstrap label
  if w.title.hasPrefix("ampo ") { return true }  // Amp — orb usage (opt-in)
  return false
}
// Command Code provider — fed by bin/cmux-commandcode-usage.sh, which reads
// api.commandcode.ai/alpha/billing/credits. Labels distinct from every other
// provider's ("cc5h "/"cc7d " can't collide with "5h "/"cx5h "/"ampu "). Same
// rolling-window shape as Claude: "cc5h" = 5-hour window, "cc7d" = weekly window.
func isCommandCodeMeter(_ w) -> Bool {
  if w.title == "cc5h" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cc5h ") { return true }  // Command Code — 5h window
  if w.title == "cc7d" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cc7d ") { return true }  // Command Code — weekly window
  return false
}
func isUsageMeter(_ w) -> Bool {
  if isCommandCodeMeter(w) { return true }
  if isClaudeMeter(w) { return true }
  if isCodexMeter(w) { return true }
  if isAmpMeter(w) { return true }
  return false
}

// ── native meter row (progress channel) ───────────────────────────
// The poller writes each sentinel's utilization via `set-progress` (value 0..1 +
// a clean label), which cmux 0.64.17 passes to the interpreter (null-until-set —
// see .claude/research/2026-07-06-conductor-sidebar-analysis.md). So a meter is a
// NATIVE ProgressView, not a unicode-block bar baked into the title. The title
// stays the anchor (isClaudeMeter/resolve_ref) AND the fallback shown here
// whenever progress is absent (bootstrap, offline-cleared, a dropped write, or
// the first poll after an app restart).
func meterWindow(_ w) -> String {   // human label; title anchor remains unchanged
  if w.title == "cc5h" { return "session" }
  if w.title.hasPrefix("cc5h ") { return "session" }
  if w.title == "cc7d" { return "week" }
  if w.title.hasPrefix("cc7d ") { return "week" }
  if w.title == "5h" { return "session" }
  if w.title.hasPrefix("5h ") { return "session" }
  if w.title == "7d" { return "week" }
  if w.title.hasPrefix("7d ") { return "week" }
  if w.title == "cx5h" { return "session" }
  if w.title.hasPrefix("cx5h ") { return "session" }
  if w.title == "cx7d" { return "week" }
  if w.title.hasPrefix("cx7d ") { return "week" }
  if w.title == "ampu" { return "threads" }
  if w.title.hasPrefix("ampu ") { return "threads" }
  if w.title == "ampo" { return "orbs" }
  if w.title.hasPrefix("ampo ") { return "orbs" }
  return "usage"
}
func meterTint(_ w) -> String {
  // Bar colour is BRAND identity: Command Code = brand purple, Claude = amber-orange.
  // Severity still reads via the 🟡/🔴 dot the poller appends to the title. Other
  // providers keep the by-value tint (blue → amber ≥70% → red ≥90%).
  if isCommandCodeMeter(w) { return "#A599E9" }
  if isClaudeMeter(w) { return "#FFCC66" }
  if hasProgress(w) {
    if w.progress.value >= 0.9 { return "#F28779" }
    if w.progress.value >= 0.7 { return "#FFCC66" }
  }
  return "#73D0FF"
}
// Severity colour for the meter's LABEL text (the "39% (19h 4m)" line): red ≥90%,
// amber ≥70%, else the normal dim grey. This REPLACES the 🔴/🟡 emoji dot the poller
// used to append — the numbers themselves now carry the warning, so a maxed meter
// reads red without an extra glyph. Falls back to dim when progress is absent.
// Severity colour for the meter's LABEL text. In practice the sidebar renders meters
// via the FALLBACK path (progress is transient and null at render time — see the
// cheatsheet), so severity must be read from the label STRING, not w.progress.value.
// meterSeverityText takes the "<pct>% (…)" detail; red ≥90%, amber ≥70%, else dim.
// Digit-prefix match because the interpreter has no int parse: 90–99% and 100% are
// red; 70–89% amber; a bare "9%"/"7%" is NOT (the % follows the single digit).
func meterSeverityColor(_ detail) -> String {
  if detail.hasPrefix("100%") { return "#F28779" }
  if detail.hasPrefix("90%") { return "#F28779" }
  if detail.hasPrefix("91%") { return "#F28779" }
  if detail.hasPrefix("92%") { return "#F28779" }
  if detail.hasPrefix("93%") { return "#F28779" }
  if detail.hasPrefix("94%") { return "#F28779" }
  if detail.hasPrefix("95%") { return "#F28779" }
  if detail.hasPrefix("96%") { return "#F28779" }
  if detail.hasPrefix("97%") { return "#F28779" }
  if detail.hasPrefix("98%") { return "#F28779" }
  if detail.hasPrefix("99%") { return "#F28779" }
  if detail.hasPrefix("70%") { return "#FFCC66" }
  if detail.hasPrefix("71%") { return "#FFCC66" }
  if detail.hasPrefix("72%") { return "#FFCC66" }
  if detail.hasPrefix("73%") { return "#FFCC66" }
  if detail.hasPrefix("74%") { return "#FFCC66" }
  if detail.hasPrefix("75%") { return "#FFCC66" }
  if detail.hasPrefix("76%") { return "#FFCC66" }
  if detail.hasPrefix("77%") { return "#FFCC66" }
  if detail.hasPrefix("78%") { return "#FFCC66" }
  if detail.hasPrefix("79%") { return "#FFCC66" }
  if detail.hasPrefix("80%") { return "#FFCC66" }
  if detail.hasPrefix("81%") { return "#FFCC66" }
  if detail.hasPrefix("82%") { return "#FFCC66" }
  if detail.hasPrefix("83%") { return "#FFCC66" }
  if detail.hasPrefix("84%") { return "#FFCC66" }
  if detail.hasPrefix("85%") { return "#FFCC66" }
  if detail.hasPrefix("86%") { return "#FFCC66" }
  if detail.hasPrefix("87%") { return "#FFCC66" }
  if detail.hasPrefix("88%") { return "#FFCC66" }
  if detail.hasPrefix("89%") { return "#FFCC66" }
  return "#8A9199"
}
// Ring FILL fraction (0..1) for Circle().trim — derived from the label string
// because progress.value is null at render time. Coarse to the nearest 10% (a 42px
// ring can't show finer), matched on the leading "<pct>%" of the detail. Falls to a
// hairline 0.02 so an empty ring still shows a faint tick rather than nothing.
func meterFrac(_ detail) -> Double {
  if detail.hasPrefix("100%") { return 1.0 }
  // Single-digit "N%" first, so "9%" (0.1) isn't mistaken for "9x%" (0.9).
  if detail.hasPrefix("0%") { return 0.02 }
  if detail.hasPrefix("1%") { return 0.05 }
  if detail.hasPrefix("2%") { return 0.05 }
  if detail.hasPrefix("3%") { return 0.05 }
  if detail.hasPrefix("4%") { return 0.05 }
  if detail.hasPrefix("5%") { return 0.08 }
  if detail.hasPrefix("6%") { return 0.08 }
  if detail.hasPrefix("7%") { return 0.08 }
  if detail.hasPrefix("8%") { return 0.1 }
  if detail.hasPrefix("9%") { return 0.1 }
  // Now the two-digit tens buckets.
  if detail.hasPrefix("9") { return 0.9 }
  if detail.hasPrefix("8") { return 0.85 }
  if detail.hasPrefix("7") { return 0.75 }
  if detail.hasPrefix("6") { return 0.65 }
  if detail.hasPrefix("5") { return 0.55 }
  if detail.hasPrefix("4") { return 0.45 }
  if detail.hasPrefix("3") { return 0.35 }
  if detail.hasPrefix("2") { return 0.25 }
  if detail.hasPrefix("1") { return 0.15 }
  return 0.02
}
// The reset countdown pulled out of "<pct>% (2d 19h)" → "2d 19h". Splits on "(" and
// trims the trailing ")". Empty/"—" when there's no parenthesised part.
func meterReset(_ detail) -> String {
  let parts = detail.split(separator: "(")
  if parts.count > 1 {
    let inner = parts[1].split(separator: ")")
    if inner.count > 0 { return String(inner[0]) }
  }
  return ""
}
// Just the "<pct>%" head of the detail (everything before the space) for the ring centre.
func meterPct(_ detail) -> String {
  let parts = detail.split(separator: " ")
  if parts.count > 0 { return String(parts[0]) }
  return detail
}
// Provider brand hue for the ring stroke (scheme B: ring = brand, severity on number).
func meterBrand(_ w) -> String {
  if isCommandCodeMeter(w) { return "#A599E9" }
  if isClaudeMeter(w) { return "#FFCC66" }
  if isCodexMeter(w) { return "#73D0FF" }
  return "#8A9199"
}
// Short provider tag shown beside each ring.
func meterProvTag(_ w) -> String {
  if isCommandCodeMeter(w) { return "CMD CODE" }
  if isClaudeMeter(w) { return "CLAUDE" }
  if isCodexMeter(w) { return "CODEX" }
  if isAmpMeter(w) { return "AMP" }
  return "USAGE"
}
// Progress-path variant (kept for when progress IS present): red ≥90%, amber ≥70%.
func meterLabelColor(_ w) -> String {
  if hasProgress(w) {
    if w.progress.value >= 0.9 { return "#F28779" }
    if w.progress.value >= 0.7 { return "#FFCC66" }
  }
  return "#8A9199"
}
// Poller title fallback protocol: "<anchor> |<detail>|<unicode bar>". The space
// before the first delimiter preserves every existing "<label> " identity match;
// the single-character split avoids provider-specific prefix parsing entirely.
// Old pre-protocol titles show "refreshing…" until the next poll migrates them.
func meterFallbackDetail(_ w) -> String {
  if w.title == "cc5h" { return "waiting…" }
  if w.title == "cc7d" { return "waiting…" }
  if w.title == "5h" { return "waiting…" }
  if w.title == "7d" { return "waiting…" }
  if w.title == "cx5h" { return "waiting…" }
  if w.title == "cx7d" { return "waiting…" }
  if w.title == "ampu" { return "waiting…" }
  if w.title == "ampo" { return "waiting…" }
  let parts = w.title.split(separator: "|")
  if parts.count > 1 { return String(parts[1]) }
  return "refreshing…"
}
func meterFallbackBar(_ w) -> String {
  let parts = w.title.split(separator: "|")
  if parts.count > 2 { return String(parts[2]) }
  return ""
}
func meterRow(_ w) -> some View {
  VStack(alignment: .leading, spacing: 3) {
    if hasProgress(w) {
      HStack(spacing: 6) {
        Text(meterWindow(w))
          .font(.system(size: 12, design: .monospaced)).foregroundColor("#CCCAC2")
        Spacer()
        if hasProgressLabel(w) {
          Text(w.progress.label)
            .font(.system(size: 11, design: .monospaced)).foregroundColor(meterLabelColor(w))
            .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.trailing)
        }
      }
      ProgressView(value: w.progress.value).tint(meterTint(w))
    } else {
      HStack(spacing: 6) {
        Text(meterWindow(w))
          .font(.system(size: 12, design: .monospaced)).foregroundColor("#CCCAC2")
        Spacer()
        Text(meterFallbackDetail(w))
          .font(.system(size: 11, design: .monospaced)).foregroundColor(meterSeverityColor(meterFallbackDetail(w)))
          .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.trailing)
      }
      if meterFallbackBar(w) != "" {
        Text(meterFallbackBar(w))
          .font(.system(size: 11, design: .monospaced)).foregroundColor(meterTint(w))
          .lineLimit(1)
      }
    }
  }
}

// One ring-gauge cell (scheme B): a brand-hued ring whose FILL fraction comes from
// the label %, the % shown in the centre coloured by SEVERITY (red ≥90 / amber ≥70 /
// else dim), and the provider tag + window + reset stacked to its right. Uses the
// fallback detail string (progress.value is null at render), same source the bars used.
func meterRing(_ w) -> some View {
  HStack(spacing: 9) {
    ZStack {
      Circle().stroke("#333A48", lineWidth: 4).frame(width: 38, height: 38)
      Circle().trim(from: 0, to: meterFrac(meterFallbackDetail(w)))
        .stroke(meterBrand(w), lineWidth: 4).frame(width: 38, height: 38)
        .rotationEffect(.degrees(-90))
      Text(meterPct(meterFallbackDetail(w)))
        .font(.system(size: 10, design: .monospaced)).bold()
        .foregroundColor(meterSeverityColor(meterFallbackDetail(w)))
    }
    VStack(alignment: .leading, spacing: 1) {
      Text(meterProvTag(w))
        .font(.system(size: 9, design: .monospaced)).bold().foregroundColor(meterBrand(w))
      Text(meterWindow(w))
        .font(.system(size: 11, design: .monospaced)).foregroundColor("#D9D7CE")
      Text(meterReset(meterFallbackDetail(w)))
        .font(.system(size: 9, design: .monospaced)).foregroundColor("#6E7787").lineLimit(1)
    }
    Spacer()
  }
  // Each cell fills half the row (maxWidth: .infinity works in this interpreter), so
  // with two rings per row the second column starts at exactly 50% — the rings align
  // on a grid instead of packing left.
  .frame(maxWidth: .infinity, alignment: .leading)
}

// ── ⌘N shortcut digit ─────────────────────────────────────────────
// The gray gutter digit is the workspace's REAL ⌘N key, mirrored from cmux's own
// WorkspaceShortcutMapper (Sources/App/TerminalDirectoryOpenSupport.swift) so the
// badge can never drift from the keystroke. Two things that logic dictates and a
// naive 1..N counter would get WRONG:
//   1. ⌘9 is NOT "the 9th" — it always targets the LAST workspace, so the digit
//      hangs off the end of the list, not off position 9.
//   2. The number indexes cmux's FULL workspace list (`manager.tabs`), which
//      includes the usage sentinels. cmux has no notion of a "sentinel" — that
//      concept lives only in this file's predicates — so the meters silently eat
//      ⌘ slots and the visible rows have gaps. Numbering the visible rows 1..N
//      instead would be a lie that makes ⌘N worse, so we key on w.index.
// 0 = this row has no ⌘ key at all (indices 8…count-2 are unreachable).
func shortcutDigit(_ w) -> Int {
  if w.index < 8 { return w.index + 1 }             // ⌘1…⌘8 = fixed zero-based index
  if w.index == workspaceCount - 1 { return 9 }     // ⌘9 = last workspace, whatever its index
  return 0
}
func shortcutLabel(_ w) -> String {
  if shortcutDigit(w) > 0 { return "⌘\(shortcutDigit(w))" }
  return ""
}

// ── row visuals ───────────────────────────────────────────────────
func accentColor(_ w) -> String {
  if isCompacting(w) { return "#DFBFFF" }
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#73D0FF"
}
func accentOpacity(_ w) -> Double {
  if w.selected { return 1.0 }
  if isCompacting(w) { return 0.9 }
  if isWorking(w) { return 0.9 }
  if needsYou(w) { return 0.9 }
  return 0.0
}
func rowFill(_ w) -> String {
  if w.selected { return "#33415E" }
  if needsYou(w) { return "#FFCC66" }
  return "#FFFFFF"
}
func rowFillOpacity(_ w) -> Double {
  if w.selected { return 0.85 }
  if needsYou(w) { return 0.10 }
  if isCompacting(w) { return 0.035 }
  if isWorking(w) { return 0.035 }
  return 0.025
}
func closeColor(_ w) -> String {
  if w.selected { return "#FFFFFF" }
  if needsYou(w) { return "#FFCC66" }
  return "#A7AFBD"
}

func row(_ w) -> some View {
  VStack(spacing: 0) {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
      HStack(alignment: .top, spacing: 8) {
        Capsule().frame(width: 3, height: 26)
          .foregroundColor(accentColor(w))
          .opacity(accentOpacity(w))
        // ⌘N gutter. Fixed width so titles stay aligned on rows that have no key
        // (shortcutLabel == ""), and dim on purpose — it's a lookup aid, not state.
        Text(shortcutLabel(w))
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(w.selected ? "#D9D7CE" : "#707A8C")
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            if agentGlyph(w) != "" {
              Text(agentGlyph(w)).font(.system(size: 12)).foregroundColor("#8A9199")
            }
            Text(displayTitle(w))
              .font(.system(size: 14, design: .monospaced))
              .fontWeight(.medium)
              .foregroundColor(w.selected ? "#FFFFFF" : "#D9D7CE")
              .lineLimit(titleLineLimit(w)).multilineTextAlignment(.leading)
            if w.pinned {
              Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor("#8A9199")
            }
          }
          // dimension 1 — agent activity
          if showsActivity(w) {
            HStack(spacing: 5) {
              if activityIcon(w) != "" {
                Image(systemName: activityIcon(w)).font(.system(size: 9)).foregroundColor(activityColor(w))
              }
              Text(activityText(w))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(activityColor(w))
                .lineLimit(1).truncationMode(.tail)
            }
          }
          // dimension 2 — repo / git state (its own row, only when present).
          // Dirty = a compact yellow "*" trailing the branch (native "main*"), not prose.
          if hasRepoInfo(w) {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundColor("#6E7787")
              Text(repoText(w))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(repoColor(w))
                .lineLimit(1).truncationMode(.tail)
              if w.dirty == true {
                Text("*").font(.system(size: 12, design: .monospaced)).bold().foregroundColor("#FFCC66")
              }
            }
          }
        }
        Spacer()
        if w.unread > 0 {
          Text("\(w.unread)")
            .font(.system(size: 10, design: .monospaced)).bold()
            .foregroundColor("#1F2430").padding(4)
            .background { Circle().foregroundColor("#FFCC66") }
        }
        Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
          Image(systemName: "xmark")
            .font(.system(size: 12)).foregroundColor(closeColor(w))
            .frame(width: 24, height: 24)
        }
      }
      .padding(6)
      .background { RoundedRectangle(cornerRadius: 0).foregroundColor(rowFill(w)).opacity(rowFillOpacity(w)) }
    }
    .contextMenu {
      Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        Label("Open", systemImage: "arrow.right.circle")
      }
      if w.pinned {
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "unpin") }) {
          Label("Unpin", systemImage: "pin.slash")
        }
      } else {
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "pin") }) {
          Label("Pin", systemImage: "pin")
        }
      }
      Menu("Color") {
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#FFCC66") }) { Text("Orange") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#73D0FF") }) { Text("Blue") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#87D96C") }) { Text("Green") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#F28779") }) { Text("Red") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "clear-color") }) { Text("Clear color") }
      }
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "move-up") }) {
        Label("Move up", systemImage: "arrow.up")
      }
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "move-down") }) {
        Label("Move down", systemImage: "arrow.down")
      }
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "move-top") }) {
        Label("Move to top", systemImage: "arrow.up.to.line")
      }
      Divider()
      Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
        Label("Close", systemImage: "xmark")
      }
    }
    Divider()
  }
}

// ── layout ────────────────────────────────────────────────────────
VStack(alignment: .leading, spacing: 0) {
  HStack(spacing: 10) {
    Text("Workspaces").font(.system(size: 14, design: .monospaced)).bold()
      .foregroundColor("#D9D7CE")
    Spacer()
    if workspaces.filter { needsYou($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "bell.fill").font(.system(size: 10)).foregroundColor("#FFCC66")
        Text("\(workspaces.filter { needsYou($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#FFCC66")
      }
    }
    if workspaces.filter { isWorking($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundColor("#87D96C")
        Text("\(workspaces.filter { isWorking($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#87D96C")
      }
    }
    if workspaces.filter { isCompacting($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "hourglass").font(.system(size: 10)).foregroundColor("#DFBFFF")
        Text("\(workspaces.filter { isCompacting($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#DFBFFF")
      }
    }
    Text(clock.time).font(.system(size: 11, design: .monospaced)).foregroundColor("#707A8C")
  }
  .padding(9)
  Divider()

  // USAGE — one shared section header for the whole meter cluster, styled like the
  // WORKSPACES header. A top-level sibling (NOT a wrapper around the panels —
  // nesting them introduced large gaps in this interpreter). Shown only when at
  // least one provider has sentinels. Each panel below carries just its brand name.
  // RING DASHBOARD (scheme B). The USAGE header + every provider's ring row live in
  // ONE tight VStack(spacing: 4) — a single root child, so the interpreter's
  // inter-sibling gaps (which padding can't remove) don't open up between the header
  // and rows or between rows. Each provider is a ROW of two ring gauges (session +
  // week, side by side): ring fill = brand hue, centre % is severity-coloured
  // (red ≥90 / amber ≥70). Hidden unless at least one provider has sentinels.
  if workspaces.filter { isUsageMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 15) {
      Text("USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")

      // COMMAND CODE — two rings (session left, week right). cc5h sorted before cc7d.
      if workspaces.filter { isCommandCodeMeter($0) }.count > 0 {
        HStack(alignment: .top, spacing: 0) {
          ForEach(workspaces.filter { isCommandCodeMeter($0) }.sorted { $0.title.hasPrefix("cc5h") && !$1.title.hasPrefix("cc5h") }) { w in
            meterRing(w)
          }
        }
      }

      // CLAUDE — two rings (5h left of 7d). Match the PREFIX, never a substring:
      // a weekly countdown can itself contain "5h".
      if workspaces.filter { isClaudeMeter($0) }.count > 0 {
        HStack(alignment: .top, spacing: 0) {
          ForEach(workspaces.filter { isClaudeMeter($0) }.sorted { $0.title.hasPrefix("5h") && !$1.title.hasPrefix("5h") }) { w in
            meterRing(w)
          }
        }
      }

      // CODEX — hidden unless Codex sentinels exist. Fed by bin/cmux-codex-usage.sh.
      if workspaces.filter { isCodexMeter($0) }.count > 0 {
        HStack(alignment: .top, spacing: 0) {
          ForEach(workspaces.filter { isCodexMeter($0) }.sorted { $0.title.hasPrefix("cx5h") && !$1.title.hasPrefix("cx5h") }) { w in
            meterRing(w)
          }
        }
      }

      // AMP — hidden unless Amp sentinels exist. Fed by bin/cmux-amp-usage.sh.
      if workspaces.filter { isAmpMeter($0) }.count > 0 {
        HStack(alignment: .top, spacing: 0) {
          ForEach(workspaces.filter { isAmpMeter($0) }.sorted { $0.title.contains("ampu") && !$1.title.contains("ampu") }) { w in
            meterRing(w)
          }
        }
      }

      // Bottom breathing room before the divider. Adds ON TOP of the VStack's 15px
      // gap, so the space below the last ring row is a touch more than the row-to-row
      // gap — tuned by this height (done here, not via chained .padding on the cluster,
      // which compounds and inflates every edge in this interpreter).
      Rectangle().fill("#1F2430").frame(height: 0)
    }
    .padding(9)
    Divider()
  }

  // WORKSPACES — labelled section header + count, then the list. This is the
  // delimiter between the usage panel and the workspace list.
  HStack(spacing: 8) {
    Text("WORKSPACES").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
    Spacer()
    Text("\(workspaces.filter { !isUsageMeter($0) }.count)")
      .font(.system(size: 10, design: .monospaced)).foregroundColor("#6E7787")
  }
  .padding(9)
  Divider()

  // Drag-and-drop reorder (persisted) — the supported way to make the list
  // draggable; the drop sends workspace_id + target index to workspace.reorder.
  Reorderable(workspaces.filter { !isUsageMeter($0) }.sorted { $0.index < $1.index }, move: "workspace.reorder") { w in
    row(w)
  }
  Spacer()
}
