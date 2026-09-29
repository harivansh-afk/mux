import AppKit
@testable import Mux
import Tiling
import XCTest

final class WindowTests: XCTestCase {
    /// Hidden test windows, no Ghostty runtime or daemon; exercise ownership
    /// without launching the app or changing the user's saved state.
    func testMoveSessionPreservesViewsTreeFocusAndWindowOwnership() throws {
        _ = NSApplication.shared
        let source = MuxWindowController()
        let destination = MuxWindowController()
        let first = try XCTUnwrap(source.activeSession)
        let firstPane = first.addInitialPane()
        source.newSession(target: .explicit("spark"))
        let moving = try XCTUnwrap(source.activeSession)
        let pane = try XCTUnwrap(moving.panes.values.first)
        moving.noteFocused(pane)
        moving.split(direction: .vertical)
        moving.noteFocused(pane)
        moving.toggleZoom()
        let scrollHost = try XCTUnwrap(pane.scrollHost)
        let before = try XCTUnwrap(moving.snapshot)

        source.moveActiveSession(to: destination)

        XCTAssertTrue(source.activeSession === first)
        XCTAssertTrue(firstPane.controller === source)
        XCTAssertTrue(destination.activeSession === moving)
        XCTAssertEqual(source.sessions.count, 1)
        XCTAssertEqual(destination.sessions.count, 1)
        XCTAssertEqual(moving.tree?.leaves, before.tree.leaves)
        XCTAssertEqual(moving.focusedID, before.focused)
        XCTAssertEqual(moving.zoomedID, before.zoomed)
        XCTAssertTrue(moving.panes[pane.id] === pane)
        XCTAssertTrue(pane.scrollHost === scrollHost)
        XCTAssertTrue(scrollHost.superview === destination.workspace)
        XCTAssertTrue(pane.window === destination.window)
        XCTAssertTrue(pane.controller === destination)
        XCTAssertNil(source.session(owning: pane))
        XCTAssertTrue(destination.session(owning: pane) === moving)
        XCTAssertEqual(destination.snapshot.sessions[0].panes[pane.id]?.target, "spark")
        XCTAssertFalse(source.canMoveSessionToNewWindow)
        XCTAssertFalse(destination.canMoveSessionToNewWindow)
        first.destroyAllSurfaces()
        moving.destroyAllSurfaces()
    }

    func testClosedWindowStaysInSubsequentSavesAndReconciliation() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let first = MuxWindowController()
        let second = MuxWindowController()
        let id = try XCTUnwrap(first.activeSession?.addInitialPane(target: "spark").id)
        second.activeSession?.addInitialPane()
        delegate.controllers = [first, second]
        delegate.windowControllerWillClose(first)
        first.activeSession?.destroyAllSurfaces()

        XCTAssertEqual(delegate.controllers.count, 1)
        XCTAssertEqual(delegate.closedWindows.map(\.id), [first.id])
        let saved = delegate.snapshot
        XCTAssertEqual(saved.windows.count, 2)
        XCTAssertTrue(saved.knownTerminals.contains(TerminalIdentity(id: id, host: "spark")))
        XCTAssertFalse(saved.knownTerminals.contains(TerminalIdentity(id: id, host: nil)))
        let restored = try XCTUnwrap(SnapshotStore.decode(JSONEncoder().encode(saved)))
        let closed = try XCTUnwrap(restored.windows.first { $0.id == first.id })
        XCTAssertEqual(closed.sessions[0].tree.leaves, [id])
        second.activeSession?.destroyAllSurfaces()
    }

    func testShortcutsDoNotConflictWithSessionCreationOrTerminalClose() throws {
        func action(_ key: String, _ flags: NSEvent.ModifierFlags) throws -> PrefixEngine.WindowShortcut? {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 45
            ))
            return PrefixEngine.windowShortcut(event)
        }
        XCTAssertEqual(try action("n", .command), .newSession)
        XCTAssertEqual(try action("N", [.command, .shift]), .newWindow)
        XCTAssertEqual(try action("n", [.command, .option, .capsLock]), .moveSession)
        XCTAssertEqual(try action("W", [.command, .shift]), .closeWindow)
        XCTAssertNil(try action("w", .command))
        XCTAssertNil(try action("n", [.command, .shift, .option]))
        XCTAssertNil(try action("n", [.command, .control]))
        XCTAssertNil(try action("n", []))
    }
}
