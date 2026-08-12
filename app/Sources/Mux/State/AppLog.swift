import Foundation

/// Append-only breadcrumbs beside state.json (`app.log`): snapshot
/// saves/loads, pane lifecycle, kill decisions, termination. The unified
/// log drops or hides app messages, and reconstructing why a session
/// vanished from timestamps alone costs hours; one plain file makes the
/// whole client side auditable after the fact. Best effort: logging must
/// never affect the session it describes.
enum AppLog {
    private static let handle: FileHandle? = {
        let url = SnapshotStore.url.deletingLastPathComponent()
            .appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private static let queue = DispatchQueue(label: "mux.applog", qos: .utility)

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
        queue.async {
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Flush before the process goes away; termination is exactly the
    /// moment the trail matters most.
    static func drain() {
        queue.sync {
            try? handle?.synchronize()
        }
    }
}
