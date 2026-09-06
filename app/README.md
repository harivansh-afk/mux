# Mux.app

Swift/AppKit on macOS, built with SwiftPM. From the repository root, run
`just ghosttykit` to fetch GhosttyKit, then `just app` to assemble
`app/.build/Mux.app`. Rust builds also need the Ghostty source and Zig;
see the root [README](../README.md). Run `swift test --package-path app`
for the app and tiling tests on macOS.

## Source layout

- `Sources/Mux/App/`: application lifecycle, Ghostty runtime callbacks,
  clipboard integration, and action dispatch to the window controller.
- `Sources/Mux/Terminal/`: Ghostty surfaces, keyboard/IME/mouse forwarding,
  scrolling, and pane metadata.
- `Sources/Mux/Tiling/`: sessions, pane ownership, and the prefix key engine.
- `Sources/Tiling/`: the Foundation-only split tree, shared by layout,
  navigation, persistence, and platform-independent tests.
- `Sources/Mux/State/`: snapshots and recovery, daemon queries and watches,
  host configuration, ix integration, and subprocesses.
- `Sources/Mux/UI/`: the window controller, Canvas, overlays, host editor,
  and theme.

## Pane targets

Sessions own client-side layout; muxd owns each persistent PTY. Restoring
layout reattaches panes by their stable IDs and replays the daemon's screen.
The client displays a notice if a missing PTY has to be recreated.

- `nil`: a local daemon PTY, addressed as `local:<pane>`.
- A host alias from `~/.config/mux/hosts.json`: a remote daemon PTY,
  reached through the local daemon's QUIC broker.
- `ix:<vm>`: a local daemon PTY running `ix shell <vm>`. Detaching retains
  that local process; persistence inside the VM depends on ix.

Splits and new sessions inherit their source pane's target. A working
directory is inherited only when targets match. Prefix `t` opens the
target picker.

## GhosttyKit

`GhosttyKit/` contains the fetched xcframework and module map. The bundle
assembler includes Ghostty runtime resources and the sibling terminfo
directory, and signs with the local `mux-dev` identity when available.
