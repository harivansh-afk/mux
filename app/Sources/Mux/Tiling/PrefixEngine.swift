import AppKit

/// The multiplexer's interaction model: the prefix is a mode among modes,
/// not a chord table. A local NSEvent monitor sees keys before any view,
/// so prefix handling is independent of terminal focus.
///
/// M1 bindings:
///   ctrl+b        arm prefix mode
///   prefix '      split right          prefix -      split down
///   prefix arrows focus direction      prefix h/j/k/l focus left/down/up/right
///   prefix z      zoom toggle          prefix x      close pane
///   prefix c      new session          prefix 1..9   select session
///   prefix n/p    next/prev session    prefix r      resize mode
///   prefix t      hosts window         prefix space  canvas (f: alias)
///   prefix ?      keybinds overlay     prefix ctrl+b send a literal ctrl+b
///   prefix esc    cancel
/// Held-ctrl aliasing: ctrl+<key> in prefix mode means <key> (the nvim-mux
/// papercut fix: you rarely release ctrl between prefix and key).
/// Resize mode: h/j/k/l nudge the enclosing split ratio, esc/enter/q exit.
/// Canvas mode: h/j/k/l walk every pane's live card grouped by session,
/// enter or a click jumps to it.
/// Hosts mode: j/k walk local, the hosts with their live probe status and
/// the ix VMs; enter splits right into one and H/J/K/L split in a given
/// direction, c opens a new session there, n creates a VM, t chooses the
/// template new VMs are built from, y copies this client's identity digest.
///
/// Mode changes drive the bottom mode bar on the active window.
final class PrefixEngine {
    enum Mode {
        case normal
        case prefix
        case resize
        case help
        case canvas
        case hosts
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
        .key("esc"), .dim(" close"),
    ]

    private static let canvasSegments: [ModeBarSegment] = [
        .badge("CANVAS"),
        .key("h/j/k/l"), .dim(" choose  "),
        .key("enter"), .dim(" jump  "),
        .key("esc"), .dim(" cancel"),
    ]

    /// The window has more keys than a bar should carry: they live in its
    /// own footer and in the keybinds overlay.
    private static let hostsSegments: [ModeBarSegment] = [
        .badge("HOSTS"),
        .key("j/k"), .dim(" choose  "),
        .key("enter"), .dim(" split  "),
        .key("?"), .dim(" keybinds"),
    ]

    private static let templateSegments: [ModeBarSegment] = [
        .badge("TEMPLATE"),
        .key("j/k"), .dim(" choose  "),
        .key("enter"), .dim(" set default  "),
        .key("esc"), .dim(" back"),
    ]

    /// The single window's controller.
    private var controller: MuxWindowController? {
        (NSApp.delegate as? AppDelegate)?.controller
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
        indicatorController?.hideCanvasOverlay()
        indicatorController?.hideHostsWindow()
        indicatorController?.hidePaneLabels()
        indicatorController = nil
        switch newMode {
        case .normal:
            break
        case .prefix:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.prefixSegments)
            // While the prefix is armed every pane names itself: bare
            // text at its corner, gone the instant the mode ends.
            indicatorController?.showPaneLabels()
        case .resize:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.resizeSegments)
        case .help:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.helpSegments)
            indicatorController?.showHelp()
        case .canvas:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.canvasSegments)
            indicatorController?.showCanvasOverlay()
        case .hosts:
            indicatorController = controller
            indicatorController?.setModeIndicator(Self.hostsSegments)
            indicatorController?.showHostsWindow()
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
            // The overlay shows everything at once; any key closes it, so
            // the momentary mode never swallows a keystroke you meant to type.
            switch key {
            case "\u{1b}", "q", "?", "\r":
                setMode(.normal)
                return nil
            default:
                setMode(.normal)
                return nil
            }

        case .canvas:
            switch key {
            case "j", "l", "\u{F701}", "\u{F703}":
                controller?.moveCanvasOverlay(by: 1)
                return nil
            case "k", "h", "\u{F700}", "\u{F702}":
                controller?.moveCanvasOverlay(by: -1)
                return nil
            case "\r":
                // Commit before the mode change tears the overlay down.
                controller?.commitCanvas()
                setMode(.normal)
                return nil
            case "\u{1b}", "q":
                setMode(.normal)
                return nil
            default:
                return nil
            }

        case .hosts:
            return handleHostsKey(key)
        }
    }

    /// The hosts window holds two lists: the machines, and (under t) the ix
    /// template new VMs are built from. Both are driven from here, so the
    /// window itself never needs focus.
    private func handleHostsKey(_ key: String) -> NSEvent? {
        guard let controller else { return nil }

        if controller.hostsWindowPickingTemplate {
            switch key {
            case "j", "\u{F701}": controller.moveHostsWindow(by: 1)
            case "k", "\u{F700}": controller.moveHostsWindow(by: -1)
            case "\r":
                // Setting the default is not a pane action: it returns to
                // the machines instead of closing the window.
                controller.commitHostsTemplate()
                indicatorController?.setModeIndicator(Self.hostsSegments)
            case "\u{1b}", "q":
                controller.showHostsMachines()
                indicatorController?.setModeIndicator(Self.hostsSegments)
            default:
                break
            }
            return nil
        }

        switch key {
        case "j", "\u{F701}": controller.moveHostsWindow(by: 1)
        case "k", "\u{F700}": controller.moveHostsWindow(by: -1)
        // Enter is the common case (split right); the capitals aim it. Every
        // one of them commits and leaves the mode, so the pane you asked for
        // is focused with nothing in front of it.
        case "\r", "L": commitHosts(direction: .horizontal)
        case "H": commitHosts(direction: .horizontal, before: true)
        case "J": commitHosts(direction: .vertical)
        case "K": commitHosts(direction: .vertical, before: true)
        case "c":
            controller.newSessionOnHostsSelection()
            setMode(.normal)
        case "n":
            controller.createIXVM()
            setMode(.normal)
        // Copying leaves the window up: the digest stays on screen as
        // confirmation of what landed on the clipboard.
        case "y": controller.copyClientDigest()
        case "t":
            controller.showHostsTemplates()
            indicatorController?.setModeIndicator(Self.templateSegments)
        case "?": setMode(.help)
        case "\u{1b}", "q": setMode(.normal)
        default:
            break
        }
        return nil
    }

    /// A click on a canvas card committed the jump; leave the mode the
    /// same way enter does.
    func endCanvas() {
        guard mode == .canvas else { return }
        setMode(.normal)
    }

    /// Commit before the mode change tears the window down.
    private func commitHosts(direction: SplitDirection, before: Bool = false) {
        controller?.commitHostsWindow(direction: direction, before: before)
        setMode(.normal)
    }

    private func runPrefixAction(key: String, event _: NSEvent) -> NSEvent? {
        switch key {
        // Splits: ' right, - down.
        case "'": controller?.split(direction: .horizontal)
        case "-": controller?.split(direction: .vertical)
        // Focus movement: arrows and h/j/k/l both cover all four directions.
        case "h", "\u{F702}": controller?.focusDirection(.left)
        case "j", "\u{F701}": controller?.focusDirection(.down)
        case "k", "\u{F700}": controller?.focusDirection(.up)
        case "l", "\u{F703}": controller?.focusDirection(.right)
        case "z": controller?.toggleZoom()
        case "x": controller?.closeFocusedPane()
        case "r": setMode(.resize)
        case "t": setMode(.hosts)
        // Space: the canvas is the navigation surface, it gets the
        // biggest key. f stays as the original alias.
        case " ", "f": setMode(.canvas)
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
