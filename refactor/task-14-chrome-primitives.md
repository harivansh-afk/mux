# task 14: three chrome views and no others

PR title: `app: PanelView, ModeBarView and FlippedView are the only chrome; PaneLabels.swift goes`

Depends on: 04.

## Why

Every piece of chrome discovered the same ideas independently.

- `PaneLabelView` (PaneLabels.swift:31-107) is `ModeBarView` retyped
  around one pink string: `textInset` (:65-67) is character for character
  `ModeBarView.textInset` (ModeBar.swift:52-54); `layout()` (:80-90)
  computes the identical frame; `render()` is
  `render([.highlight(pane.target ?? "local")])` plus the same
  `panelBg`. It skips the theme observer ModeBarView has and excuses it
  in a comment. `PaneLabelParts` is an enum namespace around one
  function with one caller.
- `HostsWindowView` and `HelpOverlayView` are the same bordered panel
  written twice: `wantsLayer`, `borderWidth = 1`, a title label, an esc
  badge, a `#selector(render)` theme observer, the identical
  `init?(coder:)` stub (HostsWindow.swift:148-166 vs HelpOverlay.swift:78-107),
  the same title-row math (:344-355 vs :158-172), the same
  `panelBg`/`dim` border/accent-badge render (:455-467 vs :185-200).
- `FlippedView` is private in CanvasOverlay.swift; `WorkspaceView` and
  `PaneContainerView` each re-declare `isFlipped { true }`; `ScrimView`
  and `StageView` exist to hold a `mouseDown` closure.
- `ModeBarSegment` (ModeBar.swift:13-41) is a struct plus `Kind` plus
  four static factories whose only purpose is letting call sites write
  `.key("x")`, which enum cases with payloads already allow. No caller
  reads `.kind` or `.text` outside `render`.
- `Chrome.uiFont` is dead (task 05). `Appearance` is a two-case enum
  used only as `== .dark` (Theme.swift:173, :179, :194;
  PaneScrollView.swift:178). `NSColor.darken(by:)` clamps with
  `min(b * (1 - amount), 1)` where the product cannot exceed `b`.
  `HelpOverlay.partition` is a 30-line greedy column balancer whose only
  input is a six-entry compile-time constant. `desiredSize(in _:)`
  ignores its parameter. `ModeBarView` and the two panels alias
  `Chrome.font`/`boldFont` into private statics.

## Changes

### UI/Theme.swift

- `enum ModeBarSegment { case badge(String), key(String), dim(String), highlight(String) }`
  moves here from ModeBar.swift (it is the chrome vocabulary). Every
  existing call site compiles unchanged.
- `ThemeManager.isDark: Bool` replaces `Appearance`; `palette { isDark ?
  .dark : .light }`.
- Delete the `min(...)` clamp in `darken`.

### UI/Chrome.swift (new; or at the bottom of Theme.swift)

```swift
/// A plain view with a top-left origin and an optional click handler.
final class FlippedView: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with _: NSEvent) { onClick?() }
}

/// The bordered panel every centred overlay is: panelBg, one hairline,
/// a bold title left, an accent badge right, re-rendered on theme change.
class PanelView: NSView {
    var title: String
    var badge: String
    static let inset: CGFloat = 14
    func desiredSize(in bounds: NSRect) -> NSSize   // title row + bodyHeight + insets
    var bodyHeight: CGFloat { 0 }     // subclass
    func layoutBody(in rect: NSRect) {}   // subclass, top-left origin
    func renderBody(_ palette: Palette) {}   // subclass
}
```

`PanelView` owns the theme observer (block-based, token stored, removed
in deinit), the `init?(coder:)` stub, the title-row layout, and the
title/badge attributed strings. `HelpOverlayView` and `HostsWindowView`
subclass it and implement the three hooks only.

### UI/ModeBar.swift

- Uses `ModeBarSegment` from Theme.swift; `render`'s switch becomes
  `case let .badge(text)` etc.
- Exposes `var desiredSize: NSSize` (width from `label.fittingSize` plus
  inset, height `Chrome.barHeight`) in addition to `desiredWidth`.
- `PaneTagView: ModeBarView` (20 lines): `init(pane:)` renders
  `[.highlight(pane.target ?? "local")]`, `override func hitTest -> nil`,
  `var paneFrame: CGRect?` moved from `PaneLabelView`. The four-sided
  inset ("tags hug their text") is `fit()` = `setFrameSize(desiredSize
  with height = text height + inset*2)`; document the one difference from
  the bars in one line.
- Delete the `font`/`boldFont` aliases; use `Chrome.` directly.

### UI/PaneLabels.swift

Deleted. `promptDir` becomes `var promptDir: String?` on `PaneView`
(it reads `pwd` and nothing else).

### UI/HelpOverlay.swift

- Subclass `PanelView`; delete the border/title/badge/observer code and
  the `init?(coder:)` stub.
- `private static let columns: [[Section]] = [[prefix, sessions, resize], [hosts, canvas, app]]`
  replaces `sections` + `partition` + the `groups` property. A section
  list edit moves the split by hand; that is one bracket.
- `desiredSize` drops the unused parameter (or keeps `PanelView`'s
  signature and ignores it; pick the base's).
- Delete the `font`/`boldFont`/`rowHeight` aliases and the duplicated
  `"keybinds"`/`" esc close "` literals (the base holds them once).

### UI/HostsWindow.swift

Only the panel plumbing changes here (subclass `PanelView`, delete the
duplicated init/layout/render lines); the row model is task 16.

### UI/CanvasOverlay.swift and MuxWindowController.swift

`ScrimView`, `StageView`, the private `FlippedView`, and `WorkspaceView`
are replaced by the shared `FlippedView`. `PaneContainerView` stays (it
has a `layout()` override) but reads `isFlipped` from... no, keep its
own one-liner; it is one line.

## Keep

- Chrome doctrine: one face, one size knob, every metric derived; the
  bars flush with the corners; prefix tags share the bars' voice with the
  four-sided inset; "overlays say each thing once" (no heading row; the
  keybinds title beside the esc badge; the `ix vms` heading stays).
- `ModeBarView`'s half-slack horizontal inset rule and its comment.

## Done when

- `PaneLabels.swift` does not exist; `rg -n 'PaneLabelView|PaneLabelParts|Appearance|partition\(' app/Sources`
  returns nothing.
- `rg -n 'isFlipped' app/Sources` returns `FlippedView` and
  `PaneContainerView` only.
- `rg -n 'borderWidth = 1$|muxThemeDidChange' app/Sources/Mux/UI/{HelpOverlay,HostsWindow}.swift`
  returns nothing (both live in `PanelView`).
- `rg -n 'NSFont' app/Sources` returns only `Theme.swift`.
- The keybinds overlay, hosts window, mode bar, session indicator and
  prefix tags render pixel-identical in light and dark (compare
  screenshots before and after; the theme flip mid-overlay still
  recolours).
- Inventory: ≥ 190 lines fewer.
