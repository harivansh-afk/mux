# Mux

<video src="https://git.harivan.sh/harivansh-afk/mux/releases/download/demo/demo.mp4" controls width="100%"></video>

A macOS-native terminal multiplexer

A pane is a machine-agnostic concept
Raw bytestreams sent over QUIC transport when remote and unix socket when local

The macOS app owns layout and recovery metadata; muxd owns terminal processes.

## Layout

- `app/` - Mux.app (Swift/AppKit). Builds on macOS only.
- `crates/mux-proto` - lane framing + shell control types, wire-compatible with ix.
- `crates/muxd` - session daemon (ix-console fork): PTYs, headless ghostty-vt, detach/reattach, live-fd self-upgrade.
- `crates/mux-attach` - stdio relay; the command every pane runs.
- `crates/ghostty-vt` - headless VT wrapper + `render_reattach` (zig shim, from ix).
- `scripts/fetch-ghosttykit.sh` - prebuilt GhosttyKit.xcframework + resources.

## Building the app

Run `just app` on macOS to build the complete bundle. Mux requires `muxd` and
`mux-attach` in its bundle and checks both before loading saved state. A bare
SwiftPM executable is not a supported launch mode; `swift test --package-path app`
still runs the app tests.

## State model

The app saves pane layout, font zoom, targets, and closed-pane recovery metadata.

Terminal content is daemon-owned and survives client disconnect for both local and remote
Reattach replays the exact screen.

Canvas reads agent titles and activity from the daemon on the pane's host.
Codex's default terminal title contains its project name. To include the chat
name, configure Codex's `~/.codex/config.toml` on that host:

```toml
[tui]
terminal_title = ["activity", "thread-title", "project-name"]
```

Add the key to the existing `[tui]` table if present. Restart Codex for the
configuration to take effect; `/rename` supplies a name for an unnamed chat.

Remote PTY bytes travel over QUIC; local panes use a Unix socket. The app renders
the stream through GhosttyKit.

There are panes and sessions (1 2 3 4 5)

**⌘W** or **prefix x** preserves the closed terminal for **60 seconds** on its
owning muxd (macOS locally, or Spark for a remote pane), then terminates it.
**⌘⇧T** reopens the same live terminal within that window and cancels its expiry.
App restarts and daemon upgrades do not renew the deadline. Closing the final
pane leaves an empty window ready to reopen. App quit and connection loss retain
normal session recovery; only explicit pane close starts the countdown.

**prefix X** or File → Kill Terminal explicitly kills a terminal. Killing or
exiting the shell cannot be undone. An unavailable host is retried; a missing
terminal is reported without starting a replacement shell. Closed terminals
continue using daemon/process memory, and their jobs keep running. This is
preservation of live processes, not disk hibernation.

See [closed-terminal design and research](docs/closed-tabs.md) for persistence,
upgrade compatibility, resource costs, and failure behavior.
