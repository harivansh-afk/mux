# task 03: Rust comments say what the code cannot

PR title: `muxd, mux-proto, mux-attach: comments that narrate, restate or remember are deleted`

Depends on: 02 (the lint-driven doc blocks are already gone).

## Why

1,201 comment lines on 4,946 of Rust code. The good ones are in
manager.rs, pty.rs and the middle of broker.rs, and they name a failure
mode (the steal-attach race, why `kill` hits pgid and pid, why the reap
never parks a thread). The rest fall into four kinds that a reader pays
for and gets nothing from:

- Narration of the next line. paths.rs is 48 comment lines over 62 of
  code, and the per-function docs say the path the body joins
  ("TOFU pin store: ~/.local/state/mux/known_hosts" above
  `client_state_dir().join("known_hosts")`).
- The same fact in three files. lib.rs:7-9 repeats manager.rs:1-12; lib.rs:18-20
  repeats main.rs:24-26 word for word; mux-proto/migrate.rs:1-9 and
  muxd/migrate.rs:4-9 describe the same SCM_RIGHTS message; the 11-step
  reattach order is written in the zig export doc, as inline numbered
  comments, and in the Rust wrapper doc.
- Fork history. "Fork of ix-console's manager.rs / pty/io.rs /
  session/attach.rs" (manager.rs:1), the same for pty.rs:1 and
  server.rs:1, "M2.5" in mux-proto/migrate.rs:1, the M4 golden-byte
  promise in shell.rs:8-12 and lib.rs. The repo's own naming rule already
  says behaviour is described on its own terms.
- Constants with essays. broker.rs:37-66 spends 26 lines on seven
  `Duration`/`&str` values; migrate.rs:53-69 spends 17 on six.

This is a delete pass. Nothing is rewritten; a comment either names a
constraint the code cannot show, or it goes.

## Changes

File by file, the lines to delete (line numbers at `dd0c7cb`; re-find by
content after task 02 shifts them):

- `crates/muxd/src/lib.rs`: lines 1-24 become two lines: what the crate
  is, and that it is a library so the integration tests can drive the
  listeners in-process.
- `crates/muxd/src/main.rs`: 1-27 become the usage block only (the five
  lines starting `Usage:`). The enrollment paragraph is CLAUDE.md's.
- `crates/muxd/src/manager.rs`: 1-3 (the fork map). Keep 4-12 (the two
  upstream bugs) exactly where they are; they are the reason the lock
  discipline exists and `read_loop` points at them.
- `crates/muxd/src/pty.rs`: 1-3 fork map; 67-74 and 91-96 (the two
  `getpwuid` SAFETY blocks) go with task 08, not here.
- `crates/muxd/src/server.rs`: 1-3 fork map; the four-line apology at
  387-390 and the five lines at 166-170 go with task 08.
- `crates/muxd/src/broker.rs`: 1-15 becomes the two sentences that are
  not written down elsewhere (the handshake is rewritten; nothing after
  it is parsed). 37-66: one line per constant, keep the `KEEP_ALIVE`
  and `MAX_IDLE` reasons as one line each. 94-102 field docs (paths.rs
  is the spec). 117-118. Keep 183-186, 199-201, 268-269: each names a
  race.
- `crates/muxd/src/migrate.rs`: 1-34 becomes ~8 lines: the wire shape
  once, the ack-before-exit invariant (23-27 verbatim), the
  lock-held-across-send invariant. Delete the numbered sequence, 53-69
  to one line per constant, 158-163, 213-221 ("pub for tests"),
  234-242, 311-312, 377-389, 448-450, 463-465. Keep 332-334 (CLOEXEC).
- `crates/muxd/src/tls.rs`: 1-15 to ~5 lines (no CA; pin plus token;
  only digests travel). 37-38, 88-89, 92-94, 182-183, 207-208 (each
  narrates the next line).
- `crates/muxd/src/quic.rs`: 1-15 to two facts (one bidi stream is one
  logical connection; remote requests may not carry a target). 27-34 one
  line each, 55-58, 61-67, 84-88, 113-114, 132-147 narration (the
  function itself is inlined in task 08).
- `crates/mux-proto/src/paths.rs`: 1-27 (the formats live in
  docs/architecture.html and are enforced in broker.rs and tls.rs). The
  per-function lines whose text is the path in the body. Keep 31-35
  (why `home()` degrades) and 94-97 (why the pidfile follows HOME).
- `crates/mux-proto/src/lib.rs`: 1-10 to one line.
- `crates/mux-proto/src/frame.rs`: 1-4 keeps "length covers lane +
  payload"; drop "keep byte-compatible with upstream" (the
  `wire_layout_is_exact` test is what keeps it).
- `crates/mux-proto/src/peer.rs`: 1-10 to the handshake shape and the
  name-keyed pty fact. 445-449 keep (version history is real).
- `crates/mux-proto/src/shell.rs`: 1-12 entirely (task 06 deletes the
  types; the lane constants need one line).
- `crates/mux-attach/src/main.rs`: 1-45 to ~15 lines: what the relay is,
  why plain threads, why socket EOF is not the end, why the input
  threads outlive a reconnect (41-45 verbatim). The usage block stays
  until task 07 moves the verbs. Delete the probe JSON sample (20-33).
  Delete "Plain data: encoding cannot fail" at 300 and 362, 331-333 and
  the Cargo.toml 16-17 duplicate, 548-553, 678, 269.
- `crates/ghostty-vt/src/lib.rs`: 1-5 ("VM console reattach" is a
  product this repo is not); the per-call `// SAFETY: handle is valid`
  lines (×8) become one module-level statement above `impl Terminal`;
  keep the two SAFETY notes on raw-slice reads.
- `crates/ghostty-vt/zig/lib.zig`: 152-168 (the 17-line export doc; the
  inline numbered comments are the same list next to the code). Of the
  inline comments keep only 206, 270-272, 295-296, 310-312.
- Tests: `crates/muxd/tests/*.rs` keep their regression narratives.
  `crates/ghostty-vt/tests/*.rs` module docs that mention VM consoles or
  Minecraft go.

## Keep

- Every comment that names a race, an ordering constraint, a signal
  semantics, or a kernel quirk. If in doubt, the test for keeping is:
  would a competent engineer delete this line of code without the
  comment and ship a bug?
- `manager.rs:4-12`, `broker.rs:183-186,199-201,268-269`,
  `migrate.rs:23-27,332-334`, `pty.rs:185-190` (why everything is built
  before fork), `server.rs:22-26` (accept backoff), `main.rs` the QUIC
  "its death is the daemon's death" paragraph, `mux-attach` 72-81.

## Done when

- `python3 refactor/tools/inventory.py` reports Rust comment lines ≤ 800
  (from 1,303 including lint-driven docs removed in task 02).
- `rg -n 'ix-console|Fork of|M1|M2|M3|M4|Minecraft|VM console' crates`
  returns nothing outside `docs/`.
- `cargo test --workspace` unchanged.
