import AppKit

/// The host chip on a remote pane: the pane's target ("spark", "ix:dev")
/// in the highlight pink, floating at the pane's top-right corner with the
/// mode bar's concentric insets. Local panes have no chip - local is the
/// quiet default; remote is the exception worth marking. The focused
/// pane's chip is fully opaque, unfocused ones recede.
final class HostBadgeView: NSView {
    static let height = Chrome.barHeight
    /// Inset from the pane's top and right edges.
    static let margin: CGFloat = 4

    private static let font = Chrome.boldFont
    private static let unfocusedAlpha: CGFloat = 0.55

    private let label = NSTextField(labelWithString: "")
    private let host: String

    /// Content-sized width, insets matching the vertical slack (see
    /// ModeBarView.textInset for the rationale).
    var desiredWidth: CGFloat {
        let inset = max(0, (Self.height - label.fittingSize.height) / 2)
        return label.fittingSize.width + inset * 2
    }

    init(host: String) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        alphaValue = Self.unfocusedAlpha
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    func setFocused(_ focused: Bool) {
        alphaValue = focused ? 1.0 : Self.unfocusedAlpha
    }

    @objc private func render() {
        // Bare text, no box: the pink on the terminal is marker enough.
        let palette = ThemeManager.shared.palette
        label.attributedStringValue = NSAttributedString(
            string: host,
            attributes: [.font: Self.font, .foregroundColor: palette.pink]
        )
        needsLayout = true
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
