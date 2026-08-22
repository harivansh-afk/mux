import AppKit

/// The mode overlay: a single row laid OVER the bottom of the terminal
/// area - panes do not reflow - containing a badge (" PREFIX ", bold
/// accent-contrast text on the accent color) followed by key/description
/// span pairs: keys bold in accent, descriptions in the dim overlay color,
/// all on panel_bg.
///
/// Unlike a full-width status strip, the bar is a content-sized box on
/// panel_bg flush with a bottom corner of the terminal area (mode bar
/// left, session indicator right); everything outside the box stays
/// transparent.
class ModeBarView: NSView {
    /// One terminal-ish row.
    static let height = Chrome.barHeight

    /// The badge is the visual edge of the bar. Horizontal inset is half
    /// the vertical slack: the full slack read wider than the gap under
    /// the badge, so the sides sit at half to match it optically.
    fileprivate var textInset: CGFloat {
        (max(0, (Self.height - label.fittingSize.height) / 2) / 2).rounded()
    }

    /// Content-sized width for the current segments.
    var desiredWidth: CGFloat {
        label.fittingSize.width + textInset * 2
    }

    /// Content-sized box at bar height.
    var desiredSize: NSSize {
        NSSize(width: desiredWidth, height: Self.height)
    }

    fileprivate let label = NSTextField(labelWithString: "")
    private var segments: [ModeBarSegment] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    func render(_ segments: [ModeBarSegment]) {
        self.segments = segments
        let palette = ThemeManager.shared.palette
        let line = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case let .badge(text):
                line.append(NSAttributedString(
                    string: " \(text) ",
                    attributes: [
                        .font: Chrome.boldFont,
                        .foregroundColor: palette.accentContrast,
                        .backgroundColor: palette.accent,
                    ]
                ))
                line.append(NSAttributedString(string: " "))
            case let .key(text):
                line.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: Chrome.boldFont,
                        .foregroundColor: palette.accent,
                    ]
                ))
            case let .dim(text):
                line.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: Chrome.font,
                        .foregroundColor: palette.dim,
                    ]
                ))
            case let .highlight(text):
                line.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: Chrome.boldFont,
                        .foregroundColor: palette.pink,
                    ]
                ))
            }
        }
        label.attributedStringValue = line
        needsLayout = true
    }

    @objc private func themeDidChange() {
        applyTheme()
        render(segments)
    }

    private func applyTheme() {
        layer?.backgroundColor = ThemeManager.shared.palette.panelBg.cgColor
    }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        let insetY = max(0, (bounds.height - size.height) / 2)
        let insetX = textInset
        label.frame = NSRect(
            x: insetX,
            y: insetY,
            width: min(size.width, bounds.width - insetX * 2),
            height: size.height
        )
    }
}

/// The tag flush with a pane's top-right corner while the prefix is
/// armed: the pane's host, in pink, and nothing else - titles and
/// directories belong to the canvas. The bars' voice exactly, with one
/// difference: the text inset is applied on all four sides, so the tag
/// hugs its text instead of standing at bar height, which against a
/// matching terminal background reads as a gap.
final class PaneTagView: ModeBarView {
    private weak var pane: PaneView?

    init(pane: PaneView) {
        self.pane = pane
        super.init()
        render([.highlight(pane.target ?? "local")])
    }

    /// The frame of the pane this tag sits on, in container coordinates
    /// (the workspace sits at the origin). nil hides the tag (the pane
    /// went away or is covered).
    var paneFrame: CGRect? {
        guard let host = pane?.scrollHost, !host.isHidden else { return nil }
        return host.frame
    }

    /// Display only: clicks fall through to the pane below.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Size the tag to its text plus the inset on every side; the
    /// positioner may then clamp the width, and layout keeps the text
    /// inset either way.
    func fit() {
        setFrameSize(NSSize(
            width: desiredSize.width,
            height: label.fittingSize.height + textInset * 2
        ))
    }
}
