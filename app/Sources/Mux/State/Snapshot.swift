import Foundation

// Layout-and-identity persistence: structural facts are
// always saved (cheap, versioned JSON); screen contents are the daemon's
// job starting in M2. Restore resurrects the layout and per-pane cwd.

struct PaneSnapshot: Codable {
    var cwd: String?
    /// Where the pane's terminal lives (see PaneView.target). Absent in
    /// files written before targets existed, which is exactly what a
    /// local pane means - so no version bump.
    var target: String?
    /// Font zoom in points relative to the config default (cmd+= /
    /// cmd+-). Absent means default, so no version bump.
    var fontDelta: Int?
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
                    focused: w.focused, zoomed: w.zoomed
                )],
                activeSession: 0
            )
        })
    }
}

enum SnapshotStore {
    static var url: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = base.appendingPathComponent("mux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    /// One-generation-ago copy, rotated on every save. Recovery source
    /// when the main file is missing or undecodable.
    private static var backupURL: URL {
        url.appendingPathExtension("bak")
    }

    /// Where an undecodable file is moved aside. Evidence is never
    /// deleted or overwritten by the fresh session's first save.
    private static var quarantineURL: URL {
        url.appendingPathExtension("corrupt")
    }

    static func save(_ snapshot: AppSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let fm = FileManager.default
            // An unchanged snapshot is not a save: rotating on it would
            // push the same bytes into .bak, and two identical saves in a
            // row (teardown paths fire more than once) would leave BOTH
            // generations holding the end state - erasing the one copy
            // that still had the sessions.
            if let existing = try? Data(contentsOf: url), existing == data {
                return
            }
            // Rotate the current file to .bak first: the previous state
            // survives a bad write or a bad snapshot by one generation.
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: backupURL)
                try? fm.moveItem(at: url, to: backupURL)
            }
            // Atomic write: never leave a torn state file.
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.log("snapshot save failed: \(error)")
        }
    }

    static func load() -> AppSnapshot? {
        if let snapshot = load(from: url, quarantineOnFailure: true) {
            return snapshot
        }
        // Main file missing or undecodable: fall back one generation.
        return load(from: backupURL, quarantineOnFailure: false)
    }

    private static func load(from source: URL, quarantineOnFailure: Bool) -> AppSnapshot? {
        struct Versioned: Decodable { var version: Int }
        guard let data = try? Data(contentsOf: source) else { return nil }
        let decoder = JSONDecoder()
        let snapshot: AppSnapshot? = if let versioned = try? decoder.decode(Versioned.self, from: data) {
            switch versioned.version {
            case AppSnapshot.currentVersion:
                try? decoder.decode(AppSnapshot.self, from: data)
            case 1:
                (try? decoder.decode(AppSnapshotV1.self, from: data))?.migrated
            default:
                nil
            }
        } else {
            nil
        }
        if snapshot == nil, quarantineOnFailure {
            let fm = FileManager.default
            try? fm.removeItem(at: quarantineURL)
            try? fm.moveItem(at: source, to: quarantineURL)
            AppLog.log("snapshot undecodable; moved aside to \(quarantineURL.lastPathComponent)")
        }
        return snapshot
    }
}

/// Detects a previous run that never reached clean termination and, when
/// it finds one, freezes the exact pre-crash snapshot before anything
/// else can rotate or overwrite it.
enum CrashMarker {
    private static var markerURL: URL {
        SnapshotStore.url.deletingLastPathComponent().appendingPathComponent("running")
    }

    /// Call once at launch, before the snapshot is loaded. Returns true
    /// if the previous run ended uncleanly; arms the marker either way.
    static func checkAndArm() -> Bool {
        let fm = FileManager.default
        let unclean = fm.fileExists(atPath: markerURL.path)
        if unclean {
            // This copy is never touched by ordinary saves, only
            // replaced by the next unclean launch.
            let precrash = SnapshotStore.url.appendingPathExtension("pre-crash")
            try? fm.removeItem(at: precrash)
            try? fm.copyItem(at: SnapshotStore.url, to: precrash)
            AppLog.log("previous run ended uncleanly; snapshot preserved at \(precrash.lastPathComponent)")
        }
        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: markerURL)
        return unclean
    }

    static func disarm() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
