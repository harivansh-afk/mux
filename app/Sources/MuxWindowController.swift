import AppKit
import GhosttyKit

/// A container view with top-left origin so tree layout math is direct.
final class PaneContainerView: NSView {
    weak var controller: MuxWindowController?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        controller?.layoutPanes()
    }
}

/// One window = one workspace = one split tree of panes.
final class MuxWindowController: NSObject, NSWindowDelegate {
    let runtime: GhosttyRuntime
    private(set) var window: NSWindow!
    private let container = PaneContainerView()
    private let modeBar = ModeBarView()

    private(set) var tree: SplitNode?
    private(set) var panes: [UUID: PaneView] = [:]
    private(set) var focusedID: UUID?
    private(set) var zoomedID: UUID?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init()

        // Borderless: no titlebar, no traffic lights, square corners.
        // Edge-resizing works via .resizable; dragging via background.
        let window = MuxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
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
        self.window = window

        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .muxThemeDidChange, object: nil)
    }

    // MARK: - Pane lifecycle

    @discardableResult
    func addInitialPane(id: UUID = UUID(), workingDirectory: String? = nil) -> PaneView {
        let pane = makePane(id: id, workingDirectory: workingDirectory)
        tree = .leaf(pane.id)
        layoutPanes()
        focus(pane)
        return pane
    }

    private func makePane(id: UUID = UUID(), workingDirectory: String? = nil) -> PaneView {
        let pane = PaneView(id: id, runtime: runtime, workingDirectory: workingDirectory)
        pane.controller = self
        panes[pane.id] = pane
        container.addSubview(pane)
        return pane
    }

    /// Restore a whole tree from a snapshot.
    func restore(tree snapshotTree: SplitNode, paneMeta: [UUID: PaneSnapshot], focused: UUID?, zoomed: UUID?) {
        for id in snapshotTree.leaves {
            _ = makePane(id: id, workingDirectory: paneMeta[id]?.cwd)
        }
        self.tree = snapshotTree
        self.zoomedID = zoomed
        layoutPanes()
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
        layoutPanes()
        focus(newPane)
        saveState()
    }

    func split(from pane: PaneView, ghosttyDirection: ghostty_action_split_direction_e) {
        switch ghosttyDirection {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
            split(from: pane, direction: .horizontal)
        default:
            split(from: pane, direction: .vertical)
        }
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
            window.close()
            return
        }
        layoutPanes()
        if focusedID == pane.id, let next = panes[nextID] {
            focus(next)
        }
        saveState()
    }

    // MARK: - Focus

    var focusedPane: PaneView? {
        guard let focusedID else { return nil }
        return panes[focusedID]
    }

    func focus(_ pane: PaneView) {
        window.makeFirstResponder(pane)
    }

    /// Called by the pane when it actually becomes first responder.
    func noteFocused(_ pane: PaneView) {
        focusedID = pane.id
    }

    func focusDirection(_ direction: FocusDirection) {
        guard let tree, let focusedID else { return }
        let rects = tree.layout(in: container.bounds)
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
            layoutPanes()
            focus(pane)
        }
    }

    func focus(from pane: PaneView, ghosttyGoto dir: ghostty_action_goto_split_e) {
        switch dir {
        case GHOSTTY_GOTO_SPLIT_LEFT: focusDirection(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: focusDirection(.right)
        case GHOSTTY_GOTO_SPLIT_UP: focusDirection(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: focusDirection(.down)
        default: break
        }
    }

    // MARK: - Zoom and resize

    func toggleZoom() {
        guard let focusedID else { return }
        zoomedID = (zoomedID == focusedID) ? nil : focusedID
        layoutPanes()
    }

    func resizeFocused(_ direction: FocusDirection, step: Double = 0.03) {
        guard let tree, let focusedID else { return }
        let axis: SplitDirection = (direction == .left || direction == .right) ? .horizontal : .vertical
        // Growing toward right/down grows whichever side the pane is on;
        // express as a first-child delta by probing the layout result.
        let delta: Double = (direction == .right || direction == .down) ? step : -step
        let before = tree.layout(in: container.bounds)[focusedID]
        var (adjusted, found) = tree.adjustingRatio(around: focusedID, axis: axis, delta: delta)
        if found {
            // If the focused pane shrank in the intended growth direction,
            // flip the sign (it was the second child).
            let after = adjusted.layout(in: container.bounds)[focusedID]
            if let b = before, let a = after {
                let grew = axis == .horizontal ? a.width >= b.width : a.height >= b.height
                let wantedGrowth = (direction == .right || direction == .down)
                if grew != wantedGrowth {
                    (adjusted, _) = tree.adjustingRatio(around: focusedID, axis: axis, delta: -delta)
                }
            }
            self.tree = adjusted
            layoutPanes()
            saveState()
        }
    }

    // MARK: - Layout

    /// Show or hide the mode overlay. nil hides it. Like herdr, the bar is
    /// an overlay on the bottom row: panes never reflow for it.
    func setModeIndicator(_ segments: [ModeBarSegment]?) {
        if let segments {
            modeBar.render(segments)
            modeBar.isHidden = false
            // Keep the overlay above any panes added since last time.
            modeBar.removeFromSuperview()
            container.addSubview(modeBar)
            positionModeBar()
        } else {
            modeBar.isHidden = true
        }
    }

    /// Content-sized box floating at the bottom-left, inset by the same
    /// margin from the left and bottom edges (container is flipped, so
    /// the bottom is at maxY).
    private func positionModeBar() {
        let bounds = container.bounds
        let margin = ModeBarView.margin
        let width = min(modeBar.desiredWidth, bounds.width - margin * 2)
        modeBar.frame = NSRect(
            x: margin,
            y: bounds.height - ModeBarView.height - margin,
            width: width,
            height: ModeBarView.height)
    }

    func layoutPanes() {
        guard let tree else { return }
        let bounds = container.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        if !modeBar.isHidden { positionModeBar() }

        if let zoomedID, let zoomed = panes[zoomedID] {
            for (_, pane) in panes {
                pane.isHidden = pane.id != zoomedID
            }
            zoomed.frame = bounds
            return
        }

        let rects = tree.layout(in: bounds)
        for (id, pane) in panes {
            if let rect = rects[id] {
                pane.isHidden = false
                pane.frame = rect
            } else {
                pane.isHidden = true
            }
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

    func windowDidBecomeKey(_ notification: Notification) {
        if let pane = focusedPane { focus(pane) }
    }

    func windowWillClose(_ notification: Notification) {
        for (_, pane) in panes { pane.destroySurface() }
        panes.removeAll()
        tree = nil
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }

    func saveState() {
        (NSApp.delegate as? AppDelegate)?.saveSnapshot()
    }
}
