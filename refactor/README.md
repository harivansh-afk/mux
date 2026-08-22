# mux refactor: the map and the ship list

This directory is the plan for making mux smaller without making it worse.
`README.md` is the map. `task-NN-*.md` are the specs, one PR each, in the
order they should land. `tools/inventory.py` is the measurement; rerun it
after every PR and the numbers in this file get replaced, not argued with.

Measured on 2026-08-22 at commit `dd0c7cb`. Tools: tokei 14 (totals),
ast-grep 0.43 (symbol inventory, both languages), a 6-line-window clone
scan, `git log --name-only` for churn, and a full read of every source
file. Thirteen per-layer audits ran before this and their raw findings are
in `~/.claude/projects/-Users-rathi-Documents-Git-mux/simplify-audit-2026-08-22.md`;
where a claim there was checked against the code and held, it is in a task
below. Where it did not hold, it is not.

## Numbers

| language | files | lines | code | comments | comment share |
|---|---:|---:|---:|---:|---:|
| Swift | 31 | 7,804 | 5,404 | 1,543 | 22% |
| Rust (incl. doc comments) | 24 | 6,912 | 4,946 | 1,201 | 20% |
| Python (scripts/) | 3 | 852 | 698 | 39 | |
| Zig | 2 | 468 | 344 | 66 | |
| HTML (docs/) | 1 | 430 | 414 | 0 | |
| Nix | 3 | 324 | 220 | 77 | |
| Shell | 4 | 190 | 106 | 68 | |
| everything | 83 | 17,414 | 12,416 | 3,088 | 20% |

1,571 declarations across Rust and Swift. 202 commits. The app has no test
target (`Package.swift` declares none); every Swift behaviour is tested by
you using it.

The 15 largest files, with what the line counts say:

| file | code | comment | note |
|---|---:|---:|---|
| Terminal/PaneView+Input.swift | 723 | 228 | ~85% verbatim port of ghostty SurfaceView_AppKit.swift |
| muxd/src/broker.rs | 832 | 143 | 424 of those lines are an inline test module |
| mux-attach/src/main.rs | 585 | 149 | ~300 lines are `--list` / `--kill` / `probe`, not relay |
| Terminal/PaneView.swift | 421 | 194 | 32% comment, mostly M2/M3 history and doctrine restated |
| UI/CanvasOverlay.swift | 444 | 123 | |
| App/GhosttyRuntime.swift | 448 | 56 | 180-line action switch |
| UI/HostsWindow.swift | 392 | 99 | the most over-built file in the app |
| muxd/src/migrate.rs | 329 | 123 | 85 lines are finding the peer by pid |
| muxd/src/manager.rs | 326 | 111 | the comments here are earned |
| UI/MuxWindowController.swift | 333 | 82 | 90 lines are one-line forwarders |
| UI/MuxWindowController+Overlays.swift | 305 | 98 | five copies of show/hide/position |
| muxd/src/server.rs | 315 | 90 | |
| Tiling/Session.swift | 293 | 57 | |
| ghostty-vt/src/lib.rs | 257 | 58 | |
| Tiling/PrefixEngine.swift | 255 | 68 | 28-line header duplicates the keybinds table |

Largest functions: `GhosttyRuntime.action` 180 lines, `PaneView.keyDown`
167 (vendored), `performKeyEquivalent` 117 (vendored), `PaneView.init` 114,
`server::handle_open` 112, `pty::spawn` 110, `PrefixEngine.handle` 101.

Churn (commits touching the file): MuxWindowController 35, PaneView 35,
Overlays 24, Session 23, AppDelegate 23, CanvasOverlay 21. The files that
change most are the ones with the most forwarding and the least shape. That
is not a coincidence; it is the thing this plan fixes.

The clone scan found only 7 duplicated 6-line windows. Mux's duplication
is not copy-paste. It is the same shape written five times with different
names (show/hide/position, the three `OpenRequest` handshakes, the two
`getpwuid` walkers, the three frame writers). A line-hash detector cannot
see that, which is why the list below was made by reading.

## The map, and how each part feels

### crates/mux-proto (616 lines, 6 files)

The crate should exist: mux-attach is a 648K sync binary and folding the
wire types into muxd would drag tokio, quinn, rustls and the zig static
library into every pane's relay. But only `peer.rs` and `frame.rs` are a
protocol. `paths.rs` and `migrate.rs` are imported by muxd and nobody else.
`shell.rs` is 57 lines of types with zero references and two of them
duplicate `peer.rs`. `FrameLimits` wraps one constant and is always
`::default()`. `FrameError` is the workspace's only thiserror user and
nobody matches on it.

How it feels: like a crate that was laid out for a plan (M4 ix codec
fixtures) and then the plan moved. Nothing here is hard; it is just
unswept.

### crates/muxd core: manager.rs, server.rs, pty.rs, main.rs (1,420 lines)

This is the best Rust in the repo. `manager::attach` installs the channel
and renders the dump under one lock; `read_loop` reads, feeds and resolves
the client under the same lock; `pty::spawn` builds argv, envp and the
resolved PATH before fork and the child makes only async-signal-safe calls;
`wait_child` never parks a thread. Every one of those has a comment that
names the failure it prevents, and every one of those comments is worth
its lines. Do not "simplify" these.

What is wrong is at the edges. `pty.rs` has two 23-line copies of a
`getpwuid` walk, calling the non-reentrant variant from a multithreaded
runtime (a real race, not a style point). `Manager::adopt` does the
lookup/insert split that `open`'s own comment says must never happen, and
skips `MAX_PTYS`. `server::read_request` fabricates a fake
`OpenRequest{mode: List}` so a version check 200 lines away fires.
`struct Open` carries six fields `OpenRequest` already has. `lib.rs`,
`main.rs` and `manager.rs` each state the same three facts as module prose.

How it feels: confident, careful, and then slightly embarrassed at the
seams where something was added in a hurry.

### crates/muxd remote: broker.rs, tls.rs, quic.rs, migrate.rs (2,000 lines)

The broker proper (dial or reuse, open a stream, rewrite the handshake,
splice) is about 150 lines and is right. Around it sit a 73-line
hand-written X.509 DER walker that exists to reach one field, a
`ServerCertVerifier` with a TLS 1.2 arm that QUIC can never call, three
wrapper types (`Link`, `Stream`, `Pin`) that wrap nothing, an SNI branch
that cannot change any outcome, and 424 lines of tests that rebuild
`quic::endpoint` by hand and hand-roll a tempdir. `tls.rs` hand-rolls hex
both ways and PEM parsing that `rustls::pki_types::pem` already provides,
and re-parses the private key on every boot to print a pin for a `muxd pin`
subcommand nothing calls. `migrate.rs` is the right design (SCM_RIGHTS plus
a screen snapshot, ack before exit) with the wrong rendezvous: 85 lines of
pidfile, SIGUSR1, "is this pid really muxd", and a 20ms exit poll, all of
which a listening socket gives you for free.

How it feels: the security-sensitive part of the daemon was written to be
defensible line by line, and it is, but the defence is heavier than the
thing it defends. There is a particular kind of dread in reading an ASN.1
parser in a terminal multiplexer.

### crates/mux-attach (784 lines)

The relay (connect, raw mode, uplink, reconnect, pump) is ~390 lines and
good. The other ~300 are daemon queries (`--list`, `--kill`, `probe`) that
never relay a byte, plus `classify`, which substring-matches seven English
sentences produced in another crate, plus a 38-line test that pins that
other crate's wording. `run_control`, `ask` and `open_session` each write
the same handshake. `PtyLine` re-declares `PtyInfo` to change nothing.
Raw `libc` termios with `mem::zeroed` where `nix::sys::termios` is already
a dependency.

How it feels: a good tool that was handed three extra jobs because it was
already on the socket. The string-classified error channel is the one
genuinely bad design decision in the Rust; everything else is tidying.

### crates/ghostty-vt (361 Rust, 273 build.rs, 468 Zig)

Out of scope by your call (FFI), except where it centralises types. Noted
for completeness: the C header declares two functions that do not exist
and omits the two that matter, `cursor_pending_wrap` is dead in all three
languages, `ScreenDump` is test-only and the sole reason serde is a
dependency, `build.rs` probes `zig version` twice and hardcodes
`x86_64-linux-musl` for a fleet whose Linux member is aarch64. One optional
task at the end.

### Rust tests (crates/*/tests, 1,390 lines)

muxd's are named regressions with real histories behind them and should
stay. Three test binaries hand-roll the same five wire helpers and two
copies have drifted (`read_output_until` panics in one, `break`s in the
other). ghostty-vt's `pty_replay.rs` is 163 lines of unsafe forkpty to
prove what `feed(b"hello\r\n")` proves, and nine of the twelve conformance
tests assert ghostty's own emulator, not this crate's shim.

### app/ App + State (1,735 lines)

`SecureInput.swift` is 126 lines of NSObject/@objc/selector ceremony for a
25-line boolean latch, with the enable/disable call written three times and
a `deinit` on a `static let` that can never run. `Session` and
`SessionSnapshot` hold the same four fields, and `AppDelegate.saveSnapshot`
transcribes one into the other three levels deep while `restore` takes the
snapshot splayed into four parameters. `AppSnapshotV1` migrates a format
that was writable for under two hours on one machine (git shows v2 landed
the same afternoon as the first Swift commit). `windows: [WindowSnapshot]`
is multi-window leftover: the writer can only produce one element, the
reader takes `windows[0]`. `GhosttyRuntime` is a singleton and is also
injected through three constructors to reach one `runtime.app` read.
`GhosttyRuntime.action` repeats `guard let view / DispatchQueue.main.async /
return true` ten times. `Probe` is modelled twice in `Muxd.swift`. Pane cwd
seeding is written twice with different filters.

How it feels: correct, and tired. Everything works; nothing is in one place.

### app/ Terminal (2,179 lines)

The least slop-heavy part of the app, and the place where the instinct
"1,099 lines must be bloat" is wrong. `PaneView+Input.swift` is a near
verbatim MIT port of ghostty's `SurfaceView_AppKit.swift`, comments
included, and its comment ratio (24%) matches upstream. Rewriting it trades
a known-correct IME implementation for novelty. The real problems are in
`PaneView.swift`: it builds the mux-attach command line and launches the
app's only raw `Process()` outside `Subprocess.swift`, the agent-state
glyph ranges are written twice across three functions,
`requestAuthorization` runs on every OSC 9, and 194 comment lines against
421 of code, much of it "M2:", "M3:", and "the unlogged hop used to be
right here".

How it feels: the vendored code is fine and should be made diffable
against upstream by splitting it out. The mux-authored 90 lines inside it
are buried.

### app/ Tiling (952 lines)

`SplitTree.swift` is the best file in the repo: 180 lines, an indirect
enum, Codable by synthesis, nothing to cut except a `(node, Bool)` tuple
that should be an optional and a hand-rolled argmin with a force unwrap.
`Session.resizeFocused` lays the whole tree out twice per keystroke to
re-derive a sign `adjustingRatio` already applies correctly, and the flip
is reachable only at the ratio clamp, where it grows the pane on a shrink
keypress. `PrefixEngine` is a real state machine padded by a
multi-window `indicatorController`, six by-name hide calls in `setMode`, a
`.help` branch whose two arms are identical, and a template sub-mode kept
outside the `Mode` enum so its bar gets poked by hand in three places.
Eleven mutation sites in `Session` each hand-write unzoom, layoutPanes,
saveState.

How it feels: SplitTree makes me want the rest of the app to look like it.

### app/ UI (2,811 lines)

The biggest lever on the Swift side. `PaneLabels.swift` is `ModeBarView`
retyped (`textInset` and `layout()` are character-for-character copies)
around one pink string. `HostsWindowView` and `HelpOverlayView` are the
same bordered panel written twice (title, esc badge, border, theme
observer, `init?(coder:)` stub, title-row math). `HostsWindow` keeps two
parallel row models, two generation counters, tears down and reallocates
two `NSTextField`s per row on every probe reply, and then carries
`statusReserve`, `grownSize`, `carriedSize` and `onContentChange` to stop
the box jittering from the rebuilds it causes. Overlay lifecycle has no
shape: presence is `isHidden` for one bar and `superview != nil` for
everything else, five bespoke show/hide/position triples, `layoutPanes`
tests five flags, `setMode` calls six hides by name. Seven controller
methods forward to `hostsWindow` while `PrefixEngine` already reaches
`canvasOverlay` directly. `CanvasOverlay` has a `Group` struct wrapping one
array kept in lockstep with a flat `items` list, the mirror-host and shadow
setup written twice, three near-empty NSView subclasses, and a second
opacity animation on every `j`/`k` that the one-spring doctrine argues
against. `WorkspaceView` exists for a push that no longer happens. Three
"keep overlay above panes" z-order lifts guard a state that cannot occur
(panes never go in `container`). `ModeBarSegment` is a struct plus a Kind
enum plus four factories where `enum { case badge(String) ... }` compiles
every call site unchanged. `HelpOverlay.partition` is a 30-line greedy
balancer for a six-entry constant.

How it feels: HostsWindow is the file I would least like to be asked to
change. The chrome is five views that each discovered the same five ideas
independently.

### CLAUDE.md

This is the most important finding and it is not code. The canvas doctrine
no longer describes the program. It pins a 38% right panel, bottom docking
for narrow windows, an `NSVisualEffectView` scrim at 0.85/0.6, "stage and
cards have NO borders (removed; do not reintroduce)", a falloff formula
`max(0.22, 0.5 - 0.14*(d-1))`, a slot glyph, `currentWheelWidth`, and "the
slab position lives in layoutPanes (canvasOpen)". Checked against the
code: none of those symbols exist, borders are set on the stage
(CanvasOverlay.swift:411) and every card (:587), the scrim is a flat black
layer at 0.95/0.72, the falloff is a 3-step ternary, and `layoutPanes`
never reads `canvasOpen`. Every stale "decided" clause is an instruction
to the next agent to rebuild something that was already deleted once. That
is the mechanism producing the bulk, and it gets fixed first.

## Principles for every task

1. Delete over abstract; abstract only when the third copy exists and the
   abstraction is deeper than the copies. "Deeper" means a caller writes
   less and knows less.
2. A comment states a constraint the code cannot show, or it goes. No
   narration of the next line, no doctrine restated from CLAUDE.md, no
   milestone history.
3. One definition per concept. The frame byte layout, the attach command
   line, the pane cwd rule, the overlay lifecycle each exist in exactly one
   place after this plan.
4. Reach directly. A one-line forwarder whose only job is to exist is
   deleted; the caller names the real object.
5. The decided invariants in CLAUDE.md (crash safety, title replay,
   conditional theme reload, never resize a pane to thumbnail it, stage
   scroll delivery, single window, QUIC transport) are not negotiable and
   every spec says which ones it touches.
6. Every PR leaves `just lint`, `cargo test --workspace` and
   `./scripts/make-app.sh` green, and ends with the inventory rerun and
   the line delta in the PR body.

## The deep modules this plan converges on

Rust:

- `mux_proto::frame`: the only place the `[u32 LE len][u8 lane][payload]`
  layout and the `[u32 len][request]` handshake exist. Pure encode/parse
  functions plus sync and async adapters of a few lines each. muxd's
  server, broker, and all three integration tests call it. Task 06.
- `mux_proto::peer::OpenError { kind, detail }`: failure is a typed value
  on the wire. `classify`, its doc, its table and its test are deleted;
  Swift switches on a kind. Task 07.
- `muxd::paths`: every filesystem location (including the migration socket
  and pidfile, today split across two crates) in one muxd module. Task 06.
- `muxd` subcommands `ls`, `kill`, `probe`, `client-digest`: daemon queries
  live with the daemon. mux-attach is a relay with one `handshake()`
  function. Task 07.
- `Manager::install`: one insertion path under one guard; `open` and
  `adopt` supply only what differs. Task 08.
- One `fingerprint(cert)` over the certificate DER, used by the daemon to
  log its pin and by the client to pin it. No DER parser, no rcgen
  re-parse. Task 09.
- `crates/muxd/tests/common/mod.rs`: one wire harness, generic over
  `AsyncRead`/`AsyncWrite`, so unix and QUIC tests share it. Task 10.
- Handoff rendezvous is one listening socket owned by the process that
  has the ptys. Task 11, optional.

Swift:

- Three chrome views and no others. `PanelView` (border, title, esc badge,
  theme observer) that `HelpOverlayView` and `HostsWindowView` subclass.
  `ModeBarView` for every boxed line of text (the pane tag subclasses it).
  `FlippedView` with an optional click handler for every flipped or
  clickable plain view. Task 14.
- `ChromeOverlay` presenter on the controller: `present`, `dismiss`,
  `dismissAll`; presence is `superview != nil` for everything including
  the mode bar; `layoutPanes` loops the presented list. Task 15.
- `Session` is the model. `Session.snapshot` and `restore(_:)` take and
  return one `SessionSnapshot`; `commit()` is the one place a structural
  mutation unzooms, relays out and saves; `NewPaneTarget.seed(from:)`
  answers the host/cwd question once. `AppSnapshot` v3 is flat. Task 12.
- `Muxd` owns every interaction with the helper binaries: `Muxd.Attach`
  builds the command line and kills; `probe`, `list`, `clientDigest`
  decode through one `jsonLines` helper; `Subprocess.run` is the only
  `Process()`. `PaneView` keeps `target` and nothing else about the relay.
  Task 13.
- Direct reach. `PrefixEngine` calls `controller.activeSession`,
  `hostsWindow`, `canvasOverlay`. `App.delegate` replaces the six
  `(NSApp.delegate as? AppDelegate)` casts. libghostty enum to mux enum is
  an `init?` on `SplitDirection`/`FocusDirection`. Task 15.
- `MirrorHostView`: one mirror CALayer plus shadow, used by the stage and
  every card. Task 17.

## Decisions only you can make

These are in task 01 because every later task assumes an answer.

1. Canvas borders. CLAUDE.md says none; the code draws a one-device-pixel
   stroke on the stage and every card and uses the accent colour for the
   selection. Keep the code (update the doctrine) or keep the doctrine
   (delete the strokes, and say how selection reads without them).
   Status (task 01, 2026-08-22): pending Hari. CLAUDE.md's doctrine now
   matches the code (borders kept) as a placeholder; not a final call.
2. Scrim. Doctrine says blur plus tint via `NSVisualEffectView` at
   0.85/0.6. Code is a flat black layer at 0.95/0.72. The blur costs a
   compositor pass per frame while the canvas is up.
   Status (task 01, 2026-08-22): pending Hari. CLAUDE.md's doctrine now
   matches the code (flat tint, no blur) as a placeholder; not a final
   call.
3. Docking and the 38% panel. Neither exists. Delete the clauses, or
   schedule the feature. The plan assumes delete.
   Status (task 01, 2026-08-22): code wins. Both clauses are deleted from
   CLAUDE.md; nothing scheduled.
4. TOFU pin over the certificate DER instead of the SPKI. Same trust
   lifetime in this repo (cert and key are generated and regenerated
   together). Cost: spark's `known_hosts` line re-pins once. Task 09
   assumes yes.
   Status (task 01, 2026-08-22): pending Hari. Recorded in CLAUDE.md as
   the plan's assumed answer (yes, DER) for task 09 to build against;
   not a final call.
5. Flip the upgrade rendezvous so the predecessor listens. One release has
   to support both directions or accept losing sessions once during the
   switch. Task 11 assumes you will schedule it and is marked optional.
   Status (task 01, 2026-08-22): pending Hari. Recorded in CLAUDE.md as
   the plan's assumed answer (schedule it, optional, task 11); not a
   final call.
6. The `muxd pin` subcommand and the boot-time SPKI log. Nothing calls
   them. Task 09 deletes them; say so if you want the out-of-band check
   kept.
   Status (task 01, 2026-08-22): pending Hari. Recorded in CLAUDE.md as
   the plan's assumed answer (delete both, task 09); not a final call.

## Ship list

| # | PR | what | est. delta | depends on | risk |
|---|---|---|---:|---|---|
| 01 | doctrine reconcile | CLAUDE.md canvas clauses match the code; decisions recorded | 0 | | none |
| 02 | lint gate: astlog | astlog rules + fixtures for Rust, Swift, Cargo; clippy allows; delete ast-grep, sgconfig, scripts/lint, CI lint job | -230 | 01 | low |
| 03 | comments: rust | delete-only pass | -350 | 02 | none |
| 04 | comments: swift | delete-only pass | -400 | 01 | none |
| 05 | dead code | the list, both languages | -120 | 02 | low |
| 06 | mux-proto shrinks, frame is one place | shell.rs types, paths and migrate into muxd, FrameLimits, FrameError, frame primitive used by muxd + tests | -150 | 05 | low |
| 07 | error kinds on the wire, muxd subcommands | OpenError; `muxd ls/kill/probe`; mux-attach pure relay; Swift Muxd consumer | -250 | 06 | medium |
| 08 | muxd core seams | Manager::install; version-first read; drop struct Open and Step; passwd helper; quic inline | -100 | 06 | low |
| 09 | one fingerprint | cert-DER pin; tls pem/hex from deps; spki_pin gone; broker wrappers and dead TLS1.2 arm; test fixtures | -200 | 07 | medium |
| 10 | rust tests | tests/common; ghostty-vt test trim | -400 | 06 | low |
| 11 | upgrade rendezvous flip | predecessor listens; pidfile machinery gone | -90 | 08 | medium, optional |
| 12 | swift state | Snapshot v3; Session.snapshot/restore; commit(); seed; runtime singleton; cwd rule once; App.delegate | -180 | 04 | medium |
| 13 | swift attach in one place | Muxd.Attach; PaneView slim; Input split into vendored files; notifications; glyph parse once | -120 | 12 | low |
| 14 | chrome primitives | PanelView; PaneTag; FlippedView; ModeBarSegment enum; Theme trims; Help columns | -200 | 04 | low |
| 15 | overlay presenter, direct reach | ChromeOverlay; facades deleted; PrefixEngine cleanup; enum inits; WorkspaceView; z-order lifts | -200 | 14 | medium |
| 16 | hosts window | one rows array, one label, fixed width | -180 | 14 | medium |
| 17 | canvas trims | MirrorHostView; Group; tick; show/commit dedup | -110 | 15 | low |
| 18 | runtime and secure input | onMain; static pointers; clipboard split; SecureInput latch | -150 | 12 | low |
| 19 | tiling fixes | resizeFocused; adjustingRatio optional; neighbor min-by; gap | -50 | 15 | low |
| 20 | e2e scripts | one harness; drop cases Rust already pins; just/CI | -300 | 07 | low |
| 21 | ghostty-vt edges (optional, FFI) | header, pending_wrap, ScreenDump/serde, build.rs, getIo | -250 | 10 | low |

Estimated total: about 3,500 lines off 15,400 of Rust and Swift (23%),
plus ~550 off scripts and lint infrastructure. Estimates are from reading,
not from doing; the inventory after each PR is the real number.

Four tasks also fix bugs found on the way and should land regardless of
the size argument: the `getpwuid` race (08), `adopt` skipping the lock
discipline and the cap (08), the resize clamp-edge flip (19), and
`split(from:ghosttyDirection:)` dropping `before:` (15).

## How to execute a task

1. `git worktree add .worktrees/task-NN -b refactor/task-NN main`.
2. Read the spec's "keep" list before touching anything.
3. Make the change. Atomic commits, one logical change each.
4. `just lint && cargo test --workspace && ./scripts/make-app.sh`, then
   test the app by hand for the behaviours the spec names.
5. `INVENTORY_OUT=/tmp python3 refactor/tools/inventory.py` and put the
   before/after totals in the PR body.
6. `tea pr create` against `main` with the spec's PR title.

## Tooling kept in the repo

`tools/inventory.py` parses every Rust and Swift file with ast-grep,
records each declaration with its line span and a cross-file reference
count, and prints per-file code/comment/blank counts. Run it from anywhere
inside the repo. It needs `ast-grep` and `fd` on PATH. Zero-reference
symbols and single-caller symbols are the dead-code and inline candidates;
the largest functions are the ones to read when a task feels stuck.
