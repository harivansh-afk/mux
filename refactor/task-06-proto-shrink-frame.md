# task 06: mux-proto is the wire, and the frame layout exists once

PR title: `mux-proto: only the shared wire; frame layout defined once and used everywhere`

Depends on: 05.

## Why

`mux-proto` has six files and two of them are a protocol. `paths.rs`
(110 lines) is called from muxd only (tls.rs:74-75, main.rs:81,100,
broker.rs:117-122, quic.rs:50, migrate.rs:87,97, tests/quic.rs:30,52);
mux-attach imports `frame`, `peer`, `shell` and never `paths`; Swift
hardcodes its own `.config/mux/hosts.json` (Hosts.swift:17). `migrate.rs`
(42 lines) is a muxd-to-muxd contract consumed by muxd/src/migrate.rs and
manager.rs:214 and nobody else. After task 05, `shell.rs` is seven
constants.

The lane frame `[u32 LE len][u8 lane][payload]` is written five times:
the sync pair in frame.rs:46-90, the async pair in server.rs:410-435
(which reaches into mux-proto only for `MAX_FRAME_SIZE`), inline in
broker.rs `write_reply` :312-320, and hand-rolled in tests/manager.rs
:391-410 and tests/quic.rs :186-203. The handshake `[u32 len][request]`
is written in server.rs `read_request`, broker.rs `open_stream`,
mux-attach `write_request`, and both tests again.

An earlier verification pass refuted "move the async pair into mux-proto"
on line count alone: relocating 26 lines and adding a tokio feature nets
about zero. That is the wrong measure. The goal is one definition, and a
lint (task 02's `no-handrolled-frame`) that keeps it that way. The layout
becomes two pure functions; the sync and async adapters are a few lines
each and are the only places that touch `write_u32_le`.

## Changes

### Moves

- `crates/mux-proto/src/paths.rs` → `crates/muxd/src/paths.rs`. Fold in
  `mux_proto::migrate::migrate_socket_path` and muxd's
  `migrate::socket_path` (the `MUXD_MIGRATE_SOCKET` override) as one
  `paths::migrate_socket()`; fold in `peer::socket_path` the same way as
  `paths::control_socket()` with the `MUXD_SOCKET` override that
  mux-attach currently implements itself (main.rs:60-66). mux-attach
  keeps a two-line copy of the `/tmp/muxd-<uid>.sock` default (it cannot
  depend on muxd); put the format string in `peer.rs` as a `const` so the
  two agree by construction.
- `crates/mux-proto/src/migrate.rs` → the top of
  `crates/muxd/src/migrate.rs` (the two structs, three constants).
  Encoding stays `peer::encode`/`decode`.
- `crates/mux-proto/src/shell.rs` is deleted. `IN_LANE_*`/`OUT_LANE_*`
  move into `frame.rs` beside the layout they index, as a `pub mod lane`
  or bare constants. `DEFAULT_COLS`/`DEFAULT_ROWS` move into `peer.rs`
  (both binaries use them: pty.rs:146, mux-attach:140).
- `lib.rs` becomes `pub mod frame; pub mod peer;` and one doc line.

### frame.rs

```rust
pub const MAX_FRAME_SIZE: u32 = 64 * 1024 * 1024;
pub const MAX_REQUEST_BYTES: u32 = 1024 * 1024;   // moved from peer.rs

/// [u32 LE len][u8 lane][payload], len = 1 + payload.len().
pub fn encode(lane: u8, payload: &[u8]) -> io::Result<Vec<u8>>;
/// The 5-byte header: (lane, payload_len). Errors on len == 0 or > MAX.
pub fn parse_header(bytes: [u8; 5]) -> io::Result<(u8, usize)>;
/// [u32 LE len][bytes]: the handshake envelope, same checks against MAX_REQUEST_BYTES.
pub fn encode_message(bytes: &[u8]) -> io::Result<Vec<u8>>;
pub fn parse_message_len(bytes: [u8; 4]) -> io::Result<usize>;

// sync (std::io), used by mux-attach
pub fn write_lane<W: Write>(w, lane, payload) -> io::Result<()>;
pub fn read_lane<R: Read>(r) -> io::Result<Option<(u8, Vec<u8>)>>;   // None on clean EOF
pub fn write_message<W: Write>(w, bytes) -> io::Result<()>;
pub fn read_message<R: Read>(r) -> io::Result<Vec<u8>>;

#[cfg(feature = "tokio")]
pub mod aio { /* the same four over AsyncRead/AsyncWrite, each ≤ 8 lines, calling encode/parse_header */ }
```

`FrameLimits` is deleted (every call site is `::default()`; verified
-22 lines). `FrameError` and the thiserror dependency are deleted;
`io::Error::new(InvalidData, ..)` via one private `fn invalid(msg)`
helper. `LaneFrame` becomes the `(u8, Vec<u8>)` tuple the async side
already uses (two fields, allowed by `no-anon-tuple`).

mux-proto `Cargo.toml` gains `[features] tokio = ["dep:tokio"]` with
tokio optional and default off; muxd enables it, mux-attach does not.
(Resolver 2 unifies features per build, so a workspace-wide `cargo
build` compiles mux-proto once with tokio; mux-attach's own binary still
links nothing from it.)

### Callers

- `server.rs`: delete `read_frame`, `write_frame`, the body of
  `read_request` and `reply`; call `frame::aio::*`. `reply` stays as the
  one-line "encode OpenReply, write on OUT_LANE_OPENED, flush" and
  becomes `pub(crate)`.
- `broker.rs`: delete `write_reply`, call `server::reply`. `open_stream`
  uses `frame::aio::write_message`.
- `mux-attach`: `write_request` becomes `frame::write_message(stream,
  &peer::encode(request))`; `read_lane_frame(.., FrameLimits::default())`
  becomes `frame::read_lane(..)`.
- `tests/manager.rs`, `tests/quic.rs`, `tests/accept.rs`: use
  `frame::aio::*` (task 10 then moves the remaining helpers into
  `tests/common`).

## Keep

- The golden byte tests: `frame::wire_layout_is_exact`,
  `peer::golden_wire_bytes`. They are the spec and must pass unchanged.
- Both cap values and the clean-EOF-at-frame-boundary contract
  (`Ok(None)`).
- The CLAUDE.md transport rule: local unix socket, QUIC for remote;
  nothing here changes a byte on the wire.

## Done when

- `rg -n 'write_u32_le|read_u32_le' crates` returns only lines inside
  `frame.rs` carrying `astlog-ignore: no-handrolled-frame`; the rule is
  removed from `lint/astlog/PENDING.md`.
- `crates/mux-proto/src` holds `lib.rs`, `frame.rs`, `peer.rs` and
  nothing else; `thiserror` is gone from the workspace table.
- `cargo test --workspace` passes; `cargo build -p mux-attach` does not
  compile tokio (check with `cargo tree -p mux-attach -e normal | rg tokio`).
- Inventory: mux-proto ≤ 330 lines; workspace ≥ 140 lines fewer.
