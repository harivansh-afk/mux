import AppKit

extension MuxWindowController {
    var snapshot: WindowSnapshot {
        // Empty sessions are omitted; translate the selected index accordingly.
        let saved = sessions.compactMap(\.snapshot)
        let selected = sessions.prefix(activeSessionIndex).compactMap(\.snapshot).count
        return WindowSnapshot(
            id: id, frame: window.frame.values, sessions: saved,
            activeSession: min(selected, max(0, saved.count - 1)),
            closedPanes: closedPanes.entries
        )
    }

    var canMoveSessionToNewWindow: Bool {
        sessions.count > 1 && activeSession?.tree != nil
    }

    /// Called only with a newly created, empty destination. Nothing detaches
    /// from muxd: moving views changes their window, not their terminal identity.
    func moveActiveSession(to destination: MuxWindowController) {
        guard canMoveSessionToNewWindow, let session = activeSession else { return }
        window.makeFirstResponder(nil)
        sessions.remove(at: activeSessionIndex)
        activeSessionIndex = min(activeSessionIndex, sessions.count - 1)
        destination.sessions = [session]
        destination.activeSessionIndex = 0
        session.move(to: destination)
        for owner in [self, destination] {
            owner.layoutPanes()
            owner.updateSessionIndicator()
            if let pane = owner.activeSession?.focusedPane {
                owner.focus(pane)
            }
        }
    }
}
