import AppKit

/// The target picker (prefix t): a bordered box centered over the panes,
/// listing `local` plus the host aliases from ~/.config/mux/hosts.json.
/// Title row ("target" left, an "esc cancel" badge right), then one row per
/// choice with the highlighted one in pink. PrefixEngine drives the
/// highlight and the commit; the picker never takes focus.
final class TargetPickerView: NSView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    private static let inset: CGFloat = 14
    private static let rowHeight: CGFloat = 22

    private let titleLabel = NSTextField(labelWithString: "target")
    private let cancelBadge = NSTextField(labelWithString: " esc cancel ")
    private var rowLabels: [NSTextField] = []

    /// `local` first, then the aliases. Reloaded every time the picker
    /// opens, so editing hosts.json needs no restart.
    private var options: [String] = ["local"]
    private var index = 0

    /// The chosen pane target: nil for `local` (see PaneView.target).
    var selection: String? {
        index == 0 ? nil : options[index]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        addSubview(titleLabel)
        addSubview(cancelBadge)
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    func reload() {
        options = ["local"] + HostsConfig.aliases()
        index = 0
        for label in rowLabels {
            label.removeFromSuperview()
        }
        rowLabels = options.map { option in
            let label = NSTextField(labelWithString: option)
            addSubview(label)
            return label
        }
        render()
    }

    /// Move the highlight, wrapping at both ends like focus movement does.
    func move(by delta: Int) {
        guard !options.isEmpty else { return }
        index = (index + delta + options.count) % options.count
        render()
    }

    /// Content-fitting size, capped to the container.
    func desiredSize(in bounds: NSRect) -> NSSize {
        let rows = rowLabels.map(\.fittingSize.width).max() ?? 0
        let title = titleLabel.fittingSize.width + Self.rowHeight + cancelBadge.fittingSize.width
        let height = Self.rowHeight * CGFloat(rowLabels.count + 1) + Self.inset * 2
        return NSSize(
            width: min(max(rows, title) + Self.inset * 2, bounds.width - 48),
            height: min(height, bounds.height * 0.75)
        )
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let row = Self.rowHeight
        titleLabel.sizeToFit()
        cancelBadge.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: inset, y: bounds.height - inset - (row + titleLabel.frame.height) / 2
        )
        cancelBadge.frame.origin = NSPoint(
            x: bounds.width - inset - cancelBadge.frame.width,
            y: bounds.height - inset - (row + cancelBadge.frame.height) / 2
        )
        for (i, label) in rowLabels.enumerated() {
            label.sizeToFit()
            label.frame.origin = NSPoint(
                x: inset,
                y: bounds.height - inset - row * CGFloat(i + 2) + (row - label.frame.height) / 2
            )
        }
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "target",
            attributes: [.font: Self.boldFont, .foregroundColor: palette.text]
        )
        cancelBadge.attributedStringValue = NSAttributedString(
            string: " esc cancel ",
            attributes: [
                .font: Self.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ]
        )
        for (i, label) in rowLabels.enumerated() {
            let selected = i == index
            label.attributedStringValue = NSAttributedString(
                string: options[i],
                attributes: [
                    .font: selected ? Self.boldFont : Self.font,
                    .foregroundColor: selected ? palette.pink : palette.dim,
                ]
            )
        }
        needsLayout = true
    }
}
