import Foundation
import Tiling

/// Metadata only: terminal contents and surviving processes stay on muxd.
struct ClosedPaneHistory {
    struct Entry: Codable {
        let id: UUID
        let pane: PaneSnapshot
        var expiresAt: Date?

        var snapshot: SessionSnapshot {
            SessionSnapshot(tree: .leaf(id), panes: [id: pane], focused: id, zoomed: nil)
        }
    }

    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        for entry in entries {
            record(id: entry.id, pane: entry.pane, expiresAt: entry.expiresAt ?? .distantPast)
        }
    }

    func contains(_ id: UUID, on host: String?) -> Bool {
        entries.contains { $0.id == id && $0.pane.daemon == host }
    }

    var isEmpty: Bool {
        !entries.contains { ($0.expiresAt ?? .distantPast) > Date() }
    }

    mutating func record(
        id: UUID, pane: PaneSnapshot, expiresAt: Date = Date().addingTimeInterval(60)
    ) {
        remove(id, on: pane.daemon)
        var saved = pane
        saved.requireExisting = true
        entries.append(Entry(id: id, pane: saved, expiresAt: expiresAt))
    }

    @discardableResult
    mutating func remove(_ id: UUID, on host: String?) -> Bool {
        let count = entries.count
        entries.removeAll { $0.id == id && $0.pane.daemon == host }
        return entries.count != count
    }

    mutating func popLast() -> Entry? {
        entries.removeAll { ($0.expiresAt ?? .distantPast) <= Date() }
        return entries.popLast()
    }
}
