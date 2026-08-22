# task 11 (optional): the predecessor listens

PR title: `muxd --upgrade: the running daemon listens for its successor; pidfile and SIGUSR1 go`

Depends on: 08. Needs README decision 5. Do this last; it changes the
handoff direction, so one release must either support both or accept
losing sessions once during the switch. Saying that plainly is part of
the PR body.

## Why

The handoff design is right: SCM_RIGHTS plus a screen snapshot, sent
under every VT lock, ack before exit. Finding the peer is not. Today the
successor binds the migration socket, reads
`~/.local/state/muxd/muxd.pid`, checks the pid is alive (`alive`) and is
actually a daemon (`is_muxd`, which calls a cfg-split `executable_of`
with an unsafe `proc_pidpath` on macOS and compares a 15-character
truncated `/proc/<pid>/comm` elsewhere), sends SIGUSR1, and after the
payload lands polls `alive(pid)` every 20ms for 5s waiting for the
control socket to be released. `write_pidfile`, `read_pidfile`,
`is_muxd`, both `executable_of`, `paths::daemon_pid`, `spawn_handoff_task`'s
signal loop, `PREDECESSOR_EXIT_TIMEOUT`, `EXIT_POLL_INTERVAL`: about 85
lines, all because a pid was chosen as the address. The recycled-pid
hazard the comments worry about ("SIGUSR1's default action is to kill")
is self-inflicted by that choice.

Separately, `receive` (migrate.rs:263-309) and `send_with_fds`
(:466-483) patch up partial headers by hand because the fds must ride the
first `sendmsg`. Sending the fds on a one-byte carrier first (a one-byte
send cannot be partial) lets the payload go as an ordinary
`[u32 len][postcard]` message through `frame::aio::read_message`.

## Changes

- At startup, after `server::bind` succeeds, the daemon binds
  `paths::migrate_socket()` (0600) and runs an accept loop in place of
  the SIGUSR1 loop. Each accepted connection is a successor asking for a
  handoff: run `hand_off` on it (same snapshot-under-locks, same ack
  wait), exit 0 on `Ok`, keep serving on `Err`.
- `muxd --upgrade` connects to that socket. Connect refused means no
  live predecessor: start empty. Connect succeeds: read the one-byte
  fd carrier with `recv_with_fds`, then `read_message`, adopt, write the
  ack, then read until EOF on the same stream. EOF is the predecessor
  exiting; proceed to `server::bind`. No pid, no signal, no poll.
- Delete `write_pidfile`, `read_pidfile`, `is_muxd`, both
  `executable_of`, `paths::daemon_pid`, `PREDECESSOR_EXIT_TIMEOUT`,
  `EXIT_POLL_INTERVAL`, `Adopted` (return `Vec<(MigratePty, OwnedFd)>`),
  `errno_to_io` (nix 0.29 has `impl From<Errno> for io::Error`).
  `alive()` stays; `manager::wait_adopted` uses it.
- `hand_off` takes the accepted `UnixStream` instead of a path.
  `bind_listener` and `accept_handoff` become the successor's `connect`
  and the predecessor's accept loop; the in-process test in
  `tests/manager.rs` (`a_self_upgrade_carries_the_pty_its_screen_and_its_child`)
  drives both halves through the new functions.
- `scripts/test-muxd-upgrade.py` (or its task-20 replacement) starts the
  old binary, runs the new one with `--upgrade`, and asserts the pty and
  its screen survive. Add the cross-version case if you decide to
  support both directions for one release.

## Keep

- Every VT lock is held from snapshot through ack. Unchanged.
- The ack-before-exit invariant and its comment (migrate.rs:23-27).
- `MUXD_MIGRATE_SOCKET` and a `HOME`-derived default, so a test daemon
  can never take the user's ptys.
- The CLOEXEC note on received fds.

## Done when

- `rg -n 'SIGUSR1|pidfile|daemon_pid|proc_pidpath|is_muxd' crates` returns
  nothing.
- `migrate.rs` ≤ 240 lines.
- `just upgrade-test` passes; a manual `muxd --upgrade` against your
  running daemon keeps every pane, and `muxd.log` shows one "handed off"
  and one "adopted" line.
