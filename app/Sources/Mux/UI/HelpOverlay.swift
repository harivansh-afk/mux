import AppKit

/// The keybinds overlay (prefix ?): a bordered box centered over the panes.
/// Title row ("keybinds" left, an "esc close" badge right), then section
/// blocks of key/description columns, then a dim footer with the overlay's
/// own keys. Scrolls without a scrollbar; PrefixEngine drives scrolling and
/// dismissal, the overlay never takes focus.
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
            ("h / j / k / l", "move focus"),
            ("z", "toggle zoom"),
            ("x", "close pane"),
            ("c", "new window"),
            ("r", "resize mode"),
            ("?", "keybinds"),
            ("esc", "cancel"),
        ]),
        Section(title: "resize  prefix r", rows: [
            ("h / j / k / l", "adjust split ratio"),
            ("esc / enter / q", "done"),
        ]),
        Section(title: "app", rows: [
            ("cmd+n", "new window"),
            ("cmd+w", "close window"),
            ("cmd+c / cmd+v", "copy / paste"),
        ]),
    ]

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    private static let inset: CGFloat = 14
    private static let rowHeight: CGFloat = 22
    /// Width of the key column in characters; descriptions start after it.
    private static let keyColumn = 18

    private let titleLabel = NSTextField(labelWithString: "keybinds")
    private let closeBadge = NSTextField(labelWithString: " esc close ")
    private let footerLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none

        addSubview(titleLabel)
        addSubview(closeBadge)
        addSubview(scrollView)
        addSubview(footerLabel)

        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Content-fitting size, capped to the container.
    func desiredSize(in bounds: NSRect) -> NSSize {
        guard let container = textView.textContainer, let lm = textView.layoutManager else {
            return NSSize(width: 420, height: 320)
        }
        lm.ensureLayout(for: container)
        let content = lm.usedRect(for: container).size
        let chrome = Self.inset * 2 + Self.rowHeight * 2  // title + footer rows
        return NSSize(
            width: min(content.width + Self.inset * 2, bounds.width - 48),
            height: min(content.height + chrome, bounds.height * 0.75))
    }

    func scroll(by dy: CGFloat) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = max(0, min(origin.y + dy, textView.frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let row = Self.rowHeight
        titleLabel.sizeToFit()
        closeBadge.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: inset, y: bounds.height - inset - (row + titleLabel.frame.height) / 2)
        closeBadge.frame.origin = NSPoint(
            x: bounds.width - inset - closeBadge.frame.width,
            y: bounds.height - inset - (row + closeBadge.frame.height) / 2)
        footerLabel.sizeToFit()
        footerLabel.frame.origin = NSPoint(
            x: inset, y: inset + (row - footerLabel.frame.height) / 2 - 4)
        scrollView.frame = NSRect(
            x: inset, y: inset + row,
            width: bounds.width - inset * 2,
            height: bounds.height - inset * 2 - row * 2)
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "keybinds",
            attributes: [.font: Self.boldFont, .foregroundColor: palette.text])
        closeBadge.attributedStringValue = NSAttributedString(
            string: " esc close ",
            attributes: [
                .font: Self.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ])

        let footer = NSMutableAttributedString()
        for (i, hint) in [("j/k", "scroll"), ("esc", "close")].enumerated() {
            if i > 0 {
                footer.append(NSAttributedString(
                    string: "  \u{00B7}  ",
                    attributes: [.font: Self.font, .foregroundColor: palette.dim]))
            }
            footer.append(NSAttributedString(
                string: hint.0 + " ",
                attributes: [.font: Self.boldFont, .foregroundColor: palette.accent]))
            footer.append(NSAttributedString(
                string: hint.1,
                attributes: [.font: Self.font, .foregroundColor: palette.dim]))
        }
        footerLabel.attributedStringValue = footer

        let buffer = NSMutableAttributedString()
        for (i, section) in Self.sections.enumerated() {
            buffer.append(NSAttributedString(
                string: (i == 0 ? "" : "\n") + section.title + "\n",
                attributes: [.font: Self.boldFont, .foregroundColor: palette.text]))
            for row in section.rows {
                buffer.append(NSAttributedString(
                    string: row.key.padding(
                        toLength: max(Self.keyColumn, row.key.count + 2),
                        withPad: " ", startingAt: 0),
                    attributes: [.font: Self.boldFont, .foregroundColor: palette.accent]))
                buffer.append(NSAttributedString(
                    string: row.desc + "\n",
                    attributes: [.font: Self.font, .foregroundColor: palette.dim]))
            }
        }
        textView.textStorage?.setAttributedString(buffer)
        needsLayout = true
    }
}
