import Foundation

/// The app's own ix preferences, at ~/.config/mux/ix.json:
///
///     { "template": "github:owner/repo/<rev>#host" }
///
/// Only the default `ix new` target lives here, and only the hosts window
/// writes it. A missing file or key means the platform base template, which
/// is what `ix new` itself defaults to - so deleting the file is a valid way
/// to reset the choice.
enum IXConfig {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mux/ix.json")
    }

    /// Read fresh on every use. The file is hand-editable, and a cached
    /// copy would quietly build VMs from a template the user has since
    /// changed.
    static func template() -> String {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              let template = file.template, !template.isEmpty
        else { return IX.defaultTemplate }
        return template
    }

    /// Persist the default template, creating ~/.config/mux if needed.
    /// Written atomically: a crash mid-write leaves the previous choice
    /// rather than a truncated file that would read as "no default".
    static func setTemplate(_ template: String) {
        let encoder = JSONEncoder()
        // Slashes unescaped: flake refs are full of them, and this file is
        // meant to stay readable enough to edit by hand.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(template: template)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private struct File: Codable {
        var template: String?
    }
}
