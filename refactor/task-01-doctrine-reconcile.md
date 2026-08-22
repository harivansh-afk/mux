# task 01: CLAUDE.md describes the program that exists

PR title: `doctrine: canvas clauses match the code; record the decisions`

Depends on: nothing. Every other task assumes this landed.

## Why

CLAUDE.md's canvas section is the instruction set every agent reads before
touching the app, and six of its "decided / do not reintroduce" clauses
describe code that is not there. Checked on 2026-08-22:

| clause in CLAUDE.md | what the code does |
|---|---|
| "a 38% right panel" | `wheelWidth = Chrome.fontSize * 12`, fixed (CanvasOverlay.swift:40) |
| "narrower windows dock the canvas to the bottom edge" | no docking path; `rg dock` hits one comment |
| "stage and cards have NO borders (removed; do not reintroduce)" | `stage.layer?.borderWidth = 1/scale` (:411), `thumb.layer?.borderWidth` on every card (:587) |
| "a within-window NSVisualEffectView (.fullScreenUI) backdrop under a black tint at 0.85 (dark) / 0.6 (light)" | `ScrimView` is a bare layer, `NSColor.black.withAlphaComponent(dark ? 0.95 : 0.72)` (:408); no NSVisualEffectView in the target |
| "smooth distance falloff d==0 ? 1 : max(0.22, 0.5 - 0.14*(d-1)) in renderSelection" | `i == index ? 1 : (abs(i-index) == 1 ? 0.6 : 0.35)` (:426) |
| "slot glyph showing the pane's cell in its split tree", "currentWheelWidth" | neither symbol nor concept exists |
| "The slab position lives in layoutPanes (canvasOpen)" | `layoutPanes` never reads `canvasOpen`; the workspace is pinned to `container.bounds` |

Each stale clause is a standing instruction to rebuild something that was
deleted. That is the mechanism that keeps regrowing code, so it is fixed
before any code is.

## Changes

1. For each row above, pick code or doctrine. Where you pick the code,
   rewrite the clause to say what the code does. Where you pick the
   doctrine, open a follow-up task file (`task-22-...`) that restores it
   and leave the clause in place with "(not yet implemented; task 22)".
   The plan assumes code wins for docking, the 38% panel, the falloff
   formula, the slot glyph, and `currentWheelWidth` (delete the clauses),
   and asks you to decide borders and the scrim.
2. Collapse the canvas bullets ("prefix f is the canvas panel", "Canvas
   docking", "Canvas spacing doctrine", "Canvas motion", "Canvas stage
   descriptor", "Stage scroll", "Canvas chrome") into the invariants the
   code holds today. Keep, verbatim, the ones that are hard-won and true:
   mirror CALayers at 30Hz and never resize a pane; one retargetable
   spring, no resume flight; bounded selection, no wrap; the two
   stage-scroll invariants (local monitor, position before scroll); the
   stage descriptor lines; tags and cards show only the host. Everything
   else in those bullets is either wrong or restates a line in the code.
3. Record the six decisions from `refactor/README.md` as one short
   "Refactor decisions (2026-08)" section: borders, scrim, docking, DER
   pin, rendezvous flip, `muxd pin`. One line each, the answer and the
   date.
4. Delete "Held-ctrl aliasing" from PrefixEngine's header when task 04
   runs; note here that CLAUDE.md does not mention it and nothing
   implements it.

## Keep

Every non-canvas section. In particular the crash-safety, title replay,
conditional-theme, transport, and single-window sections are correct as
written and are cited by later tasks.

## Done when

- Every sentence in the canvas section can be pointed at a line of code
  that does it, or carries a task number.
- The decisions section exists with six answered lines.
- `rg -n 'NSVisualEffectView|38%|dock|slot glyph|currentWheelWidth|0\.14' CLAUDE.md`
  returns only lines that carry a task number.

## Result (2026-08-22)

CLAUDE.md is not tracked in this repo (excluded by a global gitignore
line that applies to every repo, not just mux; `git log --all -- CLAUDE.md`
is empty). The edit below was made to the local file at
`/Users/rathi/Documents/Git/mux/CLAUDE.md`. Whether to start tracking it
is Hari's call; this PR carries the record of what changed and why so the
edit isn't lost if that call goes either way.

Per-clause verification, confirmed against the code on this branch:

| clause in CLAUDE.md | what the code does | verdict |
|---|---|---|
| "a 38% right panel" | `wheelWidth = Chrome.fontSize * 12`, fixed (CanvasOverlay.swift:41) | code wins, clause deleted |
| "narrower windows dock the canvas to the bottom edge" | no docking path anywhere in UI/ | code wins, clause deleted |
| "stage and cards have NO borders (removed; do not reintroduce)" | `stage.layer?.borderWidth` (CanvasOverlay.swift:411), `thumb.layer?.borderWidth` on every card (:587), both one device pixel | pending Hari, doctrine now describes the code |
| "a within-window NSVisualEffectView (.fullScreenUI) backdrop under a black tint at 0.85 (dark) / 0.6 (light)" | `ScrimView` is a bare `NSView` with a layer; `NSColor.black.withAlphaComponent(dark ? 0.95 : 0.72)` (CanvasOverlay.swift:407-408); no `NSVisualEffectView` anywhere in the Mux target | pending Hari, doctrine now describes the code |
| "smooth distance falloff d==0 ? 1 : max(0.22, 0.5 - 0.14*(d-1))" | `i == index ? 1 : (abs(i - index) == 1 ? 0.6 : 0.35)` (CanvasOverlay.swift:426), a 3-step ternary | code wins, clause rewritten to the real steps |
| "slot glyph showing the pane's cell in its split tree" | no such symbol or concept anywhere in the app | code wins, clause deleted |
| "currentWheelWidth" | no such symbol; wheel width is the fixed constant above | code wins, clause deleted |
| "The slab position lives in layoutPanes (canvasOpen)" | `layoutPanes` (MuxWindowController.swift:369) never reads `canvasOpen`; it pins `workspace.frame` to `container.bounds` unconditionally (:399) | code wins, clause rewritten |

The last row goes further than the table above says: the doctrine's whole
"Canvas motion" bullet described a workspace push (`WorkspaceView` sliding
as the canvas opens) that does not exist. The code comment at
MuxWindowController.swift:399 says outright: "The workspace never moves
for the canvas... so the ptys see nothing." What is real: the picker
overlay (scrim, stage, wheel) fades in and out as one layer over 140ms
(`MuxWindowController+Overlays.swift`, `fadeCanvas`/`canvasFade`), and the
wheel's card track has the one genuine retargetable spring (stiffness
1200, damping 68, mass 1, in `CanvasOverlay.swift`'s `positionTrack`).
Rewrote the "Canvas motion" bullet to describe that instead of the push.

Held-ctrl aliasing: PrefixEngine.swift's header (lines 17-18) documents
"ctrl+<key> in prefix mode means <key>", but nothing implements it.
`PrefixEngine.handle` reads `event.charactersIgnoringModifiers`, and
mux's own comment in `NSEvent+Ghostty.swift:38-39` says that value
"changes behavior with ctrl pressed" - i.e. ctrl+j yields a control code,
not "j". `runPrefixAction`'s switch does no control-code normalization,
so ctrl+h/j/k/l in prefix mode falls through to `default: NSSound.beep()`
instead of aliasing. CLAUDE.md never mentions this clause (confirmed by
grep), so nothing there needed changing; left as a note for task 04,
which owns PrefixEngine's header.

Decisions recorded in CLAUDE.md's new "Refactor decisions (2026-08)"
section, mirrored into this file's `refactor/README.md` entries above:

1. Canvas borders: pending Hari. Doctrine matches the code for now
   (borders kept).
2. Canvas scrim: pending Hari. Doctrine matches the code for now (flat
   tint, no blur).
3. Canvas docking / 38% panel: code wins. Deleted, nothing scheduled.
4. muxd TLS pin: pending Hari. Recorded the plan's assumed answer (pin
   the certificate DER, not the SPKI) for task 09 to build against.
5. Upgrade rendezvous: pending Hari. Recorded the plan's assumed answer
   (schedule the flip, task 11, optional).
6. `muxd pin` subcommand and boot-time SPKI log: pending Hari. Recorded
   the plan's assumed answer (delete both, task 09).

Done-when check: `rg -n 'NSVisualEffectView|38%|dock|slot glyph|currentWheelWidth|0\.14' CLAUDE.md`
returns two lines, both in the new "Refactor decisions (2026-08)"
section (the scrim and docking decision lines), each dated rather than
task-numbered - they're the recorded answer itself, not a stale clause
waiting on a future task. No hits anywhere else in the file.
