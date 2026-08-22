# task 12: Session is the model

PR title: `app: Session owns its snapshot; one commit path; flat AppSnapshot v3; one runtime`

Depends on: 04.

## Why

State is modelled twice and converted by hand at a distance. `Session`
holds `tree`, `panes`, `focusedID`, `zoomedID` (Session.swift:39-42);
`SessionSnapshot` holds the same four (Snapshot.swift:331-336).
`AppDelegate.saveSnapshot` (:188-221) walks controller → sessions → panes
→ `pwd`/`target`/`fontDelta` to build one from the other, and ends with
`.flatMap { ... }.map { [$0] } ?? []` to turn one optional window into an
array of at most one. `Session.restore(tree:paneMeta:focused:zoomed:)`
takes the snapshot splayed into four parameters, and both callers
(MuxWindowController.swift:197, :285) destructure a `SessionSnapshot` to
feed it. `addRecoverySession` takes an unlabelled
`[(UUID, String?, String?)]` that the controller loops back into a
`[UUID: PaneSnapshot]` to call restore.

`AppSnapshot.windows: [WindowSnapshot]` survives from multi-window. The
writer can only produce one element; the reader takes `windows[0]`
(AppDelegate.swift:228). `AppSnapshotV1` plus the `Versioned` probe and
the three-arm switch in `load(from:)` migrate a format that `git log
-S'currentVersion = 2'` shows was writable for under two hours on
2026-08-09 on one machine.

Every structural mutation in `Session` hand-writes the rule "unzoom,
relayout, save": `controller?.layoutPanes()` 11 times, `saveState()` 7
times, `zoomedID = nil` 7 times. The crash-safety invariant "every
structural change saves synchronously" is therefore checked by reading
eleven sites.

`NewPaneTarget` has two helpers whose two callers each repeat the same
four-line derivation (Session.swift:141-148, MuxWindowController.swift:165-172).

`GhosttyRuntime` is `static var shared` and is also passed through
`MuxWindowController(runtime:)` → `Session(runtime:controller:)` →
`PaneView(id:runtime:...)` to be read once at PaneView.swift:220, while
PaneScrollView.swift:172, Theme.swift:202/215 and the runtime's own
action handler read `GhosttyRuntime.shared`.

Pane cwd seeding from the daemon's live-process cwd is implemented twice
with different filters: AppDelegate.swift:66-78 and Overlays.swift:342-365.

`(NSApp.delegate as? AppDelegate)` appears at PrefixEngine.swift:94,
MuxWindowController.swift:434, :438, Overlays.swift:234, :237,
PaneView.swift:491, GhosttyRuntime.swift:372.

## Changes

### Snapshot.swift

```swift
struct AppSnapshot: Codable {
    static let currentVersion = 3
    var version = currentVersion
    var frame: [Double]          // x y w h
    var sessions: [SessionSnapshot]
    var activeSession: Int
}
```

`WindowSnapshot` and `AppSnapshotV1` are deleted. `load(from:)` decodes
`AppSnapshot`; on failure it decodes a private `V2 { windows:
[Window] }` and folds every window's sessions into one (this is the
"old multi-window snapshots fold all their sessions into the one window"
rule CLAUDE.md requires), taking the frame and active index from
`windows[0]`. A v1 file fails both and is quarantined, as any undecodable
file is. Keep `save`, the rotation, the unchanged-snapshot guard, the
quarantine, and `CrashMarker` byte for byte.

### Session.swift

- `var snapshot: SessionSnapshot?` (nil when `tree == nil`), building
  `panes` from `pane.pwd`, `pane.target`, `pane.fontDelta`.
- `func restore(_ s: SessionSnapshot)`.
- `private func commit(unzoom: Bool = true, relayout: Bool = true)`:
  clears `zoomedID` when asked, `layoutPanes()`, `saveState()`. Every
  mutation ends in one `commit()` call; `removePane` passes `unzoom:
  zoomedID == pane.id`, `detach` passes `relayout: false`, `noteFocused`
  keeps `saveStateSoon` (focus is the debounced class by doctrine).
- `NewPaneTarget`: one
  `func seed(from source: PaneView?) -> (target: String?, cwd: String?, cwdFrom: UUID?)`
  replacing `resolved(from:)` and `inheritsDirectory(from:)`; both
  callers become one line. Keep the one-line note that an ix pty's local
  cwd is not the VM's.
- `init(controller:)`; the `runtime` parameter and property go.

### AppDelegate.swift

- `saveSnapshot` = `guard let c = controller else { return };
  SnapshotStore.save(AppSnapshot(frame: c.window.frame.values, sessions:
  c.sessions.compactMap(\.snapshot), activeSession: c.activeSessionIndex))`.
- `restore` passes `snapshot.sessions` and `snapshot.activeSession`.
- `adoptOrphanedPanes` keeps orphan detection and calls
  `controller.applyCwds(listings, host:)` for the seeding half;
  `addRecoverySession` takes `[UUID: PaneSnapshot]`.
- `applicationDidBecomeActive/ResignActive` call
  `GhosttyRuntime.shared?.setFocus`; the `runtime` stored property goes.
- `static var delegate: AppDelegate { NSApp.delegate as! AppDelegate }`
  on an `enum App` (or as a static on `AppDelegate`), carrying the
  `astlog-ignore: no-delegate-cast`. Every other cast site uses
  `App.delegate`.

### MuxWindowController.swift / +Overlays.swift

- `init()`; `Session(controller: self)`.
- `func applyCwds(_ listings: [Muxd.PtyListing], host: String?)`: for
  each listing whose name is a pane UUID in any session with
  `pane.target == host` and not an ix pane, set `pane.pwd`.
  `refreshPaneDirectories` keeps only the target collection and the
  per-host `Muxd.list` calls, each completing into `applyCwds`.
- `restoreSessions` and `addRecoverySession` call `session.restore(_:)`.

### PaneView.swift

`init(id:workingDirectory:cwdFrom:target:ptyCommand:initialFrame:fontDelta:expectExisting:)`;
`guard let app = GhosttyRuntime.shared?.app`. `adjustAllFontSizes` uses
`App.delegate`.

## Keep

- Crash safety: atomic write, `.bak` rotation, `.corrupt` quarantine,
  one-generation fallback, the `running` marker, synchronous save on
  structural change, debounced save on frame/focus/pwd. Every one of
  these is in CLAUDE.md and none of them moves.
- The fold-many-windows-into-one rule, now as the v2 decoder.
- `restore`'s size-before-spawn behaviour (the pty handshake carries the
  pane's real dimensions) and its comment.

## Done when

- `rg -n 'WindowSnapshot|AppSnapshotV1|windows\[0\]|inheritsDirectory|resolved\(from' app/Sources`
  returns nothing.
- `rg -c 'controller?.layoutPanes()' app/Sources/Mux/Tiling/Session.swift`
  is 1 (inside `commit`).
- `rg -n 'NSApp.delegate as' app/Sources` returns only the `App.delegate`
  definition; `no-delegate-cast` leaves `PENDING.md`.
- A v2 `state.json` from before this change restores with every session
  and the window frame; then quit and confirm the file is v3. A v1 file
  (hand-write one) lands in `state.json.corrupt` and the app starts
  fresh.
- Inventory: ≥ 170 lines fewer.
