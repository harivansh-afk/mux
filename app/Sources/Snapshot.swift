import Foundation

/// Layout-and-identity persistence, herdr's model: structural facts are
/// always saved (cheap, versioned JSON); screen contents are the daemon's
/// job starting in M2. Restore resurrects the layout and per-pane cwd.

struct PaneSnapshot: Codable {
    var cwd: String?
}

struct WindowSnapshot: Codable {
    var frame: [Double] // x, y, w, h
    var tree: SplitNode
    var panes: [UUID: PaneSnapshot]
    var focused: UUID?
    var zoomed: UUID?
}

struct AppSnapshot: Codable {
    static let currentVersion = 1
    var version: Int = AppSnapshot.currentVersion
    var windows: [WindowSnapshot]
}

enum SnapshotStore {
    static var url: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    static func save(_ snapshot: AppSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            // Atomic write: never leave a torn state file.
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("snapshot save failed: \(error)")
        }
    }

    static func load() -> AppSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: data) else {
            NSLog("snapshot decode failed; starting fresh")
            return nil
        }
        guard snapshot.version == AppSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
