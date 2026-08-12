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

/// One window = window chrome (borderless NSWindow, mode bar, keybinds
/// overlay, target picker, theming) plus an ordered list of sessions.
/// Tiling state and pane lifecycle live in Session; the controller routes
/// operations to the active session (or, for pane-originated events, to
/// the session owning that pane).
///
/// The chrome itself lives in MuxWindowController+Overlays.swift.
final class MuxWindowController: NSObject, NSWindowDelegate {
    let runtime: GhosttyRuntime
    private(set) var window: NSWindow!

    /// Internal (not private): the overlay chrome is managed by
    /// MuxWindowController+Overlays.swift.
    let container = PaneContainerView()
    let modeBar = ModeBarView()
    let sessionIndicator = ModeBarView()
    let helpOverlay = HelpOverlayView()
    let panesOverlay = PanesOverlayView()
    let hostsWindow = HostsWindowView()

    private(set) var sessions: [Session] = []
    private(set) var activeSessionIndex = 0

    var activeSession: Session? {
        sessions.indices.contains(activeSessionIndex) ? sessions[activeSessionIndex] : nil
    }

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
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
        container.addSubview(modeBar)
        modeBar.isHidden = true
        container.addSubview(sessionIndicator)
        self.window = window

        sessions = [Session(runtime: runtime, controller: self)]
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

    /// Session hook: host a new pane view. The host chip is a sibling
    /// added right after its pane, so it draws above it; panes tile
    /// without overlap, so ordering against other panes never matters.
    func attach(_ pane: PaneView) {
        // Wrap the pane in its scroll view: the container owns the host,
        // the host owns the pane, and Session lays out the host.
        let host = PaneScrollView(pane: pane)
        pane.scrollHost = host
        container.addSubview(host)
        if let badge = pane.hostBadge {
            container.addSubview(badge)
        }
    }

    /// Session hook: the rect sessions lay their trees out in.
    var paneBounds: CGRect {
        container.bounds
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
        let source = activeSession?.focusedPane
        let sameHost = target.inheritsDirectory(from: source)
        let session = Session(runtime: runtime, controller: self)
        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        session.addInitialPane(
            workingDirectory: sameHost ? source?.pwd : nil,
            cwdFrom: sameHost ? source?.id : nil,
            target: target.resolved(from: source)
        )
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
        sessions = snapshots.map { _ in Session(runtime: runtime, controller: self) }
        activeSessionIndex = min(max(0, active), sessions.count - 1)
        for (index, snapshot) in snapshots.enumerated() {
            sessions[index].restore(
                tree: snapshot.tree, paneMeta: snapshot.panes,
                focused: snapshot.focused, zoomed: snapshot.zoomed
            )
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

    // MARK: - Focus

    func focus(_ pane: PaneView) {
        window.makeFirstResponder(pane)
    }

    /// Called by the pane when it actually becomes first responder.
    func noteFocused(_ pane: PaneView) {
        session(owning: pane)?.noteFocused(pane)
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
        if panesOverlay.superview != nil {
            positionPanesOverlay()
        }
        if hostsWindow.superview != nil {
            positionHostsWindow()
        }

        for (index, session) in sessions.enumerated() {
            session.applyLayout(in: bounds, visible: index == activeSessionIndex)
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
    }

    // MARK: - Window delegate

    func windowDidBecomeKey(_: Notification) {
        if let pane = focusedPane {
            focus(pane)
        }
    }

    /// Occluded surfaces stop rendering (ghostty renderer throttle).
    /// A pane draws only if the window is visible AND its session active.
    func windowDidChangeOcclusionState(_: Notification) {
        let windowVisible = window.occlusionState.contains(.visible)
        for session in sessions {
            for (_, pane) in session.panes {
                pane.setOcclusion(visible: windowVisible && !pane.isHidden)
            }
        }
    }

    func windowWillClose(_: Notification) {
        // A deliberate window close kills its daemon ptys. During app
        // termination this is a detach instead: survival across quit and
        // crash is the point of M2.
        let terminating = (NSApp.delegate as? AppDelegate)?.isTerminating ?? false
        for session in sessions {
            if !terminating {
                for (_, pane) in session.panes {
                    pane.killRemote()
                }
            }
            session.destroyAllSurfaces()
        }
        sessions.removeAll()
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
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
