import AppKit

extension PrefixEngine {
    enum WindowShortcut {
        case newSession, newWindow, moveSession, closeWindow
    }

    /// Intercept before Ghostty's default cmd+n binding and before mode keys.
    static func windowShortcut(_ event: NSEvent) -> WindowShortcut? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "n" {
            switch flags {
            case .command: return .newSession
            case [.command, .shift]: return .newWindow
            case [.command, .option]: return .moveSession
            default: return nil
            }
        }
        if key == "w", flags == [.command, .shift] {
            return .closeWindow
        }
        return nil
    }
}
