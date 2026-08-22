import Foundation

/// One-shot reads from a helper binary. The overlays ask muxd and the ix
/// CLI for live status, and none of those answers may block the main
/// thread: every caller gets its result back asynchronously.
enum Subprocess {
    static let defaultTimeout: TimeInterval = 10

    /// Run `path arguments...` off the main thread and deliver its stdout on
    /// the main thread. stderr is dropped (ix writes progress there). nil
    /// means no usable answer - the process could not be launched, or it
    /// outlived `timeout` and was killed; a nonzero exit still yields its
    /// stdout, because `muxd probe` reports failures as JSON on it.
    static func run(
        _ path: String, _ arguments: [String],
        then completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // astlog-ignore: no-raw-process
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var output: String?
            do {
                try process.run()
                let watchdog = watchdog(process, after: defaultTimeout)
                // Read before waiting: the pipe buffer would block forever the other way.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let killed = process.terminationReason == .uncaughtSignal
                    && process.terminationStatus == SIGKILL
                output = killed ? nil : String(data: data, encoding: .utf8)
            } catch {
                output = nil
            }
            DispatchQueue.main.async { completion(output) }
        }
    }

    private static func watchdog(_ process: Process, after: TimeInterval) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            // SIGKILL, not terminate(): the helper may be ignoring SIGTERM.
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + after, execute: item)
        return item
    }
}
