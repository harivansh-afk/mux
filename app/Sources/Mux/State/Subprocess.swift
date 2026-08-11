import Foundation

/// One-shot reads from a helper binary. The overlays ask mux-attach, muxd
/// and the ix CLI for live status, and none of those answers may block the
/// main thread: every caller gets its result back asynchronously.
enum Subprocess {
    /// Run `path arguments...` off the main thread and deliver its stdout on
    /// the main thread. stderr is dropped (ix writes progress there). nil
    /// means the process could not be launched at all; a nonzero exit still
    /// yields its stdout, because `mux-attach probe` reports failures as
    /// JSON on it.
    static func run(
        _ path: String, _ arguments: [String], then completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var output: String?
            do {
                try process.run()
                // Read before waiting: a helper that outgrows the pipe
                // buffer would block forever on the other order.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                output = String(data: data, encoding: .utf8)
            } catch {
                output = nil
            }
            DispatchQueue.main.async { completion(output) }
        }
    }
}
