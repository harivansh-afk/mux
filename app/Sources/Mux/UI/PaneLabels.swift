import AppKit

/// A small tag at a pane's top-right while the prefix is armed: what
/// runs here and where (title · host · directory). A quiet panel
/// background floats it above any cell content; no border - the box is
/// the chrome, the text is the information.
final class PaneLabelView: NSView {
    private weak var pane: PaneView?
    private let label = NSTextField(labelWithString: "")

    private static let padX: CGFloat = 9
    private static let padY: CGFloat = 4

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 3)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
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

    /// Size the tag to its text plus padding; the positioner may then
    /// clamp the width, and layout keeps the text inset either way.
    func fit() {
        label.sizeToFit()
        setFrameSize(NSSize(
            width: label.frame.width + Self.padX * 2,
            height: label.frame.height + Self.padY * 2
        ))
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil
        )
    }

    /// Labels are momentary (the prefix is armed for a beat) and are
    /// rebuilt on every show; no live refresh needed.
    private func render() {
        guard let pane else { return }
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.withAlphaComponent(0.94).cgColor

        // The host is the label's whole reason to exist: it reads in
        // pink (the active-item color), never in gray.
        var parts: [(text: String, color: NSColor, font: NSFont)] = [
            (pane.displayTitle, palette.text, Chrome.metaBoldFont),
        ]
        if let target = pane.target {
            parts.append((target, palette.pink, Chrome.metaBoldFont))
        }
        if let tail = (pane.pwd as NSString?)?.lastPathComponent, !tail.isEmpty {
            parts.append((tail, palette.dim, Chrome.metaFont))
        }

        let line = NSMutableAttributedString()
        for part in parts where !part.text.isEmpty {
            if line.length > 0 {
                line.append(NSAttributedString(string: " · ", attributes: [
                    .font: Chrome.metaFont,
                    .foregroundColor: palette.dim.withAlphaComponent(0.7),
                ]))
            }
            line.append(NSAttributedString(string: part.text, attributes: [
                .font: part.font,
                .foregroundColor: part.color,
            ]))
        }
        label.attributedStringValue = line
    }
}
