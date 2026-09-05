import AppKit
@testable import Mux
import XCTest

final class ClosedPaneHistoryTests: XCTestCase {
    func testReopensMostRecentFirstAndPreservesMetadata() throws {
        var history = ClosedPaneHistory()
        let first = UUID()
        let second = UUID()
        history.record(id: first, pane: PaneSnapshot(cwd: "/tmp"), killed: false)
        history.record(
            id: second, pane: PaneSnapshot(cwd: "/work", target: "spark", fontDelta: 3), killed: false
        )
        let entry = try XCTUnwrap(history.popLast())
        XCTAssertEqual(entry.id, second)
        XCTAssertTrue(entry.expectExisting)
        XCTAssertEqual(entry.snapshot.tree.leaves, [second])
        XCTAssertEqual(entry.snapshot.focused, second)
        XCTAssertEqual(entry.snapshot.panes[second]?.cwd, "/work")
        XCTAssertEqual(entry.snapshot.panes[second]?.target, "spark")
        XCTAssertEqual(entry.snapshot.panes[second]?.fontDelta, 3)
        XCTAssertEqual(history.popLast()?.id, first)
        XCTAssertNil(history.popLast())
        XCTAssertTrue(history.isEmpty)
    }

    func testKilledPaneUsesFreshIdentity() throws {
        var history = ClosedPaneHistory()
        let original = UUID()
        history.record(id: original, pane: PaneSnapshot(target: "ix:dev"), killed: true)
        let entry = try XCTUnwrap(history.popLast())
        XCTAssertNotEqual(entry.id, original)
        XCTAssertFalse(entry.expectExisting)
        XCTAssertEqual(entry.pane.target, "ix:dev")
    }

    func testHistoryKeepsNewestTwenty() {
        var history = ClosedPaneHistory()
        let ids = (0 ..< 21).map { _ in UUID() }
        for id in ids {
            history.record(id: id, pane: PaneSnapshot(), killed: false)
        }
        for id in ids.dropFirst().reversed() {
            XCTAssertEqual(history.popLast()?.id, id)
        }
        XCTAssertNil(history.popLast())
    }

    func testShortcutRequiresCommandShiftT() throws {
        func event(_ text: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: 17
            ))
        }
        XCTAssertTrue(try PrefixEngine.isReopenClosedTab(event("T", [.command, .shift])))
        XCTAssertTrue(try PrefixEngine.isReopenClosedTab(event("t", [.command, .shift, .capsLock])))
        XCTAssertFalse(try PrefixEngine.isReopenClosedTab(event("t", [.command])))
        XCTAssertFalse(try PrefixEngine.isReopenClosedTab(event("T", [.command, .shift, .option])))
        XCTAssertFalse(try PrefixEngine.isReopenClosedTab(event("T", [.command, .shift, .control])))
        XCTAssertFalse(try PrefixEngine.isReopenClosedTab(event("N", [.command, .shift])))
    }
}
