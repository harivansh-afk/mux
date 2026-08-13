# mux

https://github.com/user-attachments/assets/6e9fb624-bdd2-4310-ba92-209cc5248a67

A macOS-native terminal multiplexer

Every pane is a GhosttyKit Metal surface. 

Any pane can transparently be running on a remote host over a custom RPC built on QUIC (rip ssh)

This has two parts:
1. The macos client ui
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

A host is a pane level abstraction
