import AppKit

/// The stage's directory line, shared with anything else that names
/// where a pane lives. What a pane calls itself is only ever shown as
/// an agent topic (behind a state glyph); a shell's self-title is
/// noise the directory line already covers.
enum PaneLabelParts {
    /// The pane's directory the way its prompt would print it: the full
    /// path with the home prefix folded to `~`. Remote paths fold their
    /// own home (/home/x or /Users/x) - the pane's pwd names the pane's
    /// host, so the abbreviation reads exactly like a prompt there.
    static func promptDir(for pane: PaneView) -> String? {
        guard var dir = pane.pwd, !dir.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if dir == home || dir.hasPrefix(home + "/") {
            dir = "~" + dir.dropFirst(home.count)
        } else if let match = dir.range(
            of: "^/(home|Users)/[^/]+", options: .regularExpression
        ) {
            dir = "~" + dir[match.upperBound...]
        }
        return dir
    }
}

/// A tag flush with a pane's top-right corner while the prefix is
/// armed: the pane's host, in pink, and nothing else - titles and
/// directories belong to the canvas. Styled exactly like the bottom
/// bars: an opaque panel_bg box at bar height with the same half-slack
/// text inset, square corners, no shadow.
final class PaneLabelView: NSView {
    private weak var pane: PaneView?
    private let label = NSTextField(labelWithString: "")

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
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

    /// The bottom bars' text inset (half their vertical slack), applied
    /// on ALL four sides here: the tag hugs its text symmetrically, so
    /// nothing reads as a gap between the box and the pane corner.
    private var textInset: CGFloat {
        (max(0, (ModeBarView.height - label.fittingSize.height) / 2) / 2).rounded()
    }

    /// Size the tag to its text plus the shared inset; the positioner
    /// may then clamp the width, and layout keeps the text inset either
    /// way.
    func fit() {
        let size = label.fittingSize
        setFrameSize(NSSize(
            width: size.width + textInset * 2,
            height: size.height + textInset * 2
        ))
    }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        let inset = textInset
        label.frame = NSRect(
            x: inset,
            y: inset,
            width: min(size.width, bounds.width - inset * 2),
            height: size.height
        )
    }

    /// Labels are momentary (the prefix is armed for a beat) and are
    /// rebuilt on every show; no live refresh needed.
    private func render() {
        guard let pane else { return }
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        // The host alone, in pink (the active-item color), never gray -
        // the session indicator's highlight voice.
        label.attributedStringValue = NSAttributedString(
            string: pane.target ?? "local",
            attributes: [
                .font: Chrome.boldFont,
                .foregroundColor: palette.pink,
            ]
        )
    }
}
