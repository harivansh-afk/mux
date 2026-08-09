import AppKit

/// Borderless, square-cornered window. macOS rounds the corners of any
/// titled window; dropping the title frame entirely gives true square
/// corners with edge-resizing intact. Borderless windows refuse key/main
/// status by default, so both are overridden.
final class MuxWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
