import AppKit

/// The mode overlay: a single row laid OVER the bottom of the terminal
/// area - panes do not reflow - containing a badge (" PREFIX ", bold
/// accent-contrast text on the accent color) followed by key/description
/// span pairs: keys bold in accent, descriptions in the dim overlay color,
/// all on panel_bg.
///
/// Unlike a full-width status strip, the bar is a content-sized box floating
/// at the bottom-left, inset by the same margin from the left and bottom
/// edges of the terminal area; everything outside the box stays transparent.
struct ModeBarSegment {
    enum Kind {
        case badge
        case key
        case dim
        /// Active-item highlight (bold pink), e.g. the current session
        /// number in the session indicator.
        case highlight
    }

    let kind: Kind
    let text: String

    static func badge(_ t: String) -> ModeBarSegment {
        .init(kind: .badge, text: t)
    }

    static func key(_ t: String) -> ModeBarSegment {
        .init(kind: .key, text: t)
    }

    static func dim(_ t: String) -> ModeBarSegment {
        .init(kind: .dim, text: t)
    }

    static func highlight(_ t: String) -> ModeBarSegment {
        .init(kind: .highlight, text: t)
    }
}

final class ModeBarView: NSView {
    /// One terminal-ish row.
    static let height: CGFloat = 22
    /// Equal inset from the left and bottom edges of the terminal area,
    /// so the box sits concentric with the corner.
    static let margin: CGFloat = 4

    /// A boxed bar paints the panel background behind its text (the
    /// bottom-left mode bar); a bare one floats text straight over the
    /// terminal (the session indicator).
    private let boxed: Bool

    /// The badge is the visual edge of the bar, so its inset inside the
    /// box must be identical on every side. The horizontal inset is
    /// therefore derived from the vertical slack
    /// ((height - label height) / 2), making left gap == bottom gap
    /// exactly.
    private var textInset: CGFloat {
        max(0, (Self.height - label.fittingSize.height) / 2)
    }

    /// Content-sized width for the current segments.
    var desiredWidth: CGFloat {
        label.fittingSize.width + textInset * 2
    }

    private let label = NSTextField(labelWithString: "")
    private var segments: [ModeBarSegment] = []

    private static let font = Chrome.font
    private static let boldFont = Chrome.boldFont

    init(boxed: Bool = false) {
        self.boxed = boxed
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
            switch segment.kind {
            case .badge:
                line.append(NSAttributedString(
                    string: " \(segment.text) ",
                    attributes: [
                        .font: Self.boldFont,
                        .foregroundColor: palette.accentContrast,
                        .backgroundColor: palette.accent,
                    ]
                ))
                line.append(NSAttributedString(string: " "))
            case .key:
                line.append(NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: Self.boldFont,
                        .foregroundColor: palette.accent,
                    ]
                ))
            case .dim:
                line.append(NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: palette.dim,
                    ]
                ))
            case .highlight:
                line.append(NSAttributedString(
                    string: segment.text,
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
        layer?.backgroundColor =
            boxed ? ThemeManager.shared.palette.panelBg.cgColor : nil
    }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        let inset = max(0, (bounds.height - size.height) / 2)
        label.frame = NSRect(
            x: inset,
            y: inset,
            width: min(size.width, bounds.width - inset * 2),
            height: size.height
        )
    }
}
