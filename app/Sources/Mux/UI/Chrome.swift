import AppKit

/// A plain view with a top-left origin and an optional click handler:
/// the scrim, the stage, the wheel, the track, the pane slab. Layout
/// math in this app is written top-down, so flipped is the default and
/// the only views that opt out are the ones AppKit gives coordinates to.
class FlippedView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }
}
