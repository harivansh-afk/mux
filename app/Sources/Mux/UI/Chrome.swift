import AppKit

/// A plain view with a top-left origin and an optional click handler:
/// the scrim, the stage, the wheel, the track, the pane slab. Layout
/// math in this app is written top-down, so flipped is the default and
/// the only views that opt out are the ones AppKit gives coordinates to.
class FlippedView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }
}

/// The bordered box every centred overlay is: panel_bg behind one
/// hairline, the panel's name bold on the left of the top row and an
/// accent badge on its right, recoloured whenever the theme flips.
///
/// A subclass owns its body and nothing else: `bodySize` measures it,
/// `layoutBody` places it in the area under the top row, `renderBody`
/// colours it.
class PanelView: NSView {
    /// Padding between the panel's edge and its content.
    class var inset: CGFloat { 14 }

    /// The panel's name, left of the top row.
    var title: String {
        didSet { render() }
    }

    /// The escape hint, right of it; the spaces are the badge's padding.
    var badge: String {
        didSet { render() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var themeObserver: NSObjectProtocol?

    init(title: String, badge: String) {
        self.title = title
        self.badge = badge
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        addSubview(titleLabel)
        addSubview(badgeLabel)
        themeObserver = NotificationCenter.default.addObserver(
            forName: .muxThemeDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    // MARK: - Body

    /// The body's fitting size.
    var bodySize: NSSize {
        .zero
    }

    /// Place the body in `rect`: the content area under the top row.
    func layoutBody(in _: NSRect) {}

    /// Colour the body. Called on every theme change and on every render.
    func renderBody(_: Palette) {}

    /// Fitting widths of the top row, for a subclass sizing itself around
    /// them.
    var titleWidth: CGFloat {
        titleLabel.fittingSize.width
    }

    var badgeWidth: CGFloat {
        badgeLabel.fittingSize.width
    }

    /// Content size: the top row, the body, and the insets on both axes.
    func desiredSize(in _: NSRect) -> NSSize {
        NSSize(
            width: Self.inset * 2 + bodySize.width,
            height: Self.inset * 2 + Chrome.rowHeight + bodySize.height
        )
    }

    final func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [.font: Chrome.boldFont, .foregroundColor: palette.text]
        )
        badgeLabel.attributedStringValue = NSAttributedString(
            string: badge,
            attributes: [
                .font: Chrome.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ]
        )
        renderBody(palette)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let row = Chrome.rowHeight
        titleLabel.sizeToFit()
        badgeLabel.sizeToFit()
        let midY = bounds.height - inset - row / 2
        titleLabel.frame.origin = NSPoint(
            x: inset, y: midY - titleLabel.frame.height / 2
        )
        badgeLabel.frame.origin = NSPoint(
            x: bounds.width - inset - badgeLabel.frame.width,
            y: midY - badgeLabel.frame.height / 2
        )
        layoutBody(in: NSRect(
            x: inset,
            y: inset,
            width: max(0, bounds.width - inset * 2),
            height: max(0, bounds.height - inset * 2 - row)
        ))
    }
}
