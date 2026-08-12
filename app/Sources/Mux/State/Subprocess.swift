import Foundation

/// One-shot reads from a helper binary. The overlays ask mux-attach, muxd
/// and the ix CLI for live status, and none of those answers may block the
/// main thread: every caller gets its result back asynchronously.
enum Subprocess {
    /// How long a helper gets to answer. A probe dials a host that may be
    /// off, asleep, or holding the connection open with nothing to say,
    /// and every one of those has to end in a result the overlay can
    /// draw.
    static let defaultTimeout: TimeInterval = 10

    /// Run `path arguments...` off the main thread and deliver its stdout on
    /// the main thread. stderr is dropped (ix writes progress there). nil
    /// means no usable answer - the process could not be launched, or it
    /// outlived `timeout` and was killed; a nonzero exit still yields its
    /// stdout, because `mux-attach probe` reports failures as JSON on it.
    static func run(
        _ path: String, _ arguments: [String], timeout: TimeInterval = defaultTimeout,
        then completion: @escaping (String?) -> Void
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
                // A helper that never exits would otherwise hold this
                // worker and its caller's overlay forever. Killing it
                // closes its end of the pipe, which is what releases the
                // read below.
                let watchdog = watchdog(process, after: timeout)
                // Read before waiting: a helper that outgrows the pipe
                // buffer would block forever on the other order.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                // Whatever a killed helper managed to print is a truncated
                // answer, which every caller here would have to reject
                // anyway: report it as no answer.
                let killed = process.terminationReason == .uncaughtSignal
                    && process.terminationStatus == SIGKILL
                output = killed ? nil : String(data: data, encoding: .utf8)
            } catch {
                output = nil
            }
            DispatchQueue.main.async { completion(output) }
        }
    }

    /// Kill `process` if it is still running `after` seconds from now.
    /// The caller cancels the returned item once the helper has exited on
    /// its own.
    private static func watchdog(_ process: Process, after: TimeInterval) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            // SIGKILL, not terminate(): a helper wedged on a socket may
            // be ignoring SIGTERM, and there is nothing here worth
            // shutting down cleanly.
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + after, execute: item)
        return item
    }
}
