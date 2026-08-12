import AppKit
import GhosttyKit

// Light/dark theming for mux chrome: cozybox gruvbox with a deliberately
// greyscale accent, matching the user's terminal theme.
//
// The terminal contents theme themselves: we forward the effective
// appearance to libghostty app-wide (ghostty_app_set_color_scheme) and to
// every surface (ghostty_surface_set_color_scheme, via .muxThemeDidChange
// in PaneView), which selects the light/dark variant of the user's
// `theme = light:...,dark:...` ghostty config live and keeps OSC 10/11
// luminance detection correct for programs running inside the panes.

enum Appearance {
    case light
    case dark
}

/// The single knob for every piece of text outside the terminal panes:
/// overlays, mode bar, hosts window, session indicator.
/// One face (Berkeley Mono, falling back to the system monospaced font
/// if not installed), one size; all chrome metrics derive from it.
enum Chrome {
    static let fontSize: CGFloat = 22

    static let font =
        NSFont(name: "BerkeleyMono-Regular", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let boldFont =
        NSFont(name: "BerkeleyMono-Bold", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .bold)

    /// Row height for list-style overlays (help, panes, hosts).
    static let rowHeight: CGFloat = fontSize * 2
    /// Height of the floating bars (mode bar, session indicator): line
    /// height plus breathing room, so labels center instead of clipping.
    static let barHeight: CGFloat = fontSize + 12
}

struct Palette {
    /// Overlay/bar background (= terminal background).
    let panelBg: NSColor
    /// Accent for keys and the mode badge background.
    let accent: NSColor
    /// Badge text on accent (= panelBg for contrast).
    let accentContrast: NSColor
    /// Dim descriptions.
    let dim: NSColor
    /// Primary text.
    let text: NSColor
    /// The active-item highlight (session indicator's current number).
    let pink: NSColor
    /// Live status in the hosts overlay: a host that answered.
    let ok: NSColor
    /// Live status in the hosts overlay: a host that did not.
    let bad: NSColor
    /// Pane separator lines. Derived from the terminal background exactly
    /// like ghostty's default `split-divider-color` (Ghostty.Config.swift
    /// splitDividerColor): darken a light background by 0.08, a dark one
    /// by 0.4. Subtle in light mode, subtle in dark mode, always adjacent
    /// to the background it separates.
    let divider: NSColor

    static let dark: Palette = {
        let bg = NSColor(hex: 0x101010)
        return Palette(
            panelBg: bg,
            accent: NSColor(hex: 0xEBDBB2),
            accentContrast: bg,
            dim: NSColor(hex: 0x504945),
            text: NSColor(hex: 0xD4BE98),
            pink: NSColor(hex: 0xD3869B),
            ok: NSColor(hex: 0xA9B665),
            bad: NSColor(hex: 0xEA6962),
            divider: bg.ghosttyDividerColor
        )
    }()

    static let light: Palette = {
        let bg = NSColor(hex: 0xE7E7E7)
        return Palette(
            panelBg: bg,
            accent: NSColor(hex: 0x3C3836),
            accentContrast: bg,
            dim: NSColor(hex: 0xA89984),
            text: NSColor(hex: 0x3C3836),
            pink: NSColor(hex: 0x8F3F71),
            ok: NSColor(hex: 0x6C782E),
            bad: NSColor(hex: 0xC14A4A),
            divider: bg.ghosttyDividerColor
        )
    }()
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    // Ported 1:1 from ghostty macos/Sources/Helpers/Extensions/
    // OSColor+Extension.swift (MIT).

    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    var isLightColor: Bool {
        luminance > 0.5
    }

    func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let hsb = usingColorSpace(.sRGB) else { return self }
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }

    /// ghostty's default `split-divider-color` (Ghostty.Config.swift).
    var ghosttyDividerColor: NSColor {
        isLightColor ? darken(by: 0.08) : darken(by: 0.4)
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

    /// The current appearance as a libghostty color scheme, for the
    /// app-wide and per-surface conditional-theme state.
    var colorScheme: ghostty_color_scheme_e {
        appearance == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
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
        // and OSC 10/11 background reports match the visible theme. Each
        // surface also carries its own conditional state; PaneView pushes
        // the scheme per surface on .muxThemeDidChange below.
        if let app = GhosttyRuntime.shared?.app {
            ghostty_app_set_color_scheme(app, colorScheme)
        }

        NotificationCenter.default.post(name: .muxThemeDidChange, object: nil)
    }
}
