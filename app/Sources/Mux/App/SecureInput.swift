import Carbon
import Cocoa

/// Manages the secure keyboard input state. Ported from ghostty's
/// SecureInput.swift (MIT). Secure keyboard input is an old Carbon API
/// still in use by applications such as Webkit: while enabled, keyboard
/// input goes only to the application with keyboard focus and is not
/// echoed to other applications watching keyboard input.
///
/// It is global and stateful, so it is yielded while another application
/// is active and reacquired on return, and every enable is balanced by a
/// disable.
final class SecureInput {
    static let shared = SecureInput()

    /// Secure input for the whole app, independent of what has focus.
    var global = false { didSet { apply() } }

    /// Scoped objects (panes on a password prompt) and whether each is focused.
    private var scoped: [ObjectIdentifier: Bool] = [:]
    private var enabled = false
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.apply()
            })
        }
    }

    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        apply()
    }

    private func apply() {
        let want = NSApp.isActive && (global || scoped.values.contains(true))
        guard want != enabled else { return }
        let err = want ? EnableSecureEventInput() : DisableSecureEventInput()
        if err == noErr {
            enabled = want
        } else {
            AppLog.log("secure input err=\(err)")
        }
    }
}
