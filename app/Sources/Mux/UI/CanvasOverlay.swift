import AppKit

/// The canvas (prefix f): a pane picker floating over the dimmed live
/// workspace, with air on all sides - not a docked panel.
///
/// Right: the wheel - every pane as a card at its TRUE frame aspect,
/// grouped under small session headers. The selection is always held at
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
final class CanvasOverlayView: NSView {
    struct Entry {
        let sessionIndex: Int
        let paneID: UUID
        weak var pane: PaneView?
    }

    /// One session's cards. No header, no session number: the gap
    /// between groups is the grouping, and the session indicator
    /// highlights the selection's number live.
    struct Group {
        let entries: [Entry]
    }

    // One spacing scale, derived from the chrome size knob.
    private static let margin: CGFloat = Chrome.fontSize * 2
    private static let gap: CGFloat = Chrome.fontSize * 1.6
    private static let wheelWidth: CGFloat = Chrome.fontSize * 9
    private static let itemGap: CGFloat = 10
    private static let sectionGap: CGFloat = 22
    /// The floating badges keep their bottom strip.
    private static let bottomReserve: CGFloat = ModeBarView.height + ModeBarView.margin * 2

    /// A click on a card that is already selected - or on the stage -
    /// jumps; the controller commits and tells PrefixEngine to leave
    /// the mode.
    var onJump: ((Entry) -> Void)?
    /// A click on the scrim leaves the mode, like esc.
    var onCancel: (() -> Void)?
    /// Fires whenever the selection lands somewhere (reload, j/k, click):
    /// the session indicator follows it live, so the numbers tell you
    /// which session you are scrolling through as you scroll.
    var onSelectionChange: ((Entry?) -> Void)?

    private let scrim = ScrimView()
    private let stage = StageView()
    private let stageMirror = CALayer()
    private let stageTitle = NSTextField(labelWithString: "")
    private let stageMeta = NSTextField(labelWithString: "")
    private let wheel = FlippedView()
    private let track = FlippedView()

    private var groups: [Group] = []
    private var items: [WheelItemView] = []
    private var index = 0
    /// The pane the user came from (the focused pane on open).
    private var cameFrom: UUID?

    var selection: Entry? {
        guard items.indices.contains(index) else { return nil }
        return items[index].entry
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        scrim.onClick = { [weak self] in self?.onCancel?() }
        addSubview(scrim)

        stage.wantsLayer = true
        stage.layer?.borderWidth = 1
        stage.layer?.cornerRadius = 8
        // Depth is what separates the stage from the wall behind it:
        // one wide soft shadow, path-backed so it costs a blit, not a
        // mask pass.
        stage.layer?.shadowColor = NSColor.black.cgColor
        stage.layer?.shadowOpacity = 0.55
        stage.layer?.shadowRadius = 28
        stage.layer?.shadowOffset = CGSize(width: 0, height: 14)
        stageMirror.contentsGravity = .resizeAspect
        stageMirror.cornerRadius = 7
        stageMirror.masksToBounds = true
        stage.layer?.addSublayer(stageMirror)
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
    func reload(groups: [Group], selected: UUID?) {
        self.groups = groups
        cameFrom = selected

        for view in items {
            view.removeFromSuperview()
        }
        items = []

        for group in groups {
            for entry in group.entries {
                let item = WheelItemView(entry: entry)
                item.onClick = { [weak self] in self?.clicked(item) }
                track.addSubview(item)
                items.append(item)
            }
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
        positionTrack(animated: true)
        layoutStage()
        renderSelection()
        onSelectionChange?(selection)
        // The stage retargets with a blink-quick tick, not a crossfade:
        // the mirror swap is instant, this only softens the cut.
        if let layer = stage.layer {
            let tick = CABasicAnimation(keyPath: "opacity")
            tick.fromValue = 0.7
            tick.toValue = 1
            tick.duration = 0.13
            tick.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(tick, forKey: "stage-tick")
        }
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

    /// One pointer read and one assignment per mirror: the pane's layer
    /// holds the IOSurface of its latest frame, the mirrors show the
    /// same object. Titles drift slower, so they refresh on a coarser
    /// beat.
    private func refreshMirrors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items {
            item.mirror.contents = item.entry.pane?.layer?.contents
        }
        stageMirror.contents = selection?.pane?.layer?.contents
        CATransaction.commit()
        tick += 1
        if tick % 15 == 0 {
            renderSelection()
        }
    }

    // MARK: - Layout

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

    /// Stack headers and cards top-down, then translate the whole track
    /// so the selected card's center sits at the wheel's center. The
    /// translate is the wheel's only motion: one spring, retargetable
    /// mid-flight.
    private func positionTrack(animated: Bool) {
        var y: CGFloat = 0
        var itemIndex = 0
        for group in groups {
            for _ in group.entries {
                let item = items[itemIndex]
                let height = item.height(for: Self.wheelWidth)
                item.frame = NSRect(x: 0, y: y, width: Self.wheelWidth, height: height)
                y += height + Self.itemGap
                itemIndex += 1
            }
            y += Self.sectionGap - Self.itemGap
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

    /// The stage box takes the pane's true frame aspect and fits it into
    /// the space left of the wheel - scaled uniformly, never stretched,
    /// never resizing anything.
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
        // Two stacked descriptor lines under the stage: title, then
        // directory + host.
        let labelBlock = (Chrome.fontSize * 2.7).rounded()
        let areaH = max(1, bounds.height - Self.bottomReserve - areaY - Self.margin - labelBlock)

        let size = pane.bounds.size
        let aspect = size.width > 1 && size.height > 1 ? size.width / size.height : 16.0 / 9.0
        var w = areaW
        var h = (w / aspect).rounded()
        if h > areaH {
            h = areaH
            w = (h * aspect).rounded()
        }
        stage.frame = NSRect(
            x: (areaX + (areaW - w) / 2).rounded(),
            y: (areaY + (areaH - h) / 2).rounded(),
            width: w, height: h
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageMirror.frame = stage.bounds
        stage.layer?.shadowPath = CGPath(
            roundedRect: stage.bounds, cornerWidth: 8, cornerHeight: 8, transform: nil
        )
        CATransaction.commit()

        stageTitle.sizeToFit()
        stageMeta.sizeToFit()
        let maxLabelWidth = max(0, stage.frame.width - 1)
        // No topic line: the directory line moves up and stands alone.
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
        // The scrim drops the workspace well back - Mission Control
        // dark, not a light mist - so the live mirrors carry all the
        // brightness in the room.
        let dark = !palette.panelBg.isLightColor
        scrim.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(dark ? 0.9 : 0.62).cgColor
        stage.layer?.backgroundColor = palette.panelBg.cgColor
        stage.layer?.borderColor = palette.accent.cgColor
        renderSelection()
        needsLayout = true
    }

    /// Everything that follows the selection or the live panes: card
    /// labels and borders, distance fades, the stage labels.
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
        // The stage descriptor, two stacked lines and nothing else:
        //   <state glyph> <agent topic>
        //   <directory> [<host>]
        // No session number - the session indicator highlights the
        // selection's session live instead.
        // The first line exists only when the pane announces an agent
        // (the state glyph is the proof); a bare shell gets no first
        // line at all, whatever it titled itself - shells love titling
        // themselves after their directory, which the second line
        // already says.
        let title = NSMutableAttributedString()
        if let glyph = Self.stateGlyph(for: pane, palette: palette, font: Chrome.uiTitleFont) {
            title.append(glyph)
            let topic = pane.displayTitle
            if !topic.isEmpty {
                title.append(NSAttributedString(
                    string: topic,
                    attributes: [.font: Chrome.uiTitleFont, .foregroundColor: palette.text]
                ))
            }
        }
        stageTitle.attributedStringValue = title

        let meta = NSMutableAttributedString()
        if let dir = PaneLabelParts.promptDir(for: pane) {
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

    /// The agent-state indicator shared by the stage and the cards.
    /// Exactly two states: ◐ working (busy yellow), ✓ done (ok green).
    /// Nothing for panes that announce no state.
    static func stateGlyph(
        for pane: PaneView, palette: Palette, font: NSFont
    ) -> NSAttributedString? {
        guard let state = pane.agentState else { return nil }
        let working = state == .working
        return NSAttributedString(
            string: (working ? "\u{25D0}" : "\u{2713}") + " ",
            attributes: [
                .font: font,
                .foregroundColor: working ? palette.busy : palette.ok,
            ]
        )
    }
}

/// One wheel card: the mirrored framebuffer at the pane's true aspect,
/// its title underneath in the product voice.
private final class WheelItemView: NSView {
    let entry: CanvasOverlayView.Entry
    let mirror = CALayer()
    var onClick: (() -> Void)?

    private let thumb = NSView()
    private let titleLabel = NSTextField(labelWithString: "")

    /// The pane's real frame ratio; the card never stretches it.
    private var aspect: CGFloat {
        let size = entry.pane?.bounds.size ?? .zero
        guard size.width > 1, size.height > 1 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    private static let labelHeight = (Chrome.fontSize * 1.15).rounded()

    init(entry: CanvasOverlayView.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.shadowColor = NSColor.black.cgColor
        thumb.layer?.shadowOpacity = 0.4
        thumb.layer?.shadowRadius = 10
        thumb.layer?.shadowOffset = CGSize(width: 0, height: 5)
        mirror.contentsGravity = .resizeAspect
        mirror.cornerRadius = 4.5
        mirror.masksToBounds = true
        thumb.layer?.addSublayer(mirror)
        addSubview(thumb)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(for width: CGFloat) -> CGFloat {
        let thumbHeight = min(max((width / aspect).rounded(), 40), (width * 1.6).rounded())
        return thumbHeight + 4 + Self.labelHeight
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
        let thumbHeight = bounds.height - 4 - Self.labelHeight
        thumb.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thumbHeight)
        titleLabel.frame = NSRect(
            x: 1, y: thumbHeight + 4, width: bounds.width - 2, height: Self.labelHeight
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirror.frame = thumb.bounds
        thumb.layer?.shadowPath = CGPath(
            roundedRect: thumb.bounds, cornerWidth: 5, cornerHeight: 5, transform: nil
        )
        CATransaction.commit()
    }

    func render(palette: Palette, selected: Bool, cameFrom: Bool) {
        let line = NSMutableAttributedString()
        if cameFrom {
            line.append(NSAttributedString(
                string: "\u{25C6} ",
                attributes: [.font: Chrome.metaFont, .foregroundColor: palette.accent]
            ))
        }
        // Cards carry only the state glyph and the host - topics and
        // directories live on the stage, where there is room to read
        // them.
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
        thumb.layer?.borderColor = selected
            ? palette.accent.cgColor
            : palette.dim.withAlphaComponent(0.35).cgColor
        thumb.layer?.borderWidth = selected ? 2 : 1
        needsLayout = true
    }
}

/// The dimming layer under the picker; a click on it cancels, like esc.
private final class ScrimView: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }
}

/// The stage box; a click on it jumps to the previewed pane.
private final class StageView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
