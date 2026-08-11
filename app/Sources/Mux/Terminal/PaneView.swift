import AppKit
import GhosttyKit
import UserNotifications

/// One terminal pane: an NSView whose layer libghostty renders into (Metal,
/// IOSurface-backed sublayer, renderer thread owned by libghostty).
/// Input forwarding ported from ghostty's SurfaceView_AppKit.swift (MIT),
/// including the NSTextInputClient/IME machinery.
final class PaneView: NSView {
    let id: UUID

    /// Where this pane's terminal lives.
    ///
    /// - nil: the local daemon (`mux-attach local:<id>`).
    /// - a host alias from ~/.config/mux/hosts.json: the local daemon
    ///   relays the attach to that host (`mux-attach <alias>:<id>`).
    /// - `ix:<vm>`: a local daemon pty whose command is `ix shell <vm>`
    ///   instead of the user's shell, so the VM's session persists exactly
    ///   like a local one - the pty, and the `ix shell` inside it, outlive
    ///   the app.
    let target: String?

    /// A command to run in the pty instead of the user's shell, as argv.
    /// Only VM creation uses it (`ix new -n <name> <template>`), and only
    /// for the pane that does the creating: it is deliberately not
    /// persisted, so a restored pane derives `ix shell <name>` from its
    /// target instead - which is right, because by then the VM exists.
    private let ptyCommand: [String]?

    /// The host chip shown at this pane's top-right corner; nil for local
    /// panes. A sibling view in the pane container (libghostty owns this
    /// view's layer), laid out by Session next to the pane's frame.
    let hostBadge: HostBadgeView?

    /// The scroll view wrapping this pane (owned by the window's pane
    /// container; created in attach). Session lays out the host, and the
    /// host keeps the pane filling its visible rect.
    weak var scrollHost: PaneScrollView?

    /// Scrollback dimensions reported by the core via the SCROLLBAR
    /// action: total rows, first visible row, viewport rows.
    var scrollbar: ghostty_action_scrollbar_s?

    private(set) var surface: ghostty_surface_t?
    weak var controller: MuxWindowController?

    var title: String = "mux"
    var pwd: String?

    /// Points added to the config font size via cmd+= / cmd+- (font
    /// zoom). libghostty owns the actual value and exposes no getter,
    /// so the pane intercepts the keys, drives ghostty through binding
    /// actions, and tracks the delta itself - that is what the snapshot
    /// persists and restore replays.
    private(set) var fontDelta: Int = 0

    /// Internal (not private): managed by updateTrackingAreas in
    /// PaneView+Input.swift.
    var trackingArea: NSTrackingArea?
    private(set) var focused: Bool = false

    // MARK: - Keyboard / IME state (used by PaneView+Input.swift)

    /// In-progress IME composition (preedit) text.
    var markedText = NSMutableAttributedString()

    /// Set to non-nil during keyDown to accumulate insertText contents
    /// produced by interpretKeyEvents.
    var keyTextAccumulator: [String]?

    /// Records the timestamp of the last command/control event seen by
    /// performKeyEquivalent so doCommand(by:) can redispatch it for
    /// encoding. See ghostty's SurfaceView for the full story.
    var lastPerformKeyEvent: TimeInterval?

    /// The renderer's cell size in points, reported via the CELL_SIZE
    /// action. Used to place the IME candidate window.
    var cellSize = NSSize(width: 8, height: 16)

    /// True while a clipboard confirmation sheet is up for this pane, so
    /// racing requests complete instead of stacking sheets.
    var clipboardConfirmationActive = false

    // MARK: - Mouse state (used by PaneView+Input.swift)

    /// True when we've consumed a left mouse-down only to move focus and
    /// should suppress the matching mouse-up from being reported.
    var suppressNextLeftMouseUp = false

    /// The last force-click pressure stage, so stage 2 (force click) only
    /// fires once per press.
    var prevPressureStage = 0

    // MARK: - Secure input / notifications state

    /// Whether the surface sits on a password prompt (SECURE_INPUT action).
    /// While true and focused, keyboard input is protected from event
    /// taps via the Carbon secure input API, like ghostty.
    var passwordInput: Bool = false {
        didSet {
            let input = SecureInput.shared
            let id = ObjectIdentifier(self)
            if passwordInput {
                input.setScoped(id, focused: focused)
            } else {
                input.removeScoped(id)
            }
        }
    }

    /// Delivered notification identifiers for this pane, removed when the
    /// pane gains focus (ghostty does the same).
    private var notificationIdentifiers: Set<String> = []

    /// Coalesces rapid terminal title changes to avoid flicker (ghostty
    /// uses the same 75ms window).
    private var titleChangeTimer: Timer?

    /// Local event monitor: cmd-modified keyUp events never reach the
    /// responder chain, so we forward them from here (ghostty does the
    /// same).
    private var eventMonitor: Any?

    init(
        id: UUID = UUID(),
        runtime: GhosttyRuntime,
        workingDirectory: String? = nil,
        cwdFrom: UUID? = nil,
        target: String? = nil,
        ptyCommand: [String]? = nil,
        initialFrame: CGRect = .zero,
        fontDelta: Int = 0
    ) {
        self.id = id
        self.target = target
        self.ptyCommand = ptyCommand
        self.fontDelta = fontDelta
        hostBadge = target.map { HostBadgeView(host: $0) }
        super.init(frame: initialFrame)

        wantsLayer = true

        // Local monitor, matching ghostty: cmd-modified keyUp events never
        // trigger the responder chain, and a left mouse-down that only
        // transfers pane focus must be consumed before it becomes a
        // selection in the newly focused pane.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) {
            [weak self] event in self?.localEventHandler(event)
        }

        // The UTTypes that can be dragged onto this view.
        registerForDraggedTypes(Array(Self.dropTypes))

        guard let app = runtime.app else { return }

        // M2: every pane is a daemon pty named by the pane id. Attach
        // reconnects and replays; a missing pty is created at the saved
        // cwd. Terminal content survives the app by construction. M3: a
        // pane on a host alias is the same pty one hop away (the local
        // daemon relays the attach), and an `ix:<vm>` pane is a local pty
        // whose command is `ix shell` instead of the user's shell.
        let command = defaultCommand(cwd: workingDirectory, cwdFrom: cwdFrom)

        // A remote pane's cwd names a path on the remote host: it travels
        // as --cwd and is never handed to the local surface.
        let localWorkingDirectory = target == nil ? workingDirectory : nil

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // inherit from config
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        surface = Self.withOptionalCString(localWorkingDirectory) { wdPtr in
            Self.withOptionalCString(command) { cmdPtr -> ghostty_surface_t? in
                cfg.working_directory = wdPtr
                cfg.command = cmdPtr
                return withUnsafePointer(to: cfg) { ghostty_surface_new(app, $0) }
            }
        }

        if surface == nil {
            NSLog("ghostty_surface_new failed")
        }

        // A restored pane knows its final frame before the surface spawns
        // its command: size the surface now so the attach handshake (and
        // the daemon's screen replay) happen at the real size, not a
        // default. convertToBacking is useless before the view joins a
        // window, so scale by hand with the same factor the config used.
        if let surface, initialFrame.width > 0, initialFrame.height > 0 {
            let scale = cfg.scale_factor
            ghostty_surface_set_size(
                surface,
                UInt32(max(1, initialFrame.width * scale)),
                UInt32(max(1, initialFrame.height * scale))
            )
        }

        // Replay a persisted font zoom: a fresh surface starts at the
        // config default, so the relative action lands on the exact
        // point size the pane had.
        if fontDelta != 0 {
            bindingAction(
                fontDelta > 0
                    ? "increase_font_size:\(fontDelta)"
                    : "decrease_font_size:\(-fontDelta)"
            )
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        SecureInput.shared.removeScoped(ObjectIdentifier(self))
        if !notificationIdentifiers.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: Array(notificationIdentifiers))
        }
        titleChangeTimer?.invalidate()
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            // We only care about events with "command" because all others
            // trigger the normal responder chain.
            guard event.modifierFlags.contains(.command) else { return event }
            guard focused else { return event }
            keyUp(with: event)
            return nil

        case .leftMouseDown:
            return localEventLeftMouseDown(event)

        default:
            return event
        }
    }

    /// Ported from ghostty: clicking an unfocused pane transfers focus
    /// without also starting a selection in it.
    private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        // We only want to process events that are on this window.
        guard let window,
              event.window != nil,
              window == event.window else { return event }

        // The clicked location in this window should be this view. Hit
        // test through the window so overlays on top win.
        guard let location = window.contentView?.convert(event.locationInWindow, from: nil)
        else { return event }
        guard window.contentView?.hitTest(location) == self else { return event }

        // We always assume that we're resetting our mouse suppression
        // unless we see the specific scenario below to set it.
        suppressNextLeftMouseUp = false

        // If we're already the first responder then no focus transfer is
        // happening, so the click should continue as normal.
        guard window.firstResponder !== self else { return event }

        // If our window/app is already focused, then this click is only
        // being used to transfer split focus. Consume it so it does not
        // get forwarded to the terminal as a mouse click.
        if NSApp.isActive, window.isKeyWindow {
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }

        // Make ourselves the first responder.
        window.makeFirstResponder(self)

        // We have to keep processing the event so that AppKit can properly
        // focus the window and dispatch events. If you return nil here
        // then nobody gets a windowDidBecomeKey event and so on.
        return event
    }

    /// The pty this pane attaches to: `<alias>:<id>` for a pane hosted on
    /// another machine, `local:<id>` otherwise. An `ix:<vm>` pane is local
    /// too - the pty runs `ix shell` here, and the VM is on the far end of
    /// that command, not of the attach.
    private var attachAddress: String {
        guard let target, !target.hasPrefix(IX.prefix) else {
            return "local:\(id.uuidString)"
        }
        return "\(target):\(id.uuidString)"
    }

    /// The pane's launch command. nil means "the user's shell": the dev
    /// fallback when no relay binary is bundled. `cwdFrom` names the pty
    /// (a split's source pane, same daemon) whose live working directory
    /// the new shell inherits, resolved daemon-side - no shell
    /// integration needed. An explicit `cwd` wins.
    private func defaultCommand(cwd: String?, cwdFrom: UUID? = nil) -> String? {
        // An ix pane runs `ix shell <vm>` in its pty unless the caller named
        // something else to run there (VM creation runs `ix new` instead,
        // and the shell it drops you into is the pane).
        let inPty = ptyCommand ?? IX.vm(of: target).map { [IX.binary, "shell", $0] }
        guard let attach = Muxd.attachBinary else {
            // No relay bundled: run it directly (no persistence), or fall
            // back to the user's shell for a plain local pane.
            return inPty.map(Self.quote)
        }
        var parts = ["\"\(attach)\"", "\"\(attachAddress)\""]
        if let inPty {
            // `-- cmd` makes the pty run that command instead of the shell.
            // No cwd: the pty's working directory is this machine's and
            // means nothing inside the VM.
            parts += ["--", Self.quote(inPty)]
            return parts.joined(separator: " ")
        }
        if let cwd {
            parts += ["--cwd", "\"\(cwd)\""]
        }
        if let cwdFrom {
            parts += ["--cwd-from", "\"\(cwdFrom.uuidString)\""]
        }
        return parts.joined(separator: " ")
    }

    /// argv as one command line for libghostty, which hands the string to a
    /// shell. Every word is double-quoted, so paths with spaces and flake
    /// refs with `#` survive intact.
    private static func quote(_ argv: [String]) -> String {
        argv.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// Free the surface explicitly (kills the local child - the relay).
    /// The daemon pty behind it survives; call killRemote() too when the
    /// user actually closes the pane.
    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    /// Kill the pane's pty (deliberate close, not detach). For an ix pane
    /// that ends the `ix shell` the pty is running, and with it the session
    /// on the VM.
    func killRemote() {
        guard let attach = Muxd.attachBinary else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: attach)
        process.arguments = ["--kill", attachAddress]
        try? process.run()
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: - Font zoom

    /// Adjust the font zoom by `step` points; 0 resets to the config
    /// default. Keeps `fontDelta` in lockstep with what ghostty applies.
    func adjustFontSize(_ step: Int) {
        guard surface != nil else { return }
        if step == 0 {
            fontDelta = 0
            bindingAction("reset_font_size")
        } else {
            fontDelta += step
            bindingAction(
                step > 0 ? "increase_font_size:\(step)" : "decrease_font_size:\(-step)"
            )
        }
        controller?.saveState()
    }

    /// Internal (not private): the context menu handlers in
    /// PaneView+Input.swift drive ghostty through binding actions too.
    func bindingAction(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func setTitle(_ title: String) {
        // Coalesce rapid changes: very quick title updates cause an
        // unpleasant flicker. The timer is short enough that it still
        // feels instant (ghostty uses the same interval).
        titleChangeTimer?.invalidate()
        titleChangeTimer = Timer.scheduledTimer(
            withTimeInterval: 0.075,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.title = title
            if focused {
                window?.title = title
            }
        }
    }

    /// Post a desktop notification for this pane (OSC 9 / OSC 777),
    /// ported from ghostty: delivered notifications are tracked so they
    /// clear when the pane gains focus, and notifications for a focused
    /// pane expire after a few seconds.
    func showUserNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = self?.title ?? ""
            content.body = body
            content.sound = .default

            let uuid = UUID().uuidString
            let request = UNNotificationRequest(identifier: uuid, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    NSLog("error scheduling user notification: \(error)")
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    notificationIdentifiers.insert(uuid)

                    // If we're focused then remove the notification after
                    // a few seconds; on focus gain they clear immediately.
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            self?.notificationIdentifiers.remove(uuid)
                            UNUserNotificationCenter.current()
                                .removeDeliveredNotifications(withIdentifiers: [uuid])
                        }
                    }
                }
            }
        }
    }

    private static func withOptionalCString<T>(
        _ s: String?, _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        if let s {
            return s.withCString(body)
        }
        return body(nil)
    }

    // MARK: - Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Keep the compositor from rescaling our layer contents; we manage
        // resolution ourselves via set_content_scale (ghostty does the same).
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
    }

    /// Bind the renderer's CVDisplayLink to the display the window is on,
    /// so frame pacing follows the right refresh rate.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeScreenNotification, object: nil
        )
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification, object: window
        )
        syncDisplayID()
    }

    @objc private func windowDidChangeScreen(_: Notification) {
        syncDisplayID()
        // The new screen may have a different scale factor.
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    private func syncDisplayID() {
        guard let surface,
              let screen = window?.screen,
              let id = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? UInt32
        else { return }
        ghostty_surface_set_display_id(surface, id)
    }

    /// Renderer throttle: occluded surfaces stop drawing entirely.
    private var occlusionVisible = true

    func setOcclusion(visible: Bool) {
        guard let surface, visible != occlusionVisible else { return }
        occlusionVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
    }

    private func syncSurfaceSize() {
        guard let surface else { return }
        // libghostty wants framebuffer pixels, not points.
        let backing = convertToBacking(bounds.size)
        ghostty_surface_set_size(
            surface,
            UInt32(max(1, backing.width)),
            UInt32(max(1, backing.height))
        )
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            setFocus(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            setFocus(false)
        }
        return ok
    }

    private func setFocus(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        hostBadge?.setFocused(value)

        // If we lost our focus then remove the mouse event suppression so
        // our mouse release event leaving the surface can properly be sent
        // to stop things like mouse selection.
        if !value {
            suppressNextLeftMouseUp = false
        }

        // Update our secure input state if we are a password input.
        if passwordInput {
            SecureInput.shared.setScoped(ObjectIdentifier(self), focused: value)
        }

        // Remove any delivered notifications for this pane once it has
        // the user's attention.
        if value, !notificationIdentifiers.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: Array(notificationIdentifiers))
            notificationIdentifiers = []
        }

        guard let surface else { return }
        ghostty_surface_set_focus(surface, value)
        if value {
            window?.title = title
            controller?.noteFocused(self)
        }
    }
}
