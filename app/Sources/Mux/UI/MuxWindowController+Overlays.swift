import AppKit

/// The window's chrome: the floating mode bar, the session indicator, the
/// keybinds overlay, and the panes and hosts windows. All of them are
/// overlays on the
/// pane area - panes never reflow for them - and none of them ever takes
/// focus: PrefixEngine owns the keys and drives them from the outside.
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
    /// at the top-right corner with the same concentric insets.
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

    /// Always visible at the top-right; re-rendered whenever sessions
    /// are created, closed, switched or restored.
    func updateSessionIndicator() {
        sessionIndicator.render(sessionSegments)
        positionSessionIndicator()
    }

    /// Top-right corner (the container is flipped, so the top is minY).
    func positionSessionIndicator() {
        let bounds = container.bounds
        let margin = ModeBarView.margin
        let width = min(sessionIndicator.desiredWidth, bounds.width - margin * 2)
        sessionIndicator.frame = NSRect(
            x: bounds.width - margin - width,
            y: margin,
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

    /// prefix h: where a pane can live - local, the aliases with a live
    /// probe, the ix VMs. Every query fires on open, so the box fills in as
    /// answers arrive and re-centers itself when it grows.
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

    // MARK: - Panes overlay

    /// prefix f: every pane in the window grouped by host. Rebuilt from
    /// the live session model on every open; the highlight starts on the
    /// focused pane.
    func showPanesOverlay() {
        panesOverlay.reload(groups: panesByHost(), selected: focusedPane?.id)
        panesOverlay.removeFromSuperview()
        container.addSubview(panesOverlay)
        positionPanesOverlay()
    }

    func hidePanesOverlay() {
        panesOverlay.removeFromSuperview()
    }

    func movePanesOverlay(by delta: Int) {
        panesOverlay.move(by: delta)
        positionPanesOverlay()
    }

    /// Enter: jump to the selected pane, switching session if needed and
    /// unzooming whatever covers it.
    func commitPanesOverlay() {
        guard let entry = panesOverlay.selection,
              sessions.indices.contains(entry.sessionIndex) else { return }
        let session = sessions[entry.sessionIndex]
        guard let pane = session.panes[entry.paneID] else { return }
        selectSession(entry.sessionIndex)
        session.reveal(pane)
    }

    func positionPanesOverlay() {
        center(panesOverlay, size: panesOverlay.desiredSize(in: container.bounds))
    }

    /// Rows for the panes overlay: sessions in order, panes in tree
    /// (visual) order, grouped under `local` first and then hosts by name.
    private func panesByHost() -> [(host: String?, entries: [PanesOverlayView.Entry])] {
        var order: [String?] = []
        var groups: [String?: [PanesOverlayView.Entry]] = [:]
        for (sessionIndex, session) in sessions.enumerated() {
            for (paneIndex, paneID) in (session.tree?.leaves ?? []).enumerated() {
                guard let pane = session.panes[paneID] else { continue }
                if groups[pane.target] == nil {
                    order.append(pane.target)
                }
                groups[pane.target, default: []].append(PanesOverlayView.Entry(
                    sessionIndex: sessionIndex,
                    paneID: paneID,
                    label: "\(sessionIndex + 1).\(paneIndex + 1)  \(pane.title)",
                    detail: (pane.pwd as NSString?)?.abbreviatingWithTildeInPath ?? ""
                ))
            }
        }
        // nil (local) sorts as "" - first; aliases are alphanumeric-led.
        order.sort { ($0 ?? "") < ($1 ?? "") }
        return order.map { ($0, groups[$0] ?? []) }
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
