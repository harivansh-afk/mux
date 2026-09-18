import AppKit
@testable import Mux
import XCTest

final class ClosedPaneHistoryTests: XCTestCase {
    func testReopensMostRecentFirstAndPreservesMetadata() throws {
        var history = ClosedPaneHistory()
        let first = UUID()
        let second = UUID()
        history.record(id: first, pane: PaneSnapshot(cwd: "/tmp"))
        history.record(
            id: second, pane: PaneSnapshot(cwd: "/work", target: "spark", fontDelta: 3)
        )
        let entry = try XCTUnwrap(history.popLast())
        XCTAssertEqual(entry.id, second)
        XCTAssertEqual(entry.pane.requireExisting, true)
        XCTAssertEqual(entry.snapshot.tree.leaves, [second])
        XCTAssertEqual(entry.snapshot.focused, second)
        XCTAssertEqual(entry.snapshot.panes[second]?.cwd, "/work")
        XCTAssertEqual(entry.snapshot.panes[second]?.target, "spark")
        XCTAssertEqual(entry.snapshot.panes[second]?.fontDelta, 3)
        XCTAssertEqual(history.popLast()?.id, first)
        XCTAssertNil(history.popLast())
        XCTAssertTrue(history.isEmpty)
    }

    func testHistoryPersistsAcrossAnEmptyAppRestart() throws {
        var history = ClosedPaneHistory()
        let id = UUID()
        history.record(id: id, pane: PaneSnapshot(target: "ix:dev"))
        let snapshot = AppSnapshot(frame: [], sessions: [], activeSession: 0, closedPanes: history.entries)
        let decoded = try XCTUnwrap(SnapshotStore.decode(JSONEncoder().encode(snapshot)))
        var restored = ClosedPaneHistory(entries: decoded.closedPanes ?? [])
        XCTAssertTrue(restored.contains(id, on: nil))
        XCTAssertFalse(restored.contains(id, on: "spark"))
        let entry = try XCTUnwrap(restored.popLast())
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.pane.requireExisting, true)
        XCTAssertEqual(entry.pane.target, "ix:dev")
        let reopened = AppSnapshot(frame: [], sessions: [entry.snapshot], activeSession: 0)
        let active = try XCTUnwrap(SnapshotStore.decode(JSONEncoder().encode(reopened)))
        XCTAssertEqual(active.sessions[0].panes[id]?.requireExisting, true)
    }

    func testHistoryDoesNotEvictLiveTerminals() {
        var history = ClosedPaneHistory()
        let ids = (0 ..< 21).map { _ in UUID() }
        for id in ids {
            history.record(id: id, pane: PaneSnapshot())
        }
        for id in ids.reversed() {
            XCTAssertEqual(history.popLast()?.id, id)
        }
        XCTAssertNil(history.popLast())
    }

    func testDeduplicationAndExitAreScopedToTheOwningDaemon() {
        var history = ClosedPaneHistory()
        let id = UUID()
        history.record(id: id, pane: PaneSnapshot())
        history.record(id: id, pane: PaneSnapshot(target: "spark"))
        history.record(id: id, pane: PaneSnapshot(target: "spark", fontDelta: 2))
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertTrue(history.contains(id, on: "spark"))
        XCTAssertFalse(history.remove(id, on: "other-host"))
        XCTAssertTrue(history.remove(id, on: nil))
        XCTAssertFalse(history.contains(id, on: nil))
        XCTAssertEqual(history.popLast()?.pane.fontDelta, 2)
    }

    func testExpiredHistoryCannotReopenAndRestartDoesNotRenewDeadline() throws {
        var history = ClosedPaneHistory()
        let id = UUID()
        let deadline = Date().addingTimeInterval(-1)
        history.record(id: id, pane: PaneSnapshot(target: "spark"), expiresAt: deadline)
        XCTAssertTrue(history.isEmpty)
        let data = try JSONEncoder().encode(history.entries)
        let entries = try JSONDecoder().decode([ClosedPaneHistory.Entry].self, from: data)
        var restored = ClosedPaneHistory(entries: entries)
        XCTAssertEqual(restored.entries.first?.expiresAt, deadline)
        XCTAssertNil(restored.popLast())
    }

    func testLegacyHistoryExpiresAndCleanupIsScopedToHost() throws {
        let id = UUID()
        let entries = [ClosedPaneHistory.Entry(id: id, pane: PaneSnapshot(target: "spark"), expiresAt: nil)]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([ClosedPaneHistory.Entry].self, from: data)
        var history = ClosedPaneHistory(entries: decoded)
        XCTAssertEqual(history.expired(on: "spark").map(\.id), [id])
        XCTAssertTrue(history.expired(on: nil).isEmpty)
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
        XCTAssertTrue(try PrefixEngine.isCloseTab(event("w", [.command])))
        XCTAssertFalse(try PrefixEngine.isCloseTab(event("W", [.command, .shift])))
        XCTAssertFalse(try PrefixEngine.isCloseTab(event("w", [.command, .option])))
    }
}

private extension ClosedPaneHistory {
    mutating func record(id: UUID, pane: PaneSnapshot) {
        record(id: id, pane: pane, expiresAt: .distantFuture)
    }
}
