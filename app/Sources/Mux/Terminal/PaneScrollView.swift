import AppKit
import GhosttyKit

/// Wraps a pane in an NSScrollView to provide the native macOS overlay
/// scrollbar. Ported from ghostty's SurfaceScrollView.swift (MIT).
///
/// ## Coordinate system
/// AppKit uses a +Y-up coordinate system (origin at bottom-left), while
/// terminals use +Y-down (row 0 at top). This class handles the inversion
/// when converting between row offsets and pixel positions.
///
/// ## Architecture
/// - `scrollView`: the outermost NSScrollView that manages scrollbar
///   rendering and behavior.
/// - `documentView`: a blank NSView whose height represents the total
///   scrollback (in pixels).
/// - `pane`: the actual renderer, positioned to always fill the visible
///   rect, so libghostty only ever renders the viewport.
///
/// The scroll view never scrolls content itself: the pane consumes wheel
/// events and forwards them to the core, the core reports viewport
/// changes through the SCROLLBAR action, and dragging the scroller sends
/// scroll_to_row binding actions back to the core.
final class PaneScrollView: NSView {
    private let scrollView: NSScrollView
    private let documentView: NSView
    private let pane: PaneView
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false

    /// The last row position sent via scroll_to_row, so dragging the
    /// scroller within one row doesn't spam the core.
    private var lastSentRow: Int?

    /// Persistent cursor over the terminal content (MOUSE_SHAPE): the
    /// scroll view re-applies it when AppKit resets the cursor, which a
    /// bare NSCursor.set() does not survive.
    var documentCursor: NSCursor? {
        get { scrollView.documentCursor }
        set { scrollView.documentCursor = newValue }
    }

    init(pane: PaneView) {
        self.pane = pane

        // The scroll view is our outermost view that controls all our
        // scrollbar rendering and behavior.
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Always use the overlay style; see mouseMoved for how we make it
        // usable when the system preference is legacy scrollers.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false

        // The document view is what the scroll view actually scrolls: a
        // blank view with the desired content (scrollback) size.
        documentView = NSView(frame: NSRect(origin: .zero, size: pane.frame.size))
        scrollView.documentView = documentView

        // The document view contains the actual pane. We synchronize the
        // scrolling of the document with the pane so the renderer only
        // needs to render the viewport.
        pane.frame.origin = .zero
        documentView.addSubview(pane)

        super.init(frame: pane.frame)

        addSubview(scrollView)

        synchronizeAppearance()

        // We listen for scroll events through bounds notifications on the
        // NSClipView.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizePane()
        })

        // Live scroll events (the user actively dragging the scroller).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        // Force the overlay style back if the system preference changes.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scrollView.scrollerStyle = .overlay
        })
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // The entire bounds is a safe area; override any default insets so
    // the content view always matches the pane.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Session drives our frame directly; make sure layout() runs so
        // the scroll view and pane track it.
        needsLayout = true
    }

    override func layout() {
        super.layout()

        // Fill our entire bounds with the scroll view.
        scrollView.frame = bounds
        pane.frame.size = scrollView.bounds.size

        // Only the width here; the height depends on the scrollback state
        // and is updated in synchronizeScrollView.
        documentView.frame.size.width = scrollView.bounds.width

        synchronizeScrollView()
        synchronizePane()
    }

    /// The core reported new scrollback dimensions (SCROLLBAR action).
    func scrollbarDidUpdate() {
        synchronizeScrollView()
    }

    // MARK: - Synchronization

    private func synchronizeAppearance() {
        let runtime = GhosttyRuntime.shared
        scrollView.hasVerticalScroller = runtime?.scrollbarEnabled ?? true
        // Match the scroller's appearance to the terminal background so
        // the thumb stays visible on both light and dark themes.
        let lightBackground = runtime?.terminalBackground.isLightColor ?? false
        scrollView.appearance = NSAppearance(named: lightBackground ? .aqua : .darkAqua)
        updateTrackingAreas()
    }

    /// Positions the pane to fill the currently visible rectangle, so the
    /// renderer only renders what is on screen.
    private func synchronizePane() {
        pane.frame.origin = scrollView.contentView.documentVisibleRect.origin
    }

    /// Sizes the document view and scrolls the content view according to
    /// the core's scrollback state.
    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        // Only move our scroll position when the user isn't dragging.
        if !isLiveScrolling {
            let cellHeight = pane.cellSize.height
            if cellHeight > 0, let scrollbar = pane.scrollbar {
                // Invert: terminal offset is from the top, AppKit position
                // from the bottom.
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))

                // Track the current row so scroller drags that stay on the
                // same row don't send redundant actions.
                lastSentRow = Int(scrollbar.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The document height for the current scrollback: total rows in
    /// pixels plus the same padding the viewport has around the grid,
    /// otherwise the content view loses alignment with the pane.
    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = pane.cellSize.height
        if cellHeight > 0, let scrollbar = pane.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }

    /// Converts the dragged scroll position to a row and asks the core to
    /// scroll there.
    private func handleLiveScroll() {
        let cellHeight = pane.cellSize.height
        guard cellHeight > 0 else { return }

        // AppKit views are +Y going up, so calculate from the bottom.
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row

        pane.bindingAction("scroll_to_row:\(row)")
    }

    // MARK: - Mouse

    override func mouseMoved(with _: NSEvent) {
        // When the OS preferred style is legacy, the user should be able
        // to click and drag the scroller without wheels or gestures, so
        // flash it when the mouse moves over the scrollbar area.
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()

        // Our tracking area is the scroller frame.
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }
}
