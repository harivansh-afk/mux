@testable import Mux
import XCTest

final class CanvasLifetimeTests: XCTestCase {
    func testReloadReleasesOldCards() {
        let canvas = CanvasOverlayView(frame: .zero)
        let oldViews = NSHashTable<NSView>.weakObjects()
        autoreleasepool {
            canvas.reload(entries: [.init(sessionIndex: 0, paneID: UUID(), pane: nil)], selected: nil)
            func remember(_ view: NSView) {
                oldViews.add(view)
                view.subviews.forEach(remember)
            }
            canvas.subviews.forEach(remember)
            canvas.reload(entries: [], selected: nil)
        }
        // Every surviving view must still belong to the canvas. Detached
        // cards, their labels and their mirror layers must be released.
        for view in oldViews.allObjects {
            XCTAssertTrue(view.isDescendant(of: canvas), "detached view retained: \(view)")
        }
    }
}
