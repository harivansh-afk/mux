import Carbon
import Cocoa

/// Manages the secure keyboard input state. Ported from ghostty's
/// SecureInput.swift (MIT). Secure keyboard input is an old Carbon API
/// still in use by applications such as Webkit: while enabled, keyboard
/// input goes only to the application with keyboard focus and is not
/// echoed to other applications watching keyboard input.
///
/// Secure input is global and stateful, so a singleton manages it: yield
/// on application deactivation (it affects other apps), reacquire on
/// reactivation, and balance every enable with a disable.
final class SecureInput: NSObject {
    static let shared = SecureInput()

    // True if you want to enable secure input globally.
    var global: Bool = false {
        didSet {
            apply()
        }
    }

    // The scoped objects and whether they're currently in focus.
    private var scoped: [ObjectIdentifier: Bool] = [:]

    // This is set to true when we've successfully called
    // EnableSecureEventInput.
    private(set) var enabled: Bool = false

    // This is true if we want to enable secure input: enabled globally or
    // any of the scoped objects are in focus.
    private var desired: Bool {
        global || scoped.contains(where: { $0.value })
    }

    override private init() {
        super.init()

        // Application active/resign notifications so we can yield and
        // reacquire secure input.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onDidResignActive(notification:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onDidBecomeActive(notification:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        // Reset our state so we restore the proper system state.
        scoped.removeAll()
        global = false
        apply()
    }

    // Add a scoped object that has secure input enabled. The focused value
    // determines if the object currently has focus, so secure input is
    // only enabled while the object is focused.
    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    // Remove a scoped object completely.
    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        apply()
    }

    private func apply() {
        // If we aren't active then we don't do anything. The become/resign
        // active notifications handle applying for us.
        guard NSApp.isActive else { return }

        // We only need to apply if we're not in our desired state.
        guard enabled != desired else { return }

        let err: OSStatus
        if enabled {
            err = DisableSecureEventInput()
        } else {
            err = EnableSecureEventInput()
        }
        if err == noErr {
            enabled = desired
            return
        }

        NSLog("secure input apply failed err=\(err)")
    }

    // MARK: - Notifications

    @objc private func onDidBecomeActive(notification _: NSNotification) {
        // Only re-enable if we're not already enabled and we desire it.
        guard !enabled, desired else { return }
        let err = EnableSecureEventInput()
        if err == noErr {
            enabled = true
            return
        }

        NSLog("secure input apply failed err=\(err)")
    }

    @objc private func onDidResignActive(notification _: NSNotification) {
        // Only disable if we're enabled.
        guard enabled else { return }
        let err = DisableSecureEventInput()
        if err == noErr {
            enabled = false
            return
        }

        NSLog("secure input apply failed err=\(err)")
    }
}
