import AppKit

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAudioSharing(_:)) {
            menuItem.state = automaticAudio.enabled ? .on : .off
            let host = controller?.activeSession?.focusedPane?.daemon
            menuItem.toolTip = host.flatMap { automaticAudio.statuses[$0] }
                ?? "Let applications in attached remote panes request Mac audio."
            return true
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
