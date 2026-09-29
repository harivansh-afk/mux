import AppKit

extension AppDelegate {
    var snapshot: AppSnapshot {
        AppSnapshot(
            windows: controllers.map(\.snapshot) + closedWindows,
            activeWindow: controller?.id
        )
    }

    @discardableResult
    private func makeWindow(id: UUID = UUID(), near source: NSWindow? = nil) -> MuxWindowController {
        let controller = MuxWindowController(id: id)
        controllers.append(controller)
        if let source {
            var frame = source.frame
            frame.origin.x += 28
            frame.origin.y -= 28
            restoreFrame(frame, on: controller.window)
        }
        return controller
    }

    @objc func newWindow(_: Any?) {
        let source = controller
        let seed = NewPaneTarget.inherit.seed(from: source?.activeSession?.focusedPane)
        prefixEngine.cancel()
        let created = makeWindow(near: source?.window)
        created.activeSession?.addInitialPane(
            workingDirectory: seed.cwd, cwdFrom: seed.cwdFrom, target: seed.target
        )
        created.window.makeKeyAndOrderFront(nil)
        saveSnapshot()
    }

    @objc func moveSessionToNewWindow(_: Any?) {
        guard let source = controller, source.canMoveSessionToNewWindow else { return }
        prefixEngine.cancel()
        // Transfer is synchronous, with one save after both owners are updated.
        let created = makeWindow(near: source.window)
        source.moveActiveSession(to: created)
        created.window.makeKeyAndOrderFront(nil)
        saveSnapshot()
    }

    @objc func closeWindow(_: Any?) {
        controller?.window.close()
    }

    /// Capture metadata before surfaces detach. Parked layouts participate in
    /// every subsequent save and reconciliation, even while other windows run.
    func windowControllerWillClose(_ closing: MuxWindowController) {
        guard controllers.contains(where: { $0 === closing }) else { return }
        prefixEngine.cancel()
        if !isTerminating {
            closedWindows.append(closing.snapshot)
        }
        controllers.removeAll { $0 === closing }
        saveSnapshot()
        if controllers.isEmpty {
            beginTermination(reason: "last window closed")
        }
    }

    func saveSnapshotSoon() {
        guard !isTerminating, !isRestoring else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveSnapshot() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func saveSnapshot() {
        guard !isTerminating, !isRestoring else { return }
        pendingSave?.cancel()
        pendingSave = nil
        let saved = snapshot
        AppLog.log("save windows=\(saved.windows.count) terminals=\(saved.knownTerminals.count)")
        SnapshotStore.save(saved)
    }

    func restore(_ snapshot: AppSnapshot) {
        for saved in snapshot.windows {
            let controller = makeWindow(id: saved.id)
            controller.closedPanes = ClosedPaneHistory(entries: saved.closedPanes ?? [])
            for entry in controller.closedPanes.entries {
                controller.watch(entry.pane.daemon)
            }
            if let frame = NSRect(values: saved.frame) {
                restoreFrame(frame, on: controller.window)
            }
            controller.restoreSessions(saved.sessions, active: saved.activeSession)
            controller.window.orderFront(nil)
        }
        let selected = controllers.first { $0.id == snapshot.activeWindow } ?? controllers.first
        selected?.window.makeKeyAndOrderFront(nil)
    }

    /// A saved display may have disappeared. Keep a useful visible overlap,
    /// otherwise clamp and centre the window on the current main screen.
    private func restoreFrame(_ saved: NSRect, on window: NSWindow) {
        var rect = saved
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(rect)
            return overlap.width >= 200 && overlap.height >= 200
        }
        if !visible, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            rect.size.width = min(rect.width, vf.width)
            rect.size.height = min(rect.height, vf.height)
            rect.origin = NSPoint(x: vf.midX - rect.width / 2, y: vf.midY - rect.height / 2)
        }
        window.setFrame(rect, display: false)
    }
}
