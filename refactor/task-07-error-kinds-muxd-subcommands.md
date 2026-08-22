# task 07: failure is a typed value; daemon queries live with the daemon

PR title: `wire: OpenError with a kind; muxd ls/kill/probe; mux-attach is only a relay`

Depends on: 06.

## Why

`OpenReply` is `Result<Opened, String>` (peer.rs:505). The daemon's
failure reasons cross the wire as English. mux-attach's `classify`
(main.rs:416-433) then substring-matches seven sentences produced in
broker.rs, tls.rs and server.rs, with a doc comment explaining that order
matters because the broker wraps a pin failure in its own "cannot reach"
context, and a 38-line test (`failures_are_classified`) whose purpose is
to fail when someone rewords a log line in another crate. The class then
goes to JSON, is parsed in Swift as `Muxd.Probe.failure`, and is rendered
by `HostsWindowView`. Four sites in muxd carry comments saying "the
wording is a contract" (server.rs:51-52, :170, broker.rs:63-66).

Separately, mux-attach is documented as "the stdio relay every pane runs"
and ~300 of its 784 lines never relay a byte: `run_control` (list, kill),
`probe`/`ask`/`Listed`/`Probe`/`classify`, `PtyLine`, the human-readable
`--list` branch (no caller: Mux.app always passes `--json`), and their
tests. `run_control`, `ask` and `open_session` each spell out the same
build-OpenRequest, write, read-first-frame, decode sequence. The raw
termios block uses `mem::zeroed` and two `unsafe` blocks where
`nix::sys::termios` is already a dependency.

## Changes

### peer.rs

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ErrorKind { Unreachable, PinMismatch, TokenRejected, VersionMismatch, NoHost, Other }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenError { pub kind: ErrorKind, pub detail: String }

pub type OpenReply = Result<Opened, OpenError>;
```

`PROTOCOL_VERSION` becomes 6; the version-history comment gains "v6:
typed OpenError". `ErrorKind` serialises by name in JSON (`serde(rename_all
= "kebab-case")`) so the strings Swift sees are the ones it already
switches on.

Set the kind where the failure is raised: `server::Policy::admit`
(TokenRejected, and Other for "a remote daemon does not relay"), the
version check in `handle_connection` (VersionMismatch), `broker::relay`
(map `check_alias`/`host_addr` failures to NoHost, `Tofu::failure` to
PinMismatch, everything else from `connection`/`open_stream` to
Unreachable), `handle_open`'s `manager.open` failure (Other). Delete the
four "wording is a contract" comments and the `UNREACHABLE` prefix
constant. `host_addr` collapses its two `with_context` essays to one
`bail!("unknown host {alias:?} in {path}; known: {list}")`.

### muxd subcommands

`main.rs` gets `ls [alias] [--json]`, `kill <target>`, `probe <alias>`
beside `client-digest`. Each is connect-to-local-socket, one handshake,
print. Because muxd already has tokio, the async `frame::aio` and `peer`
are there; ~90 lines total including the JSON structs. `probe` prints the
same one-line JSON shape as today (`alias`, `ok`, `rtt_ms`, `ptys`,
`class`, `error`) with `class` taken from `OpenError.kind`. `ls --json`
prints `PtyInfo` via `serde_json::to_string(&p)` (the `PtyLine` mirror is
deleted; Swift's `PtyListing` has `cwd: String?` and decodes `null` and
absent identically, verified). The human `ls` branch is dropped; the
three Python e2e scripts that grep it assert on `PTY_NAME in line`, which
JSON satisfies.

The `muxd pin` subcommand is deleted here or in task 09 (decision 6 in
the README); if kept, it moves under the same match arm.

### mux-attach

Delete: `run_control`, `probe`, `ask`, `Listed`, `Probe`, `classify`,
`PtyLine`, the `--list`/`--json`/`--kill` parsing and dispatch, both
tests, the module-doc usage lines for them, and `serde`/`serde_json` from
its Cargo.toml.

Add one function and use it from `open_session` and `reconnect`:

```rust
fn handshake(stream: &mut UnixStream, request: &OpenRequest) -> Result<Opened> {
    frame::write_message(stream, &peer::encode(request))?;
    let (lane, payload) = frame::read_lane(stream)?.context("daemon closed during handshake")?;
    ensure!(lane == OUT_LANE_OPENED, "unexpected first lane {lane}");
    peer::decode::<OpenReply>(&payload)?.map_err(|e| anyhow!("{}: {}", e.kind, e.detail))
}
```

`RawModeGuard` is rewritten on `nix::sys::termios::{tcgetattr, cfmakeraw,
tcsetattr}`: no `unsafe`, no `zeroed`, guard holds `Option<Termios>`.
`connect`'s `pre_exec` uses `nix::unistd::setsid`. `Uplink` uses
`parking_lot::Mutex` (add the dep; it is in the workspace table) so the
`PoisonError` imports go.

### Swift

`State/Muxd.swift`: `probe`, `list`, `clientDigest` call `daemonBinary`
with `probe`, `ls --json`, `client-digest`. `Probe` becomes one
`Decodable` struct (CodingKeys `rtt_ms`, `class`), `ProbeLine` is
deleted, a `static func failed(_:)` covers the two no-binary paths, and
one `private static func jsonLines<T: Decodable>(_:) -> [T]` serves
`probe` (last line) and `list` (all lines). `HostsWindow.status(of:)`
reads `probe.failure ?? "error"`. `PaneView.killRemote` moves in task 13;
until then it calls `daemonBinary` with `kill`.

### Docs and scripts

`docs/architecture.html` section 2 reply table: `OpenReply` is
`Result<Opened, OpenError>`. `scripts/test-muxd-*.py` call `muxd ls`
instead of `mux-attach --list`.

## Keep

- mux-attach stays its own crate and stays tokio-free (648K vs muxd's
  7.0M; it is forked once per pane).
- The reconnect contract (never exits on daemon EOF; `--expect-existing`
  notice; `RESPAWN_AFTER` window) verbatim.
- The probe JSON shape and exit code: Mux.app reads it.

## Done when

- `rg -n 'classify|CLASSES|PtyLine|run_control' crates` returns nothing.
- `crates/mux-attach/src/main.rs` ≤ 420 lines; its Cargo.toml lists
  `anyhow`, `libc`, `mux-proto`, `nix`, `parking_lot` only.
- `rg -n 'wording|contract' crates/muxd/src/{server,broker}.rs` returns
  nothing.
- `no-poison-unwrap` and `no-libc-termios` leave `PENDING.md`.
- `just e2e`, `just quic-e2e`, `just upgrade-test` pass against the
  rebuilt binaries; the hosts window shows the same statuses for spark
  up, spark down, and a wrong pin (edit one byte of the `known_hosts`
  line to test the last).
