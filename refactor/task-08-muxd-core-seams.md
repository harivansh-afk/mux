# task 08: muxd core seams

PR title: `muxd: one install path, version-first handshake, passwd via nix, no carrier structs`

Depends on: 06.

## Why

The core of muxd is right and this task does not touch the parts that
are: `manager::attach`, `read_loop`'s single-lock read/feed/resolve,
`pty::spawn`'s pre-fork construction, `wait_child`, `kill`. Four seams
around them are wrong or duplicated, and two of them are bugs.

- `pty.rs:63-110`: `user_shell` and `user_home` are the same 23-line walk
  over `libc::getpwuid`, which returns a pointer into a static buffer.
  muxd calls `spawn` from any tokio worker, so two concurrent creates can
  race on that record. `nix::unistd::User::from_uid` (nix 0.29 with the
  `user` feature, already on) wraps `getpwuid_r`.
- `manager.rs:213-241`: `adopt` does `self.get(name).is_some()` then a
  separate `self.ptys.lock().insert(...)`, which is exactly the
  lookup/insert split `open`'s comment at :167-170 says must never exist,
  and it skips `MAX_PTYS`. Both build the same nine-field `PtySession`,
  insert, spawn `read_loop`, and log.
- `server.rs:378-408`: `read_request` fabricates
  `OpenRequest { version, cols: 0, rows: 0, .., mode: OpenMode::List }`
  on decode failure so the version check at :171 fires; two comment
  blocks (:166-170, :387-390) explain the two paths for one condition.
- `server.rs:195-275`: `handle_connection` destructures `OpenRequest`,
  builds `struct Open` from six of the same fields, and `handle_open`
  destructures it back. `handle_unix` (:140-143) wraps one call.
- `manager.rs:268-331`: `enum Step` has four variants for "send this, or
  stop"; two arms are empty and two both `break`.
- `quic.rs:132-147`: `handle_stream` is three statements with one
  caller, wrapped in comments.

## Changes

### pty.rs

```rust
fn passwd() -> Option<nix::unistd::User> {
    nix::unistd::User::from_uid(nix::unistd::Uid::current()).ok().flatten()
}
fn env_or<F: FnOnce(&User) -> PathBuf>(var: &str, field: F, fallback: &str) -> String
```

`user_shell()` = `env_or("SHELL", |u| u.shell.clone(), "/bin/zsh")`,
`user_home()` = `env_or("HOME", |u| u.dir.clone(), "/")`. Both `unsafe`
blocks and SAFETY comments go. Keep the two-line note on why a daemon
asks passwd.

### manager.rs

```rust
fn install(&self, name: &str, command: Vec<String>, terminal: Terminal,
           master: AsyncFd<OwnedFd>, child: Pid, adopted: bool) -> Result<Arc<PtySession>>
```

takes the guard once, rejects a duplicate name, checks `MAX_PTYS`,
inserts, drops the guard, spawns `read_loop`, logs `name, adopted`. `open`
becomes: lock, early-return on existing (so attach-or-create keeps its
one round trip), spawn pty, new terminal, `install`. The five-line
comment about the single guard moves onto `install`. `adopt` becomes:
set nonblocking, new terminal fed with the snapshot, `install(...,
adopted: true)`.

`Step` is deleted. `read_loop`'s lock block binds only what outlives it:

```rust
let Some((n, id, tx)) = ({
    let mut term = session.terminal.lock();
    match guard.try_io(|fd| read(fd, &mut buf)) {
        Ok(Ok(0)) => break,
        Ok(Ok(n)) => { term.feed(&buf[..n]); session.client.lock().as_ref().map(|c| (n, c.id, c.tx.clone())) }
        Ok(Err(e)) if e.raw_os_error() == Some(libc::EIO) => break,
        Ok(Err(e)) if e.kind() == WouldBlock => None,
        Ok(Err(e)) => { tracing::warn!(..); break }
        Err(_) => None,
    }
}) else { continue };
```

followed by the existing `send_timeout` block. The read/feed/resolve
under one lock invariant and its comment are unchanged.

### server.rs

`read_request` reads the message (task 06's `frame::aio::read_message`),
decodes the version prefix first and unconditionally, returns
`Err(Mismatch(version))` on mismatch, then decodes the whole request.
`handle_connection` matches that error to the `VersionMismatch` reply.
The synthetic request, `mode: List`, and both comment blocks go; one
line remains: "version is the first field by design".

`struct Open` is deleted. `handle_open(manager, request: OpenRequest,
cwd: Option<String>, reader, writer)` destructures `mode` itself; the
cwd-inheritance lookup moves into it beside `manager.open`. `handle_unix`
is inlined into `serve`'s spawn.

### quic.rs

`handle_stream` is inlined into the `accept_bi` spawn: call
`server::handle_connection`, `let _ = send.finish()`, one-line comment
on why finish runs on failure too.

## Keep

- `manager.rs:4-12` and every lock-ordering comment.
- `pty::spawn`'s pre-fork discipline and its comment at :185-190.
- `wait_child` / `wait_adopted` exactly as they are.
- `server::transient` and the accept backoff.

## Done when

- `rg -n 'getpwuid' crates` returns nothing; `no-getpwuid` leaves
  `PENDING.md`.
- `rg -n 'struct Open\b|enum Step|handle_unix|handle_stream' crates/muxd/src`
  returns nothing.
- A new test in `tests/manager.rs`: adopting a pty whose name already
  exists returns `Err` and leaves the original attached (today it
  silently replaces the map entry).
- `cargo test --workspace` passes; `just upgrade-test` passes.
- Inventory: muxd/src ≥ 90 lines fewer.
