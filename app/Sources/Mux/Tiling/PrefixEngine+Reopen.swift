import AppKit

extension PrefixEngine {
    static func isCloseTab(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    static func isReopenClosedTab(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift]
            && event.charactersIgnoringModifiers?.lowercased() == "t"
    }
}
