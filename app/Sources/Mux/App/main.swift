import AppKit
import GhosttyKit

// libghostty locates terminfo, shell integration, and themes via
// GHOSTTY_RESOURCES_DIR. Without it TERM=xterm-ghostty breaks.
if getenv("GHOSTTY_RESOURCES_DIR") == nil {
    let candidates = [
        Bundle.main.resourcePath.map { $0 + "/ghostty" },
        NSHomeDirectory() + "/src/ghostty/zig-out/share/ghostty",
    ].compactMap(\.self)
    if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        setenv("GHOSTTY_RESOURCES_DIR", found, 1)
    } else {
        FileHandle.standardError.write(Data(
            "warning: GHOSTTY_RESOURCES_DIR not found; shell integration will be degraded\n".utf8
        ))
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
