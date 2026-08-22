import Foundation

/// The two helper binaries bundled beside the app binary: `mux-attach`, the
/// stdio relay every pane runs, and `muxd`, the session daemon. A dev build
/// without the bundle step has neither, and every caller degrades to
/// something that still works.
enum Muxd {
    /// The relay. nil (dev builds without the bundle step) falls back to a
    /// plain local shell - panes then don't survive the app, but everything
    /// else works.
    static let attachBinary: String? = bundled("mux-attach")

    /// The daemon, which is also how the app asks about daemons: `probe`,
    /// `ls`, `kill` and `client-digest` are one-shot queries on the local
    /// socket. The serving daemon is started by the relay.
    static let daemonBinary: String? = bundled("muxd")

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
        /// handed to a shell. nil means "the user's shell", the dev
        /// fallback when no relay binary is bundled. `cwdFrom` names the
        /// pty (a split's source pane, same daemon) whose live working
        /// directory the new shell inherits, resolved daemon-side - no
        /// shell integration needed, and it wins over `cwd`, which only
        /// seeds panes with no live source (restore, recovery).
        func commandLine(cwd: String?, cwdFrom: UUID? = nil) -> String? {
            // An ix pane runs `ix shell <vm>` in its pty unless the caller
            // named something else to run there (VM creation runs `ix new`
            // instead, and the shell it drops you into is the pane).
            let inPty = ptyCommand ?? IX.vm(of: target).map { [IX.binary, "shell", $0] }
            guard let attach = attachBinary else {
                // No relay bundled: run it directly (no persistence), or
                // fall back to the user's shell for a plain local pane.
                return inPty.map(Self.quote)
            }
            var parts = ["\"\(attach)\"", "\"\(address)\""]
            if expectExisting {
                // A restored or adopted pane believes its pty survived: the
                // relay prints a notice if the daemon had to create one.
                parts.append("--expect-existing")
            }
            if let inPty {
                // `-- cmd` makes the pty run that command instead of the
                // shell. No cwd: the pty's working directory is this
                // machine's and means nothing inside the VM.
                parts += ["--", Self.quote(inPty)]
                return parts.joined(separator: " ")
            }
            if let cwdFrom {
                // Never send --cwd beside --cwd-from: the daemon would let
                // it win, and a client-side pwd can be stale (a remote
                // shell with no OSC 7 never updates it). The live process
                // is the truth.
                parts += ["--cwd-from", "\"\(cwdFrom.uuidString)\""]
            } else if let cwd {
                parts += ["--cwd", "\"\(cwd)\""]
            }
            return parts.joined(separator: " ")
        }

        /// argv as one command line for libghostty, which hands the string
        /// to a shell. Every word is double-quoted, so paths with spaces
        /// and flake refs with `#` survive intact.
        private static func quote(_ argv: [String]) -> String {
            argv.map { "\"\($0)\"" }.joined(separator: " ")
        }
    }

    /// Kill a pane's pty (a deliberate close, not a detach). For an ix
    /// pane that ends the `ix shell` the pty is running, and with it the
    /// session on the VM.
    static func kill(_ address: String) {
        guard let daemon = daemonBinary else { return }
        Subprocess.run(daemon, ["kill", address]) { _ in }
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
        guard let daemon = daemonBinary else { return }
        let probe: Probe = jsonLines(Subprocess.output(daemon, ["probe", "local"])).last
            ?? .failed("error")
        guard probe.failure == "version-mismatch" else { return }
        AppLog.log("local muxd speaks another protocol version; upgrading: \(probe.error ?? "")")
        let upgraded: Probe = jsonLines(Subprocess.output(daemon, ["upgrade"])).last
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
        guard let daemon = daemonBinary else {
            return completion(.failed("no daemon"))
        }
        Subprocess.run(daemon, ["probe", alias]) { output in
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
    }

    /// List the ptys a daemon serves for us: the local one, or `alias`
    /// via the local daemon's broker. nil when muxd is missing or the
    /// host did not answer; an empty array is a daemon with no ptys.
    static func list(host alias: String?, then completion: @escaping ([PtyListing]?) -> Void) {
        guard let daemon = daemonBinary else { return completion(nil) }
        var args = ["ls", "--json"]
        if let alias { args.append(alias) }
        Subprocess.run(daemon, args) { output in
            guard let output else { return completion(nil) }
            completion(jsonLines(output))
        }
    }

    /// This client's identity digest (`sha256:<64 hex>`), which the user
    /// pastes into the host's authorized list to let this machine in. nil
    /// when muxd is not bundled or cannot answer.
    static func clientDigest(then completion: @escaping (String?) -> Void) {
        guard let daemon = daemonBinary else { return completion(nil) }
        Subprocess.run(daemon, ["client-digest"]) { output in
            let digest = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(digest?.hasPrefix("sha256:") == true ? digest : nil)
        }
    }

    /// Every daemon query answers in JSON, one object per line. Anything
    /// the helper logged ahead of them is skipped rather than fatal.
    private static func jsonLines<T: Decodable>(_ output: String?) -> [T] {
        guard let output else { return [] }
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{") else { return nil }
            return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
        }
    }

    private static func bundled(_ name: String) -> String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
