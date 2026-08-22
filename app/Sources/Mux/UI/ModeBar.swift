import AppKit

/// The mode overlay: a single row laid OVER the bottom of the terminal
/// area - panes do not reflow - containing a badge (" PREFIX ", bold
/// accent-contrast text on the accent color) followed by key/description
/// span pairs: keys bold in accent, descriptions in the dim overlay color,
/// all on panel_bg.
///
/// Unlike a full-width status strip, the bar is a content-sized box on
/// panel_bg floating in a bottom corner (mode bar left, session indicator
/// right), inset by the same margin from the nearest edges of the terminal
/// area; everything outside the box stays transparent.
final class ModeBarView: NSView {
    /// One terminal-ish row.
    static let height = Chrome.barHeight
    /// Flush with the window corners: the bars sit ON the edge, no air.
    static let margin: CGFloat = 0

    /// The badge is the visual edge of the bar. Horizontal inset is half
    /// the vertical slack: the full slack read wider than the gap under
    /// the badge, so the sides sit at half to match it optically.
    private var textInset: CGFloat {
        (max(0, (Self.height - label.fittingSize.height) / 2) / 2).rounded()
    }

    /// Content-sized width for the current segments.
    var desiredWidth: CGFloat {
        label.fittingSize.width + textInset * 2
    }

    private let label = NSTextField(labelWithString: "")
    private var segments: [ModeBarSegment] = []

    private static let font = Chrome.font
    private static let boldFont = Chrome.boldFont

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
                        .font: Self.boldFont,
                        .foregroundColor: palette.accentContrast,
                        .backgroundColor: palette.accent,
                    ]
                ))
                line.append(NSAttributedString(string: " "))
            case let .key(text):
                line.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: Self.boldFont,
                        .foregroundColor: palette.accent,
                    ]
                ))
            case let .dim(text):
                line.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: palette.dim,
                    ]
                ))
            case let .highlight(text):
                line.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: Self.boldFont,
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
