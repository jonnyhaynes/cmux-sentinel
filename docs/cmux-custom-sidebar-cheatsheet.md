# cmux Custom Sidebar — Gotchas Cheatsheet

A one-screen field guide to the traps that cost real hours when building a cmux
[custom sidebar](https://cmux.com/docs/custom-sidebars). The sidebar runs a
**subset** of an interpreted SwiftUI-style language; the official docs tell you the
API, this tells you what bites. Everything below is verified through **cmux 0.64.20**
(re-check after upgrades — the interpreter and data model move fast).

- Official authoring reference: `cmux docs sidebars` /
  <https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/custom-sidebars.md>
- Roadmap (lifts most of these limits): `docs/data-driven-sidebar-plan.md` upstream.

## Validation is not rendering

- **`cmux sidebar validate <name>` parses and interprets against a fixed synthetic data context.**
  It does **not** mount `RenderNodeView`, run SwiftUI/AppKit layout, exercise every live-data branch,
  or prove visible pixels. A file can validate and still render blank/collapsed with real data.
- **There is no public rendered-tree, accessibility-tree, or pixel snapshot RPC.**
  `cmux sidebar open <name>` is the strongest live smoke path; `select`/`reload` exercise the same
  mounted renderer. Visual inspection remains necessary. In remote-renderer mode,
  `CMUX_RENDER_WORKER_DEBUG=1` adds worker/layout telemetry but not source-level interpreter errors.
- The upstream implementation audit and rationale for keeping visual inspection instead of a brittle
  screenshot/OCR CI gate are in [`sidebar-render-validation.md`](sidebar-render-validation.md).

## Data channels (what actually reaches the sidebar)

- **`progress`, `description`, and `color` DO reach the interpreter, but are null until
  explicitly set.** A known-set render probe is the only valid test; an empty value on an untouched
  workspace proves nothing. `progress.value` + `progress.label` can drive a value-accurate
  `ProgressView(value:)`; `color` and `description` are also bindable.
- **The title is still the strongest identity/fallback channel.** It persists, can be re-resolved
  after workspace refs rotate, and exists before the next poll restores `progress`. Keep stable
  title prefixes for sentinel identity and a Unicode fallback for bootstrap/offline windows.
- **`cmux set-status` does NOT reach custom sidebars.** It renders native-sidebar pills only; the
  binding contract has no status field. Agent-state bridges therefore still need static title
  markers (or another interpreter-visible field).
- **`cmux sidebar-state` and `extension.sidebar.snapshot` are data snapshots, not render probes.**
  The snapshot can omit `progress` immediately after a successful `set-progress`. Verify disputed
  fields with an in-sidebar `Text(...)` against a workspace where the field is known-set.

## Identity: no stable workspace id

- **cmux 0.64.15 removed stable workspace UUIDs.** `cmux workspace list --json` returns
  `id: null`; the only handle is a positional `ref` (`workspace:N`) that **rotates
  across app restarts and reorders**. Don't store a workspace id to match a row later —
  it goes stale on the next restart. Match by a stable signal you control, e.g. a
  **title prefix** (`w.title.hasPrefix("5h ")`), re-resolved every run.

## Language subset

- **String ops `.hasPrefix` / `.contains` / `.hasSuffix` / `.split` DO work**, and so
  does `==`. (An older community note claimed they blank-render — disproven on current
  builds.) Use whichever is clearest.
- **Avoid `||`** (unproven) — use an `if`-chain that returns early. `&&` is fine and
  short-circuits.
- **Top-level `let` referencing `workspaces`/`clock` fails.** Those exist only inside
  the view builder; keep `let` bindings inside the `VStack` body.

## Greedy modifiers that wreck layout

- **`Divider().background("#hex")` is the worst trap** — a color `.background()` is
  greedy and corrupts the WHOLE row (inflates height 3-4× AND breaks the sibling's
  width, shoving content to center). Use a plain `Divider()`.
- **`.frame(maxHeight: .infinity)` and `.overlay { Rectangle().frame(height: 1) }`**
  similarly balloon row height. Use `Divider()` + a single `.padding(n)`.
- **`.contentShape(Rectangle())` is a no-op** — a `Button`'s tap area is only its
  rendered content, so give each row a non-zero background fill to make the whole frame
  tappable.
- **Custom fonts aren't honored.** `.font(.custom(...))` silently falls back to the
  proportional system font and adds ~1s lag. Use `.system(size:, design: .monospaced)`.

## Title markers must be STATIC

- If you encode state in the title (e.g. a working/compacting marker), it must be a
  **static** glyph. An animated / frame-by-frame title floods cmux's title coalescer
  and **freezes the sidebar** (upstream issue #6291).

## Debugging a blank sidebar — don't guess, bisect

1. Replace the whole file with a one-line `Text("HELLO")` and confirm it renders (this
   proves the pipeline is alive).
2. Add your helpers/views back **one at a time**, running `cmux sidebar reload` after
   each, until it blanks.
3. The construct you just added is the culprit. This isolates it in ~3 steps instead of
   staring at a silent blank.

---

Worked example: this repo's [`sidebars/workspaces.swift`](../sidebars/workspaces.swift)
puts all of the above into practice (native progress meters with title-anchor fallbacks plus
hook-driven static agent-state markers).
