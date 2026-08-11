import AppKit
import GhosttyKit

/// Owns the single ghostty_app_t and the runtime callbacks. Adapted from
/// ghostty's Ghostty.App.swift (MIT), reduced to what a multiplexer needs:
/// the renderer runs on its own thread, so our only jobs are ticking the
/// app on wakeup, dispatching actions, and servicing the clipboard.
final class GhosttyRuntime {
    static var shared: GhosttyRuntime?

    var app: ghostty_app_t?
    var config: ghostty_config_t?

    /// Keyboard layout switches must reach libghostty so it reloads its
    /// key mapping (ghostty does the same).
    private var keyboardObserver: NSObjectProtocol?

    init?() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("ghostty_init failed")
            return nil
        }

        // Loads the user's regular ghostty config: fonts, theme, padding,
        // keybinds all carry over for free.
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { ud in GhosttyRuntime.wakeup(ud) },
            action_cb: { app, target, action in GhosttyRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { ud, loc, state in GhosttyRuntime.readClipboard(ud, location: loc, state: state) },
            confirm_read_clipboard_cb: { ud, str, state, request in
                GhosttyRuntime.confirmReadClipboard(ud, string: str, state: state, request: request)
            },
            write_clipboard_cb: { ud, loc, content, len, confirm in
                GhosttyRuntime.writeClipboard(ud, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { ud, alive in GhosttyRuntime.closeSurface(ud, processAlive: alive) }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            NSLog("ghostty_app_new failed")
            return nil
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        keyboardObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_keyboard_changed(app)
        }
    }

    deinit {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    /// The user's focus-follows-mouse config, read straight from the
    /// loaded ghostty config.
    var focusFollowsMouse: Bool {
        configBool("focus-follows-mouse")
    }

    private func configBool(_ key: String, default def: Bool = false) -> Bool {
        guard let config else { return def }
        var v = def
        _ = ghostty_config_get(config, &v, key, UInt(key.utf8.count))
        return v
    }

    // MARK: - Callbacks

    private static func runtime(_ userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Surface callbacks carry the surface's userdata: our PaneView.
    private static func paneView(_ userdata: UnsafeMutableRawPointer?) -> PaneView? {
        guard let userdata else { return nil }
        return Unmanaged<PaneView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func paneView(surface: ghostty_surface_t?) -> PaneView? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<PaneView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let rt = runtime(userdata) else { return }
        // Wakeup can arrive from any thread; tick on main.
        DispatchQueue.main.async { rt.tick() }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive _: Bool) {
        guard let view = paneView(userdata) else { return }
        DispatchQueue.main.async {
            view.controller?.removePane(view)
        }
    }

    // MARK: - Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = paneView(userdata), let surface = view.surface else { return false }
        guard let pasteboard = NSPasteboard.ghostty(location) else { return false }

        // Return false if there is no text-like clipboard content so
        // performable paste bindings can pass through to the terminal.
        guard let str = pasteboard.getOpinionatedStringContents() else { return false }

        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = paneView(userdata) else { return }
        guard let string, let contents = String(cString: string, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            presentClipboardConfirmation(
                view: view,
                contents: contents,
                request: request,
                state: state,
                pasteboard: nil
            )
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let pasteboard = NSPasteboard.ghostty(location) else { return }
        guard let content, len > 0 else { return }

        var items: [(mime: String, data: String)] = []
        for i in 0 ..< len {
            guard let mime = content[i].mime, let data = content[i].data else { continue }
            items.append((String(cString: mime), String(cString: data)))
        }
        guard !items.isEmpty else { return }

        if !confirm {
            // Declare all types, then set data for each.
            let types = items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }
            pasteboard.declareTypes(types, owner: nil)
            for item in items {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setString(item.data, forType: type)
            }
            return
        }

        // For confirmation, use the text/plain content if it exists.
        guard let textPlain = items.first(where: { $0.mime == "text/plain" }) else { return }
        guard let view = paneView(userdata) else { return }
        DispatchQueue.main.async {
            presentClipboardConfirmation(
                view: view,
                contents: textPlain.data,
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
                state: nil,
                pasteboard: pasteboard
            )
        }
    }

    /// The ghostty-equivalent clipboard confirmation, as a native alert
    /// sheet: unsafe pastes and OSC 52 reads/writes prompt before touching
    /// the terminal or the clipboard.
    private static func presentClipboardConfirmation(
        view: PaneView,
        contents: String,
        request: ghostty_clipboard_request_e,
        state: UnsafeMutableRawPointer?,
        pasteboard: NSPasteboard?
    ) {
        // Complete a request that races an existing prompt instead of
        // stacking sheets (ghostty does the same). confirmed=true only
        // marks the request answered; the empty string denies it.
        if view.clipboardConfirmationActive {
            if let surface = view.surface, request != GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE {
                ghostty_surface_complete_clipboard_request(surface, "", state, true)
            }
            return
        }

        let alert = NSAlert()
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            alert.messageText = "Warning: Potentially Unsafe Paste"
            alert.informativeText =
                "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "An application is attempting to read from the clipboard. The current clipboard contents are shown below."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
        default:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "An application is attempting to write to the clipboard. The content to write is shown below."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
        }
        alert.alertStyle = .warning

        // Content preview, scrollable like ghostty's confirmation window.
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        if let textView = scroll.documentView as? NSTextView {
            textView.string = contents
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        alert.accessoryView = scroll

        let complete: (Bool) -> Void = { confirmed in
            view.clipboardConfirmationActive = false
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
                guard confirmed else { return }
                let pb = pasteboard ?? .general
                pb.declareTypes([.string], owner: nil)
                pb.setString(contents, forType: .string)
            default:
                // confirmed=true marks the request answered either way; a
                // denied read completes with an empty string.
                guard let surface = view.surface else { return }
                let str = confirmed ? contents : ""
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
                }
            }
        }

        view.clipboardConfirmationActive = true
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                complete(response == .alertFirstButtonReturn)
            }
        } else {
            complete(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: - Actions

    private static func action(
        _: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // Resolve the pane view for surface-targeted actions.
        var view: PaneView?
        if target.tag == GHOSTTY_TARGET_SURFACE {
            view = paneView(surface: target.target.surface)
        }

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        case GHOSTTY_ACTION_NEW_WINDOW:
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.newWindow(nil)
            }
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let view else { return false }
            let dir = action.action.new_split
            DispatchQueue.main.async {
                view.controller?.split(from: view, ghosttyDirection: dir)
            }
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let view else { return false }
            let dir = action.action.goto_split
            DispatchQueue.main.async {
                view.controller?.focus(from: view, ghosttyGoto: dir)
            }
            return true

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let view else { return false }
            DispatchQueue.main.async { view.controller?.toggleZoom() }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            guard let view else { return false }
            DispatchQueue.main.async { view.window?.close() }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view else { return false }
            let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.setTitle(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view else { return false }
            let pwd = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.pwd = pwd.isEmpty ? nil : pwd }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.setCursorShape(shape) }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view else { return false }
            let size = action.action.cell_size
            let backingSize = NSSize(width: Double(size.width), height: Double(size.height))
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                // Reported in pixels; the IME candidate window wants points.
                view.cellSize = view.convertFromBacking(backingSize)
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // M1: surface it as a beep; real notifications later.
            NSSound.beep()
            return true

        // Silently accepted: informational or irrelevant to a multiplexer M1.
        case GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_RESET_WINDOW_SIZE,
             GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_RELOAD_CONFIG,
             GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_KEY_SEQUENCE,
             GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_COMMAND_FINISHED,
             GHOSTTY_ACTION_SHOW_CHILD_EXITED,
             GHOSTTY_ACTION_QUIT_TIMER:
            return true

        default:
            return false
        }
    }
}
