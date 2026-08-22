# task 04: Swift comments say what the code cannot

PR title: `app: comments that narrate, restate doctrine or remember milestones are deleted`

Depends on: 01.

## Why

1,543 comment lines on 5,404 of Swift. The vendored input code
(`PaneView+Input.swift`, 24%) is at ghostty's own ratio and is left alone.
The mux-authored files run higher and the excess is three kinds:

- Doctrine restated from CLAUDE.md. `PaneView.target` has a 9-line doc,
  `ptyCommand` 5, `defaultCommand` 6, `killRemote` 4, all re-telling
  CLAUDE.md paragraphs. `AppDelegate.swift:6-10` is the single-window
  rule verbatim. `CanvasOverlay.swift:3-23` re-tells the canvas doctrine
  and contradicts itself ten lines later ("grouped under small session
  headers" at :8 versus `Group`'s "No header, no session number" at :31).
  "The workspace never moves for the canvas" appears at
  MuxWindowController.swift:51-54, :396-398 and Overlays.swift:192.
- Narration of the next line. Snapshot.swift:412-413 "Rotate the current
  file to .bak first" above `moveItem(at: url, to: backupURL)`;
  Overlays.swift:17 and :86 "Keep the overlay above any panes added since
  last time" (and false, see task 15); :27-28 and :69-70 "the container
  is flipped, so the bottom is at maxY" twice; HostsWindow.swift:402
  "One path for every mutation" above `refresh()`.
- History and bookkeeping. PaneView.swift:222-227 "M2: every pane is a
  daemon pty... M3: a pane on a host alias is..."; :229-231 "The one
  unlogged hop used to be right here"; Snapshot.swift:3-5 "screen
  contents are the daemon's job starting in M2"; "managed by
  MuxWindowController+Overlays.swift" four times in
  MuxWindowController.swift (:37-38, :50, :63, :66-67); "(ghostty does the
  same)" tags at PaneView.swift:158, :172, :287, :515, :590 when the file
  header already attributes the port; PrefixEngine.swift:7-28, a 28-line
  keybinds table that `HelpOverlayView.sections` already holds as data
  and that has drifted (it documents "held-ctrl aliasing", which nothing
  implements, and says canvas binds h/j/k/l when it binds j/k).

## Changes

Delete, do not rewrite. By file:

- `App/AppDelegate.swift`: 6-10, 12-13, 46-47, 118-119, 123-125,
  136-138, 143-145, 177-179, 188-190, 192-194, 223-225.
- `App/GhosttyRuntime.swift`: 157, 170, 177-180, 253, 310, 367, 534-537.
  Keep 4-7 (attribution) and the `SECURE_INPUT` / `MOUSE_VISIBILITY`
  one-liners.
- `App/SecureInput.swift`: all of it except the MIT attribution; task 18
  rewrites the file.
- `State/Snapshot.swift`: 3-5, 412-413, 418. Keep 404-408 (the
  unchanged-snapshot rotation hazard) verbatim.
- `State/Subprocess.swift`: 11-14, 32-35, 41-44, 55-57, 61-63, keeping
  one line for "read before waiting" and one for "SIGKILL, not
  terminate()".
- `State/IXConfig.swift`: 17-19, 28-30, 33-34.
- `Terminal/PaneView.swift`: 19-27 and 30-34 and 395-400 and 452-454
  down to one line each; 117-118; 222-227; 229-231; the five ghostty
  tags; 503-504. Keep 10-12 (`mouseDownCanMoveWindow`), 260-264
  (scale by hand before the window exists), 425-427 (never send --cwd
  beside --cwd-from).
- `Terminal/PaneScrollView.swift`: 717-733 header down to the
  attribution and the one sentence about +Y inversion; the block
  comments above each observer registration.
- `Tiling/PrefixEngine.swift`: 7-28 entirely. Keep 3-6 and 29-30.
- `Tiling/Session.swift`: 29-33 ("Sessions are pure client-owned
  layout...", CLAUDE.md), 106-111 to one line, 130-135 to one line.
- `UI/MuxWindowController.swift`: 17-19 (WorkspaceView's reason no
  longer holds; task 15 deletes the class), 32, 37-38, 50, 51-54, 63,
  66-67, 396-399.
- `UI/MuxWindowController+Overlays.swift`: 3-9, 17, 27-28, 69-70, 86,
  191-192, 216-223 and 230-238 (the scroll-monitor rationale is
  CLAUDE.md's; keep a 3-line pointer), 390-393 (stale: claims "title ·
  host · dir"), 398-401.
- `UI/CanvasOverlay.swift`: 3-23 down to four lines (what it is, mirror
  layers, never touch a pane's frame, the engine drives keys); 44, 53-55,
  89-96, 180-181, 198-199, 258-261, 269-272, 302-305, 337-339, 355-356,
  402-405, 416-417, 430-439, 468-470, 566-568, 582-583.
- `UI/HostsWindow.swift`: 3-19 down to three lines (what it lists, that
  `t` swaps to templates, that the engine owns keys); 84-88, 92-102,
  107-115, 281-282, 402. The keybinding list at 7-12 is HelpOverlay's.
- `UI/Theme.swift`: 4-12 (the conditional-theme rule is in CLAUDE.md;
  keep a 3-line version inside `refresh()` at 198-214 and delete the
  rest of that block), the ten Palette field docs that restate the field
  name (keep `divider`, it cites ghostty's formula).
- `UI/ModeBar.swift`: 223-232 to two lines. 266 goes with the constant
  in task 14.
- `UI/PaneLabels.swift`: task 14 deletes the file.
- `UI/HelpOverlay.swift`: 482-487 to two lines.

## Keep

- The two hard-won stage-scroll invariants in CanvasOverlay (as a short
  pointer to CLAUDE.md, not the full text).
- `Snapshot.swift:404-408`.
- `PaneScrollView` attribution; `PaneView+Input.swift` untouched.
- The "ix panes excluded: their local pty cwd is not the VM shell's"
  note wherever the rule is implemented (one place after task 12).

## Done when

- `python3 refactor/tools/inventory.py` reports Swift comment lines
  ≤ 1,050 (PaneView+Input's 228 are inside that).
- `rg -n 'M1|M2|M3|used to be|ghostty does the same|ghostty uses the same' app/Sources`
  returns nothing outside `PaneView+Input.swift`.
- The app builds and the canvas, hosts window and keybinds overlay look
  identical.
