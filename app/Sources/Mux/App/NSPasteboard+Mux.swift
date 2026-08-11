import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Pasteboard plumbing ported from ghostty's NSPasteboard+Extension.swift
/// (MIT).
extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string.
    init?(mimeType: String) {
        // Explicit mappings for common MIME types.
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type.
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier.
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier.
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The private pasteboard for copy-on-select, so selecting text never
    /// clobbers the system clipboard (ghostty does the same).
    static let muxSelection = NSPasteboard(name: .init("com.mux.selection"))

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.muxSelection

        default:
            return nil
        }
    }

    /// Gets the contents of the pasteboard as a string following a specific
    /// set of semantics. Does these things in order:
    /// - Tries to get the absolute filesystem path of a file in the
    ///   pasteboard, shell-escaped.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns nil so performable paste bindings
    /// can pass through to the terminal.
    func getOpinionatedStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL
            {
                return Shell.escape(fileURL.path)
            }
            return item.string(forType: .string)
        }

        guard !strings.isEmpty else {
            return nil
        }
        return strings.joined(separator: " ")
    }
}

enum Shell {
    // Characters to escape in the shell.
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Escape shell-sensitive characters in a string by prefixing each with
    /// a backslash. Suitable for inserting paths into a live terminal
    /// buffer. From ghostty's Ghostty.Shell (MIT).
    static func escape(_ str: String) -> String {
        var result = str
        for char in escapeCharacters {
            result = result.replacingOccurrences(
                of: String(char),
                with: "\\\(char)"
            )
        }

        return result
    }
}
