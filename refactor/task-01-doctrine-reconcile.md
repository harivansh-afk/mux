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
