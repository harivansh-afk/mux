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

    /// The platform base template: what `ix new` boots with no target, and
    /// what mux falls back to when no default is configured.
    static let defaultTemplate = "default"

    /// One choice in the template list: what to show, and what `ix new`
    /// takes as its target.
    struct Template {
        let label: String
        let value: String
    }

    /// A name for a VM mux is about to create. Random rather than
    /// sequential because the app never sees the whole fleet, and prefixed
    /// so it is obvious in `ix ls` where the machine came from.
    static func newVMName() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "mux-" + String((0 ..< 4).compactMap { _ in alphabet.randomElement() })
    }

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

    /// The templates a new VM can be built from, newest first: only the ones
    /// that are ready to boot and not hidden, deduplicated by the target
    /// `ix new` would receive. Every field is decoded as optional because
    /// this list is the CLI's own inventory format, not a contract with us.
    static func templates(then completion: @escaping ([Template]) -> Void) {
        let args = ["templates", "ls", "--output", "json", "--message-format", "json"]
        Subprocess.run(binary, args) { output in
            guard let data = output?.data(using: .utf8),
                  let listing = try? JSONDecoder().decode(Listing.self, from: data)
            else { return completion([]) }
            var seen: Set<String> = []
            completion(
                listing.templates
                    .filter { $0.state == "ready" && $0.hidden != true }
                    .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
                    .compactMap(\.template)
                    .filter { seen.insert($0.value).inserted }
            )
        }
    }

    private struct Listing: Decodable {
        let templates: [Entry]
    }

    private struct Entry: Decodable {
        let name: String?
        let attr: String?
        let rev: String?
        let pinnedRef: String?
        let state: String?
        let hidden: Bool?
        let createdAt: Int?

        enum CodingKeys: String, CodingKey {
            case name, attr, rev, state, hidden
            case pinnedRef = "pinned_ref"
            case createdAt = "created_at"
        }

        /// A named template is its own `ix new` target. An unnamed one is
        /// addressed by the flake ref it was pinned from, and reads as the
        /// attribute plus a short rev, so the list looks like the build
        /// history it is.
        var template: Template? {
            if let name, !name.isEmpty {
                return Template(label: name, value: name)
            }
            guard let pinnedRef, !pinnedRef.isEmpty else { return nil }
            let short = (rev?.isEmpty == false ? rev! : pinnedRef).prefix(12)
            return Template(label: "\(attr ?? "template") \(short)", value: pinnedRef)
        }
    }
}
