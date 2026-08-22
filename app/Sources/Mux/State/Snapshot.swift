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

/// The whole app: one window's frame and its ordered sessions.
struct AppSnapshot: Codable {
    static let currentVersion = 3
    var version: Int = AppSnapshot.currentVersion
    var frame: [Double] // x, y, w, h
    var sessions: [SessionSnapshot]
    var activeSession: Int
}

/// v2: an array of windows, each with its own sessions. mux is
/// single-window, so every window's sessions fold into the one window
/// and nothing is dropped on the way through; the frame and the active
/// index come from the first window.
private struct AppSnapshotV2: Decodable {
    struct Window: Decodable {
        var frame: [Double]
        var sessions: [SessionSnapshot]
        var activeSession: Int
    }

    var windows: [Window]

    var folded: AppSnapshot {
        AppSnapshot(
            frame: windows.first?.frame ?? [],
            sessions: windows.flatMap(\.sessions),
            activeSession: windows.first?.activeSession ?? 0
        )
    }
}

extension CGRect {
    /// The frame as the snapshot stores it.
    var values: [Double] {
        [origin.x, origin.y, size.width, size.height]
    }

    /// nil for a frame the snapshot never wrote (or wrote short).
    init?(values: [Double]) {
        guard values.count == 4 else { return nil }
        self.init(x: values[0], y: values[1], width: values[2], height: values[3])
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

    /// Every format this build reads: the current one, else a v2 file
    /// folded into the single window. Anything older or damaged is
    /// undecodable both ways and is quarantined by the caller.
    static func decode(_ data: Data) -> AppSnapshot? {
        let decoder = JSONDecoder()
        return (try? decoder.decode(AppSnapshot.self, from: data))
            ?? (try? decoder.decode(AppSnapshotV2.self, from: data))?.folded
    }

    private static func load(from source: URL, quarantineOnFailure: Bool) -> AppSnapshot? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        let snapshot = decode(data)
        if snapshot == nil, quarantineOnFailure {
            let fm = FileManager.default
            try? fm.removeItem(at: quarantineURL)
            try? fm.moveItem(at: source, to: quarantineURL)
            NSLog("snapshot undecodable; moved aside to \(quarantineURL.lastPathComponent)")
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
            NSLog("previous run ended uncleanly; snapshot preserved at \(precrash.lastPathComponent)")
        }
        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: markerURL)
        return unclean
    }

    static func disarm() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
