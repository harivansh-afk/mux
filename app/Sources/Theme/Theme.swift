import AppKit
import GhosttyKit

/// Light/dark theming for mux chrome, matched 1:1 to the herdr palette the
/// user's nix theme renders (lib/theme.nix renderHerdrTheme): cozybox
/// gruvbox with a deliberately greyscale accent.
///
/// The terminal contents theme themselves: we forward the effective
/// appearance to libghostty via ghostty_app_set_color_scheme, which selects
/// the light/dark variant of the user's ghostty theme and keeps OSC 10/11
/// luminance detection correct for programs running inside the panes.

enum Appearance {
    case light
    case dark
}

struct Palette {
    /// Overlay/bar background (herdr panel_bg = terminal background).
    let panelBg: NSColor
    /// Accent for keys and the mode badge background.
    let accent: NSColor
    /// Badge text on accent (herdr panel_contrast_fg = panel_bg).
    let accentContrast: NSColor
    /// Dim descriptions (herdr overlay0).
    let dim: NSColor
    /// Primary text.
    let text: NSColor
    /// Pane separator lines. Dark in light mode by request.
    let divider: NSColor

    static let dark = Palette(
        panelBg: NSColor(hex: 0x101010),
        accent: NSColor(hex: 0xEBDBB2),
        accentContrast: NSColor(hex: 0x101010),
        dim: NSColor(hex: 0x504945),
        text: NSColor(hex: 0xD4BE98),
        divider: NSColor(hex: 0x504945))

    static let light = Palette(
        panelBg: NSColor(hex: 0xE7E7E7),
        accent: NSColor(hex: 0x3C3836),
        accentContrast: NSColor(hex: 0xE7E7E7),
        dim: NSColor(hex: 0xA89984),
        text: NSColor(hex: 0x3C3836),
        divider: NSColor(hex: 0x3C3836))
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
    }
}

extension Notification.Name {
    /// Posted after the appearance (and palette) changed. Views re-color
    /// themselves; nobody caches palette values across this.
    static let muxThemeDidChange = Notification.Name("muxThemeDidChange")
}

final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var appearance: Appearance = .dark
    private var observation: NSKeyValueObservation?

    var palette: Palette {
        appearance == .dark ? .dark : .light
    }

    /// Observe the system appearance for the app's lifetime and apply the
    /// initial state. Call once, after GhosttyRuntime exists.
    func start() {
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh(force: true)
    }

    private func refresh(force: Bool = false) {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next: Appearance = isDark ? .dark : .light
        guard force || next != appearance else { return }
        appearance = next

        // Tell libghostty so `theme = light:...,dark:...` configs switch
        // and OSC 10/11 background reports match the visible theme.
        if let app = GhosttyRuntime.shared?.app {
            ghostty_app_set_color_scheme(
                app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }

        NotificationCenter.default.post(name: .muxThemeDidChange, object: nil)
    }
}
