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
        // Before the snapshot is loaded: an unclean previous exit freezes
        // the pre-crash state file for post-mortem and recovery.
        _ = CrashMarker.checkAndArm()

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

        // The snapshot is a claim, not the truth: the daemons know which
        // ptys actually exist. Adopt live shells no window remembers.
        adoptOrphanedPanes()

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Ask every daemon (local, then each host alias) for its ptys and
    /// fold the ones no window knows into a recovery session. This is
    /// what makes a lost or stale state.json recoverable: the shells
    /// are alive on the daemon either way.
    private func adoptOrphanedPanes() {
        let targets: [String?] = [nil] + HostsConfig.aliases().map(Optional.some)
        for host in targets {
            Muxd.list(host: host) { [weak self] listings in
                guard let self, let listings, !listings.isEmpty else { return }
                let known = Set(self.controllers.flatMap { c in
                    c.sessions.flatMap(\.panes.keys)
                })
                let orphans = listings.compactMap { l -> (UUID, String?, String?)? in
                    // Only pane-shaped names: the pane UUID namespace is
                    // the app's, anything else is not ours to adopt.
                    guard let id = UUID(uuidString: l.name),
                          !l.exited, !l.attached, !known.contains(id)
                    else { return nil }
                    return (id, l.cwd, Self.recoveredTarget(host: host, command: l.command))
                }
                guard !orphans.isEmpty else { return }
                NSLog("adopting \(orphans.count) orphaned pty(s) from \(host ?? "local")")
                (self.keyController ?? self.controllers.first)?.addRecoverySession(orphans)
            }
        }
    }

    /// The pane target an adopted pty should carry: the host it was
    /// listed from, or `ix:<vm>` reconstructed from an `ix shell` command
    /// so the pane keeps its badge and self-healing attach.
    private static func recoveredTarget(host: String?, command: [String]) -> String? {
        if let host { return host }
        if command.count == 3, command[1] == "shell",
           command[0] == IX.binary || command[0].hasSuffix("/ix") || command[0] == "ix" {
            return "ix:\(command[2])"
        }
        return nil
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
        // Save before raising the flag: saveSnapshot is a no-op once
        // terminating, so the teardown saves (windowControllerDidClose
        // fires as AppKit closes each window with zero sessions left)
        // cannot clobber this snapshot with an empty one.
        saveSnapshot()
        isTerminating = true
        CrashMarker.disarm()
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        // Normally a no-op (shouldTerminate already saved and raised the
        // flag); covers termination paths that skip shouldTerminate.
        saveSnapshot()
        isTerminating = true
        CrashMarker.disarm()
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
        controller.addInitialPane(
            workingDirectory: source?.pwd, cwdFrom: source?.id, target: source?.target
        )
        controller.window.makeKeyAndOrderFront(nil)
        saveSnapshot()
    }

    func windowControllerDidClose(_ controller: MuxWindowController) {
        controllers.removeAll { $0 === controller }
        saveSnapshot()
    }

    // MARK: - Snapshot

    private var pendingSave: DispatchWorkItem?

    /// Coalesces high-frequency triggers (window drags, focus hops, cwd
    /// updates) into one write shortly after they settle. Structural
    /// mutations keep calling saveSnapshot directly.
    func saveSnapshotSoon() {
        guard !isTerminating else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveSnapshot() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func saveSnapshot() {
        // Termination teardown must not overwrite the snapshot taken at
        // the start of the quit; that file is the restore source.
        guard !isTerminating else { return }
        // A direct save supersedes any pending debounced one.
        pendingSave?.cancel()
        pendingSave = nil
        let windows: [WindowSnapshot] = controllers.compactMap { c in
            let sessions: [SessionSnapshot] = c.sessions.compactMap { s in
                guard let tree = s.tree else { return nil }
                var paneMeta: [UUID: PaneSnapshot] = [:]
                for (id, pane) in s.panes {
                    paneMeta[id] = PaneSnapshot(
                        cwd: pane.pwd, target: pane.target,
                        fontDelta: pane.fontDelta == 0 ? nil : pane.fontDelta
                    )
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
