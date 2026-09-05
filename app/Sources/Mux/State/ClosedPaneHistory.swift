import Foundation
import Tiling

/// Metadata only: terminal contents and surviving processes stay on muxd.
struct ClosedPaneHistory {
    struct Entry {
        let id: UUID
        let pane: PaneSnapshot
        let expectExisting: Bool

        var snapshot: SessionSnapshot {
            SessionSnapshot(tree: .leaf(id), panes: [id: pane], focused: id, zoomed: nil)
        }
    }

    private var entries: [Entry] = []

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func record(id: UUID, pane: PaneSnapshot, killed: Bool) {
        // A kill runs asynchronously. A fresh ID prevents reopening from
        // attaching to the dying pty or being caught by its pending kill.
        entries.append(Entry(id: killed ? UUID() : id, pane: pane, expectExisting: !killed))
        if entries.count > 20 {
            entries.removeFirst()
        }
    }

    mutating func popLast() -> Entry? {
        entries.popLast()
    }
}
