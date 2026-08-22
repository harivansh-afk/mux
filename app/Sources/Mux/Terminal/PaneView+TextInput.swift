import AppKit
import GhosttyKit

// IME and drag-and-drop. A near verbatim port of ghostty's
// SurfaceView_AppKit.swift (MIT), kept whole so it can be re-synced
// against upstream by diff. syncPreedit is internal rather than private
// because PaneView+Key.swift's keyDown calls it.
//
// Upstream: macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
// at ghostty fea378e565c8ddb7f49808c4f2e36a4a932e35ff (GHOSTTY_COMMIT in
// .forgejo/workflows/ci.yml).

// MARK: - NSTextInputClient

/// IME support ported from ghostty's SurfaceView_AppKit.swift (MIT).
/// Conforming makes interpretKeyEvents route composition through
/// setMarkedText/insertText, which is what makes dead keys and CJK input
/// methods work.
extension PaneView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0 ... (markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }

        // Get our range from the Ghostty API. There is a race condition
        // between getting the range and actually using it since our
        // selection may change but there isn't a good way to solve this
        // for AppKit.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)

        case let v as String:
            markedText = NSMutableAttributedString(string: v)

        default:
            NSLog("unknown marked text: \(string)")
        }

        // If we're not in a keyDown event, then we want to update our
        // preedit text immediately. This can happen due to external
        // events, for example changing keyboard layouts while composing.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange _: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surface else { return nil }

        // If the range is empty then we don't need to return anything.
        guard range.length > 0 else { return nil }

        // A lot of macOS system behaviors request bogus ranges, so we just
        // always return the attributed string containing our selection.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        return .init(string: String(cString: text.text))
    }

    func characterIndex(for _: NSPoint) -> Int {
        0
    }

    func firstRect(
        forCharacterRange range: NSRange, actualRange _: NSRangePointer?
    ) -> NSRect {
        guard let surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Ghostty will tell us where it thinks an IME keyboard should
        // render.
        var x: Double = 0
        var y: Double = 0
        var width = Double(cellSize.width)
        var height = Double(cellSize.height)

        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        if range.length == 0, width > 0 {
            // Positive width doesn't make sense for the dictation
            // microphone indicator.
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }

        // Ghostty coordinates are in top-left (0, 0) so we have to convert
        // to bottom-left since that is what AppKit expects.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height)
        )

        // Convert the point to the window coordinates.
        let winRect = convert(viewRect, to: nil)

        // Convert from view to screen coordinates.
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange _: NSRange) {
        // We must have an associated event.
        guard NSApp.currentEvent != nil else { return }
        guard let surface else { return }

        // We want the string view of the any value.
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        let hadMarkedText = hasMarkedText()

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in another key event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        if hadMarkedText, !chars.isEmpty {
            // Send preedit commits as key events instead of raw text for
            // keybind interpretation by programs.
            _ = committedPreeditTextAction(GHOSTTY_ACTION_PRESS, text: chars)
            return
        }

        let len = chars.utf8CString.count
        guard len > 1 else { return }
        chars.withCString { ptr in
            // len includes the null terminator so we subtract 1.
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    /// This function needs to exist for two reasons:
    /// 1. Prevents an audible NSBeep for unimplemented actions.
    /// 2. Allows us to properly encode super+key input events that we
    ///    don't handle (see performKeyEquivalent).
    override func doCommand(by _: Selector) {
        // If we are being processed by performKeyEquivalent with a command
        // binding, we send it back through the event system so it can be
        // encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp
        {
            NSApp.sendEvent(current)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty.
    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator.
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: - NSDraggingDestination

/// Dropping files or text onto a pane inserts it at the cursor, with file
/// paths shell-escaped. Ported from ghostty.
extension PaneView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return
        // none. This shouldn't happen because AppKit should guarantee that
        // we only receive types we registered for, but it's good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon.
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        guard let content = pb.getOpinionatedStringContents() else { return false }

        DispatchQueue.main.async { [weak self] in
            guard let self, let surface else { return }
            let len = content.utf8CString.count
            guard len > 1 else { return }
            content.withCString { ptr in
                // len includes the null terminator so we subtract 1.
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }
        return true
    }
}
