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
        let title = pane.displayTitle
        var out: [(text: String, role: Role)] = []
        if let host = pane.target, title.caseInsensitiveCompare(host) == .orderedSame {
            out.append((host, .host))
        } else {
            if !title.isEmpty {
                out.append((title, .title))
            }
            if let host = pane.target {
                out.append((host, .host))
            }
        }
        if let dir = (pane.pwd as NSString?)?.lastPathComponent, !dir.isEmpty,
           !out.contains(where: { $0.text.caseInsensitiveCompare(dir) == .orderedSame })
        {
            out.append((dir, .dir))
        }
        return out
    }
}

/// A small tag at a pane's top-right while the prefix is armed: what
/// runs here and where (the PaneLabelParts grammar). A quiet panel
/// background floats it above any cell content; no border - the box is
/// the chrome, the text is the information.
final class PaneLabelView: NSView {
    private weak var pane: PaneView?
    private let label = NSTextField(labelWithString: "")

    private static let padX: CGFloat = 9
    private static let padY: CGFloat = 4

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 3)
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

    /// Size the tag to its text plus padding; the positioner may then
    /// clamp the width, and layout keeps the text inset either way.
    func fit() {
        label.sizeToFit()
        setFrameSize(NSSize(
            width: label.frame.width + Self.padX * 2,
            height: label.frame.height + Self.padY * 2
        ))
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil
        )
    }

    /// Labels are momentary (the prefix is armed for a beat) and are
    /// rebuilt on every show; no live refresh needed.
    private func render() {
        guard let pane else { return }
        let palette = ThemeManager.shared.palette
        layer?.backgroundColor = palette.panelBg.withAlphaComponent(0.94).cgColor

        // Hosts read in pink (the active-item color), never in gray.
        let line = NSMutableAttributedString()
        for part in PaneLabelParts.parts(for: pane) {
            if line.length > 0 {
                line.append(NSAttributedString(string: " · ", attributes: [
                    .font: Chrome.metaFont,
                    .foregroundColor: palette.dim.withAlphaComponent(0.7),
                ]))
            }
            let style: (font: NSFont, color: NSColor) = switch part.role {
            case .title: (Chrome.metaBoldFont, palette.text)
            case .host: (Chrome.metaBoldFont, palette.pink)
            case .dir: (Chrome.metaFont, palette.dim)
            }
            line.append(NSAttributedString(string: part.text, attributes: [
                .font: style.font,
                .foregroundColor: style.color,
            ]))
        }
        label.attributedStringValue = line
    }
}
