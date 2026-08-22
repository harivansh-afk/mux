import AppKit

/// The keybinds overlay (prefix ?): the sections laid out in columns side
/// by side so everything fits at once - no scrolling, no footer. Section
/// headings are bare words; the key that enters a mode is that section's
/// first row. PrefixEngine drives dismissal; the overlay never takes focus.
final class HelpOverlayView: PanelView {
    private struct Section {
        let title: String
        let rows: [(key: String, desc: String)]
    }

    /// The columns as written. Moving a section across the split is one
    /// bracket, and the alternative was a balancer that read a constant.
    private static let columns: [[Section]] = [
        [
            Section(title: "prefix", rows: [
                ("ctrl+b", "arm the prefix"),
                ("ctrl+b ctrl+b", "send ctrl+b through"),
                ("'", "split right"),
                ("-", "split down"),
                ("arrows", "move focus"),
                ("h / j / k / l", "focus left / down / up / right"),
                ("z", "toggle zoom"),
                ("x", "close pane"),
                ("r", "resize mode"),
                ("t", "hosts and ix vms"),
                ("space / f", "canvas"),
                ("?", "keybinds"),
                ("esc", "cancel"),
            ]),
            Section(title: "sessions", rows: [
                ("c", "new session"),
                ("1 .. 9", "select session"),
                ("n / p", "next / previous"),
            ]),
            Section(title: "resize", rows: [
                ("prefix r", "enter resize mode"),
                ("h / j / k / l", "adjust split ratio"),
                ("H / J / K / L", "move pane in layout"),
                ("c", "break out into new session"),
                ("1 .. 9", "move pane to session"),
                ("esc / enter / q", "done"),
            ]),
        ],
        [
            Section(title: "hosts", rows: [
                ("prefix t", "open hosts"),
                ("j / k", "choose host or vm"),
                ("enter", "split right into it"),
                ("H / J / K / L", "split left/down/up/right"),
                ("c", "new session there"),
                ("n", "new ix vm"),
                ("t", "template for new vms"),
                ("y", "copy client digest"),
                ("esc / q", "close"),
            ]),
            Section(title: "canvas", rows: [
                ("prefix space / f", "open canvas"),
                ("j / k", "choose pane"),
                ("enter / click", "jump to it"),
                ("esc / q", "cancel"),
            ]),
            Section(title: "app", rows: [
                ("cmd+n", "new window"),
                ("cmd+c / cmd+v", "copy / paste"),
            ]),
        ],
    ]

    override class var inset: CGFloat { 16 }

    private static let columnGap: CGFloat = 30
    /// Key column width in characters; descriptions start after it.
    private static let keyColumn = 17

    /// One multiline label per column of sections.
    private let columnLabels: [NSTextField]

    init() {
        columnLabels = Self.columns.map { _ in
            let f = NSTextField(labelWithString: "")
            f.maximumNumberOfLines = 0
            f.cell?.wraps = false
            f.cell?.isScrollable = false
            return f
        }
        super.init(title: "keybinds", badge: " esc close ")
        columnLabels.forEach(addSubview)
    }

    override var bodySize: NSSize {
        let sizes = columnLabels.map(\.fittingSize)
        return NSSize(
            width: sizes.map(\.width).reduce(0, +)
                + Self.columnGap * CGFloat(max(0, sizes.count - 1)),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    /// Columns fill the band below the title row, top-aligned.
    override func layoutBody(in rect: NSRect) {
        var x = rect.minX
        for label in columnLabels {
            let size = label.fittingSize
            label.frame = NSRect(
                x: x, y: rect.maxY - size.height,
                width: size.width, height: size.height
            )
            x += size.width + Self.columnGap
        }
    }

    override func renderBody(_ palette: Palette) {
        for (label, sections) in zip(columnLabels, Self.columns) {
            label.attributedStringValue = Self.column(sections, palette: palette)
        }
    }

    private static func column(
        _ sections: [Section], palette: Palette
    ) -> NSAttributedString {
        let buffer = NSMutableAttributedString()
        for (i, section) in sections.enumerated() {
            buffer.append(NSAttributedString(
                string: (i == 0 ? "" : "\n") + section.title + "\n",
                attributes: [.font: Chrome.boldFont, .foregroundColor: palette.pink]
            ))
            for row in section.rows {
                buffer.append(NSAttributedString(
                    string: row.key.padding(
                        toLength: max(keyColumn, row.key.count + 2),
                        withPad: " ", startingAt: 0
                    ),
                    attributes: [.font: Chrome.boldFont, .foregroundColor: palette.accent]
                ))
                buffer.append(NSAttributedString(
                    string: row.desc + "\n",
                    attributes: [.font: Chrome.font, .foregroundColor: palette.dim]
                ))
            }
        }
        return buffer
    }
}
