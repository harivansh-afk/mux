import AppKit

/// The host chip on a remote pane: a colored dot plus the pane's target
/// ("spark", "ix:dev") floating at the pane's top-right corner with the
/// mode bar's concentric insets. Local panes have no chip - local is the
/// quiet default; remote is the exception worth marking. The focused
/// pane's chip is fully opaque, unfocused ones recede.
final class HostBadgeView: NSView {
    static let height: CGFloat = 18
    /// Inset from the pane's top and right edges.
    static let margin: CGFloat = 4

    private static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
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

    /// Stable per-host color: an FNV-1a hash of the name picks the hue;
    /// saturation and brightness are tuned per appearance so the dot reads
    /// on both panel backgrounds. The same host gets the same color across
    /// panes, sessions and launches.
    static func color(for host: String) -> NSColor {
        var hash: UInt32 = 2_166_136_261
        for byte in host.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let hue = CGFloat(hash % 360) / 360
        return ThemeManager.shared.appearance == .dark
            ? NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
            : NSColor(hue: hue, saturation: 0.65, brightness: 0.60, alpha: 1)
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: "\u{25CF} ",
            attributes: [.font: Self.font, .foregroundColor: Self.color(for: host)]
        ))
        line.append(NSAttributedString(
            string: host,
            attributes: [.font: Self.font, .foregroundColor: palette.text]
        ))
        label.attributedStringValue = line
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
