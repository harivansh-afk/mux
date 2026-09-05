import AppKit

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return controller.map { !$0.closedPanes.isEmpty } ?? false
        }
        if menuItem.action == #selector(closeTab(_:)) || menuItem.action == #selector(killTerminal(_:)) {
            return controller?.activeSession?.focusedPane != nil
        }
        return true
    }
}
