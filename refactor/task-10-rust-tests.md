# task 10: one test harness; tests that test this repo

PR title: `tests: shared muxd wire harness; ghostty-vt tests cover the shim, not ghostty`

Depends on: 06.

## Why

muxd's integration tests are good: each is a named regression (a wedged
client holding a pty name, a stolen attach clobbering the new client, an
unacknowledged handoff, accept under EMFILE). Their plumbing is not.
`read_frame` is byte-identical in tests/manager.rs:401-412 and
tests/quic.rs:193-204; `write_frame` in :391-399 and :186-191;
`write_request` in accept.rs:98-115 and quic.rs:179-184 and inlined in
manager.rs:371-377; `read_reply` in accept.rs and quic.rs;
`read_output_until` in manager.rs:414-427 and quic.rs:212-225, and those
two have drifted: one panics when the stream ends before the needle, the
other returns short. The `OpenRequest` literal is spelled out three
times, `PATIENCE` three times, the `/tmp` socket comment twice. Two
assertions in manager.rs (:46-50, :138-142) re-check what the helper
above them already guaranteed.

ghostty-vt's tests are the opposite problem. `pty_replay.rs` (163 lines)
forks a real pty under `#![expect(unsafe_code, unreachable_code, ...)]`
to feed `echo hello world` through the VT; three of its five tests reduce
to `feed(b"hello world\r\n")` with a fork in the way, one asserts nothing,
and the fifth repeats the reattach roundtrip that `reattach_scenarios.rs`
tests three more times. Real-pty-through-VT coverage exists one layer up
in muxd/tests/manager.rs:167-224. Nine of the twelve tests in
`vt_conformance.rs` assert CUP/ED/EL/tab/alt-screen semantics that live
entirely inside ghostty's terminal package. `reattach_scenarios.rs` has
`missed_output_causes_divergence`, which cannot fail unless `feed` is a
no-op, and `minecraft_server_scenario`, which is
`subsequent_output_matches_after_partial_fill` with fifteen hardcoded
Minecraft log lines.

## Changes

### crates/muxd/tests/common/mod.rs

Cargo compiles a `tests/<dir>/mod.rs` as a shared module, not a test
binary. It holds `PATIENCE`, `temp_socket` (or a `tempfile` dir),
`contains`, `request(token, target, mode) -> OpenRequest`, and generic
`write_request<W: AsyncWrite + Unpin>`, `read_reply<R: AsyncRead +
Unpin>`, `read_output_until<R>` built on `mux_proto::frame::aio`.
`quinn::SendStream` implements tokio `AsyncWrite` and `RecvStream`
implements `AsyncRead` in quinn 0.11, so one generic set serves unix and
QUIC. `read_output_until` panics on EOF before the needle (the manager.rs
behaviour; quic's short return hid a failure). Delete the per-file
copies; delete the two tautological asserts; leave the regression
narratives.

`accept.rs`: `hoard_descriptors` returns `Vec<OwnedFd>` so the manual
`close` wrapper, its SAFETY comment, and the drain loop go (and the fds
now close on a panic mid-test, which the existing comment at :65-66
worries about). `soft_nofile` inlines to `limits().rlim_cur`.

### crates/ghostty-vt

- Delete `tests/pty_replay.rs` and `nix` from `[dev-dependencies]` (its
  only user).
- `tests/vt_conformance.rs` keeps `cup_moves_cursor`, `cup_default_is_home`,
  `cuu_cud_cuf_cub` (they exercise this crate's 1-based
  `cursor_position` conversion over FFI out-params). Delete the other
  nine. `dump_row` becomes `term.screen_dump().row_texts[row].clone()`.
- `tests/reattach_scenarios.rs`: delete `missed_output_causes_divergence`
  and `minecraft_server_scenario`; move the latter's two-line
  `cursor_position` equality into `subsequent_output_matches_after_partial_fill`
  and `subsequent_output_matches_after_scroll`.
- `src/lib.rs` unit tests: `resize_updates_dimensions` and
  `new_with_zero_dimensions_clamps_to_1x1` assert values Rust itself
  just stored; fold the clamp check into `resize_zero_dimensions_clamps_to_1x1`
  (which exercises the FFI) and delete the other two. `ScreenDump` loses
  its serde derive and the crate loses the `serde` dependency; if the
  remaining tests only need `row_texts`, replace `screen_dump()` with
  `pub fn row_texts(&self) -> Vec<String>` and delete the struct and the
  `rows`/`cols` fields it echoes.

## Keep

- Every muxd regression test by name.
- The title-replay tests in ghostty-vt `src/lib.rs`
  (`render_screen_bytes_replays_title`, `..._omits_unset_title`) and the
  CRLF/truecolor/palette pins. CLAUDE.md marks title replay as an
  invariant.
- `a_self_upgrade_carries_the_pty_its_screen_and_its_child` is the
  real-pty coverage that lets `pty_replay.rs` go; do not weaken it.

## Done when

- `rg -n 'fn read_frame|fn write_frame|fn write_request|fn read_reply|fn read_output_until' crates/muxd/tests`
  returns only `common/mod.rs`.
- `crates/ghostty-vt/tests` ≤ 150 lines total; `Cargo.toml` has no
  dev-dependencies and no serde.
- `cargo test --workspace` passes with the same number of muxd tests as
  before.
- Inventory: ≥ 380 lines fewer.
