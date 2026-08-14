import AppKit

/// The hosts window (prefix t): the one surface for "where can a pane live".
/// A content-sized bordered box listing `local`, the aliases from hosts.json
/// with the address the daemon dials and a live probe status (a machine that
/// is off reads differently from one that rejected our key), and the ix VMs
/// the CLI reports. Enter splits right into the highlighted machine, H/J/K/L
/// split in a direction, c opens a new session there, n creates a VM, y
/// copies this client's identity digest - the thing the user pastes into a
/// host's authorized list.
///
/// `t` swaps the list for the ix templates a new VM is built from; enter
/// there persists the default and comes back. All queries fire on open and
/// fill in as they answer, so the box is usable immediately. Sizing is
/// sticky so late answers don't walk the edges around: pending statuses
/// reserve the width of a typical resolved one, the box only grows within
/// one open, and each open starts from the last open's final size (a
/// shrunken fleet corrects itself on the next open). PrefixEngine owns the
/// keys; the window never takes focus.
final class HostsWindowView: NSView {
    /// A host's live state as it reads on screen.
    private enum Status {
        case none
        /// Asked, still waiting.
        case pending
        case ok(String)
        case bad(String)
        /// Reported by someone else (a VM's own lifecycle state).
        case plain(String)
    }

    private enum Kind {
        case heading
        /// Shown but not selectable: an empty hosts file, a VM that is not
        /// running.
        case inert
        /// A machine a pane can live on; the payload is the pane target,
        /// nil for local.
        case host(String?)
        /// An `ix new` target.
        case template(String)
    }

    private struct Row {
        let kind: Kind
        let text: String
        /// Dim context beside the name: a host's address.
        let detail: String
        var status: Status = .none
        /// Marks the row that is already in effect (the current default
        /// template), like the panes overlay marks the pane you came from.
        var current: Bool = false

        var selectable: Bool {
            switch kind {
            case .host, .template: true
            case .heading, .inert: false
            }
        }
    }

    private static let font = Chrome.font
    private static let boldFont = Chrome.boldFont
    private static let inset: CGFloat = 14
    private static let rowHeight = Chrome.rowHeight
    /// Minimum gap between a row's name and its right-aligned status.
    private static let gap: CGFloat = 24
    /// Width reserved for a pending status, sized to a typical resolved
    /// probe, so an answer landing does not widen the box.
    private static let statusReserve = ("ok 100ms  10 ptys" as NSString)
        .size(withAttributes: [.font: font]).width

    private let titleLabel = NSTextField(labelWithString: "hosts")
    private let cancelBadge = NSTextField(labelWithString: " esc close ")
    private let footerLabel = NSTextField(labelWithString: "")
    private let selectionBar = NSView()
    private var mainLabels: [NSTextField] = []
    private var metaLabels: [NSTextField] = []

    /// The machine list and the template list are kept side by side, each
    /// with its own highlight, so `t` and back is not a reload: the probes
    /// that already answered stay answered.
    private var hostRows: [Row] = []
    private var templateRows: [Row] = []
    private var hostIndex = 0
    private var templateIndex = 0

    /// True while the template list is up. esc backs out of it instead of
    /// closing the window.
    private(set) var pickingTemplate = false

    /// The full client digest, once muxd has answered.
    private var digest: String?
    private var copied = false

    /// Bumped on every open, so answers to a previous open cannot land in
    /// the current lists.
    private var generation = 0

    /// Bumped on every entry into the template list, so a slow listing
    /// cannot append to a list that has since been rebuilt. Separate from
    /// `generation` because entering the submode must not discard the host
    /// probes still in flight behind it.
    private var templateGeneration = 0

    /// Called when late rows or a resolved status change the content size,
    /// so the controller can re-center the box.
    var onContentChange: (() -> Void)?

    /// The largest size this open has needed: the box never shrinks while
    /// it is up.
    private var grownSize = NSSize.zero
    /// The previous open's final size, used as this open's floor: the fleet
    /// is stable, so the box usually appears at full size and stays put.
    private var carriedSize = NSSize.zero

    private var rows: [Row] {
        pickingTemplate ? templateRows : hostRows
    }

    private var index: Int {
        get { pickingTemplate ? templateIndex : hostIndex }
        set {
            if pickingTemplate {
                templateIndex = newValue
            } else {
                hostIndex = newValue
            }
        }
    }

    /// The highlighted machine, or nil when nothing selectable is
    /// highlighted. `.explicit(nil)` is local, which is why this is a
    /// NewPaneTarget and not a plain string.
    var selectedHost: NewPaneTarget? {
        guard !pickingTemplate, rows.indices.contains(index),
              case let .host(target) = rows[index].kind else { return nil }
        return .explicit(target)
    }

    /// The highlighted `ix new` target while the template list is up.
    var selectedTemplate: String? {
        guard pickingTemplate, rows.indices.contains(index),
              case let .template(value) = rows[index].kind else { return nil }
        return value
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        selectionBar.wantsLayer = true
        addSubview(selectionBar)
        addSubview(titleLabel)
        addSubview(cancelBadge)
        addSubview(footerLabel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(render),
            name: .muxThemeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    // MARK: - Machines

    /// Rebuild from hosts.json and kick off every live query. Local and the
    /// aliases appear at once, with a pending status; the probes, the VM
    /// list and the digest fill in as they answer.
    func reload() {
        generation += 1
        let generation = generation
        carriedSize = grownSize
        grownSize = .zero
        copied = false
        digest = nil
        pickingTemplate = false
        templateRows = []
        templateIndex = 0

        let hosts = HostsConfig.entries()
        // No leading "hosts" heading row: the title band already says it.
        hostRows = [
            Row(kind: .host(nil), text: "local", detail: "this mac"),
        ]
        if hosts.isEmpty {
            hostRows.append(Row(
                kind: .inert, text: "none in ~/.config/mux/hosts.json", detail: ""
            ))
        }
        hostRows += hosts.map {
            Row(kind: .host($0.alias), text: $0.alias, detail: $0.addr, status: .pending)
        }
        hostIndex = 0
        resetHighlight()
        refresh()

        for host in hosts {
            Muxd.probe(alias: host.alias) { [weak self] probe in
                // Match on the target, not the label: an alias is free to
                // be spelled like anything else in the list.
                guard let self, generation == self.generation,
                      let row = hostRows.firstIndex(where: {
                          if case let .host(target) = $0.kind { target == host.alias } else { false }
                      })
                else { return }
                hostRows[row].status = Self.status(of: probe)
                refresh()
            }
        }

        IX.list { [weak self] vms in
            guard let self, generation == self.generation, !vms.isEmpty else { return }
            hostRows.append(Row(kind: .heading, text: "ix vms", detail: ""))
            hostRows += vms.map {
                Row(
                    // Only a running VM can take a shell; the rest are
                    // listed for their status and skipped by navigation.
                    kind: $0.isRunning ? .host(IX.prefix + $0.name) : .inert,
                    text: $0.name, detail: "", status: .plain($0.status)
                )
            }
            resetHighlight()
            refresh()
        }

        Muxd.clientDigest { [weak self] digest in
            guard let self, generation == self.generation else { return }
            self.digest = digest
            refresh()
        }
    }

    // MARK: - Templates

    /// t: swap in the templates a new VM would be built from. `default` is
    /// always offered - it needs no listing and always works - and the
    /// current default is marked.
    func showTemplates() {
        let current = IXConfig.template()
        pickingTemplate = true
        // Same as the machines: the title band names the list.
        templateRows = [
            Row(
                kind: .template(IX.defaultTemplate), text: IX.defaultTemplate,
                detail: "platform base", current: current == IX.defaultTemplate
            ),
        ]
        templateIndex = 0
        resetHighlight()
        refresh()

        templateGeneration += 1
        let templateGeneration = templateGeneration
        IX.templates { [weak self] templates in
            guard let self, templateGeneration == self.templateGeneration,
                  !templates.isEmpty else { return }
            templateRows += templates.map {
                Row(
                    kind: .template($0.value), text: $0.label, detail: "",
                    current: $0.value == current
                )
            }
            resetHighlight()
            refresh()
        }
    }

    /// Back to the machines, leaving their answered probes as they were.
    func showHosts() {
        pickingTemplate = false
        refresh()
    }

    /// Enter in the template list: persist the highlighted target as the
    /// default for new VMs and return to the machines.
    func commitTemplate() {
        // Always return to the machines, even with nothing highlighted: the
        // caller has already put the machine list's mode bar back up.
        if let value = selectedTemplate {
            IXConfig.setTemplate(value)
        }
        showHosts()
    }

    // MARK: - Keys

    /// Move the highlight across selectable rows, skipping headings and
    /// dead VMs, wrapping at both ends.
    func move(by delta: Int) {
        let selectable = rows.indices.filter { rows[$0].selectable }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: index) ?? 0
        index = selectable[(position + delta + selectable.count) % selectable.count]
        render()
    }

    /// y: the full digest onto the clipboard. The truncation on screen is
    /// there to be recognized, never to be retyped.
    func copyDigest() {
        guard let digest else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(digest, forType: .string)
        copied = true
        refresh()
    }

    // MARK: - Layout

    /// Content-fitting size, capped to the container. Monotonic within one
    /// open and floored by the previous open's final size, so late answers
    /// re-render in place instead of walking the edges around.
    func desiredSize(in bounds: NSRect) -> NSSize {
        let current = rows
        var body: CGFloat = 0
        for (i, main) in mainLabels.enumerated() where metaLabels.indices.contains(i) {
            var meta = metaLabels[i].fittingSize.width
            if current.indices.contains(i), case .pending = current[i].status {
                meta = max(meta, Self.statusReserve)
            }
            body = max(body, main.fittingSize.width + Self.gap + meta)
        }
        let title = titleLabel.fittingSize.width + Self.gap + cancelBadge.fittingSize.width
        let width = max(body, title, footerLabel.fittingSize.width) + Self.inset * 2
        // Title row, the rows themselves, then the footer row.
        let height = Self.rowHeight * CGFloat(current.count + 2) + Self.inset * 2
        grownSize = NSSize(
            width: max(grownSize.width, width),
            height: max(grownSize.height, height)
        )
        return NSSize(
            width: min(max(grownSize.width, carriedSize.width), bounds.width - 48),
            height: min(max(grownSize.height, carriedSize.height), bounds.height * 0.9)
        )
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let row = Self.rowHeight
        titleLabel.sizeToFit()
        cancelBadge.sizeToFit()
        footerLabel.sizeToFit()
        let titleMidY = bounds.height - inset - row / 2
        titleLabel.frame.origin = NSPoint(x: inset, y: titleMidY - titleLabel.frame.height / 2)
        cancelBadge.frame.origin = NSPoint(
            x: bounds.width - inset - cancelBadge.frame.width,
            y: titleMidY - cancelBadge.frame.height / 2
        )
        footerLabel.frame.origin = NSPoint(
            x: inset, y: inset + (row - footerLabel.frame.height) / 2
        )

        let rowsTop = bounds.height - inset - row
        let current = rows
        selectionBar.isHidden = true
        for (i, main) in mainLabels.enumerated() {
            let meta = metaLabels[i]
            let bandY = rowsTop - row * CGFloat(i + 1)
            // The footer owns the bottom row: rows that would collide with
            // it are simply not shown.
            let visible = bandY >= inset + row
            main.isHidden = !visible
            meta.isHidden = !visible
            guard visible else { continue }

            meta.sizeToFit()
            meta.frame = NSRect(
                x: bounds.width - inset - meta.frame.width,
                y: bandY + (row - meta.frame.height) / 2,
                width: meta.frame.width,
                height: meta.frame.height
            )
            main.sizeToFit()
            main.frame = NSRect(
                x: inset,
                y: bandY + (row - main.frame.height) / 2,
                width: min(main.frame.width, meta.frame.minX - inset - 8),
                height: main.frame.height
            )
            if i == index, current.indices.contains(i), current[i].selectable {
                selectionBar.frame = NSRect(x: 1, y: bandY, width: bounds.width - 2, height: row)
                selectionBar.isHidden = false
            }
        }
    }

    /// The highlight lands on the first selectable row, so enter always
    /// does something. Already-valid highlights are left alone: rows are
    /// only ever appended, and moving the highlight under the user would be
    /// worse than a stale-looking one.
    private func resetHighlight() {
        let current = rows
        guard !current.indices.contains(index) || !current[index].selectable else { return }
        index = current.firstIndex(where: \.selectable) ?? 0
    }

    /// One path for every mutation: rebuild the row labels, recolor, and
    /// let the controller re-center what may have changed size.
    private func refresh() {
        let current = rows
        for label in mainLabels + metaLabels {
            label.removeFromSuperview()
        }
        mainLabels = []
        metaLabels = []
        for _ in current {
            let main = NSTextField(labelWithString: "")
            main.lineBreakMode = .byTruncatingTail
            addSubview(main)
            mainLabels.append(main)
            let meta = NSTextField(labelWithString: "")
            addSubview(meta)
            metaLabels.append(meta)
        }
        render()
        onContentChange?()
    }

    private static func status(of probe: Muxd.Probe) -> Status {
        guard probe.ok else { return .bad(probe.failure) }
        let rtt = probe.rttMs.map { "ok \($0)ms" } ?? "ok"
        guard let ptys = probe.ptys, ptys > 0 else { return .ok(rtt) }
        return .ok("\(rtt)  \(ptys == 1 ? "1 pty" : "\(ptys) ptys")")
    }

    /// `sha256:ab12...ef89` - enough to tell at a glance whether the digest
    /// in your flake is this machine's.
    private static func short(_ digest: String) -> String {
        let hex = digest.dropFirst("sha256:".count)
        guard hex.count > 8 else { return digest }
        return "sha256:\(hex.prefix(4))\u{2026}\(hex.suffix(4))"
    }

    /// The footer: what this window is for. On the machines list that is the
    /// client digest (with the keys that act on it); in the template list it
    /// is what enter will do.
    private var footer: String {
        if pickingTemplate {
            return "enter  set default for new vms"
        }
        let digest = digest.map(Self.short) ?? "client digest unavailable"
        return digest + (copied ? "  copied" : "") + "   y copy   n new vm   t template"
    }

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor
        selectionBar.layer?.backgroundColor = palette.accent.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: pickingTemplate ? "template" : "hosts",
            attributes: [.font: Self.boldFont, .foregroundColor: palette.text]
        )
        let badge = pickingTemplate ? " esc back " : " esc close "
        cancelBadge.attributedStringValue = NSAttributedString(
            string: badge,
            attributes: [
                .font: Self.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ]
        )
        footerLabel.attributedStringValue = NSAttributedString(
            string: footer,
            attributes: [.font: Self.font, .foregroundColor: palette.dim]
        )

        for (i, row) in rows.enumerated() where i < mainLabels.count {
            let selected = i == index && row.selectable
            let main = NSMutableAttributedString()
            // A marker gutter only in the list that has something to mark,
            // so the machines keep their flush left edge.
            if pickingTemplate, row.selectable {
                main.append(NSAttributedString(
                    string: row.current ? "\u{25C6} " : "  ",
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: selected ? palette.accentContrast : palette.accent,
                    ]
                ))
            }
            let bold: Bool = switch row.kind {
            case .heading: true
            case .inert: false
            case .host, .template: selected || row.current
            }
            main.append(NSAttributedString(
                string: row.text,
                attributes: [
                    .font: bold ? Self.boldFont : Self.font,
                    .foregroundColor: selected
                        ? palette.accentContrast
                        : Self.color(of: row.kind, palette: palette),
                ]
            ))
            if !row.detail.isEmpty {
                main.append(NSAttributedString(
                    string: "  " + row.detail,
                    attributes: [
                        .font: Self.font,
                        .foregroundColor: selected ? palette.accentContrast : palette.dim,
                    ]
                ))
            }
            mainLabels[i].attributedStringValue = main

            // On the highlight bar everything switches to the contrast
            // colour: ok-green on accent would be unreadable.
            let (text, color): (String, NSColor) = switch row.status {
            case .none: ("", palette.dim)
            case .pending: ("...", palette.dim)
            case let .ok(value): (value, palette.ok)
            case let .bad(value): (value, palette.bad)
            case let .plain(value): (value, palette.dim)
            }
            metaLabels[i].attributedStringValue = NSAttributedString(
                string: text,
                attributes: [
                    .font: Self.font,
                    .foregroundColor: selected ? palette.accentContrast : color,
                ]
            )
        }
        needsLayout = true
    }

    private static func color(of kind: Kind, palette: Palette) -> NSColor {
        switch kind {
        case .heading: palette.pink
        case .inert: palette.dim
        case .host, .template: palette.text
        }
    }
}
