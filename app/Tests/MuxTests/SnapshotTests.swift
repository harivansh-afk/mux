@testable import Mux
import Tiling
import XCTest

/// The state file is the only thing between a crash and a lost session,
/// so the formats it can be found in are pinned here: what this build
/// writes, and what an older build left behind.
final class SnapshotTests: XCTestCase {
    func testOldV3SnapshotHasNoClosedTerminals() throws {
        let json = """
        {"version":3,"frame":[],"sessions":[],"activeSession":0}
        """
        let snapshot = try XCTUnwrap(SnapshotStore.decode(Data(json.utf8)))
        XCTAssertNil(snapshot.windows[0].closedPanes)
    }

    private let paneA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let paneB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let paneC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// The pane map is keyed by UUID, which JSONCoder writes as a flat
    /// [key, value, ...] array; the JSON here is the real on-disk shape.
    /// Older multi-window saves retain each window's grouping.
    func testV2PreservesWindowGroups() throws {
        let json = """
        {
          "version": 2,
          "windows": [
            {
              "frame": [10, 20, 800, 600],
              "activeSession": 1,
              "sessions": [
                {
                  "tree": { "leaf": { "_0": "\(paneA.uuidString)" } },
                  "panes": ["\(paneA.uuidString)", { "cwd": "/tmp", "fontDelta": 2 }],
                  "focused": "\(paneA.uuidString)"
                },
                {
                  "tree": { "leaf": { "_0": "\(paneB.uuidString)" } },
                  "panes": ["\(paneB.uuidString)", { "target": "spark" }]
                }
              ]
            },
            {
              "frame": [0, 0, 400, 300],
              "activeSession": 0,
              "sessions": [
                {
                  "tree": { "leaf": { "_0": "\(paneC.uuidString)" } },
                  "panes": ["\(paneC.uuidString)", {}],
                  "zoomed": "\(paneC.uuidString)"
                }
              ]
            }
          ]
        }
        """

        let snapshot = try XCTUnwrap(SnapshotStore.decode(Data(json.utf8)))
        XCTAssertEqual(snapshot.version, 4)
        XCTAssertEqual(snapshot.windows.count, 2)
        let first = snapshot.windows[0]
        let second = snapshot.windows[1]
        XCTAssertEqual(first.sessions.flatMap(\.tree.leaves), [paneA, paneB])
        XCTAssertEqual(second.sessions.flatMap(\.tree.leaves), [paneC])
        XCTAssertEqual(first.frame, [10, 20, 800, 600])
        XCTAssertEqual(first.activeSession, 1)
        XCTAssertEqual(second.frame, [0, 0, 400, 300])
        XCTAssertEqual(first.sessions[0].panes[paneA]?.cwd, "/tmp")
        XCTAssertEqual(first.sessions[0].panes[paneA]?.fontDelta, 2)
        XCTAssertEqual(first.sessions[0].focused, paneA)
        XCTAssertEqual(first.sessions[1].panes[paneB]?.target, "spark")
        XCTAssertEqual(second.sessions[0].zoomed, paneC)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testCurrentVersionRoundTrips() throws {
        let window = WindowSnapshot(
            frame: [1, 2, 3, 4],
            sessions: [SessionSnapshot(
                tree: .split(SplitBranch(
                    direction: .vertical, ratio: 0.25,
                    first: .leaf(paneA), second: .leaf(paneB)
                )),
                panes: [
                    paneA: PaneSnapshot(cwd: "/", target: nil, fontDelta: nil),
                    paneB: PaneSnapshot(cwd: nil, target: "spark", fontDelta: -1),
                ],
                focused: paneB,
                zoomed: nil
            )],
            activeSession: 0
        )

        let other = WindowSnapshot(frame: [50, 60, 800, 600], sessions: [], activeSession: 0)
        let written = AppSnapshot(windows: [window, other], activeWindow: other.id)
        let data = try JSONEncoder().encode(written)
        let read = try XCTUnwrap(SnapshotStore.decode(data))
        XCTAssertEqual(read.version, 4)
        XCTAssertEqual(read.windows.count, 2)
        XCTAssertEqual(read.activeWindow, other.id)
        XCTAssertEqual(read.windows[0].id, window.id)
        XCTAssertEqual(read.windows[0].frame, window.frame)
        XCTAssertEqual(read.windows[0].activeSession, 0)
        XCTAssertEqual(read.windows[0].sessions.count, 1)
        XCTAssertEqual(read.windows[0].sessions[0].tree.leaves, [paneA, paneB])
        XCTAssertEqual(read.windows[0].sessions[0].focused, paneB)
        XCTAssertEqual(read.windows[0].sessions[0].panes[paneB]?.target, "spark")
        XCTAssertEqual(read.windows[0].sessions[0].panes[paneB]?.fontDelta, -1)
    }

    /// v1 put one implicit session's fields inline on the window. It is
    /// not readable here, and an unreadable file is quarantined rather
    /// than parsed halfway.
    func testV1DoesNotDecode() {
        let json = """
        {
          "version": 1,
          "windows": [
            {
              "frame": [0, 0, 800, 600],
              "tree": { "leaf": { "_0": "\(paneA.uuidString)" } },
              "panes": ["\(paneA.uuidString)", { "cwd": "/tmp" }],
              "focused": "\(paneA.uuidString)"
            }
          ]
        }
        """
        XCTAssertNil(SnapshotStore.decode(Data(json.utf8)))
    }
}

extension SnapshotTests {
    func testV3MigratesItsSessionAndCloseDeadlineIntoOneWindow() throws {
        let id = UUID()
        let deadline = Date().addingTimeInterval(20)
        let window = WindowSnapshot(
            frame: [1, 2, 900, 700],
            sessions: [.init(tree: .leaf(id), panes: [id: PaneSnapshot(target: "spark")], focused: id)],
            activeSession: 0,
            closedPanes: [.init(id: UUID(), pane: PaneSnapshot(target: "ix:dev"), expiresAt: deadline)]
        )
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as? [String: Any])
        legacy.removeValue(forKey: "id")
        legacy["version"] = 3
        let read = try XCTUnwrap(SnapshotStore.decode(JSONSerialization.data(withJSONObject: legacy)))
        XCTAssertEqual(read.windows.count, 1)
        XCTAssertEqual(read.windows[0].frame, window.frame)
        XCTAssertEqual(read.windows[0].sessions[0].focused, id)
        XCTAssertEqual(read.windows[0].sessions[0].panes[id]?.target, "spark")
        XCTAssertEqual(read.windows[0].closedPanes?.first?.expiresAt, deadline)
        XCTAssertEqual(read.activeWindow, read.windows[0].id)
    }

    func testRecoveryChecksEveryWindowAndScopesIdentityToDaemon() {
        let local = UUID()
        let remote = UUID()
        let closed = UUID()
        let snapshots = [
            WindowSnapshot(frame: [], sessions: [
                .init(tree: .leaf(local), panes: [local: PaneSnapshot(target: "ix:vm")]),
            ], activeSession: 0),
            WindowSnapshot(frame: [], sessions: [
                .init(tree: .leaf(remote), panes: [remote: PaneSnapshot(target: "spark")]),
            ], activeSession: 0, closedPanes: [
                .init(id: closed, pane: PaneSnapshot(target: "other"), expiresAt: .distantFuture),
            ]),
        ]
        let snapshot = AppSnapshot(windows: snapshots)
        XCTAssertEqual(snapshot.knownTerminals, [
            TerminalIdentity(id: local, host: nil),
            TerminalIdentity(id: remote, host: "spark"),
            TerminalIdentity(id: closed, host: "other"),
        ])
        XCTAssertFalse(snapshot.knownTerminals.contains(.init(id: remote, host: nil)))
        XCTAssertFalse(snapshot.knownTerminals.contains(.init(id: local, host: "spark")))
        XCTAssertEqual(snapshot.hosts, [nil, "spark", "other"])
    }

    func testFutureSnapshotVersionIsNotSilentlyOverwritten() {
        XCTAssertNil(SnapshotStore.decode(Data("{\"version\":99,\"windows\":[]}".utf8)))
    }
}
