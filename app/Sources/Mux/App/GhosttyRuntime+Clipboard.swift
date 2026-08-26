import AppKit
import GhosttyKit

// The libghostty clipboard callbacks and their completion plumbing,
// implementing OSC 52 and the Kitty clipboard protocol (OSC 5522,
// non-text reads and writes). Split from GhosttyRuntime.swift, whose
// header explains why callbacks are file-scope functions. Ported from
// ghostty's Ghostty.App.swift (MIT).

/// One clipboard representation: a MIME type and its raw bytes.
private struct ClipboardContent {
    let mime: String
    let data: Data

    var string: String? {
        String(data: data, encoding: .utf8)
    }
}

/// Answer a surface's pending clipboard request. Everything handed to the
/// core is copied into C memory for the duration of the call only; the
/// core copies it again before returning (apprt/embedded.zig), so the
/// temporaries are freed on exit. `confirmed` is set after the user
/// approved a prompt; `remember` records a kitty session grant.
private func completeClipboardRequest(
    _ surface: ghostty_surface_t,
    contents: [ClipboardContent],
    available: [String],
    state: UnsafeMutableRawPointer?,
    confirmed: Bool = false,
    remember: Bool = false
) {
    var cStrings: [UnsafeMutablePointer<CChar>] = []
    var cDatas: [UnsafeMutableRawPointer] = []
    defer {
        cStrings.forEach { free($0) }
        cDatas.forEach { $0.deallocate() }
    }

    var cContents: [ghostty_clipboard_content_s] = []
    for entry in contents {
        guard let mime = strdup(entry.mime) else { continue }
        cStrings.append(mime)
        let buf = UnsafeMutableRawPointer.allocate(
            byteCount: max(entry.data.count, 1),
            alignment: 1
        )
        cDatas.append(buf)
        entry.data.withUnsafeBytes { src in
            if let base = src.baseAddress {
                buf.copyMemory(from: base, byteCount: src.count)
            }
        }
        cContents.append(ghostty_clipboard_content_s(
            mime: mime,
            data: buf.assumingMemoryBound(to: CChar.self),
            len: entry.data.count
        ))
    }

    var cAvailable: [UnsafePointer<CChar>?] = []
    for mime in available {
        guard let str = strdup(mime) else { continue }
        cStrings.append(str)
        cAvailable.append(UnsafePointer(str))
    }

    cContents.withUnsafeBufferPointer { contentsBuf in
        cAvailable.withUnsafeBufferPointer { availableBuf in
            var complete = ghostty_clipboard_complete_s(
                contents: contentsBuf.baseAddress,
                contents_len: contentsBuf.count,
                available: availableBuf.baseAddress,
                available_len: availableBuf.count,
                confirmed: confirmed,
                remember: remember
            )
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
        }
    }
}

private func writePasteboard(
    _ pasteboard: NSPasteboard,
    contents: [ClipboardContent]
) {
    let typed = contents.compactMap { item in
        NSPasteboard.PasteboardType(mimeType: item.mime).map { (type: $0, data: item.data) }
    }
    pasteboard.declareTypes(typed.map(\.type), owner: nil)
    for item in typed {
        pasteboard.setData(item.data, forType: item.type)
    }
}

// swiftlint:disable function_parameter_count - the signature is
// libghostty's ghostty_runtime_read_clipboard_cb typedef.

/// Serve exactly the representations the core asked for, so unrelated
/// (potentially large) clipboard contents are never loaded. `list`
/// additionally requests the metadata-only MIME listing (mode 5522
/// paste events). A non-STARTED return leaves `state` owned by the
/// core; STARTED promises exactly one complete/deny with it.
func readClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    guard let view = paneView(userdata), let surface = view.surface else {
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    guard let pasteboard = NSPasteboard.ghostty(location) else {
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }

    var contents: [ClipboardContent] = []
    var seen = Set<String>()
    if let mimes {
        for i in 0 ..< mimesLen {
            guard let ptr = mimes[i] else { continue }
            let mime = String(cString: ptr)
            guard seen.insert(mime).inserted else { continue }
            guard let data = pasteboard.data(forMime: mime) else { continue }
            contents.append(.init(mime: mime, data: data))
        }
    }

    let available = list ? pasteboard.availableMimes() : []

    // Nothing to serve and no listing requested: report unavailable so
    // performable paste bindings can pass through to the terminal.
    if contents.isEmpty, !list {
        return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
    }

    completeClipboardRequest(surface, contents: contents, available: available, state: state)
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

// swiftlint:enable function_parameter_count

/// Fired when a completion hits `clipboard-read`/`clipboard-write = ask`
/// without a prior grant. Everything in the confirm struct is borrowed
/// for this call only, so it is copied before going async; approval
/// completes with exactly the copied bytes the prompt displayed, never
/// a re-read of the clipboard. Rejection (and any unanswerable request)
/// must deny, or the core-owned state leaks.
func confirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    guard let view = paneView(userdata), let surface = view.surface else { return }
    guard let confirm else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
    }
    let c = confirm.pointee

    var reps: [ClipboardContent] = []
    if let contents = c.contents {
        for i in 0 ..< c.contents_len {
            let content = contents[i]
            let data = if content.len > 0, let ptr = content.data {
                Data(bytes: ptr, count: content.len)
            } else {
                Data()
            }
            reps.append(.init(mime: String(cString: content.mime), data: data))
        }
    }
    var avail: [String] = []
    if let available = c.available {
        for i in 0 ..< c.available_len {
            guard let ptr = available[i] else { continue }
            avail.append(String(cString: ptr))
        }
    }

    // The prompt can only display text: show the text representation
    // when there is one and summarize the rest.
    let display = reps.first(where: { $0.mime == "text/plain" }).flatMap(\.string)
        ?? reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

    // Decode an image representation so the prompt previews exactly what
    // would be disclosed rather than a byte count.
    let previewImage = reps.lazy
        .filter { $0.mime.hasPrefix("image/") }
        .compactMap { NSImage(data: $0.data) }
        .first

    let prompt = ClipboardPrompt(
        display: display,
        previewImage: previewImage,
        programName: c.name.map { String(cString: $0) },
        canRemember: c.can_remember,
        request: request
    )

    DispatchQueue.main.async {
        presentClipboardConfirmation(view: view, prompt: prompt) { confirmed, remember in
            guard let surface = view.surface else { return }
            if confirmed {
                completeClipboardRequest(
                    surface,
                    contents: reps,
                    available: avail,
                    state: state,
                    confirmed: true,
                    remember: remember
                )
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }
}

func writeClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int,
    confirm: Bool
) {
    guard let pasteboard = NSPasteboard.ghostty(location) else { return }
    guard let content, len > 0 else { return }

    var items: [ClipboardContent] = []
    for i in 0 ..< len {
        let entry = content[i]
        guard let mime = entry.mime else { continue }
        let data = if entry.len > 0, let ptr = entry.data {
            Data(bytes: ptr, count: entry.len)
        } else {
            Data()
        }
        items.append(.init(mime: String(cString: mime), data: data))
    }
    guard !items.isEmpty else { return }

    // Writes allowed by policy apply immediately. Kitty writes prompt
    // through confirmReadClipboard before ever reaching here, so only
    // OSC 52 writes under `clipboard-write = ask` continue below.
    guard confirm else {
        writePasteboard(pasteboard, contents: items)
        return
    }

    // The prompt shows the payload, so only text/plain can be confirmed.
    guard let textPlain = items.first(where: { $0.mime == "text/plain" }),
          let text = textPlain.string else { return }
    let prompt = ClipboardPrompt(
        display: text,
        previewImage: nil,
        programName: nil,
        canRemember: false,
        request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE
    )
    _ = onMain(paneView(userdata)) { view in
        presentClipboardConfirmation(view: view, prompt: prompt) { confirmed, _ in
            guard confirmed else { return }
            writePasteboard(pasteboard, contents: [textPlain])
        }
    }
}

/// What a clipboard confirmation shows: the payload (text, or a decoded
/// image), who is asking, and whether a session grant can be offered.
private struct ClipboardPrompt {
    let display: String
    let previewImage: NSImage?
    let programName: String?
    let canRemember: Bool
    let request: ghostty_clipboard_request_e
}

/// The ghostty-equivalent clipboard confirmation, as a native alert
/// sheet: unsafe pastes and OSC 52 / kitty 5522 reads and writes prompt
/// before touching the terminal or the clipboard. `decide` is called
/// exactly once; a rejected decision must map to deny (or, for writes,
/// to not writing).
private func presentClipboardConfirmation(
    view: PaneView,
    prompt: ClipboardPrompt,
    decide: @escaping (_ confirmed: Bool, _ remember: Bool) -> Void
) {
    // A request racing an existing prompt is answered as rejected
    // instead of stacking sheets (ghostty cancels superseded requests
    // the same way; denial is the protocol-correct reply for each flow).
    if view.clipboardConfirmationActive {
        decide(false, false)
        return
    }

    let program = prompt.programName.map { "\"\($0)\"" } ?? "An application"
    let (message, detail, accept, refuse) = switch prompt.request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
        ("Warning: Potentially Unsafe Paste",
         "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed.",
         "Paste", "Cancel")
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
         GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
         GHOSTTY_CLIPBOARD_REQUEST_LIST:
        ("Authorize Clipboard Access",
         "\(program) is attempting to read from the clipboard. The current clipboard contents are shown below.",
         "Allow", "Deny")
    default:
        ("Authorize Clipboard Access",
         "\(program) is attempting to write to the clipboard. The content to write is shown below.",
         "Allow", "Deny")
    }

    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: accept)
    alert.addButton(withTitle: refuse)
    alert.alertStyle = .warning
    if prompt.canRemember {
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember this choice for the session"
    }

    // Content preview: the image about to be disclosed when there is
    // one, otherwise scrollable text like ghostty's confirmation window.
    if let previewImage = prompt.previewImage {
        let imageView = NSImageView(image: previewImage)
        imageView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        imageView.imageScaling = .scaleProportionallyDown
        alert.accessoryView = imageView
    } else {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        if let textView = scroll.documentView as? NSTextView {
            textView.string = prompt.display
            textView.isEditable = false
            textView.font = Chrome.metaFont
        }
        alert.accessoryView = scroll
    }

    let finish: (NSApplication.ModalResponse) -> Void = { response in
        view.clipboardConfirmationActive = false
        decide(
            response == .alertFirstButtonReturn,
            alert.suppressionButton?.state == .on
        )
    }

    view.clipboardConfirmationActive = true
    if let window = view.window {
        alert.beginSheetModal(for: window, completionHandler: finish)
    } else {
        finish(alert.runModal())
    }
}
