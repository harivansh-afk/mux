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

    // MARK: - Canvas picker

    /// The canvas comes and goes as one quick fade - fast enough to
    /// read as a keystroke. The workspace never moves for it.
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

    /// prefix f: the pane picker floating over the dimmed workspace -
    /// the wheel of pane cards on the right, the selected pane
    /// previewed live at its true aspect on the left. Rebuilt from the
    /// live session model on every open; the selection starts on the
    /// focused pane. While the canvas is up, every pane is un-occluded
    /// so its renderer keeps producing the frames the mirrors show;
    /// hide restores the normal rule.
    func showCanvasOverlay() {
        refreshPaneDirectories()
        // Wired before reload: reload fires the first selection, and the
        // indicator should track it from the first frame.
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
    /// needed and unzooming whatever covers it. The jump is exactly the
    /// close motion, with focus landing on the chosen pane immediately.
    /// No extra theater.
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

    /// The overlay covers the whole container; its own layout puts the
    /// air, the stage and the wheel inside.
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

    /// The directory a pane shows must not depend on shell integration:
    /// most shells never report OSC 7, and reattach replays screen
    /// bytes, not escapes. The daemons resolve every pty's cwd from its
    /// live process, so each canvas open asks them once (a discrete
    /// user action, not a poll) and fills in whatever OSC 7 has not.
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

    // MARK: - Pane labels (prefix)

    /// Bare per-pane labels while the prefix is armed: every visible
    /// pane of the active session names itself (title · host · dir).
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

    /// Top-right corner of each pane; wide labels truncate rather than
    /// cross a divider.
    func positionPaneLabels() {
        let inset: CGFloat = 8
        for label in paneLabels {
            guard let frame = label.paneFrame else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.fit()
            let width = min(label.frame.width, max(0, frame.width - inset * 2))
            label.frame = NSRect(
                x: frame.maxX - inset - width,
                y: frame.minY + inset,
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
