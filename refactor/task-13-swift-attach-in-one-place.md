# task 13: the relay vocabulary lives in Muxd; the vendored input is diffable

PR title: `app: Muxd.Attach builds the command line; PaneView is a view; input split along upstream seams`

Depends on: 12.

## Why

`PaneView` stores `target`, `ptyCommand`, `expectExisting` purely to build
a mux-attach command line, then builds it: `attachAddress` (:388-393),
`defaultCommand(cwd:cwdFrom:)` (:401-433, string-concatenating quoted
argv), `quote(_:)`, and `killRemote()` (:455-461), which is the app's
only raw `Process()` outside `Subprocess.swift`. `State/Muxd.swift`
already owns the helper binaries and routes everything through
`Subprocess.run`, with its off-main-thread and SIGKILL watchdog
behaviour. An NSView is a second, inconsistent client of the same CLI.

The agent-state glyph ranges (U+2733, U+2800-28FF, U+25D0-25D3) are
written twice: `isStateGlyph` (:74-78), used only by `displayTitle`, and
inline in `static agentState(of:)` (:93-107), whose one caller is the
instance wrapper three lines above it. `showUserNotification` (:529-568)
calls `requestAuthorization` on every OSC 9 and nests the body three
closures deep; there is no launch-time request. `AppDelegate.bindingAction`
(:276-281) is `PaneView.bindingAction` retyped against
`controller?.focusedPane?.surface`, while the context-menu Copy/Paste in
`PaneView+Input.swift:739-745` already goes through the pane's method.

`PaneView+Input.swift` (1,099 lines) is not slop. `keyDown`,
`performKeyEquivalent`, `flagsChanged` and `scrollWheel` are near
verbatim ports of ghostty's `SurfaceView_AppKit.swift` (checked against
`~/src/ghostty` on 2026-08-22) and the IME machinery is the reason dead
keys and CJK input work. The problem is that ~90 mux-authored lines
(`fontZoomStep` and the zoom branch, `reportMousePos(topLeft:flags:)`
and `clearMousePos` for the canvas stage, the `scrollHost` branch of
`setCursorShape`, `menu(for:)` and its handlers) are interleaved with
vendored text, so nobody can re-sync against upstream by diff.

## Changes

### State/Muxd.swift

```swift
extension Muxd {
    struct Attach {
        let paneID: UUID
        let target: String?        // nil local, alias, or ix:<vm>
        let ptyCommand: [String]?  // ix new ...; never persisted
        let expectExisting: Bool
        var address: String        // local:<id> or <alias>:<id>; ix panes are local
        func commandLine(cwd: String?, cwdFrom: UUID?) -> String?   // nil = user shell (no relay bundled)
    }
    static func kill(_ address: String)   // Subprocess.run(attachBinary, ["--kill", address]) { _ in }
}
```

`commandLine` is today's `defaultCommand` plus `quote`, moved verbatim
including the "never send --cwd beside --cwd-from" note. After task 07,
`kill` calls `daemonBinary` with `["kill", address]`.

### Terminal/PaneView.swift

- `init(attach: Muxd.Attach, workingDirectory:cwdFrom:initialFrame:fontDelta:)`;
  keeps `let target` (chrome reads it) and drops `ptyCommand`,
  `expectExisting`, `attachAddress`, `defaultCommand`, `quote`.
  `killRemote()` becomes `Muxd.kill(attach.address)`.
- One parse of the leading scalar:
  `private var parsedTitle: (state: AgentState?, rest: String)`;
  `agentState` and `displayTitle` are one-line projections. Delete
  `isStateGlyph` and the static.
- `showUserNotification`: `center.add(request) { error in ... }` with
  one `DispatchQueue.main.async`; authorization is requested once in
  `applicationDidFinishLaunching`. Route the error through `AppLog`.
- `processExited` is already gone (task 05).

### App/AppDelegate.swift

Delete `bindingAction`; `copyFromPane`/`pasteToPane` call
`controller?.focusedPane?.bindingAction(...)`. Drop `import GhosttyKit`
if nothing else in the file needs it.

### Terminal/ file split

No line changes inside the vendored regions. Move along the existing
`MARK` boundaries:

- `PaneView+Key.swift`: lines 10-490 (keyboard, `flagsChanged`,
  `keyAction`, mods helpers), minus `fontZoomStep` and the zoom branch of
  `performKeyEquivalent`.
- `PaneView+Mouse.swift`: 493-856 minus `reportMousePos(topLeft:flags:)`,
  `clearMousePos`, the `scrollHost` branch of `setCursorShape`, and
  `menu(for:)` plus its `@objc` handlers.
- `PaneView+TextInput.swift`: 858-1099 (`NSTextInputClient`,
  `NSDraggingDestination`).
- `PaneView+Mux.swift`: the ~90 lines removed above, with one header
  saying these are mux's additions to the port.

Each vendored file keeps the MIT attribution header and gains one line
naming the upstream file and the ghostty commit the port matches
(`GHOSTTY_COMMIT` in `.forgejo/workflows/ci.yml`).

## Keep

- The hard-won invariants inside the vendored code: reuse the original
  NSEvent when translation mods are equal (Korean input), the
  `lastPerformKeyEvent` redispatch, the left-mouse-down focus-transfer
  suppression.
- The stage-scroll contract: `reportMousePos(topLeft:flags:)` and
  `clearMousePos` keep their signatures; `CanvasOverlay` calls them
  unchanged.
- The 75ms title coalescing; the per-pane `fontDelta` replay on spawn.

## Done when

- `rg -n 'Process\(\)' app/Sources` returns only `Subprocess.swift`;
  `no-raw-process` leaves `PENDING.md`.
- `rg -n 'defaultCommand|attachAddress|isStateGlyph|requestAuthorization' app/Sources`
  returns only the one launch-time authorization call.
- `diff <(sed -n '10,490p' <old PaneView+Input.swift>) PaneView+Key.swift`
  shows only the moved zoom lines and the header.
- `PaneView.swift` ≤ 560 lines.
- Manual: split, restore after `kill -9`, an ix pane, a remote pane,
  cmd+= in and out of the canvas, Korean or dead-key input, a context
  menu copy. All behave as before.
