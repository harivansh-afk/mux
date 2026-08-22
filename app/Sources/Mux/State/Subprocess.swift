import Foundation

/// One-shot reads from a helper binary. The overlays ask muxd and the ix
/// CLI for live status, and none of those answers may block the main
/// thread: every caller gets its result back asynchronously.
enum Subprocess {
    static let defaultTimeout: TimeInterval = 10

    /// Run `path arguments...` off the main thread and deliver its stdout on
    /// the main thread. stderr is dropped (ix writes progress there). nil
    /// means no usable answer - the process could not be launched, or it
    /// outlived `defaultTimeout` and was killed; a nonzero exit still
    /// yields its stdout, because `muxd probe` reports failures as JSON
    /// on it.
    static func run(
        _ path: String, _ arguments: [String],
        then completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = output(path, arguments)
            DispatchQueue.main.async { completion(output) }
        }
    }

    /// `run`, waited for right here. Only for the one moment the app may
    /// not proceed without the answer: the daemon check at launch, before
    /// any pane exists to dial it.
    static func output(_ path: String, _ arguments: [String]) -> String? {
        // astlog-ignore: no-raw-process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = watchdog(process, after: defaultTimeout)
        // Read before waiting: the pipe buffer would block forever the other way.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let killed = process.terminationReason == .uncaughtSignal
            && process.terminationStatus == SIGKILL
        return killed ? nil : String(data: data, encoding: .utf8)
    }

    /// A helper that keeps talking: `muxd watch` prints one JSON object
    /// per change for as long as the daemon lives. Every complete stdout
    /// line reaches `onLine` on the main thread; `onExit` follows the last
    /// one, at end of stream, and `terminate` ends it early. nil when the
    /// process could not be launched.
    final class Stream {
        // astlog-ignore: no-raw-process
        private let process = Process()
        private var pending = Data()

        init?(
            _ path: String, _ arguments: [String],
            onLine: @escaping (Substring) -> Void, onExit: @escaping () -> Void
        ) {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            // The handler runs on the pipe's own queue; `pending` is only
            // ever touched there. EOF is the end: it comes after every
            // line, which a termination handler would not promise.
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    DispatchQueue.main.async(execute: onExit)
                    return
                }
                pending.append(data)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(bytes: pending[..<newline], encoding: .utf8) ?? ""
                    pending.removeSubrange(...newline)
                    DispatchQueue.main.async { onLine(line[...]) }
                }
            }
            guard (try? process.run()) != nil else {
                pipe.fileHandleForReading.readabilityHandler = nil
                return nil
            }
        }

        func terminate() {
            if process.isRunning {
                process.terminate()
            }
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
