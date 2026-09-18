import AppKit

/// Ghostty owns matching, highlighting and scrolling; this view only edits
/// the query and displays its asynchronous result notifications.
final class PaneSearchBar: NSVisualEffectView, NSSearchFieldDelegate {
    private weak var pane: PaneView?
    let field = NSSearchField()
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
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        field.placeholderString = "Find in terminal"
        field.font = Chrome.metaFont
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        count.font = Chrome.metaFont
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let previous = NSButton(title: "↑", target: self, action: #selector(previousMatch))
        previous.toolTip = "Previous match (⇧⌘G)"
        let next = NSButton(title: "↓", target: self, action: #selector(nextMatch))
        next.toolTip = "Next match (⌘G)"
        let close = NSButton(title: "×", target: self, action: #selector(closeSearch))
        close.toolTip = "Close search (Escape)"
        for button in [previous, next, close] {
            button.font = Chrome.metaFont
            button.bezelStyle = .inline
        }
        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
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
            count.stringValue = "…"
        } else if selected >= 0, selected < total {
            count.stringValue = "\(selected + 1)/\(total)"
        } else {
            count.stringValue = "\(total) matches"
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
