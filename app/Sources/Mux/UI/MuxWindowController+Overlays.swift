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

    func scrollHelp(by dy: CGFloat) {
        helpOverlay.scroll(by: dy)
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
