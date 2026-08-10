import AppKit

/// The multiplexer's interaction model: the prefix is a mode among modes,
/// not a chord table. A local NSEvent monitor sees keys before any view,
/// so prefix handling is independent of terminal focus.
///
/// M1 bindings:
///   ctrl+b        arm prefix mode
///   prefix '      split right          prefix -      split down
///   prefix h/j/k/l  focus direction    prefix z      zoom toggle
///   prefix x      close pane           prefix c      new session
///   prefix 1..9   select session       prefix n/p    next/prev session
///   prefix r      resize mode          prefix esc    cancel
///   prefix t      target picker        prefix ctrl+b send a literal ctrl+b
///   prefix ?      keybinds overlay
/// Held-ctrl aliasing: ctrl+<key> in prefix mode means <key> (the nvim-mux
/// papercut fix: you rarely release ctrl between prefix and key).
/// Resize mode: h/j/k/l nudge the enclosing split ratio, esc/enter/q exit.
/// Target mode: j/k choose the machine the next pane lives on, enter
/// splits right into it, esc cancels.
///
/// Mode changes drive the bottom mode bar on the active window.
final class PrefixEngine {
    enum Mode {
        case normal
        case prefix
        case resize
        case help
        case pickTarget
    }

    private(set) var mode: Mode = .normal
    private var monitor: Any?
    /// The controller currently showing our mode bar, so we always clear
    /// the one we set even if key windows change mid-mode.
    private weak var indicatorController: MuxWindowController?

    /// Overlay span grammar: badge, then key/description pairs. Bars stay
    /// clean: the full keybinding list lives in the keybinds overlay (?).
    private static let prefixSegments: [ModeBarSegment] = [
        .badge("PREFIX"),
        .key("esc"), .dim(" cancel  "),
        .key("ctrl+b"), .dim(" send prefix  "),
        .key("?"), .dim(" keybinds"),
    ]

    private static let resizeSegments: [ModeBarSegment] = [
        .badge("RESIZE"),
        .key("h/j/k/l"), .dim(" resize  "),
        .key("esc"), .dim(" done  "),
        .key("?"), .dim(" keybinds"),
    ]

    private static let helpSegments: [ModeBarSegment] = [
        .badge("KEYBINDS"),
        .key("j/k"), .dim(" scroll  "),
        .key("esc"), .dim(" close"),
    ]

    private static let targetSegments: [ModeBarSegment] = [
        .badge("TARGET"),
        .key("j/k"), .dim(" choose  "),
        .key("enter"), .dim(" split  "),
        .key("esc"), .dim(" cancel"),
    ]

    /// Resolves the controller of the key window.
    private var controller: MuxWindowController? {
        (NSApp.delegate as? AppDelegate)?.keyController
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setMode(_ newMode: Mode) {
        mode = newMode
        indicatorController?.setModeIndicator(nil)
        indicatorController?.hideHelp()
        indicatorController?.hideTargetPicker()
        indicatorController = nil
        switch newMode {
        case .normal:
            break
        case .prefix:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.prefixSegments)
        case .resize:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.resizeSegments)
        case .help:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.helpSegments)
            indicatorController?.showHelp()
        case .pickTarget:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.targetSegments)
            indicatorController?.showTargetPicker()
        }
    }

    /// Returns nil to swallow the event, or the event to pass it through.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let key = event.charactersIgnoringModifiers ?? ""
        let hasCtrl = event.modifierFlags.contains(.control)
        let hasCmd = event.modifierFlags.contains(.command)

        switch mode {
        case .normal:
            if hasCtrl, !hasCmd, key == "b" {
                setMode(.prefix)
                return nil
            }
            return event

        case .prefix:
            // Literal prefix passthrough: ctrl+b again sends ctrl+b.
            if hasCtrl, key == "b" {
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
            case "?": setMode(.help); return nil
            case "\u{1b}", "\r", "q":
                setMode(.normal)
                return nil
            default:
                return nil
            }

        case .help:
            switch key {
            case "j", "\u{F701}": controller?.scrollHelp(by: 44); return nil
            case "k", "\u{F700}": controller?.scrollHelp(by: -44); return nil
            case "\u{1b}", "q", "?", "\r":
                setMode(.normal)
                return nil
            default:
                return nil
            }

        case .pickTarget:
            switch key {
            case "j", "\u{F701}": controller?.moveTargetPicker(by: 1); return nil
            case "k", "\u{F700}": controller?.moveTargetPicker(by: -1); return nil
            case "\r":
                // Commit before the mode change tears the picker down.
                controller?.commitTargetPicker()
                setMode(.normal)
                return nil
            case "\u{1b}", "q":
                setMode(.normal)
                return nil
            default:
                return nil
            }
        }
    }

    private func runPrefixAction(key: String, event _: NSEvent) -> NSEvent? {
        switch key {
        // Splits: ' right, - down.
        case "'": controller?.split(direction: .horizontal)
        case "-": controller?.split(direction: .vertical)
        // Focus movement.
        case "h": controller?.focusDirection(.left)
        case "j": controller?.focusDirection(.down)
        case "k": controller?.focusDirection(.up)
        case "l": controller?.focusDirection(.right)
        case "z": controller?.toggleZoom()
        case "x": controller?.closeFocusedPane()
        case "r": setMode(.resize)
        case "t": setMode(.pickTarget)
        case "?": setMode(.help)
        // Sessions.
        case "c": controller?.newSession()
        case "n": controller?.nextSession()
        case "p": controller?.prevSession()
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            controller?.selectSession(Int(key)! - 1)
        case "\u{1b}": break // cancel
        default:
            NSSound.beep()
        }
        return nil
    }
}
