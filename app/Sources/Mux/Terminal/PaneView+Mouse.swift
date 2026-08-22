import AppKit
import CoreText
import GhosttyKit

/// Mouse, scroll and tracking areas. A near verbatim port of ghostty's
/// SurfaceView_AppKit.swift (MIT), kept whole so it can be re-synced
/// against upstream by diff; mux's own additions to the port (the canvas
/// stage's synthetic hover, the context menu, the scroll host's cursor)
/// live in PaneView+Mux.swift.
///
/// Upstream: macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
/// at ghostty fea378e565c8ddb7f49808c4f2e36a4a932e35ff (GHOSTTY_COMMIT in
/// .forgejo/workflows/ci.yml).
extension PaneView {
    // MARK: - Mouse

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    /// NSEvent.buttonNumber -> ghostty mouse button. From ghostty's
    /// Ghostty.Input.MouseButton mapping.
    private static func mouseButton(fromButtonNumber n: Int) -> ghostty_input_mouse_button_e {
        switch n {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_EIGHT // back button
        case 4: GHOSTTY_MOUSE_NINE // forward button
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_FOUR
        case 8: GHOSTTY_MOUSE_FIVE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    @discardableResult
    private func mouseButton(
        _ state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        event: NSEvent
    ) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(
            surface, state, button, Self.ghosttyMods(event.modifierFlags)
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Focus transfer happens in the local event monitor (see
        // PaneView.localEventLeftMouseDown), so this press is a real
        // terminal click.
        mouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        // If this mouse-up corresponds to a focus-only click transfer,
        // suppress it so we don't emit a release without a press.
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }

        // Always reset our pressure when the mouse goes up.
        prevPressureStage = 0

        mouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, event: event)

        // Release pressure.
        if let surface {
            ghostty_surface_mouse_pressure(surface, 0, 0)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Forward to the core; if it doesn't consume the press (mouse
        // reporting off), fall through to super so menu(for:) shows the
        // context menu.
        if mouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, event: event) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, event: event) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        mouseButton(
            GHOSTTY_MOUSE_PRESS,
            button: Self.mouseButton(fromButtonNumber: event.buttonNumber),
            event: event
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        mouseButton(
            GHOSTTY_MOUSE_RELEASE,
            button: Self.mouseButton(fromButtonNumber: event.buttonNumber),
            event: event
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)

        // On mouse enter we need to reset our cursor position. This is
        // super important because we set it to -1/-1 on mouseExit and lots
        // of mouse logic (i.e. whether to send mouse reports) depends on
        // the position being in the viewport if it is.
        reportMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }

        // If the mouse is being dragged then we don't have to emit this
        // because we get mouse drag events even if we've already exited
        // the viewport (i.e. mouseDragged).
        if NSEvent.pressedMouseButtons != 0 {
            return
        }

        // Negative values indicate the cursor has left the viewport.
        ghostty_surface_mouse_pos(
            surface, -1, -1, Self.ghosttyMods(event.modifierFlags)
        )
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }

        // Notify Ghostty first: this sets up state we need for later
        // pressure handling (such as QuickLook).
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))

        // Pressure stage 2 is force click. We only want to execute this on
        // the initial transition to stage 2, and not for any repeated
        // events.
        guard prevPressureStage < 2 else { return }
        prevPressureStage = event.stage
        guard event.stage == 2 else { return }

        // If the user has force click enabled then we do a quick look.
        // There is no public API for this as far as I can tell.
        guard UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
        quickLook(with: event)
    }

    override func quickLook(with event: NSEvent) {
        guard let surface else { return super.quickLook(with: event) }

        // Grab the text under the cursor.
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else {
            return super.quickLook(with: event)
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0 else { return super.quickLook(with: event) }

        // If we can get a font then we use the font. This should always
        // work since we always have a primary font.
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // ghostty_surface_quicklook_font creates a copy of a CTFont;
            // Swift auto-retains the value put in the dict, so release the
            // original.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        // Ghostty coordinate system is top-left, convert to bottom-left
        // for AppKit.
        let pt = NSPoint(x: text.tl_px_x, y: frame.size.height - text.tl_px_y)
        let str = NSAttributedString(string: String(cString: text.text), attributes: attributes)
        showDefinition(for: str, at: pt)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // libghostty expects top-left origin.
        ghostty_surface_mouse_pos(
            surface, pos.x, frame.height - pos.y,
            Self.ghosttyMods(event.modifierFlags)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        reportMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

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
        if precision {
            scrollMods |= 1
        }
        scrollMods |= Int32(Self.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    /// NSEvent.Phase -> ghostty Momentum (src/input/mouse.zig enum(u3)).
    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }
}
