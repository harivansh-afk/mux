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

    private var trackingArea: NSTrackingArea?
    private var focused: Bool = false

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

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // inherit from config
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        self.surface = Self.withOptionalCString(workingDirectory) { wdPtr in
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

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    /// Free the surface explicitly (kills the child process).
    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    func setTitle(_ title: String) {
        self.title = title
        if focused { window?.title = title }
    }

    private static func withOptionalCString<T>(
        _ s: String?, _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        if let s { return s.withCString(body) }
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
            self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification, object: window)
        syncDisplayID()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
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
                NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
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
            UInt32(max(1, backing.height)))
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocus(false) }
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

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        _ = keyAction(action, event: event, text: Self.ghosttyCharacters(event))
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let action: ghostty_input_action_e =
            (mods.rawValue & mod != 0) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = keyAction(action, event: event)
    }

    /// Forward ctrl-modified keys that AppKit routes through the key
    /// equivalent path (cmd-modified keys belong to the menu bar).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder == self,
              event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.command)
        else { return false }
        keyDown(with: event)
        return true
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String? = nil
    ) -> Bool {
        guard let surface else { return false }

        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = Self.ghosttyMods(event.modifierFlags)
        // Heuristic from ghostty: control and command never contribute to
        // text translation; assume everything else did.
        key.consumed_mods = Self.ghosttyMods(
            event.modifierFlags.subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let cp = chars.unicodeScalars.first {
                key.unshifted_codepoint = cp.value
            }
        }

        // Only pass text if it isn't a control character: ghostty encodes
        // control characters itself (ctrl+enter breaks otherwise).
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    /// Text for a key event, dropping control characters (ghostty encodes
    /// those) and PUA function-key codepoints. From NSEvent+Extension.swift.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    private func mouseButton(
        _ state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        event: NSEvent
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, state, button, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        mouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        mouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE, event: event)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // libghostty expects top-left origin.
        ghostty_surface_mouse_pos(
            surface, pos.x, frame.height - pos.y,
            Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { reportMousePos(event) }
    override func mouseDragged(with event: NSEvent) { reportMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { reportMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { reportMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // ghostty amplifies precise (trackpad) deltas 2x; discrete
            // wheel ticks are scaled core-side by cell size.
            x *= 2
            y *= 2
        }
        // Packed struct (src/input/mouse.zig ScrollMods): bit 0 precision,
        // bits 1-3 momentum phase (inertial scrolling).
        var scrollMods: Int32 = 0
        if precision { scrollMods |= 1 }
        scrollMods |= Int32(Self.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    /// NSEvent.Phase -> ghostty Momentum (src/input/mouse.zig enum(u3)).
    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        default: cursor = .arrow
        }
        cursor.set()
    }
}
