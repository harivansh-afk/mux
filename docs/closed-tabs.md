# Closed terminal preservation

Research and design decision, 2026-09-05.

## Current lifecycle (2026-09-11)

Explicit pane close retains a terminal for at most 60 seconds. The app calls
`muxd close host:uuid` and waits for the owning daemon to acknowledge its absolute
deadline before releasing the view and relay. A failed request leaves the pane
visible. Retrying close never renews a deadline.

The PTY manager owns the timer and termination. It publishes its existing exit
event so the app removes closed history. History also saves the deadline and
refuses expired entries locally, including after an app restart. Expiry targets
the original terminal generation, so an old timer cannot kill a replacement
terminal using the same name.

`OpenMode::Reopen` cancels the lease and looks up the existing terminal without
creating a shell. Ordinary Open/Attach requests cannot cancel a close, so an
automatic relay reconnect cannot extend retention. The relay sends Reopen on
its initial user-requested attachment and uses Attach after a successful reopen.
The manager serializes reopen against expiry and rejects an elapsed deadline.

Only explicit close arms a timer. Connection loss, app quit, slow-client detach,
and daemon handoff keep their existing recovery semantics.

Protocol v10 appends Close/Reopen and the deadline reply. The daemon continues
accepting v7-v9 interactive requests. Both host daemons must be upgraded before
the app can use the new close command. Migration v2 carries each close deadline;
the new receiver accepts v1 handoffs as terminals without a pending close.
A handoff preserves the original expiry instead of starting another 60 seconds.

Legacy closed entries without a deadline are expired history. On a successful
daemon listing, the app terminates those that remain detached and prunes entries
that no longer exist. It excludes them from orphan recovery.

The earlier unlimited-retention contract is superseded by this lifecycle.
The process-preservation rationale still applies during the 60-second window.

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
workload. Explicitly closed terminals incur those costs for at most 60 seconds;
expiry terminates them. There is no suspension or disk checkpoint.

Client restarts and successful muxd live upgrades can preserve access to these
sessions. A machine reboot, forced daemon shutdown without successful handoff,
process exit, or explicit kill is outside that lifetime guarantee. Persisted
history is a reference to a live session, not a backup of its process state.
