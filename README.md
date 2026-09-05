# Mux

<video src="https://git.harivan.sh/harivansh-afk/mux/releases/download/demo/demo.mp4" controls width="100%"></video>

A macOS-native terminal multiplexer

A pane is a machine-agnostic concept
Raw bytestreams sent over QUIC transport when remote and unix socket when local

Two parts:

1. The macos client ui -> stateless
2. muxd daemon

## Layout

- `app/` - Mux.app (Swift/AppKit). Builds on macOS only.
- `crates/mux-proto` - lane framing + shell control types, wire-compatible with ix.
- `crates/muxd` - session daemon (ix-console fork): PTYs, headless ghostty-vt, detach/reattach, live-fd self-upgrade.
- `crates/mux-attach` - stdio relay; the command every remote pane runs.
- `crates/ghostty-vt` - headless VT wrapper + `render_reattach` (zig shim, from ix).
- `scripts/fetch-ghosttykit.sh` - prebuilt GhosttyKit.xcframework + resources.

## State model

The only thing the macos client owns is pane layout

Terminal content is daemon-owned and survives client disconnect for both local and remote
Reattach replays the exact screen.

muxd server sends raw PTY byte streams over UDP that are interpreted by the macos client

There are panes and sessions (1 2 3 4 5)

**⌘W** or **prefix x** closes a pane while its shell and programs keep running
on the owning muxd (macOS locally, or Spark for a remote pane). **⌘⇧T** reopens
the most recently closed pane as a focused session attached to that exact
terminal. Repeat to reopen earlier panes. Closed identities persist across app
restarts; closing the final pane leaves an empty window ready to reopen.

**prefix X** or File → Kill Terminal explicitly kills a terminal. Killing or
exiting the shell cannot be undone. An unavailable host is retried; a missing
terminal is reported without starting a replacement shell. Closed terminals
continue using daemon/process memory, and their jobs keep running. This is
preservation of live processes, not disk hibernation.

See [closed-terminal design and research](docs/closed-tabs.md) for persistence,
upgrade compatibility, resource costs, and failure behavior.
