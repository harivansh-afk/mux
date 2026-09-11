import AppKit
import GhosttyKit

// libghostty locates terminfo, shell integration, and themes via
// GHOSTTY_RESOURCES_DIR. Without it TERM=xterm-ghostty breaks.
if getenv("GHOSTTY_RESOURCES_DIR") == nil {
    let candidates = [
        Bundle.main.resourcePath.map { $0 + "/ghostty" },
        NSHomeDirectory() + "/Documents/Git/ghostty/zig-out/share/ghostty",
    ].compactMap(\.self)
    if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        setenv("GHOSTTY_RESOURCES_DIR", found, 1)
    } else {
        FileHandle.standardError.write(Data(
            "warning: GHOSTTY_RESOURCES_DIR not found; shell integration will be degraded\n".utf8
        ))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let missingHelpers = Muxd.missingHelpers()
if !missingHelpers.isEmpty {
    let alert = NSAlert()
    alert.messageText = "Mux is missing required components"
    alert.informativeText = "Reinstall or rebuild the complete Mux.app. Missing: "
        + missingHelpers.joined(separator: ", ") + "."
    alert.runModal()
    exit(EXIT_FAILURE)
}

app.delegate = App.delegate
app.run()
