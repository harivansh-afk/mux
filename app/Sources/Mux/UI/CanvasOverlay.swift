import AppKit

/// The canvas (prefix f): a pane picker floating over the dimmed live
/// workspace, with air on all sides - not a docked panel.
///
/// Right: the wheel - every pane as a card at its TRUE frame aspect,
/// grouped by session by a wider gap. The selection is always held at
/// the wheel's vertical center: moving translates the whole track (one
/// retargetable spring), the previous pane peeks above, the next below,
/// and distance fades the rest. Left: the stage - the selected pane
/// previewed large at its true aspect, scaled uniformly, never
/// stretched.
///
/// Thumbnails and the stage are mirror CALayers: ghostty publishes each
/// frame as an IOSurface in the pane layer's `contents`; the mirrors
/// assign the same object (zero copy, GPU-scaled) and re-read the
/// pointer at 30Hz while the overlay is up. No screen state is copied or
/// stored, and a pane's frame is NEVER touched to preview it - the pty
/// cannot observe the canvas.
///
/// j/k (and arrows) move, click selects (click again jumps), enter
/// jumps, esc or a click on the scrim cancels. PrefixEngine drives the
/// keys; the overlay never takes focus.
final class CanvasOverlayView: FlippedView, ChromeOverlay {
    struct Entry {
        let sessionIndex: Int
        let paneID: UUID
        weak var pane: PaneView?
    }

    // One spacing scale, derived from the chrome size knob.
    private static let margin: CGFloat = Chrome.fontSize * 2
    private static let gap: CGFloat = Chrome.fontSize * 1.6
    private static let wheelWidth: CGFloat = Chrome.fontSize * 12
    private static let itemGap: CGFloat = 10
    private static let sectionGap: CGFloat = 22
    /// The floating badges keep their bottom strip.
    private static let bottomReserve: CGFloat = ModeBarView.height

    /// A click on a card that is already selected - or on the stage -
    /// jumps; the controller commits and tells PrefixEngine to leave
    /// the mode.
    var onJump: ((Entry) -> Void)?
    /// A click on the scrim leaves the mode, like esc.
    var onCancel: (() -> Void)?
    var onSelectionChange: ((Entry?) -> Void)?

    private let scrim = FlippedView()
    /// The stage box; a click on it jumps to the previewed pane. Wheel
    /// events over it scroll the previewed pane's real scrollback, but
    /// that routing lives in the scroll monitor below, not in the view:
    /// responsive scrolling would never deliver the event to it.
    private let stage = MirrorHostView(radius: 28, offset: 14, opacity: 0.55)
    private let stageTitle = NSTextField(labelWithString: "")
    private let stageMeta = NSTextField(labelWithString: "")
    private let wheel = FlippedView()
    private let track = FlippedView()

    private var items: [WheelItemView] = []
    private var index = 0
    /// The pane the user came from (the focused pane on open).
    private var cameFrom: UUID?

    var selection: Entry? {
        guard items.indices.contains(index) else { return nil }
        return items[index].entry
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        scrim.wantsLayer = true
        scrim.onClick = { [weak self] in self?.onCancel?() }
        addSubview(scrim)

        // A click on the stage jumps to the previewed pane. Wheel events
        // over it scroll that pane for real, but that routing lives in
        // the scroll monitor below: responsive scrolling would never
        // deliver the event to this view.
        stage.onClick = { [weak self] in
            guard let self, let selection else { return }
            onJump?(selection)
        }
        addSubview(stage)
        stageTitle.lineBreakMode = .byTruncatingTail
        stageMeta.lineBreakMode = .byTruncatingTail
        addSubview(stageTitle)
        addSubview(stageMeta)

        // The wheel clips; the track carries the cards and slides as one.
        wheel.clipsToBounds = true
        track.wantsLayer = true
        wheel.addSubview(track)
        addSubview(wheel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// Rebuild the wheel; the selection starts on `selected` (the focused
    /// pane) so enter with no movement is a no-op jump.
    func reload(entries: [Entry], selected: UUID?) {
        cameFrom = selected

        for view in items {
            view.removeFromSuperview()
        }
        items = entries.map { entry in
            let item = WheelItemView(entry: entry)
            item.onClick = { [weak self] in self?.clicked(item) }
            track.addSubview(item)
            return item
        }

        index = items.firstIndex { $0.entry.paneID == selected } ?? 0
        render()
        needsLayout = true
        onSelectionChange?(selection)
    }

    /// Click: selecting is one click, going is a second - the first
    /// updates the preview, matching j/k.
    private func clicked(_ item: WheelItemView) {
        guard let i = items.firstIndex(where: { $0 === item }) else { return }
        if i == index {
            onJump?(item.entry)
        } else {
            move(by: i - index)
        }
    }

    /// Move the selection, stopping at the ends: the wheel is a bounded
    /// plane, not a ring.
    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(index + delta, 0), items.count - 1)
        guard next != index else { return }
        index = next
        clearHover()
        positionTrack(animated: true)
        layoutStage()
        renderSelection()
        onSelectionChange?(selection)
    }

    // MARK: - Live mirrors

    private var mirrorTimer: Timer?
    private var scrollMonitor: Any?
    private var tick = 0

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        mirrorTimer?.invalidate()
        mirrorTimer = nil
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        clearHover()
        guard superview != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshMirrors()
        }
        RunLoop.main.add(timer, forMode: .common)
        mirrorTimer = timer

        // Delivery is a local .scrollWheel NSEvent monitor, not a view
        // override; see CLAUDE.md's stage-scroll invariants.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            guard let self, event.window === window else { return event }
            if let pane = selection?.pane, !stage.isHidden,
               stage.frame.contains(convert(event.locationInWindow, from: nil)) {
                // Position before scroll; see CLAUDE.md's stage-scroll invariants.
                if hoverPane !== pane {
                    hoverPane?.clearMousePos()
                    hoverPane = pane
                }
                let p = stage.convert(event.locationInWindow, from: nil)
                pane.reportMousePos(
                    topLeft: NSPoint(
                        x: p.x / max(stage.bounds.width, 1) * pane.bounds.width,
                        y: p.y / max(stage.bounds.height, 1) * pane.bounds.height
                    ),
                    flags: event.modifierFlags
                )
                pane.scrollWheel(with: event)
            }
            return nil
        }
        refreshMirrors()
    }

    private weak var hoverPane: PaneView?

    private func clearHover() {
        hoverPane?.clearMousePos()
        hoverPane = nil
    }

    private func refreshMirrors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items {
            item.thumb.mirror.contents = item.entry.pane?.layer?.contents
        }
        stage.mirror.contents = selection?.pane?.layer?.contents
        CATransaction.commit()
        tick += 1
        if tick % 15 == 0 {
            renderSelection()
        }
    }

    // MARK: - Layout

    /// The whole pane area: the scrim covers everything, and this
    /// overlay's own layout puts the air, the stage and the wheel inside.
    func desiredSize(in bounds: NSRect) -> NSSize {
        bounds.size
    }

    override func layout() {
        super.layout()
        scrim.frame = bounds
        wheel.frame = NSRect(
            x: bounds.width - Self.margin - Self.wheelWidth,
            y: Self.margin,
            width: Self.wheelWidth,
            height: max(0, bounds.height - Self.margin - Self.bottomReserve)
        )
        positionTrack(animated: false)
        layoutStage()
    }

    /// Stack the cards top-down, then translate the whole track so the
    /// selected card's center sits at the wheel's center. The translate
    /// is the wheel's only motion: one spring, retargetable mid-flight.
    ///
    /// Sessions are not headed or numbered: the wider gap where the
    /// session index changes is the grouping, and the session indicator
    /// highlights the selection's number live.
    private func positionTrack(animated: Bool) {
        var y: CGFloat = 0
        for (i, item) in items.enumerated() {
            if i > 0, item.entry.sessionIndex != items[i - 1].entry.sessionIndex {
                y += Self.sectionGap - Self.itemGap
            }
            let height = item.height(for: Self.wheelWidth)
            item.frame = NSRect(x: 0, y: y, width: Self.wheelWidth, height: height)
            y += height + Self.itemGap
        }

        let selectedMid = items.indices.contains(index) ? items[index].frame.midY : 0
        let from = track.layer.map { $0.presentation()?.position ?? $0.position }
        track.frame = NSRect(
            x: 0, y: (wheel.bounds.height / 2 - selectedMid).rounded(),
            width: Self.wheelWidth, height: y
        )
        guard animated, let layer = track.layer, let from,
              from != layer.position else { return }
        let spring = CASpringAnimation(keyPath: "position")
        spring.stiffness = 1200
        spring.damping = 68
        spring.mass = 1
        spring.duration = spring.settlingDuration
        spring.fromValue = from
        layer.add(spring, forKey: "wheel")
    }

    private func layoutStage() {
        guard let pane = selection?.pane else {
            stage.isHidden = true
            stageTitle.isHidden = true
            stageMeta.isHidden = true
            return
        }
        stage.isHidden = false
        stageTitle.isHidden = false
        stageMeta.isHidden = false

        let areaX = Self.margin
        let areaY = Self.margin
        let areaW = max(1, wheel.frame.minX - Self.gap - areaX)
        let labelBlock = (Chrome.fontSize * 2.7).rounded()
        let areaH = max(1, bounds.height - Self.bottomReserve - areaY - Self.margin - labelBlock)

        var w = areaW
        var h = (w / pane.aspect).rounded()
        if h > areaH {
            h = areaH
            w = (h * pane.aspect).rounded()
        }
        stage.frame = NSRect(
            x: (areaX + (areaW - w) / 2).rounded(),
            y: (areaY + (areaH - h) / 2).rounded(),
            width: w, height: h
        )

        stageTitle.sizeToFit()
        stageMeta.sizeToFit()
        let maxLabelWidth = max(0, stage.frame.width - 1)
        let hasTitle = stageTitle.attributedStringValue.length > 0
        stageTitle.isHidden = !hasTitle
        let labelY = stage.frame.maxY + 10
        stageTitle.frame = NSRect(
            x: stage.frame.minX + 1,
            y: labelY,
            width: min(stageTitle.frame.width, maxLabelWidth),
            height: stageTitle.frame.height
        )
        stageMeta.frame = NSRect(
            x: stage.frame.minX + 1,
            y: hasTitle ? stageTitle.frame.maxY + 3 : labelY,
            width: min(stageMeta.frame.width, maxLabelWidth),
            height: stageMeta.frame.height
        )
    }

    // MARK: - Rendering

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        // The scrim is the panel background, not black: the stage text is
        // palette.text, which on the light palette is dark and vanished on
        // a black scrim. Same alpha both ways.
        scrim.layer?.backgroundColor = palette.panelBg.withAlphaComponent(0.95).cgColor
        stage.layer?.backgroundColor = palette.panelBg.cgColor
        // Square hairline, like every other piece of mux chrome: the
        // border sits exactly on the rectangular terminal content, no
        // rounded corners clipping cells or fuzzing the edge, one device
        // pixel wide.
        stage.layer?.borderColor = palette.accent.cgColor
        stage.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        renderSelection()
        needsLayout = true
    }

    private func renderSelection() {
        let palette = ThemeManager.shared.palette
        for (i, item) in items.enumerated() {
            item.render(
                palette: palette,
                selected: i == index,
                cameFrom: item.entry.paneID == cameFrom
            )
            item.alphaValue = i == index ? 1 : (abs(i - index) == 1 ? 0.6 : 0.35)
        }

        guard let entry = selection, let pane = entry.pane else { return }
        // Line one is the agent: its state glyph, its topic, either alone
        // when that is all there is, and nothing at all when the pane has
        // neither (the directory line moves up).
        let title = NSMutableAttributedString()
        if let glyph = Self.stateGlyph(for: pane, palette: palette, font: Chrome.uiTitleFont) {
            title.append(glyph)
        }
        if let topic = pane.agent?.topic, !topic.isEmpty {
            title.append(NSAttributedString(
                string: topic,
                attributes: [.font: Chrome.uiTitleFont, .foregroundColor: palette.text]
            ))
        }
        stageTitle.attributedStringValue = title

        let meta = NSMutableAttributedString()
        if let dir = pane.promptDir {
            meta.append(NSAttributedString(
                string: dir + " ",
                attributes: [.font: Chrome.metaFont, .foregroundColor: palette.dim]
            ))
        }
        meta.append(NSAttributedString(
            string: "[\(pane.target ?? "local")]",
            attributes: [.font: Chrome.metaBoldFont, .foregroundColor: palette.pink]
        ))
        stageMeta.attributedStringValue = meta
        needsLayout = true
    }

    static func stateGlyph(
        for pane: PaneView, palette: Palette, font: NSFont
    ) -> NSAttributedString? {
        guard let state = pane.agent?.state else { return nil }
        let (glyph, color): (String, NSColor) = switch state {
        case .working: ("\u{25D0}", palette.busy)
        case .idle: ("\u{2713}", palette.ok)
        case .blocked: ("\u{00D7}", palette.bad)
        }
        return NSAttributedString(
            string: glyph + " ", attributes: [.font: font, .foregroundColor: color]
        )
    }
}

/// One wheel card: the mirrored framebuffer at the pane's true aspect,
/// its title underneath in the product voice.
private final class WheelItemView: FlippedView {
    let entry: CanvasOverlayView.Entry
    let thumb = MirrorHostView(radius: 10, offset: 5, opacity: 0.4)

    private let titleLabel = NSTextField(labelWithString: "")

    /// The pane's real frame ratio; the card never stretches it.
    private var aspect: CGFloat {
        entry.pane?.aspect ?? 16.0 / 9.0
    }

    private static let labelHeight = (Chrome.fontSize * 1.15).rounded()

    init(entry: CanvasOverlayView.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        addSubview(thumb)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    func height(for width: CGFloat) -> CGFloat {
        let thumbHeight = min(max((width / aspect).rounded(), 40), (width * 1.6).rounded())
        return thumbHeight + 4 + Self.labelHeight
    }

    /// The whole card is one click target; labels never swallow the hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let thumbHeight = bounds.height - 4 - Self.labelHeight
        thumb.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thumbHeight)
        titleLabel.frame = NSRect(
            x: 1, y: thumbHeight + 4, width: bounds.width - 2, height: Self.labelHeight
        )
    }

    func render(palette: Palette, selected: Bool, cameFrom: Bool) {
        let line = NSMutableAttributedString()
        if cameFrom {
            line.append(NSAttributedString(
                string: "\u{25C6} ",
                attributes: [.font: Chrome.metaFont, .foregroundColor: palette.accent]
            ))
        }
        if let pane = entry.pane {
            if let glyph = CanvasOverlayView.stateGlyph(
                for: pane, palette: palette, font: Chrome.metaFont
            ) {
                line.append(glyph)
            }
            line.append(NSAttributedString(
                string: pane.target ?? "local",
                attributes: [.font: Chrome.metaFont, .foregroundColor: palette.pink]
            ))
        }
        titleLabel.attributedStringValue = line
        thumb.layer?.backgroundColor = palette.panelBg.cgColor
        // One device-pixel hairline for every card: the selection is
        // loudest through the accent color, not a thicker stroke.
        thumb.layer?.borderColor = selected
            ? palette.accent.cgColor
            : palette.dim.withAlphaComponent(0.35).cgColor
        thumb.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        needsLayout = true
    }
}

/// A pane's framebuffer, mirrored: ghostty publishes each frame as an
/// IOSurface in the pane layer's `contents` and `mirror` shows the same
/// object - zero copy, GPU-scaled, and the pane's own frame is never
/// touched. Depth is what separates it from the wall behind it: one soft
/// shadow, path-backed so it costs a blit, not a mask pass.
private final class MirrorHostView: FlippedView {
    let mirror = CALayer()

    init(radius: CGFloat, offset: CGFloat, opacity: Float) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = opacity
        layer?.shadowRadius = radius
        layer?.shadowOffset = CGSize(width: 0, height: offset)
        mirror.contentsGravity = .resizeAspect
        mirror.masksToBounds = true
        layer?.addSublayer(mirror)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirror.frame = bounds
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
        CATransaction.commit()
    }
}

