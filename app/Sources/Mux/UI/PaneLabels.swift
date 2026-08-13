import AppKit

/// The one grammar for pane labels everywhere they exist (prefix tags,
/// wheel cards, the stage): title · host · directory, deduplicated. A
/// remote shell often titles itself after its host, and a local one
/// after its directory - repeating the word teaches nothing. When the
/// title IS the host, the host keeps the slot: where a pane lives
/// outranks what it calls itself.
enum PaneLabelParts {
    enum Role {
        case title
        case host
        case dir
    }

    static func parts(for pane: PaneView) -> [(text: String, role: Role)] {
        // Every pane wears a host badge - local too, in the same pink,
        // so the grammar reads identically everywhere.
        let host = pane.target ?? "local"
        var title = pane.displayTitle

        // Shell title formats often lead with their own host - "(spark)
        // ~/x", "[spark] x", "spark: x". The badge already says it, in
        // pink; strip the repeat instead of printing it twice.
        for prefix in ["(\(host))", "[\(host)]", "\(host):"]
            where title.lowercased().hasPrefix(prefix.lowercased())
        {
            title = String(title.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            break
        }

        var out: [(text: String, role: Role)] = []
        if title.isEmpty || title.caseInsensitiveCompare(host) == .orderedSame {
            out.append((host, .host))
        } else {
            out.append((title, .title))
            out.append((host, .host))
        }

        // A path-shaped title already names the directory better than
        // its tail could; otherwise add the tail unless it repeats a
        // word already on the label.
        let titleIsPath = title.hasPrefix("~") || title.hasPrefix("/")
        if !titleIsPath,
           let dir = (pane.pwd as NSString?)?.lastPathComponent, !dir.isEmpty,
           !out.contains(where: { $0.text.caseInsensitiveCompare(dir) == .orderedSame })
        {
            out.append((dir, .dir))
        }
        return out
    }

    /// The pane's directory the way its prompt would print it: the full
    /// path with the home prefix folded to `~`. Remote paths fold their
    /// own home (/home/x or /Users/x) - the pane's pwd names the pane's
    /// host, so the abbreviation reads exactly like a prompt there.
    static func promptDir(for pane: PaneView) -> String? {
        guard var dir = pane.pwd, !dir.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if dir == home || dir.hasPrefix(home + "/") {
            dir = "~" + dir.dropFirst(home.count)
        } else if let match = dir.range(
            of: "^/(home|Users)/[^/]+", options: .regularExpression
        ) {
            dir = "~" + dir[match.upperBound...]
        }
        return dir
    }
}

/// A tag flush with a pane's top-right corner while the prefix is
/// armed: the pane's host, in pink, and nothing else - titles and
/// directories belong to the canvas. Styled exactly like the bottom
/// bars: an opaque panel_bg box at bar height with the same half-slack
/// text inset, square corners, no shadow.
final class PaneLabelView: NSView {
    private weak var pane: PaneView?
    private let label = NSTextField(labelWithString: "")

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// The frame of the pane this label sits on, in container
    /// coordinates (the workspace sits at the origin). nil hides the
    /// label (the pane went away or is covered).
    var paneFrame: CGRect? {
        guard let host = pane?.scrollHost, !host.isHidden else { return nil }
        return host.frame
    }

    /// Display only: clicks fall through to the pane below.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// The bottom bars' text inset (half their vertical slack), applied
    /// on ALL four sides here: the tag hugs its text symmetrically, so
    /// nothing reads as a gap between the box and the pane corner.
    private var textInset: CGFloat {
        (max(0, (ModeBarView.height - label.fittingSize.height) / 2) / 2).rounded()
    }

    /// Size the tag to its text plus the shared inset; the positioner
    /// may then clamp the width, and layout keeps the text inset either
    /// way.
    func fit() {
        let size = label.fittingSize
        setFrameSize(NSSize(
            width: size.width + textInset * 2,
            height: size.height + textInset * 2
        ))
    }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        let inset = textInset
        label.frame = NSRect(
            x: inset,
            y: inset,
            width: min(size.width, bounds.width - inset * 2),
            height: size.height
        )
    }

    /// Labels are momentary (the prefix is armed for a beat) and are
    /// rebuilt on every show; no live refresh needed.
    private func render() {
        guard let pane else { return }
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.cgColor
        // The host alone, in pink (the active-item color), never gray -
        // the session indicator's highlight voice.
        label.attributedStringValue = NSAttributedString(
            string: pane.target ?? "local",
            attributes: [
                .font: Chrome.boldFont,
                .foregroundColor: palette.pink,
            ]
        )
    }
}
