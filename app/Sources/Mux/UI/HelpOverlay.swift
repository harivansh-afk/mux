import AppKit

/// The keybinds overlay (prefix ?): the sections laid out in columns side
/// by side when the window is wide enough, stacked when it is not, and
/// the body scrolls when the window is shorter than the list; no footer.
/// Section headings are bare words; the key that enters a mode is that
/// section's first row. PrefixEngine drives dismissal; the overlay never
/// takes focus.
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
    /// The body scrolls when the window is shorter than the list.
    private let scroll = NSScrollView()
    private let document = FlippedView()
    /// Columns sit side by side when the window has the width, else one
    /// under the other. Decided in `desiredSize`, read by layout.
    private var stacked = false

    init() {
        columnLabels = Self.columns.map { _ in
            let f = NSTextField(labelWithString: "")
            f.maximumNumberOfLines = 0
            f.cell?.wraps = false
            f.cell?.isScrollable = false
            return f
        }
        super.init(title: "keybinds", badge: " esc close ")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        columnLabels.forEach(document.addSubview)
        addSubview(scroll)
    }

    private var contentSize: NSSize {
        let sizes = columnLabels.map(\.fittingSize)
        let gap = Self.columnGap * CGFloat(max(0, sizes.count - 1))
        return stacked
            ? NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +) + gap)
            : NSSize(width: sizes.map(\.width).reduce(0, +) + gap, height: sizes.map(\.height).max() ?? 0)
    }

    /// Never wider than the window, less a margin: columns stack before
    /// the right edge is lost. Stacking trades width for scrolling, not
    /// height: a stacked overlay keeps the height the columns had side by
    /// side, and the body scrolls the rest. A short window caps that too.
    override func desiredSize(in bounds: NSRect) -> NSSize {
        let room = NSSize(width: bounds.width - 48, height: bounds.height * 0.85)
        stacked = false
        let sideBySide = contentSize
        stacked = Self.inset * 2 + sideBySide.width > room.width
        let content = contentSize
        return NSSize(
            width: min(Self.inset * 2 + content.width, room.width),
            height: min(Self.inset * 2 + Chrome.rowHeight + sideBySide.height, room.height)
        )
    }

    /// The columns fill the band below the title row, top-aligned, inside
    /// the scroll view.
    override func layoutBody(in rect: NSRect) {
        scroll.frame = rect
        let content = contentSize
        document.frame = NSRect(
            x: 0, y: 0,
            width: max(rect.width, content.width), height: max(rect.height, content.height)
        )
        var origin = NSPoint.zero
        for label in columnLabels {
            let size = label.fittingSize
            label.frame = NSRect(origin: origin, size: size)
            if stacked {
                origin.y += size.height + Self.columnGap
            } else {
                origin.x += size.width + Self.columnGap
            }
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
