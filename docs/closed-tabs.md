# Closed terminal preservation

Research and design decision, 2026-09-05.

## Decision

Ordinary pane close should detach the app from the terminal and leave its shell
and programs running in the owning muxd. Command-Shift-T should attach to that
same terminal identity on that same host. This works with both macOS muxd and
Linux muxd on Spark using the existing PTY ownership model and an attach-only
protocol operation.

The existing daemon already distinguishes connection EOF from terminal death:
[`server.rs`](../crates/muxd/src/server.rs) detaches on client EOF;
[`manager.rs`](../crates/muxd/src/manager.rs) retains the PTY, keeps consuming its
output into the terminal emulator, and removes it when the process exits.
Its `attach` operation returns a rendered screen/scrollback snapshot before
streaming subsequent output. The process itself stays alive, including its
environment, unsaved editor buffers, open files, and jobs.

## User-visible contract

- Close means detach. Release the app-side terminal view and connection, and
  persist the host and terminal identity in the closed-pane history.
- Reopen means attach to that identity, newest closed pane first. Persist history
  alongside session state so an app restart does not forget detached terminals.
- Reopen must use attach-only semantics. A missing terminal must never silently
  become a newly spawned shell, including the race where it exits after a list
  response but before attachment.
- An unavailable host or failed connection is retryable. Reopen transfers the
  saved identity into a persistent open pane which displays the failure and
  retries. Closing that waiting pane puts it back into closed history. Neither
  path substitutes a local shell or loses the saved identity.
- Explicit kill remains a distinct destructive action and is not an undoable
  close. A shell that exits naturally likewise cannot be reattached. Stale history
  needs a visible failure or pruning after a definitive missing-terminal response.
- History eviction or clearing metadata must not silently kill detached work.
  Detached sessions remain discoverable through the daemon's existing session
  listing and can be explicitly attached or killed.

These are intended semantics for the implementation, not evidence of completed
UI verification.

## Rollout

Protocol v8 adds `OpenMode::Attach { name }`, which only looks up an existing
live PTY. It never enters the spawn path. The v8 daemon also accepts unchanged
v7 requests, so older attached clients can reconnect after its live upgrade.
The new attach-only operation requires updating the owning daemon as well as
the local broker and app; upgrade Spark's muxd before using reopen there.
An older remote daemon produces a visible version mismatch and retry rather
than creating a replacement. The migration payload is unchanged.

Closed history is optional metadata in the existing v3 app snapshot. It has no
automatic eviction or expiry, since forgetting entries could strand running
jobs or make orphan recovery reopen intentionally closed panes. Explicit kill
and observed process exits release terminals; daemon PTY limits still apply.
Reopened panes carry the attach-only flag into their own persisted snapshots.

## Why saving the screen is insufficient

The existing upgrade mechanism passes live PTY file descriptors with
`SCM_RIGHTS`, transfers terminal render snapshots, and waits for an adoption
acknowledgment before the old daemon exits. Shells remain running throughout;
this is not disk checkpointing or restoration of dead processes. See
[`migrate.rs`](../crates/muxd/src/migrate.rs).

A process checkpoint also needs memory mappings/pages, file descriptors, pipes,
threads, and process relationships. CRIU gathers that state using Linux `/proc`
and `ptrace`; its installation requirements include a suitably configured Linux
kernel. It is therefore not a shared macOS/Linux checkpoint backend. This review
does not establish a supported equivalent for arbitrary native macOS shell trees.
[CRIU checkpoint design](https://criu.org/Checkpoint/Restore),
[CRIU requirements](https://www.criu.org/Installation).

CRIU makes Linux disk hibernation a possible separate experiment, not a reliable
default for arbitrary terminal workloads. External resources may need caller
assistance, and some cannot be restored. TCP checkpointing requires connection
locking while the original sockets are absent to prevent resets; a remote peer's
lifetime remains outside Mux's control. From these constraints, exact restoration
after arbitrary downtime cannot be promised for arbitrary connected programs.
[External resources](https://criu.org/External_resources),
[TCP checkpoint handling](https://www.criu.org/TCP_connection).

## Why not automatically stop the shell

`SIGSTOP` suspends execution and `SIGCONT` resumes it; this does not serialize
the process or release its live kernel resources. Signaling one process group
also does not cover an interactive shell's entire job tree: foreground and
background jobs can occupy different groups. Implementing stop/resume around
pane close would add tree-tracking races, interfere with intentionally stopped
jobs, and stall background work without delivering disk-only preservation.
[POSIX signals](https://man7.org/linux/man-pages/man0/signal.h.0p.html),
[Bash job control](https://www.gnu.org/s/bash/manual/html_node/Job-Control-Basics.html),
[Apple process/group signaling](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kill.2.html).

Linux has a cgroup freezer, but this is a platform-specific process-management
facility, not disk checkpointing or a cross-platform Mux solution.
[Linux cgroup v2 documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html).

## Resource and lifetime limits

Closing releases the app's rendering and transport resources. The daemon still
owns the terminal state and PTY, and the shell and its programs still occupy
memory and can consume CPU, disk, network, or GPU resources according to their
workload. This design makes no zero-resource claim and adds no hidden automatic
kill or suspension policy.

Client restarts and successful muxd live upgrades can preserve access to these
sessions. A machine reboot, forced daemon shutdown without successful handoff,
process exit, or explicit kill is outside that lifetime guarantee. Persisted
history is a reference to a live session, not a backup of its process state.
