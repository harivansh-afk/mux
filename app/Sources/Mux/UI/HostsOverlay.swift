import AppKit

/// The hosts overlay (prefix s): a content-sized bordered box listing every
/// machine a pane can live on. `hosts` are the aliases from hosts.json with
/// the address the daemon dials and a live status, probed per host in the
/// background - a machine that is off reads differently from one that
/// rejected our key. `ix vms` is whatever the ix CLI reports, and is absent
/// when there is no ix CLI. The footer carries this client's identity
/// digest, the thing the user pastes into the host's authorized list; the
/// screen only shows enough of it to recognize, `c` copies it in full.
///
/// j/k move the highlight over the rows that can actually host a pane,
/// enter splits right into one. PrefixEngine drives it and it never takes
/// focus.
final class HostsOverlayView: NSView {
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

    private struct Row {
        /// The pane target this row opens. nil for headings and for rows
        /// that cannot host a shell (a stopped VM, an empty hosts file).
        let target: String?
        let heading: Bool
        let text: String
        /// Dim context next to the name: a host's address.
        let detail: String
        var status: Status
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    private static let inset: CGFloat = 14
    private static let rowHeight: CGFloat = 22
    /// Minimum gap between a row's name and its right-aligned status.
    private static let gap: CGFloat = 24

    private let titleLabel = NSTextField(labelWithString: "hosts")
    private let cancelBadge = NSTextField(labelWithString: " esc close ")
    private let footerLabel = NSTextField(labelWithString: "")
    private let selectionBar = NSView()
    private var mainLabels: [NSTextField] = []
    private var metaLabels: [NSTextField] = []
    private var rows: [Row] = []
    private var index = 0

    /// The full client digest, once muxd has answered.
    private var digest: String?
    private var copied = false

    /// Bumped on every open, so answers to a previous open cannot land in
    /// the current list.
    private var generation = 0

    /// Called when late-arriving rows or the digest change the content
    /// size, so the controller can re-center the box.
    var onContentChange: (() -> Void)?

    /// The highlighted row's pane target, if it can host one.
    var selection: String? {
        rows.indices.contains(index) ? rows[index].target : nil
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

    /// Rebuild from hosts.json and kick off every live query. Hosts appear
    /// immediately with a pending status; probes, the VM list and the
    /// digest fill in as they answer.
    func reload() {
        generation += 1
        let generation = generation
        copied = false
        digest = nil

        let hosts = HostsConfig.entries()
        rows = [Row(target: nil, heading: true, text: "hosts", detail: "", status: .none)]
        if hosts.isEmpty {
            rows.append(Row(
                target: nil, heading: false,
                text: "none in ~/.config/mux/hosts.json", detail: "", status: .none
            ))
        }
        rows += hosts.map {
            Row(target: $0.alias, heading: false, text: $0.alias, detail: $0.addr, status: .pending)
        }
        resetHighlight()
        rebuildLabels()

        for host in hosts {
            Muxd.probe(alias: host.alias) { [weak self] probe in
                guard let self, generation == self.generation,
                      let row = rows.firstIndex(where: { $0.target == host.alias })
                else { return }
                rows[row].status = Self.status(of: probe)
                render()
                // A resolved status is wider than the pending "...", so the
                // box has to re-fit or the alias next to it truncates.
                onContentChange?()
            }
        }

        IX.list { [weak self] vms in
            guard let self, generation == self.generation, !vms.isEmpty else { return }
            rows.append(Row(target: nil, heading: true, text: "ix vms", detail: "", status: .none))
            rows += vms.map {
                Row(
                    target: $0.isRunning ? IX.prefix + $0.name : nil,
                    heading: false, text: $0.name, detail: "",
                    status: .plain($0.status)
                )
            }
            resetHighlight()
            rebuildLabels()
            onContentChange?()
        }

        Muxd.clientDigest { [weak self] digest in
            guard let self, generation == self.generation else { return }
            self.digest = digest
            render()
            onContentChange?()
        }
    }

    /// Move the highlight across rows that can host a pane, skipping
    /// headings and dead VMs, wrapping at both ends.
    func move(by delta: Int) {
        let selectable = rows.indices.filter { rows[$0].target != nil }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: index) ?? 0
        index = selectable[(position + delta + selectable.count) % selectable.count]
        render()
    }

    /// c: the full digest onto the clipboard. The truncation on screen is
    /// there to be recognized, never to be retyped.
    func copyDigest() {
        guard let digest else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(digest, forType: .string)
        copied = true
        render()
    }

    /// Content-fitting size, capped to the container.
    func desiredSize(in bounds: NSRect) -> NSSize {
        let body = zip(mainLabels, metaLabels)
            .map { $0.fittingSize.width + Self.gap + $1.fittingSize.width }.max() ?? 0
        let title = titleLabel.fittingSize.width + Self.gap + cancelBadge.fittingSize.width
        let width = max(body, title, footerLabel.fittingSize.width)
        // Title row, the rows themselves, then the footer row.
        let height = Self.rowHeight * CGFloat(rows.count + 2) + Self.inset * 2
        return NSSize(
            width: min(width + Self.inset * 2, bounds.width - 48),
            height: min(height, bounds.height * 0.9)
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
        selectionBar.isHidden = true
        for (i, main) in mainLabels.enumerated() {
            let meta = metaLabels[i]
            let bandY = rowsTop - row * CGFloat(i + 1)
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
            if i == index, rows[i].target != nil {
                selectionBar.frame = NSRect(x: 1, y: bandY, width: bounds.width - 2, height: row)
                selectionBar.isHidden = false
            }
        }
    }

    /// The highlight lands on the first row that can host a pane, so enter
    /// always does something; a list with no such row keeps it off-list.
    private func resetHighlight() {
        guard !rows.indices.contains(index) || rows[index].target == nil else { return }
        index = rows.firstIndex { $0.target != nil } ?? 0
    }

    private func rebuildLabels() {
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
            addSubview(meta)
            metaLabels.append(meta)
        }
        render()
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

    @objc private func render() {
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        layer?.borderColor = palette.dim.cgColor
        selectionBar.layer?.backgroundColor = palette.accent.cgColor

        titleLabel.attributedStringValue = NSAttributedString(
            string: "hosts",
            attributes: [.font: Self.boldFont, .foregroundColor: palette.text]
        )
        cancelBadge.attributedStringValue = NSAttributedString(
            string: " esc close ",
            attributes: [
                .font: Self.boldFont,
                .foregroundColor: palette.accentContrast,
                .backgroundColor: palette.accent,
            ]
        )
        footerLabel.attributedStringValue = NSAttributedString(
            string: digest.map { Self.short($0) + (copied ? "  copied" : "") }
                ?? "client digest unavailable",
            attributes: [.font: Self.font, .foregroundColor: palette.dim]
        )

        for (i, row) in rows.enumerated() {
            let selected = i == index && row.target != nil
            let main = NSMutableAttributedString()
            main.append(NSAttributedString(
                string: row.text,
                attributes: [
                    .font: row.heading || selected ? Self.boldFont : Self.font,
                    .foregroundColor: selected
                        ? palette.accentContrast
                        : row.heading ? palette.pink
                        : row.target == nil ? palette.dim : palette.text,
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
            // colour: green on accent would be unreadable.
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
}
