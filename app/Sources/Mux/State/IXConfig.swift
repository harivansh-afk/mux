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

    static func template() -> String {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              let template = file.template, !template.isEmpty
        else { return IX.defaultTemplate }
        return template
    }

    static func setTemplate(_ template: String) {
        let encoder = JSONEncoder()
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
