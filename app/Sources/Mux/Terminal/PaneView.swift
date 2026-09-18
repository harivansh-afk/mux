import AppKit
import GhosttyKit
import UserNotifications

/// One terminal pane: an NSView whose layer libghostty renders into (Metal,
/// IOSurface-backed sublayer, renderer thread owned by libghostty).
/// Input forwarding ported from ghostty's SurfaceView_AppKit.swift (MIT),
/// including the NSTextInputClient/IME machinery.
final class PaneView: NSView {
    /// The window is borderless with isMovableByWindowBackground on; the
    /// default (non-opaque view = draggable background) would make AppKit
    /// steal left-click drags for window moves instead of text selection.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    let id: UUID

    /// Which pty this pane is, and how the relay reaches it. Everything
    /// the command line is built from lives in Muxd.Attach.
    let attach: Muxd.Attach

    /// Where this pane's terminal lives: nil local, a host alias, or
    /// `ix:<vm>`. Chrome, snapshots and split inheritance read it.
    var target: String? {
        attach.target
    }

    /// The daemon the pane's pty is on, as the watch and the listings key
    /// it: a host alias, or nil for local - which an ix pane is too, its
    /// pty runs `ix shell` here.
    var daemon: String? {
        IX.vm(of: target) == nil ? target : nil
    }

    /// The scroll view wrapping this pane (owned by the window's pane
    /// container; created in attach). Session lays out the host, and the
    /// host keeps the pane filling its visible rect.
    weak var scrollHost: PaneScrollView?

    /// Scrollback dimensions reported by the core via the SCROLLBAR
    /// action: total rows, first visible row, viewport rows.
    var scrollbar: ghostty_action_scrollbar_s?

    private(set) var surface: ghostty_surface_t?
    weak var controller: MuxWindowController?

    /// Only ever what the program in the pane set (OSC 0/2). Reattach
    /// replays screen contents, not title escapes, so a restored pane
    /// starts empty and chrome falls back to host/directory - never a
    /// default word that reads like data.
    var title: String = ""
    var pwd: String?

    /// The coding agent the daemon sees in this pty, or nil. Seeded from
    /// `muxd ls` and kept live by the daemon watch; the app never reads
    /// it out of the title itself.
    var agent: Muxd.AgentInfo?

    /// What the daemon says about this pty, from a listing or the watch.
    /// The cwd is the live process's, the truth here (OSC 7 overrides it
    /// when a shell does report) - except for an ix pane, whose local
    /// pty sits where `ix shell` started, not where the VM's shell is.
    func apply(agent: Muxd.AgentInfo?, cwd: String?) {
        self.agent = agent
        if let cwd, IX.vm(of: target) == nil {
            pwd = cwd
        }
    }

    /// The pane's directory the way its prompt would print it: the full
    /// path with the home prefix folded to `~`. Remote paths fold their
    /// own home (/home/x or /Users/x) - the pane's pwd names the pane's
    /// host, so the abbreviation reads exactly like a prompt there.
    var promptDir: String? {
        guard var dir = pwd, !dir.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if dir == home || dir.hasPrefix(home + "/") {
            dir = "~" + dir.dropFirst(home.count)
        } else if let match = dir.range(
            of: "^/(home|Users)/[^/]+", options: .regularExpression
        ) {
            dir = "~" + dir[match.upperBound...]
        }
        return dir
    }

    /// Points added to the config font size via cmd+= / cmd+- (font
    /// zoom). libghostty owns the actual value and exposes no getter,
    /// so the pane intercepts the keys, drives ghostty through binding
    /// actions, and tracks the delta itself - that is what the snapshot
    /// persists and restore replays.
    private(set) var fontDelta: Int = 0

    /// Internal (not private): managed by updateTrackingAreas in
    /// PaneView+Mouse.swift.
    var trackingArea: NSTrackingArea?
    private(set) var focused: Bool = false

    // MARK: - Keyboard / IME state (used by PaneView+Key.swift and

    // PaneView+TextInput.swift)

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

    // MARK: - Mouse state (used by PaneView+Mouse.swift)

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
        attach: Muxd.Attach,
        workingDirectory: String? = nil,
        cwdFrom: UUID? = nil,
        initialFrame: CGRect = .zero,
        fontDelta: Int = 0
    ) {
        id = attach.paneID
        self.attach = attach
        self.fontDelta = fontDelta
        super.init(frame: initialFrame)

        // Seed the directory from the snapshot/daemon cwd (remote panes
        // included: the path names their host's filesystem, same as
        // pwd). OSC 7 takes over the moment the shell reports.
        pwd = workingDirectory

        wantsLayer = true

        // Local monitor, matching ghostty: cmd-modified keyUp events never
        // trigger the responder chain, and a left mouse-down that only
        // transfers pane focus must be consumed before it becomes a
        // selection in the newly focused pane.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            self?.localEventHandler(event)
        }

        // The UTTypes that can be dragged onto this view.
        registerForDraggedTypes(Array(Self.dropTypes))

        guard let app = GhosttyRuntime.shared?.app else { return }

        let command = attach.commandLine(cwd: workingDirectory, cwdFrom: cwdFrom)
        AppLog.log("spawn pane=\(id.uuidString) cmd=\(command)")

        // A remote pane's cwd names a path on the remote host: it travels
        // as --cwd and is never handed to the local surface.
        let localWorkingDirectory = attach.target == nil ? workingDirectory : nil

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
            command.withCString { cmdPtr -> ghostty_surface_t? in
                cfg.working_directory = wdPtr
                cfg.command = cmdPtr
                return withUnsafePointer(to: cfg) { ghostty_surface_new(app, $0) }
            }
        }

        if surface == nil {
            AppLog.log("ghostty_surface_new FAILED pane=\(id.uuidString)")
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

        // Each surface carries its own light/dark conditional state
        // (`theme = light:...,dark:...`): push the current scheme now and
        // on every system appearance flip, like ghostty's own app does.
        // The core re-derives the surface colors and reports the change
        // to running programs (mode 2031), so TUIs repaint too.
        applyColorScheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyColorScheme),
            name: .muxThemeDidChange,
            object: nil
        )
    }

    @objc private func applyColorScheme() {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, ThemeManager.shared.colorScheme)
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
        guard let window,
              event.window != nil,
              window == event.window else { return event }

        // The clicked location in this window should be this view. Hit
        // test through the window so overlays on top win. hitTest takes a
        // point in the receiver's superview coordinates, which for the
        // contentView is window base coordinates - do not convert into the
        // (flipped) contentView's own space or the probe point mirrors
        // vertically and the wrong pane eats the click.
        guard window.contentView?.hitTest(event.locationInWindow) == self else { return event }

        suppressNextLeftMouseUp = false

        guard window.firstResponder !== self else { return event }

        // If our window/app is already focused, then this click is only
        // being used to transfer split focus. Consume it so it does not
        // get forwarded to the terminal as a mouse click.
        if NSApp.isActive, window.isKeyWindow {
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }

        window.makeFirstResponder(self)

        // We have to keep processing the event so that AppKit can properly
        // focus the window and dispatch events. If you return nil here
        // then nobody gets a windowDidBecomeKey event and so on.
        return event
    }

    /// Free the surface explicitly (kills the local child - the relay).
    /// The daemon pty behind it survives; call killRemote() too when the
    /// user explicitly kills the terminal.
    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    /// Kill the terminal immediately.
    func killRemote() {
        Muxd.kill(attach.address)
    }

    // MARK: - Font zoom

    /// Adjust the font zoom by `step` points; 0 resets to the config
    /// default. Keeps `fontDelta` in lockstep with what ghostty applies.
    func adjustFontSize(_ step: Int, save: Bool = true) {
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
        if save {
            controller?.saveState()
        }
    }

    /// Apply the same zoom step to every pane in every session (the
    /// shift variants of the zoom keys): all terminals move by the same
    /// exact increment, so per-pane zoom differences are preserved. 0
    /// resets every pane to the config default.
    static func adjustAllFontSizes(_ step: Int) {
        guard let controller = App.delegate.controller else { return }
        for session in controller.sessions {
            for (_, pane) in session.panes {
                pane.adjustFontSize(step, save: false)
            }
        }
        App.delegate.saveSnapshot()
    }

    /// The one call into ghostty's binding actions: font zoom, the
    /// context menu, and the app menu's Copy/Paste all go through here.
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
                window?.title = title.isEmpty ? "mux" : title
            }
        }
    }

    /// Post a desktop notification for this pane (OSC 9 / OSC 777),
    /// ported from ghostty: delivered notifications are tracked so they
    /// clear when the pane gains focus, and notifications for a focused
    /// pane expire after a few seconds. Authorization was asked for once,
    /// at launch; an unauthorized app gets the refusal back as an error.
    func showUserNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = self.title
        content.body = body
        content.sound = .default

        let uuid = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuid, content: content, trigger: nil)
        let paneID = id
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                AppLog.log("notification pane=\(paneID.uuidString) failed: \(error)")
                return
            }
            DispatchQueue.main.async { self?.noteDelivered(uuid) }
        }
    }

    /// Remember a delivered notification so focus can clear it. One for a
    /// pane that already has focus expires by itself after a few seconds.
    private func noteDelivered(_ uuid: String) {
        notificationIdentifiers.insert(uuid)
        guard focused else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.notificationIdentifiers.remove(uuid)
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [uuid])
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

    /// The pane's true frame ratio, for chrome that previews it at its
    /// real shape (the canvas stage and cards). 16:9 while the view is
    /// too small to say - never a stretched preview.
    var aspect: CGFloat {
        guard bounds.width > 1, bounds.height > 1 else { return 16.0 / 9.0 }
        return bounds.width / bounds.height
    }

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
            window?.title = title.isEmpty ? "mux" : title
            controller?.noteFocused(self)
        }
    }
}
