# task 19: tiling fixes

PR title: `app: resize without the layout probe; adjustingRatio returns an optional; neighbor is min-by`

Depends on: 15 (the engine calls `activeSession` directly).

## Why

`Session.resizeFocused` (Session.swift:310-333) calls
`tree.adjustingRatio`, then lays the whole tree out twice (`before`,
`after`) to compare widths, and on mismatch calls `adjustingRatio` a
third time with the opposite sign. The sign is already correct by
construction: `SplitNode.adjustingRatio` applies `+delta` under `first`
and `-delta` under `second` (SplitTree.swift:198, :211), so right/down
always grows the focused pane. The probe is unreachable in the normal
case and reachable as a bug: at the clamp floor (ratio 0.1, pane is the
first child) pressing `h` leaves the ratio unchanged, `grew` is true via
`a.width >= b.width`, `wantedGrowth` is false, and the flip re-runs with
`+delta`, growing the pane on a shrink keypress. Two full-tree layouts
per keystroke are also the kind of per-frame cost CLAUDE.md forbids.

`adjustingRatio` returns `(SplitNode, Bool)` where the Bool means
"found", and writes the first-child and second-child arms as the same
13 lines with one sign flipped. `SplitNode.neighbor` hand-rolls an argmin
with `best!.1`. `layout(in:gap:)` threads a `gap` no caller ever passes.

## Changes

- `resizeFocused`: delete lines 316-328. Body is
  `guard let adjusted = tree.adjustingRatio(around: focusedID, axis:
  axis, delta: delta) else { return }; self.tree = adjusted; commit()`.
- `adjustingRatio(around:axis:delta:) -> SplitNode?`: one loop over
  `[(true, b.first), (false, b.second)]`, recurse into the child that
  contains `id`, else if `b.direction == axis` clamp `b.ratio + (isFirst
  ? delta : -delta)`, else nil.
- `neighbor`: `rects.filter { $0.key != id && eligible($0.value) }.min
  { d2($0.value) < d2($1.value) }?.key`.
- `layout(in:)` with `private static let gap: CGFloat = 1` inside.
- Add `app/Tests/MuxTests/SplitTreeTests.swift` with a test target in
  `Package.swift`: insert/remove round-trips, `moving` at an edge
  returns nil when already spanning it, `adjustingRatio` at the clamp
  floor returns the same ratio and never flips sign, `neighbor` picks
  the nearest centre. This is the first Swift test target; SplitTree is
  pure data and the cheapest place to start one.

## Keep

- Resize mode doctrine: h/j/k/l nudge the enclosing split's ratio,
  H/J/K/L move the pane, 0.1...0.9 clamp, `step` 0.03, the outline on
  the acted-on pane.
- `moving(_:direction:in:)` unchanged.

## Done when

- `rg -n 'adjustingRatio' app/Sources` shows a `SplitNode?` return and
  no tuple.
- `rg -n 'best!' app/Sources` returns nothing.
- `swift test --package-path app` passes the new target; CI runs it.
- Manual: in a 1:1 horizontal split press `h` until the left pane is at
  its minimum and keep pressing; it stays put. Then `l` grows it.
