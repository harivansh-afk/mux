# task 16: the hosts window is a list

PR title: `app: HostsWindowView renders one attributed label into a fixed-width box`

Depends on: 14 (PanelView), 15 (presenter; `onContentChange` goes).

## Why

`HostsWindow.swift` is 539 lines for a list with a handful of actions,
and the bulk is self-inflicted. `refresh()` (:403-421) tears down every
`NSTextField` and allocates two fresh ones per row, and it runs on every
event: reload, each per-host probe callback, the ix listing, the digest
reply, copy, showHosts, showTemplates, commitTemplate. `layout()`
(:356-388) then hand-computes a frame for each of the 2N fields
(`sizeToFit`, right-align meta, clamp main against `meta.minX`, per-row
visibility) and `desiredSize` (:319-325) walks them again to measure.
Because the width is measured from live fields, the box changes size as
answers land, so three mechanisms exist to hide that: `statusReserve`
(the pixel width of the literal "ok 100ms  10 ptys"), `grownSize` /
`carriedSize` (monotone within one open, floored by the previous open),
and `onContentChange` → `positionHostsWindow` to re-centre after every
answer. Two parallel row models (`hostRows`/`templateRows`,
`hostIndex`/`templateIndex` behind computed `rows`/`index`) and two
staleness counters (`generation`, `templateGeneration`) keep the machine
list alive under the template list.

`HelpOverlayView` next door already shows the cheaper shape: one
multiline `NSTextField` per column carrying an attributed string with a
mono-padded key gutter. The chrome face is fixed-advance (Berkeley Mono
or the system mono fallback), so column math is exact.

## Changes

- One `rows: [Row]` and one `index`. Entering the template list stashes
  `(rows, index)` in `private var stashedHosts: ([Row], Int)?` and
  `showHosts()` restores it. The doctrine requirement ("coming back does
  not re-probe") holds because the stash holds the answered rows. One
  `generation` covers both lists: a probe callback checks it; a template
  listing that arrives after `showHosts()` finds `pickingTemplate ==
  false` and drops.
- Render the body as one attributed string: for each row, the name,
  two spaces, the detail in dim, padding to a fixed `columns` count, the
  status right-aligned in its colour; the selected row's attributes
  switch to `accentContrast` and the `selectionBar` lands on
  `rowsTop - row * (index + 1)` as today (pin the paragraph style's
  min/max line height to `Chrome.rowHeight` so the bar aligns).
- `desiredSize` = `(columns * Chrome.font advance + inset * 2, rows.count
  + 2 rows + inset * 2)`, capped to the container as today. `columns` is
  a constant (52 covers alias + addr + "ok 999ms  99 ptys"); a longer
  alias truncates with an ellipsis in the name column. Delete
  `statusReserve`, `grownSize`, `carriedSize`, `onContentChange`,
  `mainLabels`, `metaLabels`, and the per-row loops in `layout()` and
  `desiredSize`.
- `Status`, `Kind`, `Row`, `selectedHost`, `selectedTemplate`, `move(by:)`,
  `copyDigest`, `commitTemplate`, the footer text, `short(_:)`, and the
  probe/ix/digest callbacks stay as they are; they are the actual list.
- Subclass `PanelView` (task 14); the title is `pickingTemplate ?
  "template" : "hosts"` and the badge `" esc back "` / `" esc close "`.

## Keep

- Hosts doctrine: local + aliases with live probe + ix VMs; enter/H/J/K/L
  split, c new session, y copy digest, n new VM, t template; the `ix vms`
  heading row; inert rows for stopped VMs and an empty hosts file; focus
  wraps at both ends; the highlight never moves under the user when rows
  are appended.
- All queries fire on open and fill in as they answer; the box is usable
  immediately.
- The sticky-sizing doctrine line in CLAUDE.md is replaced by "fixed
  width, height from the row count"; say so in the PR and in task 01's
  decisions section.

## Done when

- `rg -n 'statusReserve|grownSize|carriedSize|onContentChange|mainLabels|metaLabels|templateRows|templateIndex|templateGeneration' app/Sources`
  returns nothing.
- `HostsWindow.swift` ≤ 330 lines.
- Manual: open the hosts window with spark up, down, and mid-probe; the
  box does not move or resize as answers land; t/esc round-trips keep
  the probe results; y copies the full digest; the selection bar sits on
  the highlighted row in both lists at both themes.
