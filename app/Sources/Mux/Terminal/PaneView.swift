import AppKit
import GhosttyKit

/// One terminal pane: an NSView whose layer libghostty renders into (Metal,
/// IOSurface-backed sublayer, renderer thread owned by libghostty).
/// Input forwarding adapted from ghostty's SurfaceView_AppKit.swift (MIT),
/// with the IME/preedit machinery deferred to a later milestone.
final class PaneView: NSView {
    let id: UUID
    private(set) var surface: ghostty_surface_t?
    weak var controller: MuxWindowController?

    var title: String = "mux"
    var pwd: String?

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
        command: String? = nil
    ) {
        self.id = id
        super.init(frame: .zero)

        wantsLayer = true

        guard let app = runtime.app else { return }

        // M2: every pane is a daemon pty named by the pane id. Attach
        // reconnects and replays; a missing pty is created at the saved
        // cwd. Terminal content survives the app by construction.
        var command = command
        if command == nil, let attach = Self.attachBinary {
            var parts = ["\"\(attach)\"", "local:\(id.uuidString)"]
            if let workingDirectory {
                parts += ["--cwd", "\"\(workingDirectory)\""]
            }
            command = parts.joined(separator: " ")
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // inherit from config
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        surface = Self.withOptionalCString(workingDirectory) { wdPtr in
            Self.withOptionalCString(command) { cmdPtr -> ghostty_surface_t? in
                cfg.working_directory = wdPtr
                cfg.command = cmdPtr
                return withUnsafePointer(to: cfg) { ghostty_surface_new(app, $0) }
            }
        }

        if surface == nil {
            NSLog("ghostty_surface_new failed")
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

    /// Free the surface explicitly (kills the local child - the relay).
    /// The daemon pty behind it survives; call killRemote() too when the
    /// user actually closes the pane.
    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    /// Kill the pane's daemon pty (deliberate close, not detach).
    func killRemote() {
        guard let attach = Self.attachBinary else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: attach)
        process.arguments = ["--kill", "local:\(id.uuidString)"]
        try? process.run()
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
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
        guard let surface else { return }
        ghostty_surface_set_focus(surface, value)
        if value {
            window?.title = title
            controller?.noteFocused(self)
        }
    }
}
