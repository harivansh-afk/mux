import AppKit

/// The hosts window (prefix t): the one surface for "where can a pane live".
/// A bordered box listing `local`, the aliases from hosts.json with the
/// address the daemon dials and a live probe status (a machine that is off
/// reads differently from one that rejected our key), and the ix VMs the CLI
/// reports. Enter splits right into the highlighted machine, H/J/K/L split in
/// a direction, c opens a new session there, n creates a VM, y copies this
/// client's identity digest - the thing the user pastes into a host's
/// authorized list.
///
/// `t` swaps the list for the ix templates a new VM is built from; enter
/// there persists the default and comes back. All queries fire on open and
/// fill in as they answer, so the box is usable immediately: the width is
/// a fixed column count and the height is the row count, so nothing an
/// answer says can move an edge. PrefixEngine owns the keys; the window
/// never takes focus.
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
    /// The list is this many characters wide. The chrome face is
    /// fixed-advance (Berkeley Mono, or the system mono fallback), so a
    /// character count is an exact column: an alias, its address and a
    /// resolved status sit inside 52, and the footer's longest form
    /// ("client digest unavailable" plus the keys) sets the rest.
    private static let columns = 58
    /// Minimum blank columns between a row's name and its status.
    private static let gap = 2
    /// One column of the chrome face, and the box `columns` of them make.
    private static let boxWidth = (" " as NSString)
        .size(withAttributes: [.font: font]).width * CGFloat(columns) + inset * 2

    /// Every line of the list is exactly one row high, so the selection bar
    /// lands on the highlighted one, with the glyphs lifted from the foot of
    /// that band to the middle of it.
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        return style
    }()

    private static func run(
        _ text: String, _ color: NSColor, bold: Bool = false
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: bold ? boldFont : font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .baselineOffset: (rowHeight - (font.ascender - font.descender)) / 2,
        ])
    }

    private let titleLabel = NSTextField(labelWithString: "hosts")
    private let cancelBadge = NSTextField(labelWithString: " esc close ")
    private let footerLabel = NSTextField(labelWithString: "")
    private let selectionBar = NSView()
    /// The whole list, rows and columns, as one attributed string.
    private let bodyLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.maximumNumberOfLines = 0
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        return field
    }()

    /// What is on screen: the machines, or the templates while `t` is up.
    private var rows: [Row] = []
    private var index = 0

    /// The machines and their highlight, parked while the template list
    /// stands in front of them. `t` and back is not a reload: the probes
    /// that already answered are still answered in here.
    private var stashedHosts: ([Row], Int)?

    /// True while the template list is up. esc backs out of it instead of
    /// closing the window.
    private(set) var pickingTemplate = false

    /// The full client digest, once muxd has answered.
    private var digest: String?
    private var copied = false

    /// Bumped on every open, so answers to a previous open cannot land in
    /// the current lists.
    private var generation = 0

    /// Called when late rows change the content size, so the controller can
    /// re-center the box.
    var onContentChange: (() -> Void)?

    /// The machine list wherever it currently lives: on screen, or in the
    /// stash under the template list. Probe and ix answers land in it
    /// either way, so pressing `t` mid-probe never costs an answer.
    private var hosts: [Row] {
        get { pickingTemplate ? stashedHosts?.0 ?? [] : rows }
        set {
            if pickingTemplate {
                stashedHosts?.0 = newValue
            } else {
                rows = newValue
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
        addSubview(bodyLabel)
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
        copied = false
        digest = nil
        pickingTemplate = false
        stashedHosts = nil

        let entries = HostsConfig.entries()
        // No leading "hosts" heading row: the title band already says it.
        rows = [
            Row(kind: .host(nil), text: "local", detail: "this mac"),
        ]
        if entries.isEmpty {
            rows.append(Row(
                kind: .inert, text: "none in ~/.config/mux/hosts.json", detail: ""
            ))
        }
        rows += entries.map {
            Row(kind: .host($0.alias), text: $0.alias, detail: $0.addr, status: .pending)
        }
        index = 0
        rowsChanged()

        for host in entries {
            Muxd.probe(alias: host.alias) { [weak self] probe in
                // Match on the target, not the label: an alias is free to
                // be spelled like anything else in the list.
                guard let self, generation == self.generation,
                      let row = hosts.firstIndex(where: {
                          if case let .host(target) = $0.kind { target == host.alias } else { false }
                      })
                else { return }
                hosts[row].status = Self.status(of: probe)
                render()
            }
        }

        IX.list { [weak self] vms in
            guard let self, generation == self.generation, !vms.isEmpty else { return }
            hosts += [Row(kind: .heading, text: "ix vms", detail: "")] + vms.map {
                Row(
                    // Only a running VM can take a shell; the rest are
                    // listed for their status and skipped by navigation.
                    kind: $0.isRunning ? .host(IX.prefix + $0.name) : .inert,
                    text: $0.name, detail: "", status: .plain($0.status)
                )
            }
            rowsChanged()
        }

        Muxd.clientDigest { [weak self] digest in
            guard let self, generation == self.generation else { return }
            self.digest = digest
            render()
        }
    }

    // MARK: - Templates

    /// t: swap in the templates a new VM would be built from. `default` is
    /// always offered - it needs no listing and always works - and the
    /// current default is marked.
    func showTemplates() {
        guard !pickingTemplate else { return }
        let generation = generation
        let current = IXConfig.template()
        let base = Row(
            kind: .template(IX.defaultTemplate), text: IX.defaultTemplate,
            detail: "platform base", current: current == IX.defaultTemplate
        )
        stashedHosts = (rows, index)
        pickingTemplate = true
        rows = [base]
        index = 0
        rowsChanged()

        IX.templates { [weak self] templates in
            guard let self, generation == self.generation, pickingTemplate,
                  !templates.isEmpty else { return }
            // Assign, never append: a listing left over from an earlier
            // visit to this list rebuilds the same rows instead of
            // doubling them.
            rows = [base] + templates.map {
                Row(
                    kind: .template($0.value), text: $0.label, detail: "",
                    current: $0.value == current
                )
            }
            rowsChanged()
        }
    }

    /// Back to the machines, leaving their answered probes as they were.
    func showHosts() {
        guard pickingTemplate else { return }
        pickingTemplate = false
        if let stash = stashedHosts {
            (rows, index) = stash
            stashedHosts = nil
        }
        rowsChanged()
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
        render()
    }

    // MARK: - Layout

    /// Fixed width, height from the row count: the title row, the rows, the
    /// footer row. Nothing here is measured from a label, so an answer
    /// landing cannot walk an edge; only a row appearing changes the box,
    /// and only downwards.
    func desiredSize(in bounds: NSRect) -> NSSize {
        NSSize(
            width: min(Self.boxWidth, bounds.width - 48),
            height: min(
                Self.rowHeight * CGFloat(rows.count + 2) + Self.inset * 2,
                bounds.height * 0.9
            )
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

        // The list fills the band between the title and the footer; rows
        // that would collide with the footer are clipped, not shown.
        let rowsTop = bounds.height - inset - row
        let height = min(row * CGFloat(rows.count), max(0, rowsTop - inset - row))
        bodyLabel.frame = NSRect(
            x: inset, y: rowsTop - height,
            width: bounds.width - inset * 2, height: height
        )

        let bandY = rowsTop - row * CGFloat(index + 1)
        let onScreen = rows.indices.contains(index) && rows[index].selectable
            && bandY >= inset + row
        selectionBar.isHidden = !onScreen
        if onScreen {
            selectionBar.frame = NSRect(x: 1, y: bandY, width: bounds.width - 2, height: row)
        }
    }

    /// The row set changed: repaint, and let the controller re-center a box
    /// that may have grown a row. The highlight lands on the first
    /// selectable row so enter always does something, but a highlight that
    /// is still valid stays where it is: moving it under the user as rows
    /// arrive would be worse than one that looks stale.
    private func rowsChanged() {
        if !rows.indices.contains(index) || !rows[index].selectable {
            index = rows.firstIndex(where: \.selectable) ?? 0
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

        bodyLabel.attributedStringValue = body(palette)
        needsLayout = true
    }

    /// The list as one string. Each row is its name, its dim detail, then
    /// blanks out to a status sitting in the last columns; a name with no
    /// room left on the line ends in an ellipsis. On the highlight bar every
    /// colour switches to the contrast one: ok-green on accent would be
    /// unreadable.
    private func body(_ palette: Palette) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, row) in rows.enumerated() {
            let selected = i == index && row.selectable
            let front: NSColor? = selected ? palette.accentContrast : nil
            // A marker gutter only in the list that has something to mark,
            // so the machines keep their flush left edge.
            let marker = pickingTemplate && row.selectable
                ? (row.current ? "\u{25C6} " : "  ") : ""
            let detail = row.detail.isEmpty ? "" : "  " + row.detail
            let (status, statusColor): (String, NSColor) = switch row.status {
            case .none: ("", palette.dim)
            case .pending: ("...", palette.dim)
            case let .ok(value): (value, palette.ok)
            case let .bad(value): (value, palette.bad)
            case let .plain(value): (value, palette.dim)
            }
            let room = Self.columns - marker.count - detail.count
                - status.count - Self.gap
            let name = row.text.count > room
                ? String(row.text.prefix(max(0, room - 1))) + "\u{2026}"
                : row.text
            let bold: Bool = switch row.kind {
            case .heading: true
            case .inert: false
            case .host, .template: selected || row.current
            }
            let pad = String(repeating: " ", count: max(Self.gap, room + Self.gap - name.count))
            out.append(Self.run(i == 0 ? "" : "\n", palette.dim))
            out.append(Self.run(marker, front ?? palette.accent))
            out.append(Self.run(name, front ?? Self.color(of: row.kind, palette: palette), bold: bold))
            out.append(Self.run(detail + pad, front ?? palette.dim))
            out.append(Self.run(status, front ?? statusColor))
        }
        return out
    }

    private static func color(of kind: Kind, palette: Palette) -> NSColor {
        switch kind {
        case .heading: palette.pink
        case .inert: palette.dim
        case .host, .template: palette.text
        }
    }
}
