import AppKit

/// Bare text at a pane's top-right while the prefix is armed: what runs
/// here and where (title · host · directory). Deliberately chromeless -
/// no box, no border, no background. A soft halo in the panel
/// background color keeps the line readable over any cells and melts
/// into them when they match.
final class PaneLabelView: NSTextField {
    private weak var pane: PaneView?

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// The frame of the pane this label sits on, in container
    /// coordinates (the workspace sits at the origin). nil hides the
    /// label (the pane went away or is covered).
    var paneFrame: CGRect? {
        guard let host = pane?.scrollHost, !host.isHidden else { return nil }
        return host.frame
    }

    /// Display only: clicks fall through to the pane below.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Labels are momentary (the prefix is armed for a beat) and are
    /// rebuilt on every show; no live refresh needed.
    private func render() {
        guard let pane else { return }
        let palette = ThemeManager.shared.palette
        let halo = NSShadow()
        halo.shadowColor = palette.panelBg.withAlphaComponent(0.9)
        halo.shadowBlurRadius = 3

        var parts: [(text: String, color: NSColor)] = [(pane.displayTitle, palette.text)]
        if let target = pane.target {
            parts.append((target, palette.dim))
        }
        if let tail = (pane.pwd as NSString?)?.lastPathComponent, !tail.isEmpty {
            parts.append((tail, palette.dim))
        }

        let line = NSMutableAttributedString()
        for (i, part) in parts.enumerated() where !part.text.isEmpty {
            if line.length > 0 {
                line.append(NSAttributedString(string: " · ", attributes: [
                    .font: Chrome.metaFont,
                    .foregroundColor: palette.dim.withAlphaComponent(0.7),
                    .shadow: halo,
                ]))
            }
            line.append(NSAttributedString(string: part.text, attributes: [
                .font: i == 0 ? Chrome.metaBoldFont : Chrome.metaFont,
                .foregroundColor: part.color,
                .shadow: halo,
            ]))
        }
        attributedStringValue = line
    }
}
