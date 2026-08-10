import AppKit

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
    func addInitialPane(id: UUID = UUID(), workingDirectory: String? = nil) -> PaneView {
        let pane = makePane(id: id, workingDirectory: workingDirectory)
        tree = .leaf(pane.id)
        controller?.layoutPanes()
        focus(pane)
        return pane
    }

    private func makePane(id: UUID = UUID(), workingDirectory: String? = nil) -> PaneView {
        let pane = PaneView(id: id, runtime: runtime, workingDirectory: workingDirectory)
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
        for id in snapshotTree.leaves {
            _ = makePane(id: id, workingDirectory: paneMeta[id]?.cwd)
        }
        self.tree = snapshotTree
        self.zoomedID = zoomed
        controller?.layoutPanes()
        if let focused, let pane = panes[focused] {
            focus(pane)
        } else if let first = snapshotTree.leaves.first, let pane = panes[first] {
            focus(pane)
        }
    }

    func split(from pane: PaneView? = nil, direction: SplitDirection) {
        guard let source = pane ?? focusedPane else { return }
        guard let tree else { return }
        zoomedID = nil
        // New panes inherit the source pane's cwd (OSC 7 / pwd action).
        let newPane = makePane(workingDirectory: source.pwd)
        self.tree = tree.inserting(newPane.id, at: source.id, direction: direction)
        controller?.layoutPanes()
        focus(newPane)
        controller?.saveState()
    }

    func closeFocusedPane() {
        guard let pane = focusedPane else { return }
        pane.destroySurface()
        removePane(pane)
    }

    func removePane(_ pane: PaneView) {
        guard panes[pane.id] != nil else { return }
        panes.removeValue(forKey: pane.id)
        pane.removeFromSuperview()
        if zoomedID == pane.id { zoomedID = nil }

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
        for (_, pane) in panes { pane.destroySurface() }
        for (_, pane) in panes { pane.removeFromSuperview() }
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

    func focusDirection(_ direction: FocusDirection) {
        guard let tree, let focusedID, let bounds = controller?.paneBounds else { return }
        let rects = tree.layout(in: bounds)
        var target = SplitNode.neighbor(of: focusedID, direction: direction, rects: rects)
        if target == nil {
            // tmux-style edge fallback: wrap to the far side.
            let opposite: FocusDirection
            switch direction {
            case .left: opposite = .right
            case .right: opposite = .left
            case .up: opposite = .down
            case .down: opposite = .up
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
            for (_, pane) in panes { hide(pane) }
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
        pane.isHidden = false
        pane.frame = frame
        pane.setOcclusion(visible: true)
    }

    private func hide(_ pane: PaneView) {
        pane.isHidden = true
        pane.setOcclusion(visible: false)
    }
}
