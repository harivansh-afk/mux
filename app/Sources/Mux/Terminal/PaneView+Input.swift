import AppKit
import GhosttyKit

/// Input forwarding: keyboard, mouse, scroll, cursor. Ported from
/// ghostty's SurfaceView_AppKit.swift (MIT), including the
/// NSTextInputClient/IME machinery so dead keys, CJK input methods and
/// macos-option-as-alt behave exactly like ghostty.
extension PaneView {
    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Font zoom stays pane-owned: libghostty has no way to read the
        // font size back, so ghostty never sees these keys - the pane
        // drives the change itself and tracks the delta for the snapshot.
        if let step = Self.fontZoomStep(event) {
            adjustFontSize(step)
            return
        }

        // We need to translate the mods (maybe) to handle configs such as
        // macos-option-as-alt.
        let translationModsGhostty = Self.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                Self.ghosttyMods(event.modifierFlags)
            )
        )

        // There are hidden bits set in our event that matter for certain
        // dead keys so we can't use translationModsGhostty directly.
        // Instead, we just check for exact states and set them.
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // If the translation modifiers are not equal to our original
        // modifiers then we need to construct a new NSEvent. If they are
        // equal we reuse the old one. IMPORTANT: we MUST reuse the old
        // event if they're equal because this keeps things like Korean
        // input working. There must be some object equality happening in
        // AppKit somewhere because this is required.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // By setting this to non-nil, we note that we're in a keyDown
        // event. From here, we call interpretKeyEvents so that we can
        // handle complex input such as Korean language.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // We need to know what the length of marked text was before this
        // event to know if these events cleared it.
        let markedTextBefore = markedText.length > 0

        // We need to know the keyboard layout before below because some
        // keyboard input events will change our keyboard layout and we
        // don't want those going to the terminal.
        let keyboardIdBefore: String? = if !markedTextBefore {
            KeyboardLayout.id
        } else {
            nil
        }

        // If we are in a keyDown then we don't need to redispatch a
        // command-modded key event (see docs for lastPerformKeyEvent) so
        // reset this to nil because interpretKeyEvents may dispatch it.
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // If our keyboard changed from this we just assume an input method
        // grabbed it and do nothing.
        if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id {
            return
        }

        // If we have marked text, we're in a preedit state. The order we
        // do this and the key event callbacks below doesn't matter since
        // we control the preedit state only through the preedit API.
        syncPreedit(clearIfNeeded: markedTextBefore)

        // We're composing if we have preedit (the obvious case). But we're
        // also composing if we don't have preedit and we had marked text
        // before, because this input probably just reset the preedit
        // state. It shouldn't be encoded. Example: Japanese begin
        // composing, then press backspace or ctrl+h. This should only
        // cancel the composing state but not actually delete the prior
        // input characters (prior to the composing).
        let composing = markedText.length > 0 || markedTextBefore

        // The input method may commit all or part of the preedit text via
        // insertText while handling a key that should not itself be
        // encoded. Send that committed text separately, then only replay
        // keys that should still affect the terminal after committing.
        if markedTextBefore,
           let list = keyTextAccumulator,
           list.count > 0
        {
            for text in list {
                if Self.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }

                _ = committedPreeditTextAction(action, text: text)
            }

            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    composing: false
                )
            }
            return
        }

        if let list = keyTextAccumulator, list.count > 0 {
            // Accumulated text from interpretKeyEvents (committed by the
            // IME).
            for text in list {
                // Drop bare control characters the IME accumulated while
                // composing so they don't leak through to the terminal.
                if Self.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }

                // We've composed a character; send it down. keyAction's
                // default composing=false applies because this is the
                // committed result of a composition, not in-progress
                // preedit.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                )
            }
        } else {
            // Raw control characters (e.g. ctrl+h) arriving during
            // composition belong to the IME, not the terminal.
            if Self.shouldSuppressComposingControlInput(
                event.characters,
                composing: composing
            ) {
                return
            }

            // We have no accumulated text so this is a normal key event.
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    /// cmd+= / cmd+- / cmd+0 as +1 / -1 / 0 (reset); nil for everything
    /// else.
    private static func fontZoomStep(_ event: NSEvent) -> Int? {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods == .command else { return nil }
        return switch event.charactersIgnoringModifiers {
        case "=", "+": 1
        case "-": -1
        case "0": 0
        default: nil
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Special case handling for some control keys. Ported from ghostty.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // We only care about key down events. It might not even be
        // possible to receive any other event type here.
        guard event.type == .keyDown else { return false }

        // Only process events if we're focused. Some key events like C-/
        // macOS appears to send to the first view in the hierarchy rather
        // than the first responder, and we don't want to handle those.
        if !focused {
            return false
        }

        // Get information about if this is a binding. If a binding matches
        // we perform it via keyDown so the core handles it (this is how
        // cmd-modified ghostty keybinds work without menu items).
        if let surface {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
                ghosttyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
            }
            if isBinding {
                keyDown(with: event)
                return true
            }
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim (prevent the default
            // context menu equivalent).
            if !event.modifierFlags.contains(.control) {
                return false
            }

            equivalent = "\r"

        case "/":
            // Treat C-/ as C-_. We do this because C-/ makes macOS make a
            // beep sound and we don't like the beep sound.
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            {
                return false
            }

            equivalent = "_"

        default:
            // AppKit sometimes generates synthetic NSEvents with a zero
            // timestamp (e.g. cmd+period producing a synthetic escape);
            // never process those here.
            if event.timestamp == 0 {
                return false
            }

            // All of this logic here re: lastPerformKeyEvent works around
            // AppKit redirecting some command keys through doCommand
            // before keyDown is called. See doCommand(by:).

            // Ignore all other non-command events. This lets the event
            // continue through the AppKit event systems.
            if !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control)
            {
                // Reset since we got a non-command event.
                lastPerformKeyEvent = nil
                return false
            }

            // If we have a prior command binding and the timestamp matches
            // exactly then we pass it through to keyDown for encoding.
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        keyDown(with: finalEvent!)
        return true
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

        // If we're in the middle of a preedit, don't do anything with mods.
        if hasMarkedText() { return }

        // The keyAction function will do this AGAIN below which sucks to
        // repeat but this is super cheap and flagsChanged isn't that
        // common.
        let mods = Self.ghosttyMods(event.modifierFlags)

        // If the key that pressed this is active, its a press, else
        // release.
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // If the key is pressed, its slightly more complicated,
            // because we want to check if the pressed modifier is the
            // correct side. If the correct side is pressed then its a
            // press event otherwise its a release event with the opposite
            // modifier still held.
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var key = event.ghosttyKeyEvent(
            action, translationMods: translationEvent?.modifierFlags
        )
        key.composing = composing

        // For text, we only encode UTF8 if we don't have a single control
        // character. Control characters are encoded by Ghostty itself.
        // Without this, `ctrl+enter` does the wrong thing.
        if let text, !text.isEmpty, let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    /// Send committed preedit text as a key event carrying only text, so
    /// programs waiting on keybinds still see a keypress.
    private func committedPreeditTextAction(
        _ action: ghostty_input_action_e,
        text: String
    ) -> Bool {
        guard let surface else { return false }

        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = 0
        key.text = nil
        key.composing = false
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0

        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    /// After the IME commits preedit text mid-key, only some keys should
    /// still be replayed to the terminal (arrows move the cursor after
    /// committing; plain left-arrow is already handled by AppKit).
    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7C, 0x7D, 0x7E: // right, down, up
            return true
        case 0x7B: // left
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) {
            mods |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if flags.contains(.control) {
            mods |= GHOSTTY_MODS_CTRL.rawValue
        }
        if flags.contains(.option) {
            mods |= GHOSTTY_MODS_ALT.rawValue
        }
        if flags.contains(.command) {
            mods |= GHOSTTY_MODS_SUPER.rawValue
        }
        if flags.contains(.capsLock) {
            mods |= GHOSTTY_MODS_CAPS.rawValue
        }
        return ghostty_input_mods_e(mods)
    }

    /// The inverse of ghosttyMods: rebuild NSEvent modifier flags from
    /// libghostty mods (used for translation mods).
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 {
            flags.insert(.shift)
        }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
            flags.insert(.control)
        }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
            flags.insert(.option)
        }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 {
            flags.insert(.command)
        }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 {
            flags.insert(.capsLock)
        }
        return flags
    }

    /// True when `text` is a single C0 control character (U+0000-U+001F)
    /// arriving while the IME is composing. Such input belongs to the IME
    /// and must not be forwarded to the terminal.
    static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex
        else {
            return false
        }
        return scalar.value < 0x20
    }

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

    private func mouseButton(
        _ state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        event: NSEvent
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, state, button, Self.ghosttyMods(event.modifierFlags)
        )
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

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        default: .arrow
        }
        cursor.set()
    }
}

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
    private func syncPreedit(clearIfNeeded: Bool = true) {
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
