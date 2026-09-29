import AppKit
import UserNotifications

/// Own the one delegate installed at startup; callers never downcast NSApp.delegate.
enum App {
    static let delegate = AppDelegate()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [MuxWindowController] = []
    /// Closed windows keep their layout while their terminals remain on muxd.
    var closedWindows: [WindowSnapshot] = []
    var isRestoring = true
    var pendingSave: DispatchWorkItem?
    var watches: [String?: Muxd.Watch] = [:]

    /// Menu actions follow the key window; mainWindow covers menu/alert focus.
    var controller: MuxWindowController? {
        controllers.first { $0.window === NSApp.keyWindow }
            ?? controllers.first { $0.window === NSApp.mainWindow }
            ?? controllers.last
    }

    let prefixEngine = PrefixEngine()
    let automaticAudio = AutomaticAudio()

    func applicationDidFinishLaunching(_: Notification) {
        // Before the snapshot is loaded: an unclean previous exit freezes
        // the pre-crash state file for post-mortem and recovery.
        let unclean = CrashMarker.checkAndArm()
        AppLog.log("launch unclean_previous_exit=\(unclean) attach_binary=\(Muxd.attachBinary)")

        buildMenu()

        guard let runtime = GhosttyRuntime() else {
            let alert = NSAlert()
            alert.messageText = "libghostty failed to initialize"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        GhosttyRuntime.shared = runtime

        ThemeManager.shared.start()
        prefixEngine.install()

        // Ask once, here, rather than on every OSC 9 a pane fires.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    AppLog.log("notification authorization failed: \(error)")
                } else if !granted {
                    AppLog.log("notification authorization denied")
                }
            }

        // Before the first pane dials it: a daemon left over from the
        // previous install may not speak this build's protocol.
        Muxd.upgradeStaleDaemon()

        if let snapshot = SnapshotStore.load(), !snapshot.windows.isEmpty {
            AppLog.log("restoring windows=\(snapshot.windows.count)")
            restore(snapshot)
        } else {
            AppLog.log("no restorable snapshot; starting fresh")
            newWindow(nil)
        }
        isRestoring = false
        saveSnapshot()
        adoptOrphanedPanes()

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Ask every daemon (local, then each host alias) for its ptys and
    /// fold the ones no window knows into a recovery session. This is
    /// what makes a lost or stale state.json recoverable: the shells
    /// are alive on the daemon either way.
    private func adoptOrphanedPanes() {
        let targets = snapshot.hosts.union([nil]).union(HostsConfig.aliases().map(Optional.some))
        for host in targets {
            Muxd.list(host: host) { [weak self] listings in
                guard let self, !isTerminating, let listings, !listings.isEmpty else { return }
                // The same answer that finds orphans also carries every
                // known pane's live cwd and agent.
                controllers.forEach { $0.applyListings(listings, host: host) }
                // Read ownership when the reply arrives: windows may have moved or closed.
                let known = snapshot.knownTerminals
                var orphans: [UUID: PaneSnapshot] = [:]
                for listing in listings {
                    // Only pane-shaped names: the pane UUID namespace is
                    // the app's, anything else is not ours to adopt.
                    guard let id = UUID(uuidString: listing.name),
                          !listing.exited, !listing.attached,
                          !known.contains(TerminalIdentity(id: id, host: host))
                    else { continue }
                    orphans[id] = PaneSnapshot(
                        cwd: listing.cwd,
                        target: Self.recoveredTarget(host: host, command: listing.command)
                    )
                }
                guard !orphans.isEmpty else { return }
                let names = orphans.keys.map(\.uuidString).joined(separator: ",")
                AppLog.log("adopting \(orphans.count) orphaned pty(s) from \(host ?? "local"): \(names)")
                controllers.first?.addRecoverySession(orphans)
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
           command[0].hasSuffix("/ix") || command[0] == "ix"
        {
            return "ix:\(command[2])"
        }
        return nil
    }

    func applicationDidBecomeActive(_: Notification) {
        GhosttyRuntime.shared?.setFocus(true)
    }

    func applicationDidResignActive(_: Notification) {
        GhosttyRuntime.shared?.setFocus(false)
    }

    private(set) var isTerminating = false

    func beginTermination(reason: String) {
        guard !isTerminating else { return }
        AppLog.log("terminating (\(reason))")
        saveSnapshot()
        isTerminating = true
        stopAudioSharing()
        stopWatches()
        CrashMarker.disarm()
        AppLog.drain()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        beginTermination(reason: "applicationShouldTerminate")
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        beginTermination(reason: "applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc func newSession(_: Any?) {
        prefixEngine.cancel()
        if let controller {
            controller.newSession()
        } else {
            newWindow(nil)
        }
    }

    @objc func reopenClosedTab(_: Any?) {
        prefixEngine.reopenClosedTab()
    }

    @objc func closeTab(_: Any?) {
        prefixEngine.closeTab()
    }

    @objc func killTerminal(_: Any?) {
        prefixEngine.killTerminal()
    }

    @objc func copyFromPane(_: Any?) {
        if let editor = controller?.window.firstResponder as? NSTextView {
            editor.copy(nil)
            return
        }
        controller?.activeSession?.focusedPane?.bindingAction("copy_to_clipboard")
    }

    @objc func pasteToPane(_: Any?) {
        if let editor = controller?.window.firstResponder as? NSTextView {
            editor.paste(nil)
            return
        }
        controller?.activeSession?.focusedPane?.bindingAction("paste_from_clipboard")
    }

    @objc func findInPane(_: Any?) {
        controller?.activeSession?.focusedPane?.bindingAction("start_search")
    }

    @objc func findNextInPane(_: Any?) {
        controller?.activeSession?.focusedPane?.bindingAction("navigate_search:next")
    }

    @objc func findPreviousInPane(_: Any?) {
        controller?.activeSession?.focusedPane?.bindingAction("navigate_search:previous")
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About mux",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide mux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit mux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Session", action: #selector(newSession(_:)), keyEquivalent: "n")
        let newWindow = fileMenu.addItem(
            withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n"
        )
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        let detach = fileMenu.addItem(
            withTitle: "Move Session to New Window",
            action: #selector(moveSessionToNewWindow(_:)), keyEquivalent: "n"
        )
        detach.keyEquivalentModifierMask = [.command, .option]
        let closeWindow = fileMenu.addItem(
            withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let reopen = fileMenu.addItem(
            withTitle: "Reopen Closed Tab", action: #selector(reopenClosedTab(_:)), keyEquivalent: "t"
        )
        reopen.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Kill Terminal", action: #selector(killTerminal(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Automatic Remote Audio",
            action: #selector(toggleAudioSharing(_:)), keyEquivalent: ""
        )
        fileMenuItem.submenu = fileMenu
        main.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(copyFromPane(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(pasteToPane(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(findInPane(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNextInPane(_:)), keyEquivalent: "g")
        let previous = editMenu.addItem(
            withTitle: "Find Previous", action: #selector(findPreviousInPane(_:)), keyEquivalent: "g"
        )
        previous.keyEquivalentModifierMask = [.command, .shift]
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        main.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
