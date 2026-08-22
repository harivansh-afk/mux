# task 17: canvas trims

PR title: `app: one MirrorHostView for stage and cards; no Group; one animation; one close path`

Depends on: 15.

## Why

`CanvasOverlayView` honours every decided canvas invariant and spends
more scaffolding than it needs to.

- `struct Group { let entries: [Entry] }` (:31-36) wraps one array. It
  is stored as `groups`, flattened into `items` in `reload`, and
  re-walked in `positionTrack` (:306-318) with a hand-managed `itemIndex`
  cursor in lockstep with `items`. The only information it carries, where
  a session boundary falls, is already `Entry.sessionIndex`.
  `MuxWindowController.canvasGroups()` exists to build the wrapper.
- The stage and each card are the same object built twice: mirror
  `CALayer` + `contentsGravity`/`masksToBounds` + black shadow +
  `shadowPath` refreshed inside a disabled-actions transaction
  (:88-103 and :372-376 for the stage; :505-519 and :544-556 per card).
  The pane aspect with its 16/9 fallback is written at :496-501 and
  :359-360.
- `move(by:)` adds a `CABasicAnimation` on the stage's opacity (0.7 → 1,
  0.13s) on every j/k on top of the wheel spring. The comment concedes
  the mirror swap is instant; CLAUDE.md says canvas motion is one
  retargetable spring and "must read as a keystroke, not an animation".
- `showCanvasOverlay` calls `positionCanvasOverlay()` and
  `applyCanvasOcclusion()` and then `layoutPanes()`, which calls both
  again; `applyCanvasOcclusion` touches every surface of every session,
  so every open does it twice. The three callbacks are reassigned on
  every open. `commitCanvas(_:)` repeats `hideCanvasOverlay`'s close
  sequence line for line.

## Changes

- `private final class MirrorHostView: FlippedView` holding `let mirror
  = CALayer()`, the shadow setup (radius and offset as init parameters:
  28/14 for the stage, 10/5 for a card), and a `layout()` that sets
  `mirror.frame = bounds` and `shadowPath` in one disabled-actions
  transaction. The stage is one; each `WheelItemView` contains one.
- `var aspect: CGFloat` on `PaneView` (bounds ratio, 16/9 when the view
  is too small to know), used by both places.
- Delete `Group`; `reload(entries: [Entry], selected: UUID?)`. In
  `positionTrack`, iterate `items` once and add `sectionGap` when
  `items[i].entry.sessionIndex != items[i-1].entry.sessionIndex`.
  `canvasGroups()` becomes a `flatMap` returning `[Entry]`.
- Delete the stage opacity tick.
- Assign `onSelectionChange`/`onJump`/`onCancel` once in the controller's
  init. `showCanvasOverlay` calls `present(canvasOverlay)` (task 15),
  sets `canvasOpen`, and lets the one `layoutPanes()` position and
  occlude. `commitCanvas(_:)` ends with `selectSession(...);
  session.reveal(pane); hideCanvasOverlay()`.
- Decision 1 from task 01 applies here: if the doctrine wins on borders,
  `render()` and `WheelItemView.render` drop the `borderWidth`/`borderColor`
  lines and selection reads by alpha alone; if the code wins, nothing
  changes and the doctrine already says so after task 01.

## Keep

Every line of CLAUDE.md's canvas section as it reads after task 01, and
in particular: mirror layers re-read at 30Hz and never a pane frame
touched; the scroll monitor installed and removed in
`viewDidMoveToSuperview` with position-before-scroll and the `hoverPane`
-1/-1 report; the single spring constants (1200/68/1); bounded selection;
`cameFrom` marker; cards show only the state glyph and the host; the two
stage descriptor lines; teardown scheduled after the fade and standing
down on reopen.

## Done when

- `rg -n 'struct Group|canvasGroups|stage-tick|shadowRadius' app/Sources`
  returns only the two `MirrorHostView` initialisers.
- `rg -c 'applyCanvasOcclusion\(\)' app/Sources/Mux/UI/MuxWindowController+Overlays.swift`
  is ≤ 2 (the definition and the teardown).
- `CanvasOverlay.swift` ≤ 520 lines.
- Manual: open the canvas with three sessions and an ix pane; j/k/click/
  enter/esc; wheel-scroll over the stage scrolls the previewed pane and
  nothing under the scrim; reopen mid-close bends the fade; session
  indicator follows the selection.
