# task 05: dead code

PR title: `dead code: symbols with no reader, in both languages`

Depends on: 02 (so the lint gate is in place to catch regressions).

## Why

`refactor/tools/inventory.py` lists every declaration with a cross-file
reference count. These have zero readers, confirmed by `rg` on
2026-08-22. Each is a small cut; together they are ~120 lines and, more
usefully, they stop lying about what the program does.

## Changes

Rust:

- `crates/mux-proto/src/shell.rs`: `METHOD`, `DEFAULT_PORT`, and every
  type from line 25 down (`EnvVar`, `Mode`, `Request`, `ClientControl`,
  `SessionInfo`, `OpenSuccess`, `ServerEvent`). Zero references; two of
  them duplicate `peer.rs`. The seven constants that remain are moved in
  task 06; here just delete the types. `docs/architecture.html:136-151`
  describes these types and should lose that block in the same PR.
- `crates/mux-proto/src/peer.rs`: `ServerEvent::Detached`. muxd never
  produces it; mux-attach handles it at main.rs:691. Delete the variant
  and the arm. (Protocol note: postcard encodes enum discriminants by
  index and `Detached` is the last variant, so removing it does not
  change `Exit`'s bytes. The golden test at peer.rs:592 still passes.)
- `crates/muxd/src/manager.rs`: `PtySession::exit_code` (declared :76,
  written :193, :233, :346, never loaded).
- `crates/ghostty-vt/src/lib.rs`: `Terminal::cursor_pending_wrap`
  (:129-138), its extern at :41, and the Zig export
  `ghostty_vt_terminal_cursor_pending_wrap` (zig/lib.zig:143-150). The
  pending-wrap state that matters is read inside `renderReattach`.
- `crates/mux-proto/src/lib.rs:18`: the `pub use` re-export of
  `read_lane_frame`, `write_lane`, `FrameLimits`, `LaneFrame`; every
  caller uses the full path. (Verified: `cargo check --workspace
  --all-targets` is clean without it.)
- `crates/muxd/src/tls.rs`: `Identity::spki_pin` stays until task 09
  decides the pin format; not here.

Swift:

- `Terminal/PaneView.swift`: `processExited` (:463-466).
- `UI/Theme.swift`: `Chrome.uiFont` (:36-38).
- `UI/ModeBar.swift`: `ModeBarView.margin` is a constant 0 pinned by
  doctrine ("ModeBarView.margin is 0 - do not reintroduce air"). Delete
  it and the three arithmetic uses (`CanvasOverlay.bottomReserve`,
  Overlays.swift:31 and :73).
- `Tiling/PrefixEngine.swift`: the `event _: NSEvent` parameter of
  `runPrefixAction` (:318), unread.
- `UI/MuxWindowController.swift`: the `from _: PaneView` parameter of
  `focus(from:ghosttyGoto:)` (:330), unread; the one caller passes a
  view it then ignores.
- `State/Subprocess.swift`: the `timeout:` parameter of `run` has no
  call site that passes it (Muxd.swift:38, :76, :91; IX.swift:65, :79 all
  take the default). Use `defaultTimeout` inside.
- `App/GhosttyRuntime.swift`: `configBool(_:default:)` has one caller
  (`autoSecureInput`), whose one consumer re-defaults it with `?? true`.
  Inline the config read into the consumer.
- `App/AppDelegate.swift:290`: the "About mux" item is added with
  `action: nil` and renders permanently disabled. Either delete it and
  the separator, or give it
  `#selector(NSApplication.orderFrontStandardAboutPanel(_:))`. Pick the
  selector; it is one token.
- `App/AppDelegate.swift:103`: `command[0] == IX.binary ||
  command[0].hasSuffix("/ix") || command[0] == "ix"`; the first test is
  subsumed by the other two (`IX.binary` is an absolute path ending in
  `/ix` or the literal `"ix"`).

Scripts:

- `scripts/fetch-ghosttykit.sh:6-7` "M1 setup: point REPO at our ghostty
  artifacts fork once its CI exists" is a note to a past self.

## Keep

- `Terminal::screen_dump` / `ScreenDump` are test-only but the tests
  still use them; task 10 decides.
- `ModeBarSegment` factories go in task 14, not here; they are not dead,
  just redundant.

## Done when

- `rg -n 'processExited|uiFont|exit_code|cursor_pending_wrap|Detached|ModeBarView\.margin|METHOD|DEFAULT_PORT' crates app/Sources`
  returns nothing.
- `cargo test --workspace` and the app build pass; `just lint` passes.
- Inventory: ≥ 110 lines fewer than after task 04.
