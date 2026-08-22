import AppKit

/// A chrome view the window puts up and takes down: the mode bar, the
/// session indicator, the keybinds overlay, the hosts window, the canvas.
/// All of them are overlays on the pane area - panes never reflow for
/// them - and none of them ever takes focus: PrefixEngine owns the keys
/// and drives them from the outside (the canvas additionally takes
/// clicks, which also route through the engine to leave the mode).
protocol ChromeOverlay: NSView {
    func desiredSize(in bounds: NSRect) -> NSSize
}

extension PanelView: ChromeOverlay {}

extension MuxWindowController {
    // MARK: - Presenting

    /// Presence is `superview != nil` for every overlay, and `presented`
    /// is the list layout walks.
    func present(_ overlay: ChromeOverlay) {
        if overlay.superview == nil {
            container.addSubview(overlay)
            presented.append(overlay)
        }
        // Adding a subview puts it on top, so the bars are lifted back:
        // the mode bar above the canvas overlay, and the session
        // indicator with it (it tracks the canvas selection live).
        for bar in [modeBar, sessionIndicator]
            where bar !== overlay && bar.superview != nil
        {
            container.addSubview(bar, positioned: .above, relativeTo: nil)
        }
        position(overlay)
    }

    func dismiss(_ overlay: ChromeOverlay) {
        overlay.removeFromSuperview()
        presented.removeAll { $0 === overlay }
    }

    /// Every mode change starts here, so nothing the previous mode put
    /// up survives it.
    func dismissAllChrome() {
        // The canvas leaves on its own fade; its teardown dismisses it.
        hideCanvasOverlay()
        // The session indicator is not mode chrome: it is always up.
        for overlay in presented
            where overlay !== sessionIndicator && overlay !== canvasOverlay
        {
            dismiss(overlay)
        }
        hidePaneTags()
        hideResizeOutline()
    }

    /// The two bars sit on a bottom corner; everything else is centred.
    func position(_ overlay: ChromeOverlay) {
        if overlay === modeBar {
            positionBar(modeBar, edge: .minX)
        } else if overlay === sessionIndicator {
            positionBar(sessionIndicator, edge: .maxX)
        } else {
            let bounds = container.bounds
            let size = overlay.desiredSize(in: bounds)
            overlay.frame = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    /// Content-sized box flush with a bottom corner of the pane area
    /// (the container is flipped, so the bottom is at maxY).
    func positionBar(_ bar: ModeBarView, edge: NSRectEdge) {
        let bounds = container.bounds
        let size = bar.desiredSize(in: bounds)
        bar.frame = NSRect(
            x: edge == .minX ? 0 : bounds.width - size.width,
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Mode bar

    /// The bar is an overlay on the bottom row: panes never reflow for it.
    func setModeIndicator(_ segments: [ModeBarSegment]) {
        modeBar.render(segments)
        present(modeBar)
    }

    // MARK: - Session indicator

    /// `1 2 3` with the active number highlighted - or, while the canvas
    /// is up, the session of the selected card, so the numbers follow
    /// the scroll live. Mirrors the mode bar across the bottom edge with
    /// the same flush corners.
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
        present(sessionIndicator)
    }

    // MARK: - Hosts window

    /// prefix t: where a pane can live - local, the aliases with a live
    /// probe, the ix VMs. Every query fires on open, so the box fills in as
    /// answers arrive; the view's sticky sizing keeps the box from moving
    /// while they land.
    func showHostsWindow() {
        hostsWindow.reload()
        present(hostsWindow)
    }

    /// Enter / H J K L: split the focused pane into the highlighted machine.
    /// Rows that cannot host a pane are not selectable, so a nil selection
    /// means there is nothing to open (which is not the same as `local`,
    /// hence NewPaneTarget rather than a bare string).
    func commitHostsWindow(direction: SplitDirection, before: Bool = false) {
        guard let target = hostsWindow.selectedHost else { return }
        activeSession?.split(direction: direction, before: before, target: target)
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
        activeSession?.split(
            direction: .horizontal,
            target: .explicit(IX.prefix + name),
            ptyCommand: [IX.binary, "new", "-n", name, IXConfig.template()]
        )
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
            dismiss(canvasOverlay)
            applyCanvasOcclusion()
        }
    }

    /// The canvas takes clicks (a card, the stage, the scrim), and each
    /// of them ends the mode through the engine that owns the keys.
    /// Wired once, at init: the overlay outlives every open.
    func wireCanvasCallbacks() {
        canvasOverlay.onSelectionChange = { [weak self] entry in
            self?.canvasSessionHighlight = entry?.sessionIndex
            self?.updateSessionIndicator()
        }
        canvasOverlay.onJump = { [weak self] entry in
            self?.commitCanvas(entry)
            App.delegate.prefixEngine.endCanvas()
        }
        canvasOverlay.onCancel = {
            App.delegate.prefixEngine.endCanvas()
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
        canvasOverlay.reload(entries: canvasEntries(), selected: activeSession?.focusedPane?.id)
        if canvasOverlay.superview == nil {
            canvasOverlay.layer?.opacity = 0
            present(canvasOverlay)
        }
        // Reopening mid-close: the pending teardown sees canvasOpen and
        // stands down; the fade retargets from wherever it is.
        canvasClosing = false
        canvasOpen = true
        // One pass positions the overlay and un-occludes every pane.
        layoutPanes()
        // The mirrors carry the first frame of the fade, so lay them out
        // before it starts.
        canvasOverlay.layoutSubtreeIfNeeded()
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
        selectSession(entry.sessionIndex)
        session.reveal(pane)
        hideCanvasOverlay()
    }

    /// Wheel rows: sessions in order, panes in tree (visual) order.
    private func canvasEntries() -> [CanvasOverlayView.Entry] {
        sessions.enumerated().flatMap { sessionIndex, session in
            (session.tree?.leaves ?? []).compactMap { paneID in
                guard let pane = session.panes[paneID] else { return nil }
                return CanvasOverlayView.Entry(
                    sessionIndex: sessionIndex,
                    paneID: paneID,
                    pane: pane
                )
            }
        }
    }

    /// Ask every daemon holding a pane for its directories. Once per
    /// canvas open: a discrete user action, not a poll.
    func refreshPaneDirectories() {
        var hosts: Set<String?> = []
        for session in sessions {
            for (_, pane) in session.panes where IX.vm(of: pane.target) == nil {
                hosts.insert(pane.target)
            }
        }
        for host in hosts {
            Muxd.list(host: host) { [weak self] listings in
                guard let self, let listings else { return }
                applyCwds(listings, host: host)
            }
        }
    }

    /// One daemon's answer, applied to the panes it speaks for. The
    /// directory a pane shows must not depend on shell integration: most
    /// shells never report OSC 7, and reattach replays screen bytes, not
    /// escapes. A listing names its pane by UUID and carries the cwd the
    /// daemon read from the live process, which is the truth here; OSC 7
    /// overrides it later when a shell does report. ix panes are
    /// excluded: their local pty cwd is where `ix shell` started, not
    /// where the shell in the VM is.
    func applyCwds(_ listings: [Muxd.PtyListing], host: String?) {
        for session in sessions {
            for (id, pane) in session.panes
                where pane.target == host && IX.vm(of: pane.target) == nil
            {
                if let cwd = listings.first(where: { $0.name == id.uuidString })?.cwd {
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
        guard let host = activeSession?.focusedPane?.scrollHost else { return }
        host.wantsLayer = true
        host.layer?.borderColor = ThemeManager.shared.palette.accent.cgColor
        host.layer?.borderWidth = 1 / window.backingScaleFactor
        resizeOutlineHost = host
    }

    func hideResizeOutline() {
        resizeOutlineHost?.layer?.borderWidth = 0
        resizeOutlineHost = nil
    }

    // MARK: - Pane tags (prefix)

    /// While the prefix is armed, every visible pane of the active
    /// session wears its host in a corner tag.
    func showPaneTags() {
        hidePaneTags()
        guard let session = activeSession else { return }
        for id in session.tree?.leaves ?? [] {
            guard let pane = session.panes[id] else { continue }
            if let zoomed = session.zoomedID, zoomed != id {
                continue
            }
            let tag = PaneTagView(pane: pane)
            container.addSubview(tag)
            paneTags.append(tag)
        }
        positionPaneTags()
    }

    func hidePaneTags() {
        for tag in paneTags {
            tag.removeFromSuperview()
        }
        paneTags.removeAll()
    }

    /// Flush with each pane's top-right corner, mirroring the bottom
    /// bars on their window corners; wide tags truncate rather than
    /// cross a divider.
    func positionPaneTags() {
        for tag in paneTags {
            guard let frame = tag.paneFrame else {
                tag.isHidden = true
                continue
            }
            tag.isHidden = false
            tag.fit()
            let width = min(tag.frame.width, frame.width)
            tag.frame = NSRect(
                x: frame.maxX - width,
                y: frame.minY,
                width: width,
                height: tag.frame.height
            )
        }
    }
}
