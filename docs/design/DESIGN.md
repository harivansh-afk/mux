# mux design language

Decision record for the UI direction approved 2026-08-13. The living
mockups are in `mockups.html` (open in a browser; keys 1-4 switch sheets,
j/k drive the canvas wheel).

## The three layers

Every piece of information lives in exactly one layer. The default view
never gains a new persistent element; new capability lands in glance, in
canvas, or (later) in a command palette.

1. **Ambient** - always on, color and geometry only, never text.
   Read from the corner of the eye.
2. **Glance** - appears while the prefix is held, vanishes on release.
   One line of text per thing, no more.
3. **Command** - modal surfaces (canvas, hosts, palette). Full detail,
   full control.

## Ambient

- **Host spine**: a 3px strip of host color on the edge of a remote pane.
  Local panes get nothing. This is border geometry, outside the terminal
  cells - mux still paints nothing over cell content for host identity.
- **Session chips**: one row of chips, bottom-center, replacing nothing
  (the mode bar and host indicator keep their corners; all three share one
  box style). A chip is `number + name + 5px state dot`:
  - pulsing yellow: a command is running in that session
  - green: something finished since the session was last looked at
  - red: bell, or a command exited non-zero
  - idle: no dot at all - an idle fleet is nearly invisible
  - 2px host-colored ticks under the chip edge show where its panes live
- Chip numbers ARE the existing `prefix 1-9` sessions. No new abstraction.

## Glance (hold the prefix)

- Holding ctrl+b (past ~350ms) shows, per pane, a one-line mono tag:
  `title · host · state`. Terminals recede slightly (~72% ink), never
  more. Chips gain a few inline words (`build 4m`, `exit 1 · 40s`) without
  growing taller. Releasing the key dismisses everything instantly.
- A tap still arms prefix mode exactly as today.

## Canvas (prefix f) - pane picker

Pane-level, as decided; sessions are groups, not the unit.

- Floats over the dimmed live workspace with air on all sides - not a
  full-bleed takeover and not an edge-docked panel.
- Right: a wheel of pane cards grouped under small session headers. The
  selection is always vertically centered; the previous pane peeks above,
  the next below; distance fades and slightly scales cards. j/k (and
  arrows) scroll, click selects, enter goes, esc snaps home.
- Left: the selected pane previewed large - the same live IOSurface
  mirror the canvas already uses, at the pane's true frame aspect.
  Scaled uniformly, never stretched, never resized: the pty must never
  observe the canvas (hard constraint, unchanged).
- The wheel chooses a pane; `prefix <n>` jumps to a session. Two
  different verbs, two different tools.

## Two voices (typography)

- **Machine voice - Berkeley Mono**: anything the machine said or the
  user could type: commands, paths, hosts, keys, digests, badges.
- **Product voice - SF Pro**: labels about content: titles, session
  names, counts, section headers. Real hierarchy (13/600 titles, 12/500
  body, 11/600 caps headers), not one mono size for everything.
- The rule: mono is for content, SF is for labels about content. Never
  the reverse. Implementation stays one `Chrome` enum - it grows a second
  face and a small set of text styles; no view hardcodes a font.

## Color

- `Theme.swift` palette untouched: panelBg, accent (selection), pink
  (the active item), ok, bad, divider derivation - all as today.
- Three additions, all in the same gruvbox family:
  - running: yellow `#D8A657` (the pulse)
  - host spark: blue `#7DAEA3`
  - host ix: aqua `#89B482`
- Host hues appear only as spines, chip ticks, and glance text. Chrome
  keeps deriving from the terminal background, so themes keep working.

## Motion

- Everything reads as a keystroke, not an animation: 120-180ms, the
  fast-out curve of the existing spring, one retargetable motion per
  surface (retarget mid-flight, never restart).
- Nothing idles except the running pulse (2.2s, shallow) and the
  terminal's own cursor.

## Data honesty

- Chip and tag states come from OSC 133 command marks (start/finish/exit
  code) and terminal titles (OSC 0/2), surfaced by muxd which owns every
  pty. Nothing is guessed from output heuristics; if the shell has no
  integration, the pane simply shows no state rather than a wrong one.

## Explicitly unchanged

- Single window, ever. Sessions via `prefix 1-9 / c / n / p`. No
  focus-follows-mouse. No pane resizing for thumbnails. No client-side
  screen state. No persistent status bar, no per-pane title bars, no
  text badges painted over terminal cells.
