import XCTest

@testable import Mux

/// The state file is the only thing between a crash and a lost session,
/// so the formats it can be found in are pinned here: what this build
/// writes, and what an older build left behind.
final class SnapshotTests: XCTestCase {
    private let paneA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let paneB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let paneC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// The pane map is keyed by UUID, which JSONCoder writes as a flat
    /// [key, value, ...] array; the JSON here is the real on-disk shape.
    /// A v2 file could hold several windows. mux is single-window now,
    /// so every window's sessions fold into the one window and none is
    /// dropped; the frame and the active index come from the first.
    func testV2FoldsEveryWindowIntoOneSnapshot() throws {
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
        XCTAssertEqual(snapshot.sessions.count, 3)
        XCTAssertEqual(snapshot.sessions.flatMap(\.tree.leaves), [paneA, paneB, paneC])
        XCTAssertEqual(snapshot.frame, [10, 20, 800, 600])
        XCTAssertEqual(snapshot.activeSession, 1)
        XCTAssertEqual(snapshot.sessions[0].panes[paneA]?.cwd, "/tmp")
        XCTAssertEqual(snapshot.sessions[0].panes[paneA]?.fontDelta, 2)
        XCTAssertEqual(snapshot.sessions[0].focused, paneA)
        XCTAssertEqual(snapshot.sessions[1].panes[paneB]?.target, "spark")
        XCTAssertEqual(snapshot.sessions[2].zoomed, paneC)
    }

    func testCurrentVersionRoundTrips() throws {
        let written = AppSnapshot(
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

        let data = try JSONEncoder().encode(written)
        let read = try XCTUnwrap(SnapshotStore.decode(data))
        XCTAssertEqual(read.version, 3)
        XCTAssertEqual(read.frame, written.frame)
        XCTAssertEqual(read.activeSession, 0)
        XCTAssertEqual(read.sessions.count, 1)
        XCTAssertEqual(read.sessions[0].tree.leaves, [paneA, paneB])
        XCTAssertEqual(read.sessions[0].focused, paneB)
        XCTAssertEqual(read.sessions[0].panes[paneB]?.target, "spark")
        XCTAssertEqual(read.sessions[0].panes[paneB]?.fontDelta, -1)
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
