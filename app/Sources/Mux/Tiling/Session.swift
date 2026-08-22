import AppKit

/// Where a pane being created should live: inherited from the pane it is
/// split from, or chosen explicitly (nil = the local daemon).
enum NewPaneTarget {
    case inherit
    case explicit(String?)

    /// What a new pane starts from, given the pane it comes from: the
    /// host it lives on, and the source's live working directory when it
    /// stays on the same machine (a path from another machine means
    /// nothing here, and an ix pty's local cwd is where `ix shell`
    /// started, not where the shell in the VM is). The directory is
    /// resolved daemon-side from the source pane's process (cwdFrom);
    /// pwd rides along only as the new pane's label seed, and can be
    /// stale on a remote shell that never reports OSC 7.
    func seed(from source: PaneView?) -> (target: String?, cwd: String?, cwdFrom: UUID?) {
        let target: String? = switch self {
        case .inherit: source?.target
        case let .explicit(explicit): explicit
        }
        guard let source, target == source.target, IX.vm(of: target) == nil else {
            return (target, nil, nil)
        }
        return (target, source.pwd, source.id)
    }
}

/// One session: a split tree of panes with its focus and zoom state.
/// The unit the user switches between and the unit of layout persistence.
///
/// Sessions are pure client-owned layout. The daemon side (M2+) never
/// learns they exist: a pane's terminal content is addressed per-pane,
/// so one session can span machines. Window chrome stays in
/// MuxWindowController; Session reaches it only through narrow hooks
/// (attach, focus, layoutPanes, saveState, sessionDidEmpty).
final class Session {
    private weak var controller: MuxWindowController?

    private(set) var tree: SplitNode?
    private(set) var panes: [UUID: PaneView] = [:]
    private(set) var focusedID: UUID?
    private(set) var zoomedID: UUID?

    init(controller: MuxWindowController) {
        self.controller = controller
    }

    /// The session as the state file stores it. nil while there is no
    /// tree: an empty session is not written.
    var snapshot: SessionSnapshot? {
        guard let tree else { return nil }
        return SessionSnapshot(
            tree: tree,
            panes: panes.mapValues {
                PaneSnapshot(
                    cwd: $0.pwd, target: $0.target,
                    fontDelta: $0.fontDelta == 0 ? nil : $0.fontDelta
                )
            },
            focused: focusedID,
            zoomed: zoomedID
        )
    }

    /// The end of every structural change: drop a zoom that no longer
    /// applies, lay the tree out, focus, and put the new shape on disk
    /// before the next event. `save: false` is for the paths whose only
    /// change is focus - the debounced class - and for a restore, where
    /// the caller saves once the whole window is back.
    private func commit(
        focus pane: PaneView? = nil, unzoom: Bool = true,
        relayout: Bool = true, save: Bool = true
    ) {
        if unzoom {
            zoomedID = nil
        }
        if relayout {
            controller?.layoutPanes()
        }
        if let pane {
            focus(pane)
        }
        if save {
            controller?.saveState()
        }
    }

    var focusedPane: PaneView? {
        guard let focusedID else { return nil }
        return panes[focusedID]
    }

    func contains(_ pane: PaneView) -> Bool {
        panes[pane.id] != nil
    }

    // MARK: - Pane lifecycle

    @discardableResult
    func addInitialPane(
        id: UUID = UUID(), workingDirectory: String? = nil, cwdFrom: UUID? = nil,
        target: String? = nil
    ) -> PaneView {
        let pane = makePane(
            id: id, workingDirectory: workingDirectory, cwdFrom: cwdFrom, target: target
        )
        tree = .leaf(pane.id)
        commit(focus: pane, save: false)
        return pane
    }

    private func makePane(
        id: UUID = UUID(), workingDirectory: String? = nil, cwdFrom: UUID? = nil,
        target: String? = nil, ptyCommand: [String]? = nil,
        initialFrame: CGRect = .zero, fontDelta: Int = 0,
        expectExisting: Bool = false
    ) -> PaneView {
        let pane = PaneView(
            id: id, workingDirectory: workingDirectory, cwdFrom: cwdFrom,
            target: target, ptyCommand: ptyCommand, initialFrame: initialFrame,
            fontDelta: fontDelta, expectExisting: expectExisting
        )
        pane.controller = controller
        panes[pane.id] = pane
        controller?.attach(pane)
        return pane
    }

    /// Rebuild a whole tree from a snapshot.
    func restore(_ snapshot: SessionSnapshot) {
        // Size each pane before its surface spawns the attach command, so
        // the pty handshake carries the pane's real dimensions and the
        // daemon replays the screen at the size it was left at. A zoomed
        // pane was covering the whole container when the snapshot was
        // taken; the covered panes keep their tree rects, exactly as they
        // did pre-quit.
        let bounds = controller?.paneBounds ?? .zero
        let rects = snapshot.tree.layout(in: bounds)
        for id in snapshot.tree.leaves {
            let meta = snapshot.panes[id]
            _ = makePane(
                id: id, workingDirectory: meta?.cwd, target: meta?.target,
                initialFrame: (snapshot.zoomed == id) ? bounds : (rects[id] ?? bounds),
                fontDelta: meta?.fontDelta ?? 0, expectExisting: true
            )
        }
        tree = snapshot.tree
        zoomedID = snapshot.zoomed
        let focused = snapshot.focused.flatMap { panes[$0] }
            ?? snapshot.tree.leaves.first.flatMap { panes[$0] }
        commit(focus: focused, unzoom: false, save: false)
    }

    /// `before` puts the new pane on the left/top side of the split, which
    /// is how the hosts window offers all four directions.
    func split(
        from pane: PaneView? = nil,
        direction: SplitDirection,
        before: Bool = false,
        target: NewPaneTarget = .inherit,
        ptyCommand: [String]? = nil
    ) {
        guard let source = pane ?? focusedPane, let tree else { return }
        let seed = target.seed(from: source)
        // Splits inherit the source pane's font zoom, matching ghostty's
        // window-inherit-font-size default.
        let newPane = makePane(
            workingDirectory: seed.cwd, cwdFrom: seed.cwdFrom,
            target: seed.target, ptyCommand: ptyCommand,
            fontDelta: source.fontDelta
        )
        self.tree = tree.inserting(
            newPane.id, at: source.id, direction: direction, newFirst: before
        )
        commit(focus: newPane)
    }

    func closeFocusedPane() {
        guard let pane = focusedPane else { return }
        AppLog.log("kill pane=\(pane.id.uuidString) (prefix x)")
        pane.killRemote()
        pane.destroySurface()
        removePane(pane)
    }

    func removePane(_ pane: PaneView) {
        guard panes[pane.id] != nil else { return }
        AppLog.log("remove pane=\(pane.id.uuidString)")
        panes.removeValue(forKey: pane.id)
        pane.removeFromSuperview()
        pane.scrollHost?.removeFromSuperview()
        let wasZoomed = zoomedID == pane.id
        tree = tree?.removing(pane.id)
        guard let tree, let nextID = tree.leaves.first else {
            controller?.sessionDidEmpty(self)
            return
        }
        commit(
            focus: focusedID == pane.id ? panes[nextID] : nil,
            unzoom: wasZoomed
        )
    }

    // MARK: - Moving panes

    /// Move the focused pane one step through the layout (resize mode
    /// H/J/K/L). Unzooms first: a move under a zoom is invisible.
    func moveFocused(_ direction: FocusDirection) {
        guard let tree, let focusedID, let bounds = controller?.paneBounds else { return }
        let moved = tree.moving(focusedID, direction: direction, in: bounds)
        if let moved {
            self.tree = moved
        }
        commit(save: moved != nil)
    }

    /// Release a pane to another session: it leaves the tree with its
    /// surface and views untouched (the workspace hosts panes regardless
    /// of session). An emptied session closes like any other.
    func detach(_ pane: PaneView) {
        guard panes[pane.id] != nil else { return }
        panes.removeValue(forKey: pane.id)
        let wasZoomed = zoomedID == pane.id
        tree = tree?.removing(pane.id)
        if focusedID == pane.id {
            focusedID = tree?.leaves.first
        }
        guard tree != nil else {
            controller?.sessionDidEmpty(self)
            return
        }
        // The caller lays the window out: a pane leaving one session and
        // joining another is one move, not two.
        commit(unzoom: wasZoomed, relayout: false)
    }

    /// Take in a detached pane: split at the focused pane, or become the
    /// whole tree when the session is new.
    func adopt(_ pane: PaneView) {
        panes[pane.id] = pane
        if let tree, let at = focusedID ?? tree.leaves.first {
            self.tree = tree.inserting(pane.id, at: at, direction: .horizontal)
        } else {
            tree = .leaf(pane.id)
        }
        commit(focus: pane)
    }

    func destroyAllSurfaces() {
        for (_, pane) in panes {
            pane.destroySurface()
        }
        for (_, pane) in panes {
            pane.removeFromSuperview()
            pane.scrollHost?.removeFromSuperview()
        }
        panes.removeAll()
        tree = nil
    }

    // MARK: - Focus

    func focus(_ pane: PaneView) {
        controller?.focus(pane)
    }

    /// Called (via the controller) when a pane actually becomes first
    /// responder.
    func noteFocused(_ pane: PaneView) {
        guard focusedID != pane.id else { return }
        focusedID = pane.id
        controller?.saveStateSoon()
    }

    /// Jump focus straight to a pane (the panes overlay), unzooming
    /// whatever covers it first.
    func reveal(_ pane: PaneView) {
        guard panes[pane.id] != nil else { return }
        let covered = zoomedID != nil && zoomedID != pane.id
        commit(focus: pane, unzoom: covered, relayout: covered, save: false)
    }

    func focusDirection(_ direction: FocusDirection) {
        guard let tree, let focusedID, let bounds = controller?.paneBounds else { return }
        let rects = tree.layout(in: bounds)
        var target = SplitNode.neighbor(of: focusedID, direction: direction, rects: rects)
        if target == nil {
            // tmux-style edge fallback: wrap to the far side.
            let opposite: FocusDirection = switch direction {
            case .left: .right
            case .right: .left
            case .up: .down
            case .down: .up
            }
            var candidate = focusedID
            while let next = SplitNode.neighbor(of: candidate, direction: opposite, rects: rects) {
                candidate = next
            }
            target = candidate == focusedID ? nil : candidate
        }
        if let target, let pane = panes[target] {
            commit(focus: pane, save: false)
        }
    }

    // MARK: - Zoom and resize

    func toggleZoom() {
        guard let focusedID else { return }
        zoomedID = (zoomedID == focusedID) ? nil : focusedID
        commit(unzoom: false)
    }

    func resizeFocused(_ direction: FocusDirection, step: Double = 0.03) {
        guard let tree, let focusedID, let bounds = controller?.paneBounds else { return }
        let axis: SplitDirection = (direction == .left || direction == .right) ? .horizontal : .vertical
        // Growing toward right/down grows whichever side the pane is on;
        // express as a first-child delta by probing the layout result.
        let delta: Double = (direction == .right || direction == .down) ? step : -step
        let before = tree.layout(in: bounds)[focusedID]
        var (adjusted, found) = tree.adjustingRatio(around: focusedID, axis: axis, delta: delta)
        if found {
            // If the focused pane shrank in the intended growth direction,
            // flip the sign (it was the second child).
            let after = adjusted.layout(in: bounds)[focusedID]
            if let b = before, let a = after {
                let grew = axis == .horizontal ? a.width >= b.width : a.height >= b.height
                let wantedGrowth = (direction == .right || direction == .down)
                if grew != wantedGrowth {
                    (adjusted, _) = tree.adjustingRatio(around: focusedID, axis: axis, delta: -delta)
                }
            }
            self.tree = adjusted
            commit(unzoom: false)
        }
    }

    // MARK: - Layout

    /// Apply the tree layout to pane frames within `bounds`. An inactive
    /// session hides all its panes; their processes keep running but the
    /// renderer stops drawing them (occlusion).
    func applyLayout(in bounds: CGRect, visible: Bool = true) {
        guard visible else {
            for (_, pane) in panes {
                hide(pane)
            }
            return
        }
        guard let tree else { return }

        if let zoomedID, let zoomed = panes[zoomedID] {
            for (_, pane) in panes where pane.id != zoomedID {
                hide(pane)
            }
            show(zoomed, frame: bounds)
            return
        }

        let rects = tree.layout(in: bounds)
        for (id, pane) in panes {
            if let rect = rects[id] {
                show(pane, frame: rect)
            } else {
                hide(pane)
            }
        }
    }

    private func show(_ pane: PaneView, frame: CGRect) {
        // The scroll host is the laid-out view; it keeps the pane filling
        // its visible rect.
        let host = pane.scrollHost
        host?.isHidden = false
        host?.frame = frame
        pane.isHidden = false
        if host == nil {
            pane.frame = frame
        }
        pane.setOcclusion(visible: true)
    }

    private func hide(_ pane: PaneView) {
        pane.scrollHost?.isHidden = true
        pane.isHidden = true
        pane.setOcclusion(visible: false)
    }
}
