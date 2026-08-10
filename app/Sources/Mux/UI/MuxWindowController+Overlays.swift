import AppKit

/// The window's chrome: the floating mode bar, the session indicator, the
/// keybinds overlay and the target picker. All of them are overlays on the
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
            showSessionIndicator()
        } else {
            modeBar.isHidden = true
            if indicatorFlashTimer == nil {
                sessionIndicator.isHidden = true
            }
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
    /// at the bottom-right corner with the same concentric insets.
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

    private func showSessionIndicator() {
        indicatorFlashTimer?.invalidate()
        indicatorFlashTimer = nil
        sessionIndicator.render(sessionSegments)
        sessionIndicator.isHidden = false
        sessionIndicator.removeFromSuperview()
        container.addSubview(sessionIndicator)
        positionSessionIndicator()
    }

    /// Visible while a mode bar is up; a switch flashes it for a second
    /// so normal use stays chrome-free.
    func flashSessionIndicator() {
        showSessionIndicator()
        indicatorFlashTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            indicatorFlashTimer = nil
            if modeBar.isHidden {
                sessionIndicator.isHidden = true
            }
        }
    }

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

    // MARK: - Target picker

    /// prefix t: pick where the next pane's terminal should live. The list
    /// is re-read from hosts.json on every open.
    func showTargetPicker() {
        targetPicker.reload()
        targetPicker.removeFromSuperview()
        container.addSubview(targetPicker)
        positionTargetPicker()
    }

    func hideTargetPicker() {
        targetPicker.removeFromSuperview()
    }

    func moveTargetPicker(by delta: Int) {
        targetPicker.move(by: delta)
        positionTargetPicker()
    }

    /// Enter: split the focused pane rightwards into the chosen target.
    func commitTargetPicker() {
        split(direction: .horizontal, target: .explicit(targetPicker.selection))
    }

    func positionTargetPicker() {
        center(targetPicker, size: targetPicker.desiredSize(in: container.bounds))
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
