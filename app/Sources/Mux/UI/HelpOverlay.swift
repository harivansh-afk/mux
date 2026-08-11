import AppKit

/// The keybinds overlay (prefix ?): a bordered box centered over the panes.
/// Title row ("keybinds" left, an "esc close" badge right), then the section
/// blocks laid out in columns side by side so everything fits at once - no
/// scrolling. PrefixEngine drives dismissal; the overlay never takes focus.
final class HelpOverlayView: NSView {
    private struct Section {
        let title: String
        let rows: [(key: String, desc: String)]
    }

    private static let sections: [Section] = [
        Section(title: "prefix  ctrl+b", rows: [
            ("ctrl+b", "send prefix to terminal"),
            ("'", "split right"),
            ("-", "split down"),
            ("arrows", "move focus"),
            ("j / k / l", "focus down / up / right"),
            ("z", "toggle zoom"),
            ("x", "close pane"),
            ("r", "resize mode"),
            ("h", "hosts and ix vms"),
            ("f", "panes by host"),
            ("?", "keybinds"),
            ("esc", "cancel"),
        ]),
        Section(title: "sessions", rows: [
            ("c", "new session"),
            ("1 .. 9", "select session"),
            ("n / p", "next / previous"),
        ]),
        Section(title: "resize  prefix r", rows: [
            ("h / j / k / l", "adjust split ratio"),
            ("esc / enter / q", "done"),
        ]),
        Section(title: "hosts  prefix h", rows: [
            ("j / k", "choose host or vm"),
            ("enter", "split right into it"),
            ("H / J / K / L", "split left/down/up/right"),
            ("c", "new session there"),
            ("n", "new ix vm"),
            ("t", "template for new vms"),
            ("y", "copy client digest"),
            ("esc / q", "close"),
        ]),
        Section(title: "panes  prefix f", rows: [
            ("j / k", "choose pane (by host)"),
            ("enter", "jump to it"),
            ("esc / q", "cancel"),
        ]),
        Section(title: "app", rows: [
            ("cmd+n", "new window"),
            ("cmd+c / cmd+v", "copy / paste"),
        ]),
    ]

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    private static let inset: CGFloat = 16
    private static let rowHeight: CGFloat = 22
    private static let columnGap: CGFloat = 30
    /// Key column width in characters; descriptions start after it.
    private static let keyColumn = 17

    private let titleLabel = NSTextField(labelWithString: "keybinds")
    private let closeBadge = NSTextField(labelWithString: " esc close ")
    private let footerLabel = NSTextField(labelWithString: "")
    /// One multiline label per column of sections.
    private let columnLabels: [NSTextField]

    override init(frame: NSRect) {
        // Balance the sections across two order-preserving columns.
        let groups = Self.partition(Self.sections, into: 2)
        columnLabels = groups.map { _ in
            let f = NSTextField(labelWithString: "")
            f.maximumNumberOfLines = 0
            f.cell?.wraps = false
            f.cell?.isScrollable = false
            return f
        }
        self.groups = groups

        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1

        addSubview(titleLabel)
        addSubview(closeBadge)
        addSubview(footerLabel)
        columnLabels.forEach(addSubview)

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

    private let groups: [[Section]]

    /// Split sections into `n` contiguous, order-preserving columns whose
    /// heights are as even as possible (greedy on a running target).
    private static func partition(_ sections: [Section], into n: Int) -> [[Section]] {
        let weights = sections.map { $0.rows.count + 2 } // title + rows + gap
        let total = weights.reduce(0, +)
        let target = Double(total) / Double(n)
        var groups: [[Section]] = []
        var current: [Section] = []
        var height = 0
        var used = 0
        for (i, section) in sections.enumerated() {
            current.append(section)
            height += weights[i]
            let remainingCols = n - used - 1
            let remainingSections = sections.count - i - 1
            // Close the column once it reaches the running target, but leave
            // at least one section for each remaining column.
            if used < n - 1,
               Double(height) >= target,
               remainingSections > remainingCols
            {
                groups.append(current)
                current = []
                height = 0
                used += 1
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// Fixed content size: title row + tallest column + footer row + insets.
    func desiredSize(in _: NSRect) -> NSSize {
        let widths = columnLabels.map(\.fittingSize.width)
        let heights = columnLabels.map(\.fittingSize.height)
        let bodyWidth = widths.reduce(0, +)
            + Self.columnGap * CGFloat(max(0, columnLabels.count - 1))
        let bodyHeight = heights.max() ?? 0
        return NSSize(
            width: Self.inset * 2 + bodyWidth,
            height: Self.inset * 2 + Self.rowHeight * 2 + bodyHeight
        )
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let row = Self.rowHeight
        titleLabel.sizeToFit()
        closeBadge.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: inset, y: bounds.height - inset - (row + titleLabel.frame.height) / 2
        )
        closeBadge.frame.origin = NSPoint(
            x: bounds.width - inset - closeBadge.frame.width,
            y: bounds.height - inset - (row + closeBadge.frame.height) / 2
        )
        footerLabel.sizeToFit()
        footerLabel.frame.origin = NSPoint(x: inset, y: inset)

        // Columns fill the band between the title and footer rows, top-aligned.
        let bandTop = bounds.height - inset - row
        var x = inset
        for label in columnLabels {
            let size = label.fittingSize
            label.frame = NSRect(x: x, y: bandTop - size.height, width: size.width, height: size.height)
            x += size.width + Self.columnGap
        }
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "keybinds",
            attributes: [.font: Self.boldFont, .foregroundColor: palette.text]
        )
        closeBadge.attributedStringValue = NSAttributedString(
            string: " esc close ",
            attributes: [
                .font: Self.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ]
        )
        footerLabel.attributedStringValue = NSAttributedString(
            string: "esc close",
            attributes: [.font: Self.font, .foregroundColor: palette.dim]
        )

        for (label, group) in zip(columnLabels, groups) {
            label.attributedStringValue = column(for: group, palette: palette)
        }
        needsLayout = true
    }

    private func column(for sections: [Section], palette: Palette) -> NSAttributedString {
        let buffer = NSMutableAttributedString()
        for (i, section) in sections.enumerated() {
            buffer.append(NSAttributedString(
                string: (i == 0 ? "" : "\n") + section.title + "\n",
                attributes: [.font: Self.boldFont, .foregroundColor: palette.pink]
            ))
            for row in section.rows {
                buffer.append(NSAttributedString(
                    string: row.key.padding(
                        toLength: max(Self.keyColumn, row.key.count + 2),
                        withPad: " ", startingAt: 0
                    ),
                    attributes: [.font: Self.boldFont, .foregroundColor: palette.accent]
                ))
                buffer.append(NSAttributedString(
                    string: row.desc + "\n",
                    attributes: [.font: Self.font, .foregroundColor: palette.dim]
                ))
            }
        }
        return buffer
    }
}
