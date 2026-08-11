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

    /// The daemon. Only ever run here as a one-shot query (`client-digest`);
    /// the running daemon is started by the relay.
    static let daemonBinary: String? = bundled("muxd")

    /// One host's live state, from `mux-attach probe <alias>`.
    struct Probe {
        let ok: Bool
        /// Round trip to the host, present when ok.
        let rttMs: Int?
        /// Ptys the host is serving for us, present when ok.
        let ptys: Int?
        /// Why the host is not usable: the failure class the relay reports
        /// (`unreachable`, `pin-mismatch`, `token-rejected`,
        /// `version-mismatch`, `no-host`, `error`), or our own reason for
        /// never having asked.
        let failure: String
    }

    /// Ask the local daemon about one host. Failures are results, not
    /// errors: the overlay shows the class so a wrong pin reads differently
    /// from a machine that is simply off.
    static func probe(alias: String, then completion: @escaping (Probe) -> Void) {
        guard let attach = attachBinary else {
            return completion(Probe(ok: false, rttMs: nil, ptys: nil, failure: "no relay"))
        }
        Subprocess.run(attach, ["probe", alias]) { output in
            // One line of JSON, but be tolerant of anything the relay logs
            // ahead of it.
            guard let line = output?.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
                  let decoded = try? JSONDecoder().decode(
                      ProbeLine.self, from: Data(line.utf8)
                  )
            else {
                return completion(Probe(ok: false, rttMs: nil, ptys: nil, failure: "error"))
            }
            completion(Probe(
                ok: decoded.ok,
                rttMs: decoded.rttMs,
                ptys: decoded.ptys,
                failure: decoded.failure ?? "error"
            ))
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

    private struct ProbeLine: Decodable {
        let ok: Bool
        let rttMs: Int?
        let ptys: Int?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case rttMs = "rtt_ms"
            case ptys
            case failure = "class"
        }
    }

    private static func bundled(_ name: String) -> String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
