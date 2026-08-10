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

## Building the crates

`crates/ghostty-vt` compiles ghostty's terminal package from source, so the Rust
workspace needs Zig 0.16.0 on `PATH` (or at `$HOME/tools/zig-0.16.0/`) and a
ghostty checkout:

    export GHOSTTY_SOURCE_DIR="$HOME/src/ghostty/src"
    cargo test --workspace

The checkout must match the generation of `app/GhosttyKit/GhosttyKit.xcframework`;
CI pins it as `GHOSTTY_COMMIT` in `.forgejo/workflows/ci.yml`, which is also where
the Linux build of `muxd` is proven.

`just e2e` runs `scripts/test-muxd-e2e.py`: it drives `mux-attach` under a real
pty, SIGKILLs the client, reattaches and checks the replay. It uses a throwaway
`HOME` and a private socket, so it never touches a daemon you are living in.

## State model

Layout and identity are client-owned (versioned JSON snapshots). 
Terminal content is daemon-owned and survives client disconnect, reattach replays the exact screen.
Restore layout and identity always; pixels come back from the daemon in form of raw byte stream

Terminology: a *session* is the client-side unit you switch between (prefix c /
1..9), a group of split panes - pure layout state. The daemon addresses terminal
content per-pane (a *pty*); it never learns client sessions exist, which is what
lets one session span machines.

## Milestones

M1 local-only app (done); M2 local muxd - kill the app mid-htop, reopen, htop is
still there (done; M2.5 daemon self-upgrade via SCM_RIGHTS pending); M3 remote
muxd over QUIC streams (quinn - never ssh/mosh/plain TCP; the local muxd brokers
one connection per host) + ix VMs via `ix shell` relay; M4 native ix client
(their codec encoding + connect-token dial; same session protocol); M5 agent
identity, workspace env, JSON CLI, predictive echo.
