import AppKit

/// The multiplexer's interaction model, carried over from herdr: the prefix
/// is a mode among modes, not a chord table. A local NSEvent monitor sees
/// keys before any view, so prefix handling is independent of terminal focus.
///
/// M1 bindings (herdr defaults + the user's config.toml deltas):
///   ctrl+b        arm prefix mode
///   prefix '      split right          prefix -      split down
///   prefix h/j/k/l  focus direction    prefix z      zoom toggle
///   prefix x      close pane           prefix c      new window
///   prefix r      resize mode          prefix esc    cancel
///   prefix ctrl+b send a literal ctrl+b
/// Held-ctrl aliasing: ctrl+<key> in prefix mode means <key> (the nvim-mux
/// papercut fix: you rarely release ctrl between prefix and key).
/// Resize mode: h/j/k/l nudge the enclosing split ratio, esc/enter/q exit.
///
/// Mode changes drive the bottom mode bar on the active window.
final class PrefixEngine {
    enum Mode {
        case normal
        case prefix
        case resize
    }

    private(set) var mode: Mode = .normal
    private var monitor: Any?
    /// The controller currently showing our mode bar, so we always clear
    /// the one we set even if key windows change mid-mode.
    private weak var indicatorController: MuxWindowController?

    private static let prefixHint =
        "PREFIX   ' split right   - split down   h/j/k/l focus   z zoom   x close   c window   r resize"
    private static let resizeHint =
        "RESIZE   h/j/k/l adjust   esc done"

    /// Resolves the controller of the key window.
    private var controller: MuxWindowController? {
        (NSApp.delegate as? AppDelegate)?.keyController
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func setMode(_ newMode: Mode) {
        mode = newMode
        indicatorController?.setModeIndicator(nil)
        indicatorController = nil
        switch newMode {
        case .normal:
            break
        case .prefix:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.prefixHint)
        case .resize:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.resizeHint)
        }
    }

    /// Returns nil to swallow the event, or the event to pass it through.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let key = event.charactersIgnoringModifiers ?? ""
        let hasCtrl = event.modifierFlags.contains(.control)
        let hasCmd = event.modifierFlags.contains(.command)

        switch mode {
        case .normal:
            if hasCtrl && !hasCmd && key == "b" {
                setMode(.prefix)
                return nil
            }
            return event

        case .prefix:
            // Literal prefix passthrough: ctrl+b again sends ctrl+b.
            if hasCtrl && key == "b" {
                setMode(.normal)
                return event
            }
            setMode(.normal)
            return runPrefixAction(key: key, event: event)

        case .resize:
            switch key {
            case "h": controller?.resizeFocused(.left); return nil
            case "j": controller?.resizeFocused(.down); return nil
            case "k": controller?.resizeFocused(.up); return nil
            case "l": controller?.resizeFocused(.right); return nil
            case "\u{1b}", "\r", "q":
                setMode(.normal)
                return nil
            default:
                return nil
            }
        }
    }

    private func runPrefixAction(key: String, event: NSEvent) -> NSEvent? {
        switch key {
        // Splits: the user's herdr deltas (' right, - down).
        case "'": controller?.split(direction: .horizontal)
        case "-": controller?.split(direction: .vertical)

        // Focus movement.
        case "h": controller?.focusDirection(.left)
        case "j": controller?.focusDirection(.down)
        case "k": controller?.focusDirection(.up)
        case "l": controller?.focusDirection(.right)

        case "z": controller?.toggleZoom()
        case "x": controller?.closeFocusedPane()
        case "c": (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        case "r": setMode(.resize)

        case "\u{1b}": break // cancel

        default:
            NSSound.beep()
        }
        return nil
    }
}
