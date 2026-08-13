import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var runtime: GhosttyRuntime?
    /// The one window. mux is deliberately single-window: sessions are
    /// the unit of grouping (prefix c / 1..9 / canvas), and a second
    /// window would only add a second copy of every window-scoped
    /// invariant (focus routing, snapshot identity, close semantics)
    /// for no capability.
    private(set) var controller: MuxWindowController?
    /// Internal (not private): the canvas overlay's click-to-jump ends
    /// the mode through the engine, exactly like enter does.
    let prefixEngine = PrefixEngine()

    func applicationDidFinishLaunching(_: Notification) {
        // Before the snapshot is loaded: an unclean previous exit freezes
        // the pre-crash state file for post-mortem and recovery.
        let unclean = CrashMarker.checkAndArm()
        AppLog.log("launch unclean_previous_exit=\(unclean) attach_binary=\(Muxd.attachBinary ?? "MISSING (panes fall back to plain shells)")")

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
            let panes = snapshot.windows.flatMap(\.sessions).flatMap { $0.panes.keys.map(\.uuidString) }
            AppLog.log("restoring windows=\(snapshot.windows.count) panes=\(panes.joined(separator: ","))")
            restore(snapshot)
        } else {
            AppLog.log("no restorable snapshot; starting fresh")
            makeWindow()?.addInitialPane()
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
                guard let self, let controller, let listings, !listings.isEmpty else { return }
                // The same answer that finds orphans also carries every
                // known pane's live cwd - the daemon resolves it from
                // the pty's process, which no shell integration has to
                // report. Seed the restored panes with it (OSC 7, when
                // it exists, overwrites later). ix panes excluded: their
                // local pty cwd is not the VM shell's.
                for session in controller.sessions {
                    for (id, pane) in session.panes
                        where pane.target == host && IX.vm(of: pane.target) == nil
                    {
                        if let listing = listings.first(where: { $0.name == id.uuidString }),
                           let cwd = listing.cwd
                        {
                            pane.pwd = cwd
                        }
                    }
                }
                let known = Set(controller.sessions.flatMap(\.panes.keys))
                let orphans = listings.compactMap { l -> (UUID, String?, String?)? in
                    // Only pane-shaped names: the pane UUID namespace is
                    // the app's, anything else is not ours to adopt.
                    guard let id = UUID(uuidString: l.name),
                          !l.exited, !l.attached, !known.contains(id)
                    else { return nil }
                    return (id, l.cwd, Self.recoveredTarget(host: host, command: l.command))
                }
                guard !orphans.isEmpty else { return }
                AppLog.log("adopting \(orphans.count) orphaned pty(s) from \(host ?? "local"): \(orphans.map(\.0.uuidString).joined(separator: ","))")
                controller.addRecoverySession(orphans)
            }
        }
    }

    /// The pane target an adopted pty should carry: the host it was
    /// listed from, or `ix:<vm>` reconstructed from an `ix shell` command
    /// so the pane keeps its self-healing attach.
    private static func recoveredTarget(host: String?, command: [String]) -> String? {
        if let host {
            return host
        }
        if command.count == 3, command[1] == "shell",
           command[0] == IX.binary || command[0].hasSuffix("/ix") || command[0] == "ix"
        {
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

    /// Mark the app as exiting: save while the sessions are still alive,
    /// then freeze the snapshot against the teardown that follows. Called
    /// from every path that ends the app - shouldTerminate for a real
    /// quit, and the window's close, which with one window IS quitting.
    func beginTermination(reason: String) {
        guard !isTerminating else { return }
        AppLog.log("terminating (\(reason))")
        saveSnapshot()
        isTerminating = true
        CrashMarker.disarm()
        AppLog.drain()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Save before raising the flag: saveSnapshot is a no-op once
        // terminating, so the teardown saves cannot clobber this
        // snapshot with an empty one.
        beginTermination(reason: "applicationShouldTerminate")
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        // Normally a no-op (shouldTerminate already saved and raised the
        // flag); covers termination paths that skip shouldTerminate.
        beginTermination(reason: "applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    // MARK: - The window

    /// Create the single window. Returns nil if it already exists (or
    /// the runtime is gone); there is never a second one.
    @discardableResult
    private func makeWindow() -> MuxWindowController? {
        guard controller == nil, let runtime else { return nil }
        let controller = MuxWindowController(runtime: runtime)
        self.controller = controller
        controller.window.makeKeyAndOrderFront(nil)
        return controller
    }

    func windowControllerDidClose(_: MuxWindowController) {
        // The window is the app: with it gone the app terminates
        // (terminateAfterLastWindowClosed); the snapshot was saved by
        // beginTermination before teardown.
        controller = nil
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
        let windows: [WindowSnapshot] = controller.flatMap { c in
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
        }.map { [$0] } ?? []
        let panes = windows.flatMap(\.sessions).map(\.panes.count).reduce(0, +)
        AppLog.log("save windows=\(windows.count) panes=\(panes)")
        SnapshotStore.save(AppSnapshot(windows: windows))
    }

    /// Rebuild the single window from a snapshot. Files written by
    /// multi-window builds fold every window's sessions into it, so
    /// nothing is dropped on the way through.
    private func restore(_ snapshot: AppSnapshot) {
        guard let controller = makeWindow() else { return }
        let first = snapshot.windows[0]
        if first.frame.count == 4 {
            restoreFrame(
                NSRect(x: first.frame[0], y: first.frame[1], width: first.frame[2], height: first.frame[3]),
                on: controller.window
            )
        }
        controller.restoreSessions(
            snapshot.windows.flatMap(\.sessions), active: first.activeSession
        )
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

    // MARK: - Menu actions

    @objc func newSession(_: Any?) {
        controller?.newSession()
    }

    @objc func copyFromPane(_: Any?) {
        bindingAction("copy_to_clipboard")
    }

    @objc func pasteToPane(_: Any?) {
        bindingAction("paste_from_clipboard")
    }

    private func bindingAction(_ action: String) {
        guard let surface = controller?.focusedPane?.surface else { return }
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
        fileMenu.addItem(withTitle: "New Session", action: #selector(newSession(_:)), keyEquivalent: "n")
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
