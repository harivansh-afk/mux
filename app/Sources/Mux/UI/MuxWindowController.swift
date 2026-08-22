import AppKit
import GhosttyKit

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

/// The slab every pane lives on. The canvas slides this one view, so
/// the push is a single animated property instead of many pane frames
/// racing each other.
final class WorkspaceView: NSView {
    override var isFlipped: Bool {
        true
    }
}

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
    let workspace = WorkspaceView()
    let modeBar = ModeBarView()
    let sessionIndicator = ModeBarView()
    let helpOverlay = HelpOverlayView()
    let canvasOverlay = CanvasOverlayView()
    let hostsWindow = HostsWindowView()

    private(set) var sessions: [Session] = []
    private(set) var activeSessionIndex = 0

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
    var paneLabels: [PaneLabelView] = []

    /// The scroll host wearing the resize-mode outline (managed by
    /// MuxWindowController+Overlays.swift). Non-nil only while resize
    /// mode is up.
    weak var resizeOutlineHost: PaneScrollView?

    var activeSession: Session? {
        sessions.indices.contains(activeSessionIndex) ? sessions[activeSessionIndex] : nil
    }

    override init() {
        super.init()

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
        container.addSubview(workspace)
        container.addSubview(modeBar)
        modeBar.isHidden = true
        container.addSubview(sessionIndicator)
        self.window = window

        sessions = [Session(controller: self)]
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

    /// Session hook: host a new pane view.
    func attach(_ pane: PaneView) {
        // Wrap the pane in its scroll view: the workspace slab owns the
        // host, the host owns the pane, and Session lays out the host.
        let host = PaneScrollView(pane: pane)
        pane.scrollHost = host
        workspace.addSubview(host)
    }

    /// Session hook: the rect sessions lay their trees out in.
    var paneBounds: CGRect {
        workspace.bounds
    }

    /// Session hook: last pane in the session closed. The session closes;
    /// the last session closing closes the window.
    func sessionDidEmpty(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        guard !sessions.isEmpty else {
            window.close()
            return
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

    /// prefix c: a new session with one pane. It follows the focused pane's
    /// host and working directory (resolved daemon-side from its live
    /// process), or the machine the hosts window named - in which case
    /// there is no directory to inherit.
    func newSession(target: NewPaneTarget = .inherit) {
        let seed = target.seed(from: activeSession?.focusedPane)
        let session = Session(controller: self)
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

    /// resize c: break the focused pane out into its own new session.
    /// A sole pane already is one; no-op.
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

    /// resize 1..9: move the focused pane into that session, following
    /// it. The pane splits at the target's focused pane; a source session
    /// this empties closes (which is why the target is found again by
    /// identity after the detach).
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

    /// prefix 1..9: select a session by position (0-based here).
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

    // MARK: - Tiling API (forwarded to the active session)

    var focusedPane: PaneView? {
        activeSession?.focusedPane
    }

    @discardableResult
    func addInitialPane(
        id: UUID = UUID(), workingDirectory: String? = nil, cwdFrom: UUID? = nil,
        target: String? = nil
    ) -> PaneView? {
        activeSession?.addInitialPane(
            id: id, workingDirectory: workingDirectory, cwdFrom: cwdFrom, target: target
        )
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

    func split(
        direction: SplitDirection,
        before: Bool = false,
        target: NewPaneTarget = .inherit,
        ptyCommand: [String]? = nil
    ) {
        activeSession?.split(
            direction: direction, before: before, target: target, ptyCommand: ptyCommand
        )
    }

    func split(from pane: PaneView, ghosttyDirection: ghostty_action_split_direction_e) {
        let session = session(owning: pane) ?? activeSession
        switch ghosttyDirection {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
            session?.split(from: pane, direction: .horizontal)
        default:
            session?.split(from: pane, direction: .vertical)
        }
    }

    func closeFocusedPane() {
        activeSession?.closeFocusedPane()
    }

    func removePane(_ pane: PaneView) {
        (session(owning: pane) ?? activeSession)?.removePane(pane)
    }

    func focusDirection(_ direction: FocusDirection) {
        activeSession?.focusDirection(direction)
    }

    func focus(from _: PaneView, ghosttyGoto dir: ghostty_action_goto_split_e) {
        switch dir {
        case GHOSTTY_GOTO_SPLIT_LEFT: focusDirection(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: focusDirection(.right)
        case GHOSTTY_GOTO_SPLIT_UP: focusDirection(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: focusDirection(.down)
        default: break
        }
    }

    func toggleZoom() {
        activeSession?.toggleZoom()
    }

    func resizeFocused(_ direction: FocusDirection, step: Double = 0.03) {
        activeSession?.resizeFocused(direction, step: step)
    }

    func moveFocusedPane(_ direction: FocusDirection) {
        activeSession?.moveFocused(direction)
    }

    // MARK: - Focus

    func focus(_ pane: PaneView) {
        window.makeFirstResponder(pane)
    }

    /// Called by the pane when it actually becomes first responder.
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

        if !modeBar.isHidden {
            positionModeBar()
        }
        // Always visible: keep it above panes added since the last layout
        // and glued to the top-right through resizes.
        if container.subviews.last !== sessionIndicator {
            sessionIndicator.removeFromSuperview()
            container.addSubview(sessionIndicator)
        }
        positionSessionIndicator()
        if helpOverlay.superview != nil {
            positionHelpOverlay()
        }
        if canvasOverlay.superview != nil {
            positionCanvasOverlay()
        }
        if hostsWindow.superview != nil {
            positionHostsWindow()
        }
        if !paneLabels.isEmpty {
            positionPaneLabels()
        }

        // The workspace never moves for the canvas: the picker floats
        // above it and the scrim dims it in place. Sizes and positions
        // untouched, so the ptys see nothing.
        workspace.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
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
        if let pane = focusedPane {
            focus(pane)
        }
    }

    /// Occluded surfaces stop rendering (ghostty renderer throttle).
    /// A pane draws only if the window is visible AND its session active -
    /// or the canvas overlay is up, whose thumbnails mirror every pane.
    func windowDidChangeOcclusionState(_: Notification) {
        applyCanvasOcclusion()
    }

    func windowWillClose(_: Notification) {
        // The window is the app, so closing it is quitting: save while
        // the sessions are still alive, then detach - every pty survives
        // for the next launch. Killing ptys is only ever a per-pane act
        // (prefix x), never a side effect of the app going away.
        let delegate = NSApp.delegate as? AppDelegate
        delegate?.beginTermination(reason: "window closed")
        for session in sessions {
            session.destroyAllSurfaces()
        }
        sessions.removeAll()
        delegate?.windowControllerDidClose(self)
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
        (NSApp.delegate as? AppDelegate)?.saveSnapshot()
    }

    func saveStateSoon() {
        (NSApp.delegate as? AppDelegate)?.saveSnapshotSoon()
    }
}
