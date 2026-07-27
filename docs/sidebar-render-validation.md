# cmux Custom-Sidebar Render Validation

**Audited:** 2026-07-27 against cmux 0.64.20 and upstream `main`.

## Question

Can cmux deterministically validate a custom sidebar end to end, beyond source interpretation?

## Findings

- `cmux sidebar validate <name>` is stronger than a parser-only check. Upstream
  `CustomSidebarValidator.validate` calls `SwiftViewInterpreter.evaluate` against a fixed synthetic
  workspace context and accepts any non-null `RenderNode`.
- Validation still does not mount `RenderNodeView`, run SwiftUI/AppKit layout, evaluate every branch
  reached only by live workspace data, or inspect visible pixels.
- `cmux rpc extension.sidebar.snapshot '{}'` serializes workspace data. It does not load the custom
  sidebar, return a `RenderNode`, expose a view tree, or perform layout.
- The remote renderer exercises the full offscreen AppKit/SwiftUI path through
  `RenderWorkerCoordinator`, but publishes a remote Core Animation layer rather than an image or
  serializable view tree. No public CLI/RPC wraps it as a render assertion.
- `CMUX_RENDER_WORKER_DEBUG=1` exposes worker/pump/layout telemetry, not source-level diagnostics for
  unsupported interpreter constructs.
- Last-good rendering can mask a failing edit: `CustomSidebarModel` retains the prior successful
  node if a new evaluation returns nil.

## Practical ceiling

1. Run `cmux sidebar validate <name>` for synthetic interpretation.
2. Run `make sidebar-live` to stage the repo file under a temporary name and open the real live-data
   path. The helper closes the surface and removes the staged file after inspection.
3. Inspect the result visually. For a blank panel, replace the body with `Text("HELLO")`, verify it,
   then restore helpers and views incrementally.

Do not add a brittle screenshot/OCR gate: cmux currently exposes no stable isolated-pixel capture,
render-tree, or accessibility-tree contract. Screenshots remain useful for human review, not as a
deterministic CI assertion.

Upstream issue [manaflow-ai/cmux#9002](https://github.com/manaflow-ai/cmux/issues/9002) requests a
supported mounted-render artifact. Until that exists, `make sidebar-live` reports command/mount
success and explicitly leaves the visual verdict to the human; it never claims a pixel pass.

## Upstream references

- `Packages/macOS/CmuxSwiftRender/Sources/CmuxSwiftRender/SwiftViewInterpreter.swift`
- `Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Sidebar/CustomSidebarValidator.swift`
- `Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Sidebar/CustomSidebarModel.swift`
- `Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Sidebar/CustomSidebarContentView.swift`
- `Packages/macOS/CmuxSidebarInterpreterService/Sources/CmuxSidebarRemoteRender/RenderWorkerCoordinator.swift`
- `Sources/TerminalController+CustomSidebarCommands.swift`

Repository: <https://github.com/manaflow-ai/cmux>
