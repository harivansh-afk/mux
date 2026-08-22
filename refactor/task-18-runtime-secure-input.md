# task 18: GhosttyRuntime without ceremony; SecureInput as a latch

PR title: `app: GhosttyRuntime dispatch helper and static callbacks; SecureInput in 30 lines`

Depends on: 12 (App.delegate, singleton-only runtime).

## Why

`GhosttyRuntime.action` is 180 lines, the largest function in the app.
Ten of its surface-targeted cases (`NEW_SPLIT`, `GOTO_SPLIT`,
`TOGGLE_SPLIT_ZOOM`, `CLOSE_WINDOW`, `SET_TITLE`, `PWD`, `MOUSE_SHAPE`,
`CELL_SIZE`, `DESKTOP_NOTIFICATION`, `SCROLLBAR`) write the same three
lines around one statement: `guard let view else { return false }`,
`DispatchQueue.main.async { ... }`, `return true`. `view` is a `var`
conditionally assigned (:357-360), which forces the shadow `let view =
view` at :471 so a closure captures a value. Two userdata unwrappers
exist with one caller each (:158-166). The four C callbacks in the
runtime config (:32-41) are closures that only forward to a static
function with the matching signature. `presentClipboardConfirmation`
takes two mutually exclusive nil-carriers (`state`, `pasteboard`) and
selects four strings with a 20-line switch; `writeClipboard` computes
`PasteboardType(mimeType:)` twice per item. `.monospacedSystemFont` at
:313 is the one font in the app not from `Chrome`.

`SecureInput.swift` is 126 lines of `NSObject`, two `@objc` selector
observers, `global`/`scoped`/`enabled`/`desired`, and the
Enable/Disable call written three times (`apply`, `onDidBecomeActive`,
`onDidResignActive`) with the same error tail. `apply()` early-returns
when `!NSApp.isActive`, which is the condition the two handlers exist to
paper over. `deinit` resets state on a `static let` that never
deallocates.

## Changes

### GhosttyRuntime.swift

```swift
private static func onMain(_ view: PaneView?, _ body: @escaping (PaneView) -> Void) -> Bool {
    guard let view else { return false }
    DispatchQueue.main.async { body(view) }
    return true
}
```

Each of the ten cases becomes `return onMain(view) { $0.setTitle(title) }`
(capturing the C payload into a Swift value before the closure, as
today). `let view: PaneView? = target.tag == GHOSTTY_TARGET_SURFACE ?
paneView(surface: target.target.surface) : nil`; delete the shadow. One
`paneView(_ userdata:)` unwrapper; the surface variant calls it with
`ghostty_surface_userdata`. Pass the statics directly as the C function
pointers (`wakeup_cb: GhosttyRuntime.wakeup`); delete the trampolines.

Clipboard: split into `completeSurfaceRequest(view:state:contents:confirmed:)`
and `writePasteboard(_:contents:)`; the alert copy is a four-tuple
`switch` assigned once; build `typed = items.compactMap { ... }` once for
`declareTypes` and the set loop. The preview text view uses
`Chrome.metaFont`.

`NSLog` → `AppLog.log` throughout (`no-nslog` then leaves `PENDING.md`
with task 13's and this file's sites gone; Snapshot.swift's two and
SecureInput's go in the same PR).

### SecureInput.swift

```swift
final class SecureInput {
    static let shared = SecureInput()
    var global = false { didSet { apply() } }
    private var scoped: [ObjectIdentifier: Bool] = [:]
    private var enabled = false
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.apply() })
        }
    }
    func setScoped(_ id: ObjectIdentifier, focused: Bool) { scoped[id] = focused; apply() }
    func removeScoped(_ id: ObjectIdentifier) { scoped[id] = nil; apply() }

    private func apply() {
        let want = NSApp.isActive && (global || scoped.values.contains(true))
        guard want != enabled else { return }
        let err = want ? EnableSecureEventInput() : DisableSecureEventInput()
        if err == noErr { enabled = want } else { AppLog.log("secure input err=\(err)") }
    }
}
```

Keep the MIT attribution line and the one sentence on what secure input
is. Callers (`PaneView.passwordInput`, the `SECURE_INPUT` action) are
unchanged.

## Keep

- Every action case and every "silently accepted" action.
- The clipboard confirmation semantics: a request racing an existing
  sheet completes with `confirmed=true` and the empty string; OSC 52
  write declares `.string` on the target pasteboard; paste/read complete
  the surface request.
- The untrusted OSC 8 prompt.
- Secure input yields on deactivate and reacquires on activate; every
  enable is balanced by a disable.

## Done when

- `rg -c 'DispatchQueue.main.async' app/Sources/Mux/App/GhosttyRuntime.swift`
  ≤ 8 (the non-surface cases and `onMain`).
- `rg -n 'NSLog|@objc private func on|override private init|class SecureInput: NSObject' app/Sources`
  returns nothing; `no-nslog` and `no-adhoc-font` leave `PENDING.md`.
- `GhosttyRuntime.swift` ≤ 440 lines; `SecureInput.swift` ≤ 45.
- Manual: a password prompt in a pane enables secure input (check the
  menu-bar lock or `ioreg -l | grep SecureInput`), cmd-tab away clears
  it, cmd-tab back restores it; paste with a newline prompts; OSC 52
  write from a script prompts.
