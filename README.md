# mux

A macOS-native terminal multiplexer on libghostty that speaks the ix shell protocol.

Every pane is a GhosttyKit Metal surface. Any pane can transparently be a session on
an ix VM, a plain Linux box running `muxd`, or the Mac itself. No web layer, no
sidebar, no chrome: the UI is the panes.

Read `docs/architecture.html` first - it is the design document and the map of what
is forked from where (ix-console, ghostty's Swift SplitTree, a modal
prefix-key interaction model).

## Layout

- `app/` - Mux.app (Swift/AppKit). Builds on macOS only.
- `crates/mux-proto` - lane framing + shell control types, wire-compatible with ix.
- `crates/muxd` - session daemon (ix-console fork): PTYs, headless ghostty-vt,
  detach/reattach, live-fd self-upgrade.
- `crates/mux-attach` - stdio relay; the command every remote pane runs.
- `crates/ghostty-vt` - headless VT wrapper + `render_reattach` (zig shim, from ix).
- `scripts/fetch-ghosttykit.sh` - prebuilt GhosttyKit.xcframework + resources.

## State model

Layout and identity are client-owned (versioned JSON snapshots). Terminal content is
daemon-owned: it survives client disconnect, and reattach replays the exact screen.
Restore layout and identity always; pixels come back from the daemon.

Terminology: a *session* is the client-side unit you switch between (prefix c /
1..9), a group of split panes - pure layout state. The daemon addresses terminal
content per-pane (a *pty*); it never learns client sessions exist, which is what
lets one session span machines.

## Milestones

M1 local-only app; M2 local muxd (kill the app mid-htop, reopen, htop is still
there); M3 remote muxd + ix VMs via `ix shell` relay; M4 native ix QUIC client;
M5 agent identity, workspace env, JSON CLI, predictive echo.
