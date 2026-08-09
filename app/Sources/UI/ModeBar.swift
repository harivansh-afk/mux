import AppKit

/// herdr's mode overlay, 1:1 (src/ui/menus.rs render_prefix_overlay):
/// a single row laid OVER the bottom of the terminal area - panes do not
/// reflow - containing a badge (" PREFIX ", bold accent-contrast text on
/// the accent color) followed by key/description span pairs: keys bold in
/// accent, descriptions in the dim overlay color, all on panel_bg.
struct ModeBarSegment {
    enum Kind {
        case badge
        case key
        case dim
    }

    let kind: Kind
    let text: String

    static func badge(_ t: String) -> ModeBarSegment { .init(kind: .badge, text: t) }
    static func key(_ t: String) -> ModeBarSegment { .init(kind: .key, text: t) }
    static func dim(_ t: String) -> ModeBarSegment { .init(kind: .dim, text: t) }
}

final class ModeBarView: NSView {
    /// One terminal-ish row.
    static let height: CGFloat = 22

    private let label = NSTextField(labelWithString: "")
    private var segments: [ModeBarSegment] = []

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .muxThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

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
                    ]))
                line.append(NSAttributedString(string: " "))
            case .key:
                line.append(NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: Self.boldFont,
                        .foregroundColor: palette.accent,
                    ]))
            case .dim:
                line.append(NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: palette.dim,
                    ]))
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
        label.sizeToFit()
        label.frame = NSRect(
            x: 8,
            y: (bounds.height - label.frame.height) / 2,
            width: min(label.frame.width, bounds.width - 16),
            height: label.frame.height)
    }
}
