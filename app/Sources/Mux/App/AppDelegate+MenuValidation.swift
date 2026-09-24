import AppKit

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAudioSharing(_:)) {
            menuItem.title = audioSharing == nil ? "Share Mac Audio with This Pane" : "Stop Sharing Mac Audio"
            menuItem.state = audioSharing == nil ? .off : .on
            return audioSharing != nil || controller?.activeSession?.focusedPane?.daemon != nil
        }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return controller.map { !$0.closedPanes.isEmpty } ?? false
        }
        if menuItem.action == #selector(closeTab(_:)) || menuItem.action == #selector(killTerminal(_:)) {
            return controller?.activeSession?.focusedPane != nil
        }
        return true
    }
}
