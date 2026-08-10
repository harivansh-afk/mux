import Foundation

/// Host aliases, read from ~/.config/mux/hosts.json:
///
///     { "spark": { "addr": "100.64.0.7:4433" } }
///
/// The app only ever needs the names. An alias is the target half of a
/// pane's attach address (`spark:<uuid>`); resolving it to an address and
/// dialing it is the local daemon's job.
struct HostEntry: Codable {
    var addr: String
}

enum HostsConfig {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mux/hosts.json")
    }

    /// Alias names in stable order. A missing or malformed file is not an
    /// error - it means the user has no remote hosts yet.
    static func aliases() -> [String] {
        guard let data = try? Data(contentsOf: url),
              let hosts = try? JSONDecoder().decode([String: HostEntry].self, from: data)
        else { return [] }
        return hosts.keys.sorted()
    }
}
