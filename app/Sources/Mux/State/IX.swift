import Foundation

/// The ix CLI. A pane targeting `ix:<vm>` is a local daemon pty running
/// `ix shell <vm>`, and the target picker and hosts overlay list the VMs
/// the CLI reports.
enum IX {
    struct VM: Decodable {
        let name: String
        /// The VM's lifecycle state as ix reports it ("running", ...).
        let status: String

        /// Only a running VM can host a shell.
        var isRunning: Bool {
            status == "running"
        }
    }

    /// The prefix marking a pane target as an ix VM (`ix:<name>`).
    static let prefix = "ix:"

    /// `ix:<vm>` -> `<vm>`, nil for any other target.
    static func vm(of target: String?) -> String? {
        guard let target, target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// Absolute path to the ix binary. A GUI app inherits a bare PATH that
    /// has none of the usual install locations in it, so they are searched
    /// by hand; the bare name is the last resort, for a PATH that does.
    static let binary: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/ix",
            "/opt/homebrew/bin/ix",
            "/usr/local/bin/ix",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ix"
    }()

    /// The VMs ix knows about, re-listed on every call. `ix ls` prints its
    /// JSON array on stdout and its progress line on stderr, so stdout
    /// parses on its own. Anything unexpected (no CLI, not logged in, no
    /// network) comes back as an empty list: the VM rows simply never
    /// appear, which is the right answer for a machine that does not use ix.
    static func list(then completion: @escaping ([VM]) -> Void) {
        Subprocess.run(binary, ["ls", "--output", "json", "--message-format", "json"]) { output in
            guard let data = output?.data(using: .utf8),
                  let vms = try? JSONDecoder().decode([VM].self, from: data)
            else { return completion([]) }
            completion(vms)
        }
    }
}
