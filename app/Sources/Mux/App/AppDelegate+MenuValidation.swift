import AppKit

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return controller.map { !$0.closedPanes.isEmpty } ?? false
        }
        return true
    }
}
