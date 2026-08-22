import AppKit

extension MuxWindowController {
    /// Show or hide the mode overlay. nil hides it. The bar is an overlay
    /// on the bottom row: panes never reflow for it.
    func setModeIndicator(_ segments: [ModeBarSegment]?) {
        if let segments {
            modeBar.render(segments)
            modeBar.isHidden = false
            modeBar.removeFromSuperview()
            container.addSubview(modeBar)
            positionModeBar()
        } else {
            modeBar.isHidden = true
        }
    }

    /// Content-sized box floating at the bottom-left, inset by the same
    /// margin from the left and bottom edges.
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

    /// `1 2 3` with the active number highlighted - or, while the canvas
    /// is up, the session of the selected card, so the numbers follow
    /// the scroll live. Mirrors the mode bar across the bottom edge with
    /// the same concentric insets.
    private var sessionSegments: [ModeBarSegment] {
        let highlighted = canvasSessionHighlight ?? activeSessionIndex
        var segments: [ModeBarSegment] = []
        for index in sessions.indices {
            if index > 0 {
                segments.append(.dim(" "))
            }
            let label = "\(index + 1)"
            segments.append(
                index == highlighted ? .highlight(label) : .dim(label)
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

    /// Bottom-right corner, level with the mode bar in the opposite corner.
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

    var hostsWindowPickingTemplate: Bool {
        hostsWindow.pickingTemplate
    }

    /// Coming back does not re-probe: the answers the hosts already gave are still on screen.
    func showHostsTemplates() {
        hostsWindow.showTemplates()
        positionHostsWindow()
    }

    func showHostsMachines() {
        hostsWindow.showHosts()
        positionHostsWindow()
    }

    func commitHostsTemplate() {
        hostsWindow.commitTemplate()
        positionHostsWindow()
    }

    /// For pasting into a host's authorized list.
    func copyClientDigest() {
        hostsWindow.copyDigest()
        positionHostsWindow()
    }

    /// Rows that cannot host a pane are not selectable, so a nil selection
    /// means there is nothing to open (which is not the same as `local`,
    /// hence NewPaneTarget rather than a bare string).
    func commitHostsWindow(direction: SplitDirection, before: Bool = false) {
        guard let target = hostsWindow.selectedHost else { return }
        split(direction: direction, before: before, target: target)
    }

    func newSessionOnHostsSelection() {
        guard let target = hostsWindow.selectedHost else { return }
        newSession(target: target)
    }

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

    // MARK: - Canvas picker

    /// The canvas comes and goes as one quick fade - fast enough to read as a keystroke.
    private static let canvasFade: CFTimeInterval = 0.14

    /// Retargetable: reopening mid-close bends the fade from wherever
    /// the overlay's opacity currently is, never restarts it.
    private func fadeCanvas(to opacity: Float) {
        guard let layer = canvasOverlay.layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = opacity
        guard from != opacity else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.duration = Self.canvasFade
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(fade, forKey: "canvas-fade")
    }

    /// The fade outlives the mode change; tear the overlay down only
    /// after it lands, and only if nobody reopened it meanwhile.
    private func scheduleCanvasTeardown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.canvasFade + 0.02) { [weak self] in
            guard let self, !canvasOpen, canvasClosing else { return }
            canvasClosing = false
            canvasOverlay.removeFromSuperview()
            applyCanvasOcclusion()
        }
    }

    /// Rebuilt from the live session model on every open; the selection starts on the focused pane.
    func showCanvasOverlay() {
        refreshPaneDirectories()
        canvasOverlay.onSelectionChange = { [weak self] entry in
            self?.canvasSessionHighlight = entry?.sessionIndex
            self?.updateSessionIndicator()
        }
        canvasOverlay.reload(groups: canvasGroups(), selected: focusedPane?.id)
        canvasOverlay.onJump = { [weak self] entry in
            self?.commitCanvas(entry)
            (NSApp.delegate as? AppDelegate)?.prefixEngine.endCanvas()
        }
        canvasOverlay.onCancel = {
            (NSApp.delegate as? AppDelegate)?.prefixEngine.endCanvas()
        }
        if canvasOverlay.superview == nil {
            canvasOverlay.layer?.opacity = 0
            container.addSubview(canvasOverlay)
            positionCanvasOverlay()
            canvasOverlay.layoutSubtreeIfNeeded()
        }
        // The floating badges stay above the overlay; layoutPanes
        // re-lifts the session indicator, the mode bar needs it here.
        if !modeBar.isHidden {
            modeBar.removeFromSuperview()
            container.addSubview(modeBar)
            positionModeBar()
        }
        // Reopening mid-close: the pending teardown sees canvasOpen and
        // stands down; the fade retargets from wherever it is.
        canvasClosing = false
        canvasOpen = true
        applyCanvasOcclusion()
        layoutPanes()
        fadeCanvas(to: 1)
    }

    func hideCanvasOverlay() {
        guard canvasOverlay.superview != nil, !canvasClosing else { return }
        canvasClosing = true
        canvasOpen = false
        canvasSessionHighlight = nil
        updateSessionIndicator()
        fadeCanvas(to: 0)
        scheduleCanvasTeardown()
    }

    func moveCanvasOverlay(by delta: Int) {
        canvasOverlay.move(by: delta)
    }

    func applyCanvasOcclusion() {
        let windowVisible = window.occlusionState.contains(.visible)
        let canvasOpen = canvasOverlay.superview != nil
        for session in sessions {
            for (_, pane) in session.panes {
                pane.setOcclusion(visible: windowVisible && (canvasOpen || !pane.isHidden))
            }
        }
    }

    /// Switches session if needed and unzooms whatever covers the pane.
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
        canvasSessionHighlight = nil
        selectSession(entry.sessionIndex)
        updateSessionIndicator()
        session.reveal(pane)
        layoutPanes()
        fadeCanvas(to: 0)
        scheduleCanvasTeardown()
    }

    func positionCanvasOverlay() {
        canvasOverlay.frame = container.bounds
    }

    /// Wheel rows: sessions in order, panes in tree (visual) order.
    private func canvasGroups() -> [CanvasOverlayView.Group] {
        sessions.enumerated().map { sessionIndex, session in
            var entries: [CanvasOverlayView.Entry] = []
            for paneID in session.tree?.leaves ?? [] {
                guard let pane = session.panes[paneID] else { continue }
                entries.append(CanvasOverlayView.Entry(
                    sessionIndex: sessionIndex,
                    paneID: paneID,
                    pane: pane
                ))
            }
            return CanvasOverlayView.Group(entries: entries)
        }
    }

    /// Each canvas open asks the daemons for every pty's live cwd once
    /// (a discrete action, not a poll) and fills in whatever OSC 7 has not.
    func refreshPaneDirectories() {
        var hosts: Set<String?> = []
        var panesByID: [UUID: PaneView] = [:]
        for session in sessions {
            for (id, pane) in session.panes {
                // ix panes excluded: their local pty cwd is where `ix
                // shell` started, not where the shell in the VM is.
                guard IX.vm(of: pane.target) == nil else { continue }
                hosts.insert(pane.target)
                panesByID[id] = pane
            }
        }
        for host in hosts {
            Muxd.list(host: host) { listings in
                for listing in listings ?? [] {
                    guard let id = UUID(uuidString: listing.name),
                          let pane = panesByID[id], pane.target == host,
                          let cwd = listing.cwd
                    else { continue }
                    pane.pwd = cwd
                }
            }
        }
    }

    // MARK: - Resize outline

    /// Resize mode marks the pane being acted on with the same one-
    /// device-pixel accent stroke the canvas gives its selection. The
    /// stroke lives on the scroll host's layer, so it rides every
    /// layout the mode causes for free.
    func showResizeOutline() {
        hideResizeOutline()
        guard let host = focusedPane?.scrollHost else { return }
        host.wantsLayer = true
        host.layer?.borderColor = ThemeManager.shared.palette.accent.cgColor
        host.layer?.borderWidth = 1 / window.backingScaleFactor
        resizeOutlineHost = host
    }

    func hideResizeOutline() {
        resizeOutlineHost?.layer?.borderWidth = 0
        resizeOutlineHost = nil
    }

    // MARK: - Pane labels (prefix)

    /// Text only - no boxes, no borders, nothing persistent grows on
    /// the panes.
    func showPaneLabels() {
        hidePaneLabels()
        guard let session = activeSession else { return }
        for id in session.tree?.leaves ?? [] {
            guard let pane = session.panes[id] else { continue }
            if let zoomed = session.zoomedID, zoomed != id {
                continue
            }
            let label = PaneLabelView(pane: pane)
            container.addSubview(label)
            paneLabels.append(label)
        }
        positionPaneLabels()
    }

    func hidePaneLabels() {
        for label in paneLabels {
            label.removeFromSuperview()
        }
        paneLabels.removeAll()
    }

    /// Wide labels truncate rather than cross a divider.
    func positionPaneLabels() {
        for label in paneLabels {
            guard let frame = label.paneFrame else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.fit()
            let width = min(label.frame.width, frame.width)
            label.frame = NSRect(
                x: frame.maxX - width,
                y: frame.minY,
                width: width,
                height: label.frame.height
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
