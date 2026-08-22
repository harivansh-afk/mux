import AppKit
import GhosttyKit

/// What mux adds to the ported input handling: font zoom, which
/// libghostty cannot report back and so the pane has to own; the canvas
/// stage's synthetic hover, which is how a wheel event over a thumbnail
/// reaches the pane it mirrors; the context menu; and the cursor, which
/// has to be set on the enclosing scroll view rather than the pane. None
/// of it is in the port, and keeping it out of PaneView+Key.swift and
/// PaneView+Mouse.swift is what makes those two diffable against ghostty.
extension PaneView {
    // MARK: - Font zoom

    /// cmd+= / cmd+- / cmd+0 as +1 / -1 / 0 (reset) for the focused
    /// pane; the same keys with shift held step every pane in the app.
    /// nil for everything else. Internal (not private): PrefixEngine
    /// parses the same keys in canvas mode, where they act on the
    /// previewed pane instead of the focused one.
    static func fontZoomStep(_ event: NSEvent) -> (step: Int, allPanes: Bool)? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods == .command || mods == [.command, .shift] else { return nil }
        // Shift changes the character (= becomes +, - becomes _), so
        // match on the key's unmodified character.
        let step: Int
        switch event.characters(byApplyingModifiers: []) {
        case "=", "+": step = 1
        case "-": step = -1
        case "0": step = 0
        default: return nil
        }
        return (step, mods.contains(.shift))
    }

    /// The zoom branch of performKeyEquivalent. Intercepted there (not
    /// keyDown) because the shifted all-pane variants are not ghostty
    /// bindings and would otherwise take the doCommand detour; ghostty
    /// never sees these keys at all, because it has no way to report the
    /// font size back and the pane tracks the delta itself for the
    /// snapshot.
    func muxFontZoom(_ event: NSEvent) -> Bool {
        guard let zoom = Self.fontZoomStep(event) else { return false }
        if zoom.allPanes {
            Self.adjustAllFontSizes(zoom.step)
        } else {
            adjustFontSize(zoom.step)
        }
        return true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        // We only support right-click menus.
        switch event.type {
        case .rightMouseDown:
            break

        case .leftMouseDown:
            if !event.modifierFlags.contains(.control) {
                return nil
            }

            // AppKit calls menu BEFORE calling any mouse events. If mouse
            // capturing is enabled then we never show the context menu so
            // that we can handle ctrl+left-click in the terminal app.
            guard let surface else { return nil }
            if ghostty_surface_mouse_captured(surface) {
                return nil
            }

            // If we return a non-nil menu then mouse events will never be
            // processed by the core, so we need to manually send a right
            // mouse down event.
            _ = ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                GHOSTTY_MOUSE_RIGHT,
                Self.ghosttyMods(event.modifierFlags)
            )

        default:
            return nil
        }

        let menu = NSMenu()

        // Only offer copy when there is a selection.
        if hasSelection {
            menu.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Paste", action: #selector(pasteFromClipboard(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(contextSplitRight(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Split Down", action: #selector(contextSplitDown(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset Terminal", action: #selector(resetTerminal(_:)), keyEquivalent: "")

        return menu
    }

    private var hasSelection: Bool {
        guard let surface else { return false }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        return text.text_len > 0
    }

    // MARK: - Menu handlers

    @objc func copySelection(_: Any?) {
        bindingAction("copy_to_clipboard")
    }

    @objc func pasteFromClipboard(_: Any?) {
        bindingAction("paste_from_clipboard")
    }

    @objc private func contextSplitRight(_: Any?) {
        controller?.split(from: self, ghosttyDirection: GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @objc private func contextSplitDown(_: Any?) {
        controller?.split(from: self, ghosttyDirection: GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @objc private func resetTerminal(_: Any?) {
        bindingAction("reset")
    }

    // MARK: - Canvas stage hover

    /// Report a hover position that did not come from AppKit hit-testing:
    /// the canvas stage maps points on the preview onto the pane it
    /// mirrors. libghostty's scroll handling is only meaningful at a
    /// mouse position - a mouse-reporting program receives the wheel AT
    /// the surface's stored position, which starts (and parks, on
    /// mouseExited) at -1/-1 = outside the viewport - so the stage must
    /// place the mouse before it scrolls. Top-left origin, pane points.
    func reportMousePos(topLeft point: NSPoint, flags: NSEvent.ModifierFlags) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, point.x, point.y, Self.ghosttyMods(flags))
    }

    /// The synthetic counterpart of mouseExited: the stage preview moved
    /// off this pane, so its phantom hover leaves the viewport.
    func clearMousePos() {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods([]))
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        default: .arrow
        }
        // The scroll view re-applies its documentCursor whenever AppKit
        // resets the cursor; a bare set() does not survive mouse moves.
        if let scrollHost {
            scrollHost.documentCursor = cursor
        } else {
            cursor.set()
        }
    }
}
