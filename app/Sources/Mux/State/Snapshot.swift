import Foundation

/// Layout-and-identity persistence: structural facts are
/// always saved (cheap, versioned JSON); screen contents are the daemon's
/// job starting in M2. Restore resurrects the layout and per-pane cwd.

struct PaneSnapshot: Codable {
    var cwd: String?
}

struct SessionSnapshot: Codable {
    var tree: SplitNode
    var panes: [UUID: PaneSnapshot]
    var focused: UUID?
    var zoomed: UUID?
}

struct WindowSnapshot: Codable {
    var frame: [Double] // x, y, w, h
    var sessions: [SessionSnapshot]
    var activeSession: Int
}

struct AppSnapshot: Codable {
    static let currentVersion = 2
    var version: Int = AppSnapshot.currentVersion
    var windows: [WindowSnapshot]
}

/// v1: one implicit session per window, its fields inline on the window.
private struct AppSnapshotV1: Decodable {
    struct Window: Decodable {
        var frame: [Double]
        var tree: SplitNode
        var panes: [UUID: PaneSnapshot]
        var focused: UUID?
        var zoomed: UUID?
    }

    var windows: [Window]

    var migrated: AppSnapshot {
        AppSnapshot(windows: windows.map { w in
            WindowSnapshot(
                frame: w.frame,
                sessions: [SessionSnapshot(
                    tree: w.tree, panes: w.panes,
                    focused: w.focused, zoomed: w.zoomed)],
                activeSession: 0)
        })
    }
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
        struct Versioned: Decodable { var version: Int }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard let versioned = try? decoder.decode(Versioned.self, from: data) else {
            NSLog("snapshot decode failed; starting fresh")
            return nil
        }
        switch versioned.version {
        case AppSnapshot.currentVersion:
            return try? decoder.decode(AppSnapshot.self, from: data)
        case 1:
            return (try? decoder.decode(AppSnapshotV1.self, from: data))?.migrated
        default:
            return nil
        }
    }
}
