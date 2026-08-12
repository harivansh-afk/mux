import AppKit

/// The window's chrome: the floating mode bar, the session indicator, the
/// keybinds overlay, and the canvas and hosts windows. All of them are
/// overlays on the
/// pane area - panes never reflow for them - and none of them ever takes
/// focus: PrefixEngine owns the keys and drives them from the outside
/// (the canvas additionally takes clicks, which also route through the
/// engine to leave the mode).
extension MuxWindowController {
    /// Show or hide the mode overlay. nil hides it. The bar is an overlay
    /// on the bottom row: panes never reflow for it.
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
    func positionModeBar() {
        let bounds = container.bounds
        let margin = ModeBarView.margin
        let width = min(modeBar.desiredWidth, bounds.width - margin * 2)
        modeBar.frame = NSRect(
            x: margin,
            y: bounds.height - ModeBarView.height - margin,
            width: width,
            height: ModeBarView.height
        )
    }

    // MARK: - Session indicator

    /// `1 2 3` with the active number highlighted. Mirrors the mode bar
    /// across the bottom edge with the same concentric insets.
    private var sessionSegments: [ModeBarSegment] {
        var segments: [ModeBarSegment] = []
        for index in sessions.indices {
            if index > 0 {
                segments.append(.dim(" "))
            }
            let label = "\(index + 1)"
            segments.append(
                index == activeSessionIndex ? .highlight(label) : .dim(label)
            )
        }
        return segments
    }

    /// Always visible at the bottom-right; re-rendered whenever sessions
    /// are created, closed, switched or restored.
    func updateSessionIndicator() {
        sessionIndicator.render(sessionSegments)
        positionSessionIndicator()
    }

    /// Bottom-right corner (the container is flipped, so the bottom is
    /// maxY), level with the mode bar in the opposite corner.
    func positionSessionIndicator() {
        let bounds = container.bounds
        let margin = ModeBarView.margin
        let width = min(sessionIndicator.desiredWidth, bounds.width - margin * 2)
        sessionIndicator.frame = NSRect(
            x: bounds.width - margin - width,
            y: bounds.height - ModeBarView.height - margin,
            width: width,
            height: ModeBarView.height
        )
    }

    // MARK: - Keybinds overlay

    func showHelp() {
        // Keep the overlay above any panes added since last time.
        helpOverlay.removeFromSuperview()
        container.addSubview(helpOverlay)
        positionHelpOverlay()
    }

    func hideHelp() {
        helpOverlay.removeFromSuperview()
    }

    func positionHelpOverlay() {
        center(helpOverlay, size: helpOverlay.desiredSize(in: container.bounds))
    }

    // MARK: - Hosts window

    /// prefix t: where a pane can live - local, the aliases with a live
    /// probe, the ix VMs. Every query fires on open, so the box fills in as
    /// answers arrive; the view's sticky sizing keeps the box from moving
    /// while they land.
    func showHostsWindow() {
        hostsWindow.onContentChange = { [weak self] in self?.positionHostsWindow() }
        hostsWindow.reload()
        hostsWindow.removeFromSuperview()
        container.addSubview(hostsWindow)
        positionHostsWindow()
    }

    func hideHostsWindow() {
        hostsWindow.removeFromSuperview()
    }

    func moveHostsWindow(by delta: Int) {
        hostsWindow.move(by: delta)
        positionHostsWindow()
    }

    /// True while the template list is up, so esc backs out of it rather
    /// than closing the window.
    var hostsWindowPickingTemplate: Bool {
        hostsWindow.pickingTemplate
    }

    /// t / esc: swap between the machines and the templates a new VM would
    /// be built from. Coming back does not re-probe: the answers the hosts
    /// already gave are still on screen.
    func showHostsTemplates() {
        hostsWindow.showTemplates()
        positionHostsWindow()
    }

    func showHostsMachines() {
        hostsWindow.showHosts()
        positionHostsWindow()
    }

    /// Enter in the template list: persist the highlighted `ix new` target
    /// as the default for new VMs.
    func commitHostsTemplate() {
        hostsWindow.commitTemplate()
        positionHostsWindow()
    }

    /// y: the client identity digest onto the clipboard, for pasting into a
    /// host's authorized list.
    func copyClientDigest() {
        hostsWindow.copyDigest()
        positionHostsWindow()
    }

    /// Enter / H J K L: split the focused pane into the highlighted machine.
    /// Rows that cannot host a pane are not selectable, so a nil selection
    /// means there is nothing to open (which is not the same as `local`,
    /// hence NewPaneTarget rather than a bare string).
    func commitHostsWindow(direction: SplitDirection, before: Bool = false) {
        guard let target = hostsWindow.selectedHost else { return }
        split(direction: direction, before: before, target: target)
    }

    /// c: a whole new session on the highlighted machine, rather than a
    /// split beside the pane you were in.
    func newSessionOnHostsSelection() {
        guard let target = hostsWindow.selectedHost else { return }
        newSession(target: target)
    }

    /// n: create a VM and open a pane on it. mux names the machine up front,
    /// so the pane's target is `ix:<name>` from the first frame: the pane is
    /// the creation progress and then the shell, and a restore later derives
    /// `ix shell <name>` from that target - by which time the VM exists.
    func createIXVM() {
        let name = IX.newVMName()
        split(
            direction: .horizontal,
            target: .explicit(IX.prefix + name),
            ptyCommand: [IX.binary, "new", "-n", name, IXConfig.template()]
        )
    }

    func positionHostsWindow() {
        center(hostsWindow, size: hostsWindow.desiredSize(in: container.bounds))
    }

    // MARK: - Canvas panel

    /// The panel's share of the window; the workspace slides left by
    /// exactly this much, so the two motions read as one push.
    var canvasPanelWidth: CGFloat {
        (container.bounds.width * 0.38).rounded()
    }

    /// A sidebar needs real width to be readable; when the window can't
    /// give it that (half-screen and narrower), the canvas docks to the
    /// bottom edge as a full-width bar instead, and the workspace slides
    /// up by the bar's height.
    var canvasDocksBottom: Bool {
        canvasPanelWidth < 320
    }

    var canvasPanelHeight: CGFloat {
        min(320, (container.bounds.height * 0.35).rounded())
    }

    /// One spring for everything canvas - slab and panel share it so
    /// they always land together. Tuned for speed: response
    /// ~0.18s, essentially critically damped (no bounce tax), arrival
    /// reads at roughly 130ms. Retargetable: spamming open/close bends
    /// the motion from its current on-screen position, never restarts.
    private static let canvasStiffness: CGFloat = 1200
    private static let canvasDamping: CGFloat = 68

    private static func canvasSpring(_ keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.stiffness = canvasStiffness
        spring.damping = canvasDamping
        spring.mass = 1
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Where a view visually is right now (mid-flight included), so a
    /// new spring picks up from there.
    private func presentedPosition(of view: NSView) -> CGPoint? {
        view.layer.map { $0.presentation()?.position ?? $0.position }
    }

    /// Run `changes` (which parks the workspace slab and the panel at
    /// their model positions), then spring both from wherever they were.
    private func slideCanvas(_ changes: () -> Void) {
        let workspaceFrom = presentedPosition(of: workspace)
        let panelFrom = presentedPosition(of: canvasOverlay)
        changes()
        for (view, from) in [(workspace, workspaceFrom), (canvasOverlay, panelFrom)] {
            guard let layer = view.layer, let from, from != layer.position else { continue }
            let spring = Self.canvasSpring("position")
            spring.fromValue = from
            layer.add(spring, forKey: "canvas-slide")
        }
    }

    /// The spring outlives the mode change; tear the panel down only
    /// after it settles, and only if nobody reopened it meanwhile.
    private func scheduleCanvasTeardown() {
        let settle = Self.canvasSpring("position").settlingDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, !canvasOpen, canvasClosing else { return }
            canvasClosing = false
            canvasOverlay.removeFromSuperview()
            applyCanvasOcclusion()
        }
    }

    /// prefix f: every pane in the window as a live card, stacked in a
    /// right panel, grouped by session. The panel slides in while the
    /// workspace slides out left. Rebuilt from the live session model on
    /// every open; the highlight starts on the focused pane. While the
    /// canvas is up, every pane is un-occluded so its renderer keeps
    /// producing the frames the thumbnails mirror; hide restores the
    /// normal rule.
    func showCanvasOverlay() {
        canvasOverlay.reload(groups: canvasGroups(), selected: focusedPane?.id)
        canvasOverlay.onJump = { [weak self] entry in
            self?.commitCanvas(entry)
            (NSApp.delegate as? AppDelegate)?.prefixEngine.endCanvas()
        }
        if canvasOverlay.superview == nil {
            container.addSubview(canvasOverlay)
            // Start just offscreen at the final size (canvasOpen is
            // still false, so this parks it), so the slide-in is the
            // only motion.
            positionCanvasOverlay()
            canvasOverlay.layoutSubtreeIfNeeded()
        }
        // The floating badges stay above the panel (they overlap it when
        // it docks bottom); layoutPanes re-lifts the session indicator,
        // the mode bar needs it here.
        if !modeBar.isHidden {
            modeBar.removeFromSuperview()
            container.addSubview(modeBar)
            positionModeBar()
        }
        // Reopening mid-close: the pending teardown sees canvasOpen and
        // stands down; the spring retargets from wherever the panel is.
        canvasClosing = false
        canvasOpen = true
        applyCanvasOcclusion()
        slideCanvas { [self] in
            layoutPanes()
            positionCanvasOverlay()
        }
    }

    func hideCanvasOverlay() {
        guard canvasOverlay.superview != nil, !canvasClosing else { return }
        canvasClosing = true
        canvasOpen = false
        slideCanvas { [self] in
            layoutPanes()
            positionCanvasOverlay()
        }
        scheduleCanvasTeardown()
    }

    func moveCanvasOverlay(by delta: Int) {
        canvasOverlay.move(by: delta)
    }

    /// Canvas open: every pane renders (the thumbnails are live).
    /// Canvas closed: back to "visible window AND active session".
    func applyCanvasOcclusion() {
        let windowVisible = window.occlusionState.contains(.visible)
        let canvasOpen = canvasOverlay.superview != nil
        for session in sessions {
            for (_, pane) in session.panes {
                pane.setOcclusion(visible: windowVisible && (canvasOpen || !pane.isHidden))
            }
        }
    }

    /// Enter / click: jump to the selected pane, switching session if
    /// needed and unzooming whatever covers it. The resume is the same
    /// motion as esc - the workspace slides home as the panel leaves -
    /// with focus landing on the chosen pane immediately. No extra
    /// theater.
    func commitCanvas() {
        guard let entry = canvasOverlay.selection else { return }
        commitCanvas(entry)
    }

    func commitCanvas(_ entry: CanvasOverlayView.Entry) {
        guard sessions.indices.contains(entry.sessionIndex) else { return }
        let session = sessions[entry.sessionIndex]
        guard let pane = session.panes[entry.paneID] else { return }
        guard canvasOverlay.superview != nil, !canvasClosing else { return }
        canvasClosing = true
        canvasOpen = false
        slideCanvas { [self] in
            selectSession(entry.sessionIndex)
            session.reveal(pane)
            layoutPanes()
            positionCanvasOverlay()
        }
        scheduleCanvasTeardown()
    }

    /// The panel owns the right edge - or the bottom one when the window
    /// is too narrow for a sidebar. Closed (or closing) it parks just
    /// offscreen so layout passes never fight the slide-out.
    func positionCanvasOverlay() {
        let bounds = container.bounds
        let docksBottom = canvasDocksBottom
        canvasOverlay.docksBottom = docksBottom
        if docksBottom {
            // The container is flipped: the bottom edge is maxY.
            canvasOverlay.frame = NSRect(
                x: 0,
                y: canvasOpen ? bounds.height - canvasPanelHeight : bounds.height,
                width: bounds.width,
                height: canvasPanelHeight
            )
        } else {
            canvasOverlay.frame = NSRect(
                x: canvasOpen ? bounds.width - canvasPanelWidth : bounds.width,
                y: 0,
                width: canvasPanelWidth,
                height: bounds.height
            )
        }
    }

    /// Canvas rows: sessions in order, panes in tree (visual) order.
    private func canvasGroups() -> [CanvasOverlayView.Group] {
        sessions.enumerated().map { sessionIndex, session in
            var entries: [CanvasOverlayView.Entry] = []
            for (paneIndex, paneID) in (session.tree?.leaves ?? []).enumerated() {
                guard let pane = session.panes[paneID] else { continue }
                entries.append(CanvasOverlayView.Entry(
                    sessionIndex: sessionIndex,
                    paneID: paneID,
                    index: "\(sessionIndex + 1).\(paneIndex + 1)",
                    pane: pane
                ))
            }
            return CanvasOverlayView.Group(
                title: "session \(sessionIndex + 1)",
                entries: entries,
                tree: session.tree,
                current: sessionIndex == activeSessionIndex
            )
        }
    }

    /// Centered boxes (keybinds, picker) share one placement rule.
    private func center(_ view: NSView, size: NSSize) {
        let bounds = container.bounds
        view.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
