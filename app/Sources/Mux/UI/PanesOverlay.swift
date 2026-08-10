import AppKit

/// The panes overlay (prefix f): every pane in the window grouped by the
/// host its terminal lives on - local first, then hosts by name, each
/// header carrying the host's chip color. A row is
/// `<session>.<pane>  <title>  <cwd>`; j/k move across pane rows (headers
/// are skipped), enter jumps to the selected pane, switching session if
/// needed. Rebuilt from the live session model every time it opens;
/// PrefixEngine drives it and it never takes focus.
final class PanesOverlayView: NSView {
    struct Entry {
        let sessionIndex: Int
        let paneID: UUID
        let text: String
    }

    private enum Item {
        case header(String?)
        case entry(Entry)
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    private static let inset: CGFloat = 14
    private static let rowHeight: CGFloat = 22

    private let titleLabel = NSTextField(labelWithString: "panes")
    private let cancelBadge = NSTextField(labelWithString: " esc cancel ")
    private var rowLabels: [NSTextField] = []
    private var items: [Item] = []
    private var index = 0

    /// The highlighted pane row, if any.
    var selection: Entry? {
        guard items.indices.contains(index),
              case let .entry(entry) = items[index] else { return nil }
        return entry
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        addSubview(titleLabel)
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
        items = []
        for group in groups {
            items.append(.header(group.host))
            items.append(contentsOf: group.entries.map(Item.entry))
        }
        index = items.firstIndex {
            if case let .entry(entry) = $0 { entry.paneID == selected } else { false }
        } ?? items.firstIndex {
            if case .entry = $0 { true } else { false }
        } ?? 0

        for label in rowLabels {
            label.removeFromSuperview()
        }
        rowLabels = items.map { _ in
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            return label
        }
        render()
    }

    /// Move the highlight across pane rows, skipping headers, wrapping at
    /// both ends.
    func move(by delta: Int) {
        let entries = items.indices.filter {
            if case .entry = items[$0] { true } else { false }
        }
        guard !entries.isEmpty else { return }
        let position = entries.firstIndex(of: index) ?? 0
        index = entries[(position + delta + entries.count) % entries.count]
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
            label.frame = NSRect(
                x: inset,
                y: bounds.height - inset - row * CGFloat(i + 2) + (row - label.frame.height) / 2,
                width: min(label.frame.width, bounds.width - inset * 2),
                height: label.frame.height
            )
        }
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "panes",
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
            switch items[i] {
            case let .header(host):
                let line = NSMutableAttributedString()
                if let host {
                    line.append(NSAttributedString(
                        string: "\u{25CF} ",
                        attributes: [
                            .font: Self.boldFont,
                            .foregroundColor: HostBadgeView.color(for: host),
                        ]
                    ))
                }
                line.append(NSAttributedString(
                    string: host ?? "local",
                    attributes: [.font: Self.boldFont, .foregroundColor: palette.pink]
                ))
                label.attributedStringValue = line
            case let .entry(entry):
                let selected = i == index
                label.attributedStringValue = NSAttributedString(
                    string: "  " + entry.text,
                    attributes: [
                        .font: selected ? Self.boldFont : Self.font,
                        .foregroundColor: selected ? palette.pink : palette.dim,
                    ]
                )
            }
        }
        needsLayout = true
    }
}
