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

/// The single knob for every piece of text outside the terminal panes:
/// overlays, mode bar, hosts window, session indicator.
/// One face (Berkeley Mono, falling back to the system monospaced font
/// if not installed), one size; all chrome metrics derive from it.
enum Chrome {
    static let fontSize: CGFloat = 22

    static let font = mono("BerkeleyMono-Regular", size: fontSize, weight: .regular)
    static let boldFont = mono("BerkeleyMono-Bold", size: fontSize, weight: .bold)

    /// The product voice: SF for labels ABOUT content (the canvas stage's
    /// agent topic). The mono face above stays the machine voice for
    /// content itself (commands, paths, hosts, keys). Same size knob.
    static let uiTitleFont = NSFont.systemFont( // astlog-ignore: no-adhoc-font
        ofSize: (fontSize * 0.95).rounded(), weight: .semibold
    )

    /// Small mono for metadata lines (pane labels, canvas meta).
    static let metaFont = mono("BerkeleyMono-Regular", size: (fontSize * 0.72).rounded(), weight: .regular)
    static let metaBoldFont = mono("BerkeleyMono-Bold", size: (fontSize * 0.72).rounded(), weight: .bold)

    /// The one place a face is resolved: the named font, or the system mono
    /// when it is not installed.
    private static func mono(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // astlog-ignore: no-adhoc-font
        NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Row height for list-style overlays (help, panes, hosts).
    static let rowHeight: CGFloat = fontSize * 2
    /// Height of the floating bars (mode bar, session indicator): line
    /// height plus breathing room, so labels center instead of clipping.
    static let barHeight: CGFloat = fontSize + 12
}

/// A run of text in the chrome's voice. Bars, tags and badges are all
/// sequences of these; ModeBarView.render is the one place they become
/// pixels.
enum ModeBarSegment {
    /// Bold accent-contrast text on the accent colour, plus a trailing
    /// space: the mode name at the head of a bar.
    case badge(String)
    case key(String)
    case dim(String)
    /// Active-item highlight (bold pink): the current session number, a
    /// pane's host on its prefix tag.
    case highlight(String)
}

struct Palette {
    let panelBg: NSColor
    let accent: NSColor
    let accentContrast: NSColor
    let dim: NSColor
    let text: NSColor
    let pink: NSColor
    let ok: NSColor
    let bad: NSColor
    let busy: NSColor
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
            busy: NSColor(hex: 0xD8A657),
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
            busy: NSColor(hex: 0xB47109),
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
            brightness: b * (1 - amount),
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

    private(set) var isDark = true
    private var observation: NSKeyValueObservation?

    var palette: Palette {
        isDark ? .dark : .light
    }

    /// The current appearance as a libghostty color scheme, for the
    /// app-wide and per-surface conditional-theme state.
    var colorScheme: ghostty_color_scheme_e {
        isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
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
        let next = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard force || next != isDark else { return }
        isDark = next

        if let app = GhosttyRuntime.shared?.app {
            ghostty_app_set_color_scheme(app, colorScheme)
            // Conditional-theme invariant (CLAUDE.md): this reload must stay
            // synchronous and run before any surface is created, or a
            // surface born mid-transition silently loses its attach command.
            GhosttyRuntime.shared?.reloadConfig(soft: true)
        }

        NotificationCenter.default.post(name: .muxThemeDidChange, object: nil)
    }
}
