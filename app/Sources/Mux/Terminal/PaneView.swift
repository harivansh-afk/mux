import AppKit
import GhosttyKit

/// One terminal pane: an NSView whose layer libghostty renders into (Metal,
/// IOSurface-backed sublayer, renderer thread owned by libghostty).
/// Input forwarding adapted from ghostty's SurfaceView_AppKit.swift (MIT),
/// with the IME/preedit machinery deferred to a later milestone.
final class PaneView: NSView {
    let id: UUID

    /// Where this pane's terminal lives.
    ///
    /// - nil: the local daemon (`mux-attach local:<id>`).
    /// - a host alias from ~/.config/mux/hosts.json: the local daemon
    ///   relays the attach to that host (`mux-attach <alias>:<id>`).
    /// - `ix:<vm>`: no daemon and no persistence at all, the pane simply
    ///   execs `ix shell <vm>`.
    let target: String?

    /// `ix:<vm>` panes exec a plain command; there is no pty to attach to,
    /// reconnect to, or kill.
    static let ixPrefix = "ix:"

    /// The host chip shown at this pane's top-right corner; nil for local
    /// panes. A sibling view in the pane container (libghostty owns this
    /// view's layer), laid out by Session next to the pane's frame.
    let hostBadge: HostBadgeView?

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
    private var focused: Bool = false

    /// The bundled stdio relay. nil (dev builds without the bundle step)
    /// falls back to a plain local shell - panes then don't survive the
    /// app, but everything else works.
    static let attachBinary: String? = {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("mux-attach").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    init(
        id: UUID = UUID(),
        runtime: GhosttyRuntime,
        workingDirectory: String? = nil,
        target: String? = nil,
        command: String? = nil,
        initialFrame: CGRect = .zero,
        fontDelta: Int = 0
    ) {
        self.id = id
        self.target = target
        self.fontDelta = fontDelta
        hostBadge = target.map { HostBadgeView(host: $0) }
        super.init(frame: initialFrame)

        wantsLayer = true

        guard let app = runtime.app else { return }

        // M2: every pane is a daemon pty named by the pane id. Attach
        // reconnects and replays; a missing pty is created at the saved
        // cwd. Terminal content survives the app by construction. M3: a
        // pane on a host alias is the same pty one hop away (the local
        // daemon relays the attach), while `ix:<vm>` is a plain exec.
        let command = command ?? defaultCommand(cwd: workingDirectory)

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
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    /// The pty this pane attaches to: `local:<id>`, or `<alias>:<id>` for
    /// a pane hosted on another machine. nil for `ix:<vm>` panes, which
    /// have no pty on either side of the wire.
    private var attachAddress: String? {
        guard let target else { return "local:\(id.uuidString)" }
        guard !target.hasPrefix(Self.ixPrefix) else { return nil }
        return "\(target):\(id.uuidString)"
    }

    /// The pane's launch command. nil means "the user's shell": the dev
    /// fallback when no relay binary is bundled.
    private func defaultCommand(cwd: String?) -> String? {
        if let target, target.hasPrefix(Self.ixPrefix) {
            return "ix shell \"\(target.dropFirst(Self.ixPrefix.count))\""
        }
        guard let attach = Self.attachBinary, let attachAddress else { return nil }
        var parts = ["\"\(attach)\"", "\"\(attachAddress)\""]
        if let cwd {
            parts += ["--cwd", "\"\(cwd)\""]
        }
        return parts.joined(separator: " ")
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

    /// Kill the pane's pty (deliberate close, not detach). A no-op for
    /// `ix:<vm>` panes: closing the surface already ends the process.
    func killRemote() {
        guard let attach = Self.attachBinary, let attachAddress else { return }
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

    private func bindingAction(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func setTitle(_ title: String) {
        self.title = title
        if focused {
            window?.title = title
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
        guard let surface else { return }
        ghostty_surface_set_focus(surface, value)
        if value {
            window?.title = title
            controller?.noteFocused(self)
        }
    }
}
