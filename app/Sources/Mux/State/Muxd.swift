import Foundation

/// Bundled helpers: every pane runs through mux-attach and is owned by muxd.
/// Startup checks the complete bundle before loading or changing saved state.
enum Muxd {
    private static let helperDirectory = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
    static let attachBinary = helperDirectory.appendingPathComponent("mux-attach").path
    static let daemonBinary = helperDirectory.appendingPathComponent("muxd").path

    static func missingHelpers(in directory: URL = helperDirectory) -> [String] {
        ["mux-attach", "muxd"].filter {
            !FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Everything about one pane's pty that the relay needs to be told.
    /// The command line and the kill are the only two things anyone does
    /// with a pane's attachment, and both live here.
    struct Attach {
        let paneID: UUID

        /// Where this pane's terminal lives.
        ///
        /// - nil: the local daemon (`mux-attach local:<id>`).
        /// - a host alias from ~/.config/mux/hosts.json: the local daemon
        ///   relays the attach to that host (`mux-attach <alias>:<id>`).
        /// - `ix:<vm>`: a local daemon pty whose command is `ix shell <vm>`
        ///   instead of the user's shell, so the VM's session persists
        ///   exactly like a local one - the pty, and the `ix shell` inside
        ///   it, outlive the app.
        let target: String?

        /// A command to run in the pty instead of the user's shell, as
        /// argv. Only VM creation uses it (`ix new -n <name> <template>`),
        /// and only for the pane that does the creating: it is
        /// deliberately not persisted, so a restored pane derives
        /// `ix shell <name>` from its target instead - which is right,
        /// because by then the VM exists.
        let ptyCommand: [String]?

        /// True for restored and adopted panes: their pty is believed to
        /// exist, so the relay is told to call out a `created` reply (the
        /// daemon lost the shell) instead of silently starting fresh.
        let expectExisting: Bool
        var requireExisting: Bool = false

        /// The pty to attach to: `<alias>:<id>` for a pane hosted on
        /// another machine, `local:<id>` otherwise. An `ix:<vm>` pane is
        /// local too - the pty runs `ix shell` here, and the VM is on the
        /// far end of that command, not of the attach.
        var address: String {
            guard let target, !target.hasPrefix(IX.prefix) else {
                return "local:\(paneID.uuidString)"
            }
            return "\(target):\(paneID.uuidString)"
        }

        /// The pane's launch command, as libghostty wants it: one string
        /// handed to a shell. `cwdFrom` names the
        /// pty (a split's source pane, same daemon) whose live working
        /// directory the new shell inherits, resolved daemon-side - no
        /// shell integration needed, and it wins over `cwd`, which only
        /// seeds panes with no live source (restore, recovery).
        func commandLine(cwd: String?, cwdFrom: UUID? = nil) -> String {
            // An ix pane runs `ix shell <vm>` in its pty unless the caller
            // named something else to run there (VM creation runs `ix new`
            // instead, and the shell it drops you into is the pane).
            let inPty = ptyCommand ?? IX.vm(of: target).map { [IX.binary, "shell", $0] }
            var parts = [attachBinary, address]
            if requireExisting {
                parts.append("--require-existing")
            } else if expectExisting {
                // A restored or adopted pane believes its pty survived: the
                // relay prints a notice if the daemon had to create one.
                parts.append("--expect-existing")
            }
            if let inPty {
                // `-- cmd` makes the pty run that command instead of the
                // shell. No cwd: the pty's working directory is this
                // machine's and means nothing inside the VM.
                parts += ["--"] + inPty
                return Self.quote(parts)
            }
            if let cwdFrom {
                // Never send --cwd beside --cwd-from: the daemon would let
                // it win, and a client-side pwd can be stale (a remote
                // shell with no OSC 7 never updates it). The live process
                // is the truth.
                parts += ["--cwd-from", cwdFrom.uuidString]
            } else if let cwd {
                parts += ["--cwd", cwd]
            }
            return Self.quote(parts)
        }

        /// Quote argv once at the shell boundary, preserving every literal byte.
        static func quote(_ argv: [String]) -> String {
            argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        }
    }

    /// Arm expiry on the owning daemon before dropping the pane's relay.
    static func close(_ address: String, then completion: @escaping (Date?) -> Void) {
        Subprocess.run(daemonBinary, ["close", address]) { output in
            let milliseconds = output.flatMap {
                Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            completion(milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }

    static func kill(_ address: String) {
        Subprocess.run(daemonBinary, ["kill", address]) { _ in }
    }

    /// One host's live state, from `muxd probe <alias>`.
    struct Probe: Decodable {
        let ok: Bool
        /// Round trip to the host, present when ok.
        let rttMs: Int?
        /// Ptys the host is serving for us, present when ok.
        let ptys: Int?
        /// Why the host is not usable: the daemon's failure kind
        /// (`unreachable`, `pin-mismatch`, `token-rejected`,
        /// `version-mismatch`, `no-host`, `error`).
        let failure: String?
        /// The failure in the daemon's words, for the log.
        let error: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case rttMs = "rtt_ms"
            case ptys
            case failure = "class"
            case error
        }

        /// Nothing was asked, or nothing came back.
        static func failed(_ reason: String) -> Probe {
            Probe(ok: false, rttMs: nil, ptys: nil, failure: reason, error: nil)
        }
    }

    /// The local daemon outlives the app, so the first launch after an
    /// install can meet one speaking an older protocol, and every pane
    /// would then sit in "cannot attach" until someone ran `muxd
    /// --upgrade` by hand. Ask before any pane exists; on a version
    /// mismatch, `muxd upgrade` starts the bundled binary as the
    /// successor and returns once it answers on the socket (or gives up,
    /// bounded). Waited for here, on purpose: panes born during the
    /// handoff would dial the daemon being replaced.
    static func upgradeStaleDaemon() {
        let probe: Probe = jsonLines(Subprocess.output(daemonBinary, ["probe", "local"])).last
            ?? .failed("error")
        guard probe.failure == "version-mismatch" else { return }
        AppLog.log("local muxd speaks another protocol version; upgrading: \(probe.error ?? "")")
        let upgraded: Probe = jsonLines(Subprocess.output(daemonBinary, ["upgrade"])).last
            ?? .failed("no answer")
        if upgraded.ok {
            AppLog.log("muxd upgraded in \(upgraded.rttMs ?? 0)ms, serving \(upgraded.ptys ?? 0) pty(s)")
        } else {
            AppLog.log("muxd upgrade failed (\(upgraded.failure ?? "")): \(upgraded.error ?? "")")
        }
    }

    /// Ask the local daemon about one host. Failures are results, not
    /// errors: the overlay shows the kind so a wrong pin reads differently
    /// from a machine that is simply off.
    static func probe(alias: String, then completion: @escaping (Probe) -> Void) {
        Subprocess.run(daemonBinary, ["probe", alias]) { output in
            completion(jsonLines(output).last ?? .failed("error"))
        }
    }

    /// One pty from `muxd ls --json`: what the daemon holds, keyed by pane
    /// UUID, with the foreground process's cwd when readable. The startup
    /// reconciliation diffs this against the windows' own panes to find
    /// orphans.
    struct PtyListing: Decodable {
        let name: String
        let command: [String]
        let attached: Bool
        let exited: Bool
        let cwd: String?
        @Lenient var agent: AgentInfo?
    }

    /// The coding agent the daemon sees in a pty, from the foreground
    /// process and the terminal it tracks. The app renders this and never
    /// reads titles itself.
    struct AgentInfo: Decodable, Equatable {
        let agent: String
        let state: AgentState
        /// What the agent says it is doing; may be empty.
        let topic: String
    }

    enum AgentState: String, Decodable {
        case working
        case idle
        case blocked
    }

    /// A field that is allowed to be absent, null, or something this build
    /// does not know (a new agent or state name): any of those reads as
    /// nil instead of failing the whole line. The synthesized decode of a
    /// `@Lenient` property lands on the container overload below, which
    /// is what makes absent and null nil rather than errors.
    @propertyWrapper
    struct Lenient<Value: Decodable>: Decodable {
        var wrappedValue: Value?

        init(wrappedValue: Value?) {
            self.wrappedValue = wrappedValue
        }

        init(from decoder: Decoder) {
            wrappedValue = try? Value(from: decoder)
        }
    }

    /// One line of `muxd watch --json`: the pty it is about and what the
    /// daemon now sees there.
    struct WatchEvent: Decodable {
        let name: String
        @Lenient var agent: AgentInfo?
        let cwd: String?
        let exited: Bool
    }

    /// `muxd watch --json [alias]`: one line per pty when it starts, then
    /// one per change, for as long as the daemon lives. The watch restarts
    /// itself when the stream ends - the daemon may be mid-upgrade - after
    /// a second, then five, until stopped.
    final class Watch {
        private let alias: String?
        private let onEvent: (WatchEvent) -> Void
        private var stream: Subprocess.Stream?
        private var restart: DispatchWorkItem?
        private var backoff: TimeInterval = 1

        init(host alias: String?, onEvent: @escaping (WatchEvent) -> Void) {
            self.alias = alias
            self.onEvent = onEvent
            start()
        }

        deinit {
            stop()
        }

        func stop() {
            restart?.cancel()
            restart = nil
            stream?.terminate()
            stream = nil
        }

        private func start() {
            var args = ["watch", "--json"]
            if let alias {
                args.append(alias)
            }
            stream = Subprocess.Stream(daemonBinary, args, onLine: { [weak self] line in
                guard let self, let event: WatchEvent = decode(line) else { return }
                // A line means the daemon is there: the next outage gets
                // the short retry again.
                backoff = 1
                onEvent(event)
            }, onExit: { [weak self] in
                guard let self, stream != nil else { return }
                stream = nil
                let item = DispatchWorkItem { [weak self] in self?.start() }
                restart = item
                DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: item)
                backoff = 5
            })
        }
    }

    /// List the ptys a daemon serves for us: the local one, or `alias`
    /// via the local daemon's broker. nil when the host did not answer;
    /// an empty array is a daemon with no ptys.
    static func list(host alias: String?, then completion: @escaping ([PtyListing]?) -> Void) {
        var args = ["ls", "--json"]
        if let alias {
            args.append(alias)
        }
        Subprocess.run(daemonBinary, args) { output in
            guard let output else { return completion(nil) }
            completion(jsonLines(output))
        }
    }

    /// This client's identity digest (`sha256:<64 hex>`), which the user
    /// pastes into the host's authorized list to let this machine in. nil
    /// when muxd cannot answer.
    static func clientDigest(then completion: @escaping (String?) -> Void) {
        Subprocess.run(daemonBinary, ["client-digest"]) { output in
            let digest = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(digest?.hasPrefix("sha256:") == true ? digest : nil)
        }
    }

    /// Every daemon query answers in JSON, one object per line. Anything
    /// the helper logged ahead of them is skipped rather than fatal.
    private static func jsonLines<T: Decodable>(_ output: String?) -> [T] {
        guard let output else { return [] }
        return output.split(separator: "\n").compactMap(decode)
    }

    /// One line of a daemon's output, if it is a JSON object of the shape
    /// asked for.
    static func decode<T: Decodable>(_ line: Substring) -> T? {
        guard line.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }
}

extension KeyedDecodingContainer {
    func decode<T>(_: Muxd.Lenient<T>.Type, forKey key: Key) -> Muxd.Lenient<T> {
        Muxd.Lenient(wrappedValue: try? decodeIfPresent(T.self, forKey: key))
    }
}
