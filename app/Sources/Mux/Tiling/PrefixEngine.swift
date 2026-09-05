import AppKit
import Tiling

/// The multiplexer's interaction model: the prefix is a mode among modes,
/// not a chord table. A local NSEvent monitor sees keys before any view,
/// so prefix handling is independent of terminal focus.
///
///
/// The mode is the whole story: it names the bar, the overlay that is up,
/// and the keys that mean anything.
final class PrefixEngine {
    enum Mode {
        case normal
        case prefix
        case resize
        case help
        case canvas
        case hosts
        /// The hosts window's other list. A mode of its own, so the bar
        /// follows it the way every other mode's bar does.
        case hostsTemplate
    }

    private(set) var mode: Mode = .normal
    private var monitor: Any?

    /// Overlay span grammar: badge, then key/description pairs. Bars stay
    /// clean: the full keybinding list lives in the keybinds overlay (?).
    private static func segments(for mode: Mode) -> [ModeBarSegment] {
        switch mode {
        case .normal:
            []
        case .prefix:
            [.badge("PREFIX"),
             .key("esc"), .dim(" cancel  "),
             .key("ctrl+b"), .dim(" send prefix  "),
             .key("?"), .dim(" keybinds")]
        case .resize:
            [.badge("RESIZE"),
             .key("h/j/k/l"), .dim(" resize  "),
             .key("H/J/K/L"), .dim(" move  "),
             .key("esc"), .dim(" done  "),
             .key("?"), .dim(" keybinds")]
        case .help:
            [.badge("KEYBINDS"),
             .key("esc"), .dim(" close")]
        case .canvas:
            [.badge("CANVAS"),
             .key("h/j/k/l"), .dim(" choose  "),
             .key("enter"), .dim(" jump  "),
             .key("esc"), .dim(" cancel")]
        // The hosts window has more keys than a bar should carry: they
        // live in its own footer and in the keybinds overlay.
        case .hosts:
            [.badge("HOSTS"),
             .key("j/k"), .dim(" choose  "),
             .key("enter"), .dim(" split  "),
             .key("?"), .dim(" keybinds")]
        case .hostsTemplate:
            [.badge("TEMPLATE"),
             .key("j/k"), .dim(" choose  "),
             .key("enter"), .dim(" set default  "),
             .key("esc"), .dim(" back")]
        }
    }

    /// The single window's controller.
    private var controller: MuxWindowController? {
        App.delegate.controller
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Self.isReopenClosedTab(event) {
                reopenClosedTab()
                return nil
            }
            if Self.isCloseTab(event) {
                closeTab()
                return nil
            }
            return handle(event)
        }
    }

    func reopenClosedTab() {
        guard let controller, !controller.closedPanes.isEmpty else { return }
        setMode(.normal)
        controller.reopenClosedTab()
    }

    func closeTab() {
        setMode(.normal)
        controller?.activeSession?.closeFocusedPane()
    }

    func killTerminal() {
        setMode(.normal)
        controller?.activeSession?.killFocusedPane()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Every mode change clears the chrome first, so nothing the old mode
    /// put up outlives it; then this mode puts up its own.
    private func setMode(_ newMode: Mode) {
        let previous = mode
        mode = newMode
        controller?.dismissAllChrome()
        guard let controller, newMode != .normal else { return }
        controller.setModeIndicator(Self.segments(for: newMode))
        switch newMode {
        case .normal:
            break
        case .prefix:
            // While the prefix is armed every pane names itself: bare
            // text at its corner, gone the instant the mode ends.
            controller.showPaneTags()
        case .resize:
            controller.showResizeOutline()
        case .help:
            controller.present(controller.helpOverlay)
        case .canvas:
            controller.showCanvasOverlay()
        // Swapping between the window's two lists must not re-probe the
        // machines that have already answered.
        case .hosts where previous == .hostsTemplate:
            controller.hostsWindow.showHosts()
            controller.present(controller.hostsWindow)
        case .hosts:
            controller.showHostsWindow()
        case .hostsTemplate:
            controller.hostsWindow.showTemplates()
            controller.present(controller.hostsWindow)
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
            return runPrefixAction(key: key)

        case .resize:
            let session = controller?.activeSession
            switch key {
            case "h": session?.resizeFocused(.left); return nil
            case "j": session?.resizeFocused(.down); return nil
            case "k": session?.resizeFocused(.up); return nil
            case "l": session?.resizeFocused(.right); return nil
            // Capitals move the pane itself through the layout.
            case "H": session?.moveFocused(.left); return nil
            case "J": session?.moveFocused(.down); return nil
            case "K": session?.moveFocused(.up); return nil
            case "L": session?.moveFocused(.right); return nil
            // Session moves commit and leave the mode, like hosts does:
            // the pane lands somewhere resize no longer describes.
            case "c":
                controller?.movePaneToNewSession()
                setMode(.normal)
                return nil
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                controller?.movePane(toSession: Int(key)! - 1)
                setMode(.normal)
                return nil
            case "?": setMode(.help); return nil
            case "\u{1b}", "\r", "q":
                setMode(.normal)
                return nil
            default:
                return nil
            }

        case .help:
            // The overlay shows everything at once, so any key closes it:
            // the momentary mode never swallows a keystroke you meant.
            setMode(.normal)
            return nil

        case .canvas:
            // The zoom keys keep working inside the canvas, but the
            // single-pane variants act on the PREVIEWED pane, not the
            // focused one hiding under the scrim - the stage mirror
            // shows the reflow live. Shift variants stay global, as
            // everywhere.
            if let zoom = PaneView.fontZoomStep(event) {
                if zoom.allPanes {
                    PaneView.adjustAllFontSizes(zoom.step)
                } else {
                    controller?.canvasOverlay.selection?.pane?
                        .adjustFontSize(zoom.step)
                }
                return nil
            }
            switch key {
            case "j", "l", "\u{F701}", "\u{F703}":
                controller?.canvasOverlay.move(by: 1)
                return nil
            case "k", "h", "\u{F700}", "\u{F702}":
                controller?.canvasOverlay.move(by: -1)
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

        case .hostsTemplate:
            return handleTemplateKey(key)
        }
    }

    /// The machines list. The window never takes focus: every key it
    /// answers to arrives here.
    private func handleHostsKey(_ key: String) -> NSEvent? {
        guard let controller else { return nil }
        switch key {
        case "j", "\u{F701}": controller.hostsWindow.move(by: 1)
        case "k", "\u{F700}": controller.hostsWindow.move(by: -1)
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
        case "y": controller.hostsWindow.copyDigest()
        case "t": setMode(.hostsTemplate)
        case "?": setMode(.help)
        case "\u{1b}", "q": setMode(.normal)
        default:
            break
        }
        return nil
    }

    /// The ix template new VMs are built from. Setting the default is not
    /// a pane action, so both enter and esc land back on the machines
    /// rather than closing the window.
    private func handleTemplateKey(_ key: String) -> NSEvent? {
        guard let controller else { return nil }
        switch key {
        case "j", "\u{F701}": controller.hostsWindow.move(by: 1)
        case "k", "\u{F700}": controller.hostsWindow.move(by: -1)
        case "\r":
            controller.hostsWindow.commitTemplate()
            setMode(.hosts)
        case "\u{1b}", "q": setMode(.hosts)
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

    private func runPrefixAction(key: String) -> NSEvent? {
        let session = controller?.activeSession
        switch key {
        // Splits: ' right, - down.
        case "'": session?.split(direction: .horizontal)
        case "-": session?.split(direction: .vertical)
        // Focus movement: arrows and h/j/k/l both cover all four directions.
        case "h", "\u{F702}": session?.focusDirection(.left)
        case "j", "\u{F701}": session?.focusDirection(.down)
        case "k", "\u{F700}": session?.focusDirection(.up)
        case "l", "\u{F703}": session?.focusDirection(.right)
        case "z": session?.toggleZoom()
        case "x": session?.closeFocusedPane()
        case "X": session?.killFocusedPane()
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
