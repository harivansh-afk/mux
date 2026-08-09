# Mux.app

Swift/AppKit. Builds on macOS only - generate the Xcode project here on the Mac.

## Module plan

Standard SwiftPM layout: all sources under `Sources/Mux/`, grouped by feature.

- `Sources/Mux/App/` - lifecycle. Owns the single `ghostty_app_t`; wraps
  `ghostty_runtime_config_s` (wakeup_cb, action_cb, clipboard cbs) and dispatches
  the ~70 action tags (new_split, goto_split, toggle_split_zoom, new_tab, ...)
  into NotificationCenter. Adapted from ghostty's `Ghostty.App.swift` (MIT).
- `Sources/Mux/Terminal/` - `PaneView: NSView` hosting a ghostty surface.
  `ghostty_surface_new` with the view in `platform.nsview`; forward key/text/
  mouse/scroll/IME (NSTextInputClient); `ghostty_surface_set_size` on layout,
  `set_content_scale` on screen change. Adapted from `SurfaceView_AppKit.swift`.
- `Sources/Mux/Tiling/` - the multiplexer. `SplitTree` adapted from ghostty's
  `macos/Sources/Features/Splits/SplitTree.swift` (Codable BSP: leaf/split with
  direction+ratio, spatial rects for h/j/k/l focus, zoomed node). Plus the
  prefix engine: mode enum (normal/prefix/resize), local NSEvent monitor ahead
  of the focused surface, held-ctrl aliasing, edge fallback motion.
- `Sources/Mux/State/` - versioned JSON layout snapshots: BSP tree +
  per-pane {target, session id, cwd, launch argv, label, agent session ref},
  stable never-reused pane/tab ids, autosave on mutation. Restore = rebuild
  tree, re-exec each pane's command (M1: local shell at cwd; M2: mux-attach
  target which replays the daemon's screen).
- `Sources/Mux/UI/` - window chrome: borderless `MuxWindow`, the window
  controller, the floating mode bar, the help overlay, and theming.

## Pane command per milestone

- M1: user's shell at the saved cwd (plain local exec)
- M2: `mux-attach local:<session>` (local muxd, unix socket)
- M3: `mux-attach <host>:<session>` and `ix shell <vm>` for ix VMs
- M4: `mux-attach ix:<vm>` (native QUIC + connect token)

## GhosttyKit

`GhosttyKit/` holds module.modulemap + the fetched xcframework + resources
(see ../scripts/fetch-ghosttykit.sh). Set GHOSTTY_RESOURCES_DIR at launch.
