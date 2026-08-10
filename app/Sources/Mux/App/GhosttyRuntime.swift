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
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyRuntime.wakeup(ud) },
            action_cb: { app, target, action in GhosttyRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { ud, loc, state in GhosttyRuntime.readClipboard(ud, location: loc, state: state) },
            confirm_read_clipboard_cb: { ud, str, state, _ in GhosttyRuntime.confirmReadClipboard(ud, string: str, state: state) },
            write_clipboard_cb: { ud, loc, content, len, confirm in GhosttyRuntime.writeClipboard(ud, location: loc, content: content, len: len, confirm: confirm) },
            close_surface_cb: { ud, alive in GhosttyRuntime.closeSurface(ud, processAlive: alive) }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            NSLog("ghostty_app_new failed")
            return nil
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    deinit {
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
        location _: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = paneView(userdata), let surface = view.surface else { return false }
        let str = NSPasteboard.general.string(forType: .string) ?? ""
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?
    ) {
        // M1: no confirmation dialog; complete the request as confirmed.
        guard let view = paneView(userdata), let surface = view.surface else { return }
        ghostty_surface_complete_clipboard_request(surface, string, state, true)
    }

    private static func writeClipboard(
        _: UnsafeMutableRawPointer?,
        location _: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm _: Bool
    ) {
        guard len > 0, let content else { return }
        // Prefer text/plain; fall back to the first entry.
        var chosen: ghostty_clipboard_content_s = content[0]
        for i in 0 ..< len {
            let c = content[i]
            if let mime = c.mime, String(cString: mime) == "text/plain" {
                chosen = c
                break
            }
        }
        guard let data = chosen.data else { return }
        let str = String(cString: data)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
    }

    // MARK: - Actions

    private static func action(
        _: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // Resolve the pane view for surface-targeted actions.
        var view: PaneView? = nil
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

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // M1: surface it as a beep; real notifications later.
            NSSound.beep()
            return true

        // Silently accepted: informational or irrelevant to a multiplexer M1.
        case GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT,
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
