# task 15: one overlay lifecycle; the engine reaches the real objects

PR title: `app: ChromeOverlay presenter; controller forwarders deleted; PrefixEngine modes are the whole story`

Depends on: 14.

## Why

The overlay lifecycle has no shape. Presence is `isHidden` for the mode
bar and `superview != nil` for the help, hosts, canvas and pane labels.
Showing is the same three lines each time (`removeFromSuperview();
container.addSubview(x); positionX()`) at Overlays.swift:17-19, :86-89,
:108-111. Hiding is `x.removeFromSuperview()` in two one-line methods.
Positioning is `center(x, size: x.desiredSize(in:))` twice.
`layoutPanes` (MuxWindowController.swift:373-394) re-tests each of five
presence flags in five `if` blocks. `PrefixEngine.setMode` (:111-119)
calls six `hide*` methods by name on every mode change so no overlay is
forgotten, and holds a weak `indicatorController` "in case key windows
change mid-mode" for an app with one window by doctrine.

`MuxWindowController.swift:262-350` ("Tiling API") is ~20 one-line
forwarders to `activeSession` (`focusedPane`, `addInitialPane`, `split`,
`closeFocusedPane`, `focusDirection`, `toggleZoom`, `resizeFocused`,
`moveFocusedPane`, ...). Overlays.swift:114-154 is seven more forwarders
to `hostsWindow`, each `hostsWindow.foo(); positionHostsWindow()`, while
`PrefixEngine` already reaches `controller?.canvasOverlay.selection?.pane`
directly (:222-223) and the trailing re-centre is dead on four of them
(they run through `refresh()`, which fires `onContentChange`, which is
wired to `positionHostsWindow`). A key press travels engine → controller →
view with no decision in the middle. These are the two most-churned
files in the repo (35 and 24 commits).

`split(from:ghosttyDirection:)` (:308-316) folds
`GHOSTTY_SPLIT_DIRECTION_LEFT` and `RIGHT` into the same call without
`before:`, silently dropping the direction; `focus(from:ghosttyGoto:)`
ignores its pane. These 31 lines are the only reason the controller
imports GhosttyKit.

`WorkspaceView` exists, per its comment, so the canvas push can slide one
view; the push is gone (`positionCanvasOverlay` is `canvasOverlay.frame =
container.bounds`), and the view is an exact stand-in for `container`.
Three "keep the overlay above any panes added since last time" lifts
(Overlays.swift:17-19, :86-88, MuxWindowController.swift:377-381) guard a
state that cannot occur: panes go into `workspace`, never `container`.
`MuxWindow.swift` is a 15-line file for two one-line overrides used
forty lines away in another file.

The hosts template picker is a sub-mode kept outside `Mode`:
`handleHostsKey` asks the view `hostsWindowPickingTemplate`, and re-renders
the bar by hand at three sites (:265, :268, :296) with a `templateSegments`
that has no `Mode` case. The `.help` branch (:200-210) is a switch whose
two arms are identical.

## Changes

### MuxWindowController+Overlays.swift

```swift
protocol ChromeOverlay: NSView { func desiredSize(in bounds: NSRect) -> NSSize }
extension MuxWindowController {
    func present(_ overlay: ChromeOverlay)     // addSubview if needed, position, append to presented
    func dismiss(_ overlay: ChromeOverlay)     // removeFromSuperview, remove from presented
    func dismissAllChrome()                    // every presented overlay, the pane tags, the resize outline
}
```

`PanelView` (task 14) conforms; `CanvasOverlayView` conforms returning
`bounds`; `ModeBarView` conforms with its `desiredSize`. The mode bar and
session indicator are positioned by an `edge` (`positionBar(_:edge:)`
replaces `positionModeBar` + `positionSessionIndicator`); everything else
is centred. `layoutPanes` becomes `for o in presented { position(o) }`
plus the workspace frame and session layout. The mode bar uses superview
presence like everything else; `setModeIndicator(nil)` is `dismiss(modeBar)`.

Delete `showHelp`, `hideHelp`, `positionHelpOverlay`, `hideHostsWindow`,
`moveHostsWindow`, `hostsWindowPickingTemplate`, `showHostsTemplates`,
`showHostsMachines`, `commitHostsTemplate`, `copyClientDigest`,
`positionHostsWindow`, `moveCanvasOverlay`, `center`. Keep
`showHostsWindow` (wires `onContentChange` once, in init, then
`reload` + `present`), `commitHostsWindow`, `newSessionOnHostsSelection`,
`createIXVM`, the canvas show/hide/commit (task 17 trims them), the
resize outline, the pane tags.

### MuxWindowController.swift

- Delete the "Tiling API" block except `removePane` (needs
  `session(owning:)`) and `restoreSessions`. Callers use
  `controller.activeSession?.x(...)`.
- `split(from:ghosttyDirection:)` and `focus(from:ghosttyGoto:)` are
  deleted; `SplitDirection.init?(_ d: ghostty_action_split_direction_e)`
  returning `(direction, before)` and
  `FocusDirection.init?(_ d: ghostty_action_goto_split_e)` live in
  `Terminal/NSEvent+Ghostty.swift` (renamed `Ghostty+Mux.swift`: it is
  the libghostty-to-mux translation file). `GhosttyRuntime.action` and
  the context menu call `session(owning: view)?.split(from: view,
  direction:, before:)` and `activeSession?.focusDirection(_)`. This
  fixes the dropped `before:`.
- `WorkspaceView` deleted; `workspace` is a `FlippedView` pinned once
  with an autoresizing mask; the per-layout `workspace.frame =` goes.
  Delete the three z-order lifts and their comments; keep only the one
  real ordering need, "mode bar above the canvas overlay"
  (Overlays.swift:249-255), stated in those words inside `present`.
- `MuxWindow` moves to the bottom of this file beside
  `PaneContainerView`; `MuxWindow.swift` deleted. Keep the first clause
  of its comment.
- Drop `import GhosttyKit` from the controller.

### PrefixEngine.swift

- `Mode` gains `case hostsTemplate`. `setMode` becomes: `controller?.dismissAllChrome()`,
  then `guard let controller, newMode != .normal`, set the bar from
  `static func segments(for: Mode)`, then one `present`/show call per
  case (`.hostsTemplate` calls `hostsWindow.showTemplates()`; leaving it
  via `setMode(.hosts)` calls `showHosts()`). `indicatorController` is
  deleted; the three manual `setModeIndicator` calls in `handleHostsKey`
  become `setMode(.hosts)` / `setMode(.hostsTemplate)`.
- `.help` is `case .help: setMode(.normal); return nil`.
- `handleHostsKey` calls `controller.hostsWindow.move(by:)`,
  `.pickingTemplate`, `.copyDigest()`, `.commitTemplate()` directly; the
  canvas branch calls `controller.canvasOverlay.move(by:)`.

## Keep

- Every keybinding and mode transition exactly as `HelpOverlayView.sections`
  lists them; the keybinds overlay is the spec and this task must not
  change a row.
- Overlays never take focus; the engine owns keys (CLAUDE.md).
- The resize outline's one-device-pixel stroke and its follow-on-click
  behaviour (`noteFocused`).
- "Mode bar above canvas" ordering.

## Done when

- `rg -n 'hideHelp|showHelp|hideHostsWindow|moveHostsWindow|hostsWindowPickingTemplate|showHostsTemplates|showHostsMachines|commitHostsTemplate|copyClientDigest|moveCanvasOverlay|indicatorController|WorkspaceView|templateSegments' app/Sources`
  returns nothing except `segments(for:)`'s `.hostsTemplate` arm.
- `rg -n 'removeFromSuperview' app/Sources/Mux/UI/MuxWindowController*.swift`
  returns only `dismiss` and the pane-tag teardown.
- `rg -n 'GhosttyKit' app/Sources/Mux/UI/MuxWindowController.swift`
  returns nothing.
- `MuxWindow.swift` does not exist.
- Manual: every mode enters and exits cleanly, including
  hosts → t → esc → esc; a ghostty `new_split:left` keybind (add one to
  your ghostty config to test) now opens on the left.
- Inventory: ≥ 190 lines fewer across the three files.
