import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var runtime: GhosttyRuntime?
    private(set) var controllers: [MuxWindowController] = []
    private let prefixEngine = PrefixEngine()

    var keyController: MuxWindowController? {
        controllers.first { $0.window.isKeyWindow } ?? controllers.first
    }

    func applicationDidFinishLaunching(_: Notification) {
        buildMenu()

        guard let runtime = GhosttyRuntime() else {
            let alert = NSAlert()
            alert.messageText = "libghostty failed to initialize"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        GhosttyRuntime.shared = runtime
        self.runtime = runtime

        ThemeManager.shared.start()
        prefixEngine.install()

        if let snapshot = SnapshotStore.load(), !snapshot.windows.isEmpty {
            restore(snapshot)
        } else {
            newWindow(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_: Notification) {
        runtime?.setFocus(true)
    }

    func applicationDidResignActive(_: Notification) {
        runtime?.setFocus(false)
    }

    /// True once quit begins: window teardown during termination is a
    /// detach (ptys survive for restore), never a kill.
    private(set) var isTerminating = false

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        saveSnapshot()
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        isTerminating = true
        saveSnapshot()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Windows

    @objc func newWindow(_: Any?) {
        guard let runtime else { return }
        let controller = MuxWindowController(runtime: runtime)
        controllers.append(controller)
        // New windows follow the key pane's target and cwd, like prefix c.
        let source = keyController?.focusedPane
        controller.addInitialPane(workingDirectory: source?.pwd, target: source?.target)
        controller.window.makeKeyAndOrderFront(nil)
        saveSnapshot()
    }

    func windowControllerDidClose(_ controller: MuxWindowController) {
        controllers.removeAll { $0 === controller }
        saveSnapshot()
    }

    // MARK: - Snapshot

    func saveSnapshot() {
        let windows: [WindowSnapshot] = controllers.compactMap { c in
            let sessions: [SessionSnapshot] = c.sessions.compactMap { s in
                guard let tree = s.tree else { return nil }
                var paneMeta: [UUID: PaneSnapshot] = [:]
                for (id, pane) in s.panes {
                    paneMeta[id] = PaneSnapshot(cwd: pane.pwd, target: pane.target)
                }
                return SessionSnapshot(
                    tree: tree, panes: paneMeta,
                    focused: s.focusedID, zoomed: s.zoomedID
                )
            }
            guard !sessions.isEmpty else { return nil }
            let f = c.window.frame
            return WindowSnapshot(
                frame: [f.origin.x, f.origin.y, f.size.width, f.size.height],
                sessions: sessions,
                activeSession: c.activeSessionIndex
            )
        }
        SnapshotStore.save(AppSnapshot(windows: windows))
    }

    private func restore(_ snapshot: AppSnapshot) {
        guard let runtime else { return }
        for w in snapshot.windows {
            let controller = MuxWindowController(runtime: runtime)
            controllers.append(controller)
            if w.frame.count == 4 {
                restoreFrame(
                    NSRect(x: w.frame[0], y: w.frame[1], width: w.frame[2], height: w.frame[3]),
                    on: controller.window
                )
            }
            controller.restoreSessions(w.sessions, active: w.activeSession)
            controller.window.makeKeyAndOrderFront(nil)
        }
        if controllers.isEmpty {
            newWindow(nil)
        }
    }

    /// Frames saved under a different display arrangement can land
    /// off-screen, and borderless windows get no AppKit constraining.
    /// Require a meaningful visible intersection, else recenter on the
    /// main screen (clamped to fit).
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
            rect.origin = NSPoint(
                x: vf.midX - rect.width / 2,
                y: vf.midY - rect.height / 2
            )
        }
        window.setFrame(rect, display: false)
    }

    // MARK: - Clipboard menu actions

    @objc func copyFromPane(_: Any?) {
        bindingAction("copy_to_clipboard")
    }

    @objc func pasteToPane(_: Any?) {
        bindingAction("paste_from_clipboard")
    }

    private func bindingAction(_ action: String) {
        guard let surface = keyController?.focusedPane?.surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About mux", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide mux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit mux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenuItem.submenu = fileMenu
        main.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(copyFromPane(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(pasteToPane(_:)), keyEquivalent: "v")
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        NSApp.mainMenu = main
    }
}
