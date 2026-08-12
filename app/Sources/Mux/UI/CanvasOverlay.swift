import AppKit

/// The canvas panel (prefix f): a live overview of the whole window,
/// sliding in from the right while the workspace slides left beneath it
/// (translation only - pane sizes never change, so the ptys cannot
/// observe the canvas). Every pane is a stacked card whose thumbnail is
/// the pane's real framebuffer, mirrored. Cards sit tight under their
/// session header with space - not boxes - doing the grouping, and
/// each carries a slot glyph: a miniature of the session's split tree
/// with this pane's cell filled, so window membership reads without
/// labels.
///
/// Thumbnails are CALayers whose `contents` is the same IOSurface the
/// pane's own layer shows (ghostty publishes each frame that way): zero
/// copy, scaled by the compositor, refreshed by re-reading the pointer
/// on a timer while the overlay is up. No screen state is ever copied or
/// stored, and a pane's frame is NEVER touched to thumbnail it - that
/// would resize the pty (PaneView.setFrameSize syncs the surface size).
///
/// h/j/k/l walk the cards, enter or a click jumps, esc cancels. Rebuilt
/// from the live session model on every open; PrefixEngine drives the
/// keys and the overlay never takes focus.
final class CanvasOverlayView: NSView {
    struct Entry {
        let sessionIndex: Int
        let paneID: UUID
        /// `<session>.<pane>` in tree (visual) order.
        let index: String
        weak var pane: PaneView?
    }

    struct Group {
        let title: String
        let entries: [Entry]
        let tree: SplitNode?
        let current: Bool
    }

    private static let font = Chrome.font
    private static let boldFont = Chrome.boldFont
    /// One spacing scale for the whole panel: one margin from every
    /// edge, one small gap inside a session, one large gap between
    /// sessions. Nothing else.
    private static let inset: CGFloat = 20
    private static let rowHeight = Chrome.rowHeight
    /// Stacked same-size cards: width follows the panel, the thumbnail
    /// keeps a wide terminal-ish aspect.
    private static let thumbAspect: CGFloat = 0.55
    private static let cardGap: CGFloat = 10
    private static let sectionGap: CGFloat = 28

    private let titleLabel = NSTextField(labelWithString: "canvas")
    private let countLabel = NSTextField(labelWithString: "")
    private let cancelBadge = NSTextField(labelWithString: " esc cancel ")
    private let scroll = NSScrollView()
    private let content = FlippedView()
    /// The panel's only stroke: a hairline on the edge it shares with
    /// the workspace.
    private let edge = NSView()

    private var groups: [Group] = []
    private var headerLabels: [NSTextField] = []
    private var cards: [CardView] = []
    private var index = 0
    /// The pane the user came from (the focused pane on open).
    private var cameFrom: UUID?

    /// A click on a card jumps straight to that pane; the controller
    /// commits and tells PrefixEngine to leave the mode.
    var onJump: ((Entry) -> Void)?

    var selection: Entry? {
        guard cards.indices.contains(index) else { return nil }
        return cards[index].entry
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.wantsLayer = true

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        // A bounded plane: the list stops at its edges, no rubber-band
        // past the first or last card.
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = content
        addSubview(scroll)
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(cancelBadge)
        addSubview(edge)

        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// Rebuild the cards; the highlight starts on `selected` (the focused
    /// pane) so enter with no movement is a no-op jump.
    func reload(groups: [Group], selected: UUID?) {
        self.groups = groups
        cameFrom = selected

        for view in headerLabels + cards {
            view.removeFromSuperview()
        }
        headerLabels = []
        cards = []

        for group in groups {
            let header = NSTextField(labelWithString: "")
            header.lineBreakMode = .byTruncatingTail
            content.addSubview(header)
            headerLabels.append(header)

            for entry in group.entries {
                let card = CardView(entry: entry)
                if let tree = group.tree {
                    card.glyph.slots = (
                        rects: tree.leaves.compactMap {
                            tree.layout(in: SlotGlyphView.canvasRect, gap: 1)[$0]
                        },
                        mine: tree.leaves.firstIndex(of: entry.paneID) ?? 0
                    )
                }
                card.onClick = { [weak self] in self?.onJump?(entry) }
                content.addSubview(card)
                cards.append(card)
            }
        }

        index = cards.firstIndex { $0.entry.paneID == selected } ?? 0
        let total = cards.count
        countLabel.stringValue = "\(total == 1 ? "1 pane" : "\(total) panes")"
            + " : \(groups.count == 1 ? "1 session" : "\(groups.count) sessions")"
        render()
    }

    /// Move the highlight across cards, stopping at the ends: the list
    /// is a bounded plane, not a ring.
    func move(by delta: Int) {
        guard !cards.isEmpty else { return }
        let next = min(max(index + delta, 0), cards.count - 1)
        guard next != index else { return }
        index = next
        render()
        cards[index].scrollToVisible(cards[index].bounds)
    }

    /// The image rect inside a card's thumbnail - the aspect-fit rect
    /// the mirror actually draws - in `view` coordinates. The resume
    /// flight starts exactly on those pixels, so the image never
    /// changes shape on the way to the pane.
    func thumbContentFrame(of entry: Entry, in view: NSView) -> NSRect? {
        guard let card = cards.first(where: { $0.entry.paneID == entry.paneID }),
              card.window != nil
        else { return nil }
        var rect = card.thumb.bounds
        if let size = entry.pane?.frame.size, size.width > 1, size.height > 1 {
            let scale = min(rect.width / size.width, rect.height / size.height)
            rect = NSRect(
                x: rect.midX - size.width * scale / 2,
                y: rect.midY - size.height * scale / 2,
                width: size.width * scale,
                height: size.height * scale
            )
        }
        return card.thumb.convert(rect, to: view)
    }

    // MARK: - Live mirrors

    private var mirrorTimer: Timer?
    private var tick = 0

    /// Mirrors run exactly while the overlay is on screen.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        mirrorTimer?.invalidate()
        mirrorTimer = nil
        guard superview != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshMirrors()
        }
        RunLoop.main.add(timer, forMode: .common)
        mirrorTimer = timer
        refreshMirrors()
    }

    /// One pointer read and one assignment per card: the pane's layer
    /// holds the IOSurface of its latest frame, the mirror shows the
    /// same object. Titles and directories drift slower, so they refresh
    /// on a coarser beat.
    private func refreshMirrors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in cards {
            card.mirror.contents = card.entry.pane?.layer?.contents
        }
        CATransaction.commit()
        tick += 1
        if tick % 15 == 0 {
            renderTitles()
        }
    }

    // MARK: - Layout

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

        edge.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        scroll.frame = NSRect(
            x: 1, y: 0,
            width: max(0, bounds.width - 1),
            height: max(0, bounds.height - inset - row)
        )
        layoutContent()
    }

    private func layoutContent() {
        let width = scroll.bounds.width - Self.inset * 2
        guard width > 80 else { return }
        let cardHeight = Chrome.barHeight + width * Self.thumbAspect
        var y = Self.cardGap
        var cardIndex = 0

        for (i, group) in groups.enumerated() {
            let header = headerLabels[i]
            header.sizeToFit()
            header.frame = NSRect(
                x: Self.inset, y: y,
                width: min(header.frame.width, width), height: header.frame.height
            )
            y += header.frame.height + Self.cardGap

            for _ in group.entries {
                cards[cardIndex].frame = NSRect(
                    x: Self.inset, y: y, width: width, height: cardHeight
                )
                y += cardHeight + Self.cardGap
                cardIndex += 1
            }
            y += Self.sectionGap - Self.cardGap
        }
        content.frame = NSRect(
            x: 0, y: 0, width: scroll.bounds.width, height: max(y, scroll.bounds.height)
        )
    }

    // MARK: - Rendering

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        edge.layer?.backgroundColor = palette.dim.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "canvas",
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

        for (i, group) in groups.enumerated() {
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(
                string: group.title,
                attributes: [.font: Self.boldFont, .foregroundColor: palette.pink]
            ))
            let hosts = Set(group.entries.map { $0.pane?.target ?? "local" })
            var meta = "  \(group.entries.count == 1 ? "1 pane" : "\(group.entries.count) panes")"
                + " : \(hosts.sorted().joined(separator: " "))"
            if group.current {
                meta += " : current"
            }
            line.append(NSAttributedString(
                string: meta,
                attributes: [.font: Self.font, .foregroundColor: palette.dim]
            ))
            headerLabels[i].attributedStringValue = line
        }
        renderTitles()
        needsLayout = true
    }

    /// Card titles come live from the pane (title and pwd change as the
    /// program runs), so they re-render on the mirror timer's slow beat.
    private func renderTitles() {
        let palette = ThemeManager.shared.palette
        for (i, card) in cards.enumerated() {
            card.render(
                palette: palette,
                selected: i == index,
                cameFrom: card.entry.paneID == cameFrom
            )
        }
    }
}

/// One pane card: a title row (index, directory, title, host - the
/// PanesOverlay part grammar), the slot glyph, and the mirrored
/// framebuffer beneath.
private final class CardView: NSView {
    let entry: CanvasOverlayView.Entry
    let thumb = NSView()
    let mirror = CALayer()
    let glyph = SlotGlyphView()
    var onClick: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")

    init(entry: CanvasOverlayView.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(glyph)
        thumb.wantsLayer = true
        mirror.contentsGravity = .resizeAspect
        thumb.layer?.addSublayer(mirror)
        addSubview(thumb)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// Title on top, thumbnail below: top-left math.
    override var isFlipped: Bool {
        true
    }

    /// The whole card is one click target; labels never swallow the hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }

    override func layout() {
        super.layout()
        let titleHeight = Chrome.barHeight
        glyph.frame = NSRect(
            x: bounds.width - SlotGlyphView.canvasRect.width,
            y: (titleHeight - SlotGlyphView.canvasRect.height) / 2,
            width: SlotGlyphView.canvasRect.width,
            height: SlotGlyphView.canvasRect.height
        )
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(
            x: 0, y: (titleHeight - titleLabel.frame.height) / 2,
            width: min(titleLabel.frame.width, glyph.frame.minX - 6),
            height: titleLabel.frame.height
        )
        thumb.frame = NSRect(
            x: 0, y: titleHeight,
            width: bounds.width, height: bounds.height - titleHeight
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirror.frame = thumb.bounds
        CATransaction.commit()
    }

    func render(palette: Palette, selected: Bool, cameFrom: Bool) {
        let line = NSMutableAttributedString()
        if cameFrom {
            line.append(NSAttributedString(
                string: "\u{25C6} ",
                attributes: [.font: Chrome.font, .foregroundColor: palette.accent]
            ))
        }
        var parts = [entry.index]
        if let pane = entry.pane {
            parts.append((pane.pwd as NSString?)?.lastPathComponent ?? "")
            parts.append(Self.sessionTitle(pane.title))
            parts.append(pane.target ?? "")
        }
        for (i, part) in parts.filter({ !$0.isEmpty }).enumerated() {
            if i > 0 {
                line.append(NSAttributedString(
                    string: " : ",
                    attributes: [.font: Chrome.font, .foregroundColor: palette.pink]
                ))
            }
            line.append(NSAttributedString(
                string: part,
                attributes: [
                    .font: i == 0 || selected ? Chrome.boldFont : Chrome.font,
                    .foregroundColor: selected ? palette.accent : palette.text,
                ]
            ))
        }
        titleLabel.attributedStringValue = line
        thumb.layer?.backgroundColor = palette.panelBg.cgColor
        thumb.layer?.borderColor = selected
            ? palette.accent.cgColor
            : palette.dim.withAlphaComponent(0.35).cgColor
        thumb.layer?.borderWidth = selected ? 2 : 1
        glyph.selected = selected
        glyph.needsDisplay = true
        needsLayout = true
    }

    /// The pane title as a session name: drop the state glyph coding
    /// agents prefix their titles with (claude uses U+2733 idle and a
    /// braille spinner while working).
    private static func sessionTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if let first = title.unicodeScalars.first,
           first.value == 0x2733 || (0x2800 ... 0x28FF).contains(first.value) {
            title = String(title.unicodeScalars.dropFirst())
                .trimmingCharacters(in: .whitespaces)
        }
        return title
    }
}

/// A miniature of the session's split tree with this pane's cell filled:
/// which window the card belongs to and where it sits in it, without a
/// label.
private final class SlotGlyphView: NSView {
    /// Glyph canvas, derived from the chrome size knob.
    static let canvasRect = CGRect(
        x: 0, y: 0, width: Chrome.fontSize * 1.3, height: Chrome.fontSize * 0.8
    )

    var slots: (rects: [CGRect], mine: Int) = ([], 0)
    var selected = false

    override var isFlipped: Bool {
        true
    }

    override func draw(_: NSRect) {
        let palette = ThemeManager.shared.palette
        for (i, rect) in slots.rects.enumerated() {
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            if i == slots.mine {
                (selected ? palette.accent : palette.text).setFill()
                path.fill()
            } else {
                palette.dim.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
