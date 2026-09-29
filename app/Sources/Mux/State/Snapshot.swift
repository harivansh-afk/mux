import Foundation
import Tiling

struct PaneSnapshot: Codable {
    var cwd: String?
    /// Where the pane's terminal lives (see PaneView.target). Absent in
    /// files written before targets existed, which is exactly what a
    /// local pane means - so no version bump.
    var target: String?
    /// Font zoom in points relative to the config default (cmd+= /
    /// cmd+-). Absent means default, so no version bump.
    var fontDelta: Int?
    /// Reopened terminals must never silently become a fresh shell.
    var requireExisting: Bool?

    var daemon: String? {
        IX.vm(of: target) == nil ? target : nil
    }
}

struct SessionSnapshot: Codable {
    var tree: SplitNode
    var panes: [UUID: PaneSnapshot]
    var focused: UUID?
    var zoomed: UUID?
}

/// Stable window identity keeps focus and session ownership across launches.
struct WindowSnapshot: Codable {
    let id: UUID
    var frame: [Double]
    var sessions: [SessionSnapshot]
    var activeSession: Int
    var closedPanes: [ClosedPaneHistory.Entry]?

    init(
        id: UUID = UUID(), frame: [Double], sessions: [SessionSnapshot],
        activeSession: Int, closedPanes: [ClosedPaneHistory.Entry]? = nil
    ) {
        self.id = id
        self.frame = frame
        self.sessions = sessions
        self.activeSession = activeSession
        self.closedPanes = closedPanes
    }

    private enum CodingKeys: String, CodingKey {
        case id, frame, sessions, activeSession, closedPanes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frame = try values.decode([Double].self, forKey: .frame)
        sessions = try values.decode([SessionSnapshot].self, forKey: .sessions)
        activeSession = try values.decode(Int.self, forKey: .activeSession)
        closedPanes = try values.decodeIfPresent([ClosedPaneHistory.Entry].self, forKey: .closedPanes)
    }
}

/// A pane UUID is scoped to its daemon; ix panes belong to the local daemon.
struct TerminalIdentity: Hashable {
    let id: UUID
    let host: String?
}

struct AppSnapshot: Codable {
    static let currentVersion = 4
    var version = AppSnapshot.currentVersion
    var windows: [WindowSnapshot]
    var activeWindow: UUID?

    init(windows: [WindowSnapshot], activeWindow: UUID? = nil) {
        self.windows = windows
        self.activeWindow = activeWindow
    }

    private enum CodingKeys: String, CodingKey {
        case version, windows, activeWindow
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        switch storedVersion {
        case 2, Self.currentVersion:
            windows = try values.decode([WindowSnapshot].self, forKey: .windows)
            activeWindow = try values.decodeIfPresent(UUID.self, forKey: .activeWindow) ?? windows.first?.id
        case 3:
            // The former single-window format becomes exactly one window.
            windows = try [WindowSnapshot(from: decoder)]
            activeWindow = windows.first?.id
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values, debugDescription: "Unsupported snapshot version"
            )
        }
    }

    /// Includes closed windows and closed terminals. Reconciliation must never
    /// adopt their detached PTYs into a different window's recovery session.
    var knownTerminals: Set<TerminalIdentity> {
        var known: Set<TerminalIdentity> = []
        for window in windows {
            for session in window.sessions {
                for id in session.tree.leaves {
                    known.insert(TerminalIdentity(id: id, host: session.panes[id]?.daemon))
                }
            }
            for entry in window.closedPanes ?? [] {
                known.insert(TerminalIdentity(id: entry.id, host: entry.pane.daemon))
            }
        }
        return known
    }

    var hosts: Set<String?> {
        Set(knownTerminals.map(\.host))
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

    /// Decode current windows or migrate v2/v3 without losing their grouping.
    static func decode(_ data: Data) -> AppSnapshot? {
        try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    private static func load(from source: URL, quarantineOnFailure: Bool) -> AppSnapshot? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        let snapshot = decode(data)
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
