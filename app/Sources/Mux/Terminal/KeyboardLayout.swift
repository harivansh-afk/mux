import Carbon

/// Identifies the active keyboard input source. From ghostty's
/// KeyboardLayout.swift (MIT): keyDown compares the layout before and
/// after interpretKeyEvents to detect input-method layout switches that
/// should not reach the terminal.
enum KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        {
            let sourceId = unsafeBitCast(sourceIdPointer, to: CFString.self)
            return sourceId as String
        }

        return nil
    }
}
