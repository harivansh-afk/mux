import AppKit

/// The panes overlay (prefix f): a large centered panel - the window minus
/// proportional margins - listing every pane grouped by the host its
/// terminal lives on, local first, then hosts by name. Host headings carry
/// a right-aligned pane count; a pane row is branch glyphs plus
/// `<session>.<pane>  title` on the left and its cwd right-aligned, with a
/// diamond in the gutter marking the pane you came from. j/k move a
/// full-width highlight bar across pane rows (headers are skipped), enter
/// jumps to the selected pane, esc cancels. Rebuilt from the live session
/// model every time it opens; PrefixEngine drives it and it never takes
/// focus.
final class PanesOverlayView: NSView {
    struct Entry {
        let sessionIndex: Int
        let paneID: UUID
        let label: String
        let detail: String
    }

    private struct Row {
        let entry: Entry?
        /// Tree glyphs before the text; empty for host headings.
        let glyph: String
        let text: String
        let meta: String
        /// The pane the user came from (the focused pane on open).
        let current: Bool
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    private static let inset: CGFloat = 16
    private static let rowHeight: CGFloat = 26

    private let titleLabel = NSTextField(labelWithString: "panes")
    private let countLabel = NSTextField(labelWithString: "")
    private let cancelBadge = NSTextField(labelWithString: " esc cancel ")
    private let separator = NSView()
    private let selectionBar = NSView()
    private var mainLabels: [NSTextField] = []
    private var metaLabels: [NSTextField] = []
    private var rows: [Row] = []
    private var index = 0

    /// The highlighted pane row, if any.
    var selection: Entry? {
        guard rows.indices.contains(index) else { return nil }
        return rows[index].entry
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        selectionBar.wantsLayer = true
        separator.wantsLayer = true
        addSubview(selectionBar)
        addSubview(separator)
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(cancelBadge)
        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// Rebuild the list; the highlight starts on `selected` (the focused
    /// pane) so enter with no movement is a no-op jump.
    func reload(groups: [(host: String?, entries: [Entry])], selected: UUID?) {
        rows = []
        for group in groups {
            let count = group.entries.count
            rows.append(Row(
                entry: nil, glyph: "", text: group.host ?? "local",
                meta: count == 1 ? "1 pane" : "\(count) panes", current: false
            ))
            for (position, entry) in group.entries.enumerated() {
                rows.append(Row(
                    entry: entry,
                    glyph: position == count - 1 ? "\u{2570}\u{2500} " : "\u{251C}\u{2500} ",
                    text: entry.label,
                    meta: entry.detail,
                    current: entry.paneID == selected
                ))
            }
        }
        index = rows.firstIndex { $0.current }
            ?? rows.firstIndex { $0.entry != nil } ?? 0

        let total = rows.filter { $0.entry != nil }.count
        countLabel.stringValue = total == 1 ? "1 pane" : "\(total) panes"

        for label in mainLabels + metaLabels {
            label.removeFromSuperview()
        }
        mainLabels = []
        metaLabels = []
        for _ in rows {
            let main = NSTextField(labelWithString: "")
            main.lineBreakMode = .byTruncatingTail
            addSubview(main)
            mainLabels.append(main)
            let meta = NSTextField(labelWithString: "")
            meta.lineBreakMode = .byTruncatingHead
            addSubview(meta)
            metaLabels.append(meta)
        }
        render()
    }

    /// Move the highlight across pane rows, skipping headers, wrapping at
    /// both ends.
    func move(by delta: Int) {
        let entries = rows.indices.filter { rows[$0].entry != nil }
        guard !entries.isEmpty else { return }
        let position = entries.firstIndex(of: index) ?? 0
        index = entries[(position + delta + entries.count) % entries.count]
        render()
    }

    /// The window minus proportional margins: the overlay is a workspace
    /// view, not a content-sized popup.
    func desiredSize(in bounds: NSRect) -> NSSize {
        NSSize(
            width: max(bounds.width - max(bounds.width / 16, 32) * 2, 240),
            height: max(bounds.height - max(bounds.height / 10, 24) * 2, 160)
        )
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let row = Self.rowHeight
        titleLabel.sizeToFit()
        countLabel.sizeToFit()
        cancelBadge.sizeToFit()
        let titleMidY = bounds.height - inset - row / 2
        titleLabel.frame.origin = NSPoint(
            x: inset, y: titleMidY - titleLabel.frame.height / 2
        )
        cancelBadge.frame.origin = NSPoint(
            x: bounds.width - inset - cancelBadge.frame.width,
            y: titleMidY - cancelBadge.frame.height / 2
        )
        countLabel.frame.origin = NSPoint(
            x: cancelBadge.frame.minX - 16 - countLabel.frame.width,
            y: titleMidY - countLabel.frame.height / 2
        )
        separator.frame = NSRect(
            x: 1, y: bounds.height - inset - row, width: bounds.width - 2, height: 1
        )

        let rowsTop = separator.frame.minY - 6
        selectionBar.isHidden = true
        for (i, main) in mainLabels.enumerated() {
            let meta = metaLabels[i]
            let bandY = rowsTop - row * CGFloat(i + 1)
            let visible = bandY >= inset
            main.isHidden = !visible
            meta.isHidden = !visible
            guard visible else { continue }

            meta.sizeToFit()
            let metaWidth = min(meta.frame.width, (bounds.width - inset * 2) / 2)
            meta.frame = NSRect(
                x: bounds.width - inset - metaWidth,
                y: bandY + (row - meta.frame.height) / 2,
                width: metaWidth,
                height: meta.frame.height
            )
            main.sizeToFit()
            main.frame = NSRect(
                x: inset,
                y: bandY + (row - main.frame.height) / 2,
                width: min(main.frame.width, meta.frame.minX - inset - 16),
                height: main.frame.height
            )
            if i == index, rows.indices.contains(i), rows[i].entry != nil {
                selectionBar.frame = NSRect(
                    x: 1, y: bandY, width: bounds.width - 2, height: row
                )
                selectionBar.isHidden = false
            }
        }
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor
        separator.layer?.backgroundColor = palette.divider.cgColor
        selectionBar.layer?.backgroundColor = palette.accent.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "panes",
            attributes: [.font: Self.boldFont, .foregroundColor: palette.text]
        )
        countLabel.attributedStringValue = NSAttributedString(
            string: countLabel.stringValue,
            attributes: [.font: Self.font, .foregroundColor: palette.dim]
        )
        cancelBadge.attributedStringValue = NSAttributedString(
            string: " esc cancel ",
            attributes: [
                .font: Self.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ]
        )

        for (i, row) in rows.enumerated() {
            let selected = i == index && row.entry != nil
            let main = NSMutableAttributedString()
            if row.entry == nil {
                main.append(NSAttributedString(
                    string: row.text,
                    attributes: [.font: Self.boldFont, .foregroundColor: palette.pink]
                ))
            } else {
                main.append(NSAttributedString(
                    string: row.current ? "\u{25C6} " : "  ",
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: selected ? palette.accentContrast : palette.accent,
                    ]
                ))
                main.append(NSAttributedString(
                    string: row.glyph,
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: selected ? palette.accentContrast : palette.dim,
                    ]
                ))
                main.append(NSAttributedString(
                    string: row.text,
                    attributes: [
                        .font: selected || row.current ? Self.boldFont : Self.font,
                        .foregroundColor: selected ? palette.accentContrast : palette.text,
                    ]
                ))
            }
            mainLabels[i].attributedStringValue = main
            metaLabels[i].attributedStringValue = NSAttributedString(
                string: row.meta,
                attributes: [
                    .font: Self.font,
                    .foregroundColor: selected ? palette.accentContrast : palette.dim,
                ]
            )
        }
        needsLayout = true
    }
}
