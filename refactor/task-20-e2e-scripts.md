# task 20: one e2e harness, and only the cases Rust cannot cover

PR title: `scripts: muxd_harness.py; e2e scripts keep only real-pty, real-binary cases`

Depends on: 07 (the `muxd ls` verb).

## Why

`scripts/test-muxd-e2e.py` (319 lines), `test-muxd-upgrade.py` (316)
and `test-muxd-quic-e2e.py` (217) each re-derive the same harness:
repo root and binary discovery, a tempdir `HOME`, a private socket, a
daemon spawn with a readiness poll, `pty.openpty`, log and fail helpers,
about 60-80 lines each with nothing shared. Only the first runs in CI.
Much of what they prove is already pinned in-process:
`muxd/tests/manager.rs` covers the self-upgrade fd handoff with the
child pid and screen
(`a_self_upgrade_carries_the_pty_its_screen_and_its_child`) and the
unacknowledged handoff; `muxd/tests/quic.rs` covers the authenticated
QUIC listener. What needs the real binaries under a real pty is smaller:
mux-attach's reconnect-and-replay across a daemon restart and across
`--upgrade`, the `--expect-existing` notice, and the end-to-end
broker dial through a second daemon.

## Changes

- `scripts/muxd_harness.py`: `find_binaries()`, `Daemon(home, socket,
  quic=None)` context manager (spawn, wait for the socket, kill and
  reap on exit), `Pty(cmd)` wrapper over `pty.openpty` with
  `expect(needle, timeout)`, and `log`/`fail`. Typed, `uv run`-able, no
  third-party deps.
- `test-muxd-e2e.py` keeps: attach, `kill -9` the relay, reattach
  replays; `--expect-existing` prints the notice when the pty was
  recreated; `muxd ls --json` lists the pane. Delete cases that
  re-assert list/kill semantics the Rust tests own.
- `test-muxd-upgrade.py` keeps: a pane with a running program survives
  `muxd --upgrade` and its relay reconnects without a notice.
- `test-muxd-quic-e2e.py` keeps: two daemons on loopback, a pane
  targeting the alias attaches through the broker, a wrong token is
  refused with `token-rejected`, a changed pin is refused with
  `pin-mismatch` (the JSON `class`, now from `ErrorKind`).
- `justfile`: `e2e` runs all three; CI runs `just e2e` in the rust job
  (the QUIC and upgrade cases are loopback and hermetic; the comment
  claiming otherwise predates the harness isolation).
- Replace `mux-attach --list` with `muxd ls --json` everywhere.

## Keep

- Every script runs against a throwaway `HOME` and a private socket and
  can never touch the user's daemon (`MUXD_SOCKET`, `MUXD_MIGRATE_SOCKET`,
  `HOME`).

## Done when

- `wc -l scripts/*.py` ≤ 450 total.
- `just e2e` passes locally and in CI.
- `rg -n 'mux-attach.*--list' scripts` returns nothing.
