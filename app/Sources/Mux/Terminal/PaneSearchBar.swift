import AppKit

/// Ghostty owns matching, highlighting and scrolling; this view only edits
/// the query and displays its asynchronous result notifications.
final class PaneSearchBar: NSView, NSTextFieldDelegate {
    private weak var pane: PaneView?
    let field = NSTextField()
    static let preferredSize = NSSize(width: 325, height: 44)
    private let input = NSView()
    private let count = NSTextField(labelWithString: "")
    private var submittedQuery: String?
    var total = -1 {
        didSet { updateCount() }
    }

    var selected = -1 {
        didSet { updateCount() }
    }

    var ownsFirstResponder: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === field || responder === field.currentEditor()
    }

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 4
        shadow?.shadowOffset = .zero
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.3)

        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search terminal")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.lineBreakMode = .byTruncatingHead

        input.wantsLayer = true
        input.layer?.cornerRadius = 6
        for view in [field, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            input.addSubview(view)
        }

        // Ghostty's upward chevron advances toward older scrollback matches.
        let next = searchButton("chevron.up", label: "Next match (⌘G)", action: #selector(nextMatch))
        let previous = searchButton("chevron.down", label: "Previous match (⇧⌘G)", action: #selector(previousMatch))
        let close = searchButton("xmark", label: "Close search (Escape)", action: #selector(closeSearch))
        let stack = NSStackView(views: [input, next, previous, close])
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: input.trailingAnchor, constant: -50),
            field.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            count.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            count.trailingAnchor.constraint(equalTo: input.trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: input.centerYAnchor),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    private func searchButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
            target: self,
            action: action
        )
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            input.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
    }

    func start(needle: String) {
        if !needle.isEmpty {
            field.stringValue = needle
        }
        // The menu may have been invoked while a different pane owned focus.
        if let pane {
            pane.controller?.noteFocused(pane)
        }
        window?.makeFirstResponder(field)
        field.selectText(nil)
        submitQuery()
    }

    func controlTextDidChange(_: Notification) {
        submitQuery()
    }

    func controlTextDidBeginEditing(_: Notification) {
        if let pane {
            pane.controller?.noteFocused(pane)
        }
    }

    private func submitQuery() {
        guard submittedQuery != field.stringValue else { return }
        submittedQuery = field.stringValue
        total = -1
        selected = -1
        pane?.bindingAction("search:\(field.stringValue)")
    }

    func end() {
        submittedQuery = nil
        removeFromSuperview()
    }

    private func updateCount() {
        if field.stringValue.isEmpty {
            count.stringValue = ""
        } else if total < 0 {
            count.stringValue = ""
        } else if selected >= 0, selected < total {
            count.stringValue = "\(selected + 1)/\(total)"
        } else {
            count.stringValue = "-/\(total)"
        }
    }

    @objc private func previousMatch() {
        pane?.bindingAction("navigate_search:previous")
    }

    @objc private func nextMatch() {
        pane?.bindingAction("navigate_search:next")
    }

    @objc private func closeSearch() {
        pane?.bindingAction("end_search")
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                previousMatch()
            } else {
                nextMatch()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearch()
        default:
            return false
        }
        return true
    }
}
