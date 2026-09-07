import AppKit
import Tiling

/// One window = window chrome (borderless NSWindow, mode bar, keybinds
/// overlay, target picker, theming) plus an ordered list of sessions.
/// Tiling state and pane lifecycle live in Session; the controller routes
/// operations to the active session (or, for pane-originated events, to
/// the session owning that pane).
///
/// The chrome itself lives in MuxWindowController+Overlays.swift.
final class MuxWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!

    /// Internal (not private): the overlay chrome is managed by
    /// MuxWindowController+Overlays.swift.
    let container = PaneContainerView()
    /// The slab every pane lives on.
    let workspace = FlippedView()
    let modeBar = ModeBarView()
    let sessionIndicator = ModeBarView(drawsBackground: false)
    let helpOverlay = HelpOverlayView()
    let canvasOverlay = CanvasOverlayView()
    let hostsWindow = HostsWindowView()

    /// The chrome that is currently up, in the order it was presented.
    /// Managed by `present` / `dismiss`; layout walks it.
    var presented: [ChromeOverlay] = []

    private(set) var sessions: [Session] = []
    private(set) var activeSessionIndex = 0
    var closedPanes = ClosedPaneHistory()

    /// Canvas state (managed by MuxWindowController+Overlays.swift):
    /// the picker floats over the workspace, which never moves for it -
    /// sizes and positions untouched, so no pty ever observes the
    /// canvas. `canvasClosing` keeps the fade-out from being torn down
    /// by the mode change that follows a commit.
    var canvasOpen = false
    var canvasClosing = false
    /// While the canvas is up, the session indicator highlights the
    /// session of the selected card instead of the active session, so
    /// the numbers follow the scroll in real time. nil = canvas closed.
    var canvasSessionHighlight: Int?

    /// Bare per-pane labels while the prefix is armed (managed by
    /// MuxWindowController+Overlays.swift).
    var paneTags: [PaneTagView] = []

    /// The scroll host wearing the resize-mode outline (managed by
    /// MuxWindowController+Overlays.swift). Non-nil only while resize
    /// mode is up.
    weak var resizeOutlineHost: PaneScrollView?

    /// One `muxd watch` per daemon this window has panes on, keyed by
    /// host alias (nil = local). Started for local at launch and for a
    /// host the first time a pane lands there; stopped at termination.
    private var watches: [String?: Muxd.Watch] = [:]

    var activeSession: Session? {
        sessions.indices.contains(activeSessionIndex) ? sessions[activeSessionIndex] : nil
    }

    override init() {
        super.init()
        watch(nil)

        // Borderless: no titlebar, no traffic lights, square corners.
        // Edge-resizing works via .resizable; dragging via background.
        let window = MuxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "mux"
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.center()
        window.tabbingMode = .disallowed
        window.delegate = self
        container.controller = self
        container.wantsLayer = true
        window.contentView = container
        workspace.wantsLayer = true
        workspace.frame = container.bounds
        workspace.autoresizingMask = [.width, .height]
        container.addSubview(workspace)
        self.window = window

        // Late rows and resolved probe statuses change the box's size;
        // re-centre it where it stands rather than letting it grow off
        // its corner.
        hostsWindow.onContentChange = { [weak self] in
            guard let self, hostsWindow.superview != nil else { return }
            position(hostsWindow)
        }

        sessions = [Session(controller: self)]
        wireCanvasCallbacks()
        updateSessionIndicator()

        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .muxThemeDidChange, object: nil
        )
    }

    // MARK: - Session plumbing

    /// The session that owns a given pane (pane-originated events can
    /// arrive for panes in inactive sessions).
    func session(owning pane: PaneView) -> Session? {
        sessions.first { $0.contains(pane) }
    }

    func attach(_ pane: PaneView) {
        // Wrap the pane in its scroll view: the workspace slab owns the
        // host, the host owns the pane, and Session lays out the host.
        let host = PaneScrollView(pane: pane)
        pane.scrollHost = host
        workspace.addSubview(host)
        watch(pane.daemon)
    }

    /// Follow one daemon's ptys: every agent and directory change it
    /// reports lands on the pane it names. Idempotent per daemon.
    func watch(_ host: String?) {
        guard watches[host] == nil else { return }
        watches[host] = Muxd.Watch(host: host) { [weak self] event in
            guard let self, let id = UUID(uuidString: event.name) else { return }
            if event.exited, closedPanes.remove(id, on: host) {
                saveState()
            }
            pane(id, on: host)?.apply(agent: event.agent, cwd: event.cwd)
        }
    }

    func stopWatches() {
        watches.values.forEach { $0.stop() }
        watches.removeAll()
    }

    /// The pane whose pty `host`'s daemon calls `id`, if this window has
    /// it. Pty names are pane UUIDs, so the name is the match.
    func pane(_ id: UUID, on host: String?) -> PaneView? {
        for session in sessions {
            if let pane = session.panes[id], pane.daemon == host {
                return pane
            }
        }
        return nil
    }

    var paneBounds: CGRect {
        workspace.bounds
    }

    /// Keep an empty window after the last pane closes so it can be reopened.
    func sessionDidEmpty(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        if sessions.isEmpty {
            sessions = [Session(controller: self)]
            activeSessionIndex = 0
            window.makeFirstResponder(nil)
        }
        if index < activeSessionIndex {
            activeSessionIndex -= 1
        } else if activeSessionIndex >= sessions.count {
            activeSessionIndex = sessions.count - 1
        }
        layoutPanes()
        if let pane = activeSession?.focusedPane {
            focus(pane)
        }
        updateSessionIndicator()
        saveState()
    }

    // MARK: - Session switching

    func reopenClosedTab() {
        guard let entry = closedPanes.popLast() else { return }
        let session = Session(controller: self)
        sessions.removeAll { $0.tree == nil }
        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        session.restore(entry.snapshot)
        layoutPanes()
        updateSessionIndicator()
        saveState()
    }

    /// Follows the focused pane's host and working directory, or the
    /// machine the hosts window named - in which case there is no
    /// directory to inherit.
    func newSession(target: NewPaneTarget = .inherit) {
        let seed = target.seed(from: activeSession?.focusedPane)
        let session = Session(controller: self)
        sessions.removeAll { $0.tree == nil }
        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        session.addInitialPane(
            workingDirectory: seed.cwd, cwdFrom: seed.cwdFrom, target: seed.target
        )
        layoutPanes()
        updateSessionIndicator()
        saveState()
    }

    /// Orphan recovery: a new session adopting daemon ptys no window
    /// knew about (a lost or stale snapshot), split evenly. Appended,
    /// not selected: the session indicator shows it without yanking
    /// focus from whatever the user is doing.
    func addRecoverySession(_ panes: [UUID: PaneSnapshot]) {
        // Sorted so the same set of recovered ptys always lands in the
        // same order; a dictionary's is per-run.
        let ids = panes.keys.sorted { $0.uuidString < $1.uuidString }
        guard let first = ids.first else { return }
        var tree: SplitNode = .leaf(first)
        var previous = first
        for id in ids.dropFirst() {
            tree = tree.inserting(id, at: previous, direction: .horizontal)
            previous = id
        }
        let session = Session(controller: self)
        sessions.removeAll { $0.tree == nil }
        sessions.append(session)
        session.restore(SessionSnapshot(
            tree: tree, panes: panes, focused: first, zoomed: nil
        ))
        layoutPanes()
        // Session.restore focused its own pane; give focus back to the
        // session the user is actually looking at.
        if let pane = activeSession?.focusedPane {
            focus(pane)
        }
        updateSessionIndicator()
        saveState()
    }

    /// A sole pane already is its own session; no-op.
    func movePaneToNewSession() {
        guard let source = activeSession, let pane = source.focusedPane,
              source.panes.count > 1 else { return }
        source.detach(pane)
        let session = Session(controller: self)
        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        session.adopt(pane)
        layoutPanes()
        updateSessionIndicator()
        saveState()
    }

    /// The pane splits at the target's focused pane; a source session this
    /// empties closes (which is why the target is found again by identity
    /// after the detach).
    func movePane(toSession index: Int) {
        guard sessions.indices.contains(index), index != activeSessionIndex,
              let source = activeSession, let pane = source.focusedPane else { return }
        let target = sessions[index]
        source.detach(pane)
        guard let targetIndex = sessions.firstIndex(where: { $0 === target }) else { return }
        activeSessionIndex = targetIndex
        target.adopt(pane)
        layoutPanes()
        updateSessionIndicator()
        saveState()
    }

    func selectSession(_ index: Int) {
        guard sessions.indices.contains(index), index != activeSessionIndex else { return }
        activeSessionIndex = index
        layoutPanes()
        if let pane = activeSession?.focusedPane {
            focus(pane)
        }
        updateSessionIndicator()
        saveState()
    }

    func nextSession() {
        guard sessions.count > 1 else { return }
        selectSession((activeSessionIndex + 1) % sessions.count)
    }

    func prevSession() {
        guard sessions.count > 1 else { return }
        selectSession((activeSessionIndex + sessions.count - 1) % sessions.count)
    }

    /// Rebuild all sessions from a snapshot. The active session is
    /// restored last so its focused pane ends up first responder.
    func restoreSessions(_ snapshots: [SessionSnapshot], active: Int) {
        guard !snapshots.isEmpty else { return }
        sessions = snapshots.map { _ in Session(controller: self) }
        activeSessionIndex = min(max(0, active), sessions.count - 1)
        for (index, snapshot) in snapshots.enumerated() {
            sessions[index].restore(snapshot)
        }
        layoutPanes()
        updateSessionIndicator()
        if let pane = activeSession?.focusedPane {
            focus(pane)
        }
    }

    /// A pane can die in an inactive session, so the owning session is
    /// found before the active one is assumed.
    func removePane(_ pane: PaneView) {
        (session(owning: pane) ?? activeSession)?.removePane(pane)
    }

    // MARK: - Focus

    func focus(_ pane: PaneView) {
        window.makeFirstResponder(pane)
    }

    func noteFocused(_ pane: PaneView) {
        session(owning: pane)?.noteFocused(pane)
        // A click can refocus mid-resize-mode; the outline follows.
        if resizeOutlineHost != nil, resizeOutlineHost !== pane.scrollHost {
            showResizeOutline()
        }
    }

    // MARK: - Layout

    func layoutPanes() {
        let bounds = container.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        for overlay in presented {
            position(overlay)
        }
        if !paneTags.isEmpty {
            positionPaneTags()
        }

        // The workspace never moves for the canvas: the picker floats
        // above it and the scrim dims it in place, so no pty ever
        // observes a size or position it did not ask for.
        for (index, session) in sessions.enumerated() {
            session.applyLayout(in: workspace.bounds, visible: index == activeSessionIndex)
        }
        // applyLayout re-occludes hidden panes; while the canvas is up
        // they must keep rendering for their thumbnails.
        if canvasOverlay.superview != nil {
            applyCanvasOcclusion()
        }
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        applyTheme()
    }

    /// The divider lines between panes are the container background showing
    /// through the layout gaps; theming the container themes the dividers.
    private func applyTheme() {
        let palette = ThemeManager.shared.palette
        container.layer?.backgroundColor = palette.divider.cgColor
        window.backgroundColor = palette.divider
        if resizeOutlineHost != nil {
            showResizeOutline()
        }
    }

    // MARK: - Window delegate

    func windowDidBecomeKey(_: Notification) {
        if let pane = activeSession?.focusedPane {
            focus(pane)
        }
    }

    func windowDidChangeOcclusionState(_: Notification) {
        applyCanvasOcclusion()
    }

    func windowWillClose(_: Notification) {
        // The window is the app, so closing it is quitting: save while
        // the sessions are still alive, then detach - every pty survives
        // for the next launch. Killing ptys is only ever a per-pane act
        // (prefix X), never a side effect of the app going away.
        App.delegate.beginTermination(reason: "window closed")
        for session in sessions {
            session.destroyAllSurfaces()
        }
        sessions.removeAll()
        App.delegate.windowControllerDidClose(self)
    }

    /// Frame changes fire continuously during drags and live resizes;
    /// save debounced so a crash mid-session still restores the frame.
    func windowDidMove(_: Notification) {
        saveStateSoon()
    }

    func windowDidResize(_: Notification) {
        saveStateSoon()
    }

    func saveState() {
        App.delegate.saveSnapshot()
    }

    func saveStateSoon() {
        App.delegate.saveSnapshotSoon()
    }
}

/// A container view with top-left origin so tree layout math is direct.
final class PaneContainerView: NSView {
    weak var controller: MuxWindowController?
    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        controller?.layoutPanes()
    }
}


/// Borderless, square-cornered window. Borderless windows refuse
/// key/main status by default, so both are overridden.
final class MuxWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
