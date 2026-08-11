import AppKit

/// Where a pane being created should live: inherited from the pane it is
/// split from, or chosen explicitly (nil = the local daemon).
enum NewPaneTarget {
    case inherit
    case explicit(String?)
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
    private let runtime: GhosttyRuntime

    private(set) var tree: SplitNode?
    private(set) var panes: [UUID: PaneView] = [:]
    private(set) var focusedID: UUID?
    private(set) var zoomedID: UUID?

    init(runtime: GhosttyRuntime, controller: MuxWindowController) {
        self.runtime = runtime
        self.controller = controller
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
        controller?.layoutPanes()
        focus(pane)
        return pane
    }

    private func makePane(
        id: UUID = UUID(), workingDirectory: String? = nil, cwdFrom: UUID? = nil,
        target: String? = nil, initialFrame: CGRect = .zero, fontDelta: Int = 0
    ) -> PaneView {
        let pane = PaneView(
            id: id, runtime: runtime, workingDirectory: workingDirectory, cwdFrom: cwdFrom,
            target: target, initialFrame: initialFrame, fontDelta: fontDelta
        )
        pane.controller = controller
        panes[pane.id] = pane
        controller?.attach(pane)
        return pane
    }

    /// Rebuild a whole tree from a snapshot.
    func restore(
        tree snapshotTree: SplitNode,
        paneMeta: [UUID: PaneSnapshot],
        focused: UUID?,
        zoomed: UUID?
    ) {
        // Size each pane before its surface spawns the attach command, so
        // the pty handshake carries the pane's real dimensions and the
        // daemon replays the screen at the size it was left at. A zoomed
        // pane was covering the whole container when the snapshot was
        // taken; the covered panes keep their tree rects, exactly as they
        // did pre-quit.
        let bounds = controller?.paneBounds ?? .zero
        let rects = snapshotTree.layout(in: bounds)
        for id in snapshotTree.leaves {
            let frame = (zoomed == id) ? bounds : (rects[id] ?? bounds)
            _ = makePane(
                id: id, workingDirectory: paneMeta[id]?.cwd, target: paneMeta[id]?.target,
                initialFrame: frame, fontDelta: paneMeta[id]?.fontDelta ?? 0
            )
        }
        tree = snapshotTree
        zoomedID = zoomed
        controller?.layoutPanes()
        if let focused, let pane = panes[focused] {
            focus(pane)
        } else if let first = snapshotTree.leaves.first, let pane = panes[first] {
            focus(pane)
        }
    }

    func split(
        from pane: PaneView? = nil,
        direction: SplitDirection,
        target: NewPaneTarget = .inherit
    ) {
        guard let source = pane ?? focusedPane else { return }
        guard let tree else { return }
        zoomedID = nil
        // New panes inherit the source pane's target, and its working
        // directory only when the targets match: a path from another
        // machine means nothing here, and vice versa. The directory is
        // resolved daemon-side from the source pane's live process
        // (cwdFrom); pwd (OSC 7, when shell integration provides it) is
        // an explicit override.
        let newTarget: String? = switch target {
        case .inherit: source.target
        case let .explicit(explicit): explicit
        }
        // An ix pane's pty runs `ix shell` on this machine, so its working
        // directory is wherever the daemon started and says nothing about
        // where you are inside the VM: never inherit it.
        let sameHost = newTarget == source.target && IX.vm(of: newTarget) == nil
        // Splits inherit the source pane's font zoom, matching ghostty's
        // window-inherit-font-size default.
        let newPane = makePane(
            workingDirectory: sameHost ? source.pwd : nil,
            cwdFrom: sameHost ? source.id : nil,
            target: newTarget, fontDelta: source.fontDelta
        )
        self.tree = tree.inserting(newPane.id, at: source.id, direction: direction)
        controller?.layoutPanes()
        focus(newPane)
        controller?.saveState()
    }

    func closeFocusedPane() {
        guard let pane = focusedPane else { return }
        pane.killRemote()
        pane.destroySurface()
        removePane(pane)
    }

    func removePane(_ pane: PaneView) {
        guard panes[pane.id] != nil else { return }
        panes.removeValue(forKey: pane.id)
        pane.removeFromSuperview()
        pane.scrollHost?.removeFromSuperview()
        pane.hostBadge?.removeFromSuperview()
        if zoomedID == pane.id {
            zoomedID = nil
        }

        tree = tree?.removing(pane.id)
        guard let tree, let nextID = tree.leaves.first else {
            controller?.sessionDidEmpty(self)
            return
        }
        controller?.layoutPanes()
        if focusedID == pane.id, let next = panes[nextID] {
            focus(next)
        }
        controller?.saveState()
    }

    func destroyAllSurfaces() {
        for (_, pane) in panes {
            pane.destroySurface()
        }
        for (_, pane) in panes {
            pane.removeFromSuperview()
            pane.scrollHost?.removeFromSuperview()
            pane.hostBadge?.removeFromSuperview()
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
        focusedID = pane.id
    }

    /// Jump focus straight to a pane (the panes overlay), unzooming
    /// whatever covers it first.
    func reveal(_ pane: PaneView) {
        guard panes[pane.id] != nil else { return }
        if let zoomedID, zoomedID != pane.id {
            self.zoomedID = nil
            controller?.layoutPanes()
        }
        focus(pane)
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
            zoomedID = nil
            controller?.layoutPanes()
            focus(pane)
        }
    }

    // MARK: - Zoom and resize

    func toggleZoom() {
        guard let focusedID else { return }
        zoomedID = (zoomedID == focusedID) ? nil : focusedID
        controller?.layoutPanes()
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
            controller?.layoutPanes()
            controller?.saveState()
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
        if let badge = pane.hostBadge {
            // The container is flipped, so the pane's top edge is minY.
            let margin = HostBadgeView.margin
            let width = min(badge.desiredWidth, frame.width - margin * 2)
            badge.frame = NSRect(
                x: frame.maxX - margin - width,
                y: frame.minY + margin,
                width: width,
                height: HostBadgeView.height
            )
            badge.isHidden = false
        }
        pane.setOcclusion(visible: true)
    }

    private func hide(_ pane: PaneView) {
        pane.scrollHost?.isHidden = true
        pane.isHidden = true
        pane.hostBadge?.isHidden = true
        pane.setOcclusion(visible: false)
    }
}
