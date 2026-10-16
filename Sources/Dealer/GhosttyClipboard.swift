import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// libghostty's clipboard callbacks: a trimmed port of `Ghostty.App.readClipboard`,
/// `confirmReadClipboard` and `writeClipboard` and of `NSPasteboard+Extension.swift` in
/// ghostty-org/ghostty (at the pinned commit). Reads are MIME based: libghostty asks for
/// representations (text/plain for a paste, others for OSC 52/kitty reads) and may ask for the
/// list of available types. Only the standard pasteboard is served (no selection clipboard).
///
/// Ghostty's `clipboard-read` / `clipboard-write` (allow, deny, ask; defaults ask and allow) are
/// enforced by libghostty itself (#55): `deny` never reaches these callbacks, `allow` completes
/// without asking, and `ask` comes back as `confirm_read_clipboard_cb` (reads) or a write with
/// `confirm` set. A paste that trips `clipboard-paste-protection` (unsafe text, unless the program
/// takes bracketed paste and `clipboard-paste-bracketed-safe` holds) arrives the same way (#72).
/// Dealer only supplies the question: a sheet through `TerminalWindowController.confirm`, naming
/// the pane, shown once the pane's window is key (as Ghostty.app defers it until focused). Cancel
/// denies, as Ghostty does, and so does the window closing before it was asked.
enum GhosttyClipboard {
    struct Content { let mime: String; let data: Data }

    /// The pasteboard OSC 52 reads and writes use. The self-test swaps in a private one.
    static var pasteboard: NSPasteboard = .general
    /// Whether a window counts as key for showing a confirmation. The self-test overrides it (a
    /// self-test run usually isn't the active app, so it has no key window).
    static var isKey: (NSWindow) -> Bool = { $0.isKeyWindow }

    static func read(_ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                     state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?,
                     mimesLen: Int, list: Bool) -> ghostty_clipboard_read_result_e {
        guard let surface = SurfaceView.from(ud)?.surface,
              location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let pb = pasteboard
        var contents: [Content] = []
        var seen = Set<String>()
        for i in 0..<(mimes == nil ? 0 : mimesLen) {
            guard let p = mimes?[i] else { continue }
            let mime = String(cString: p)
            guard seen.insert(mime).inserted, let data = Self.data(pb, forMime: mime) else { continue }
            contents.append(Content(mime: mime, data: data))
        }
        let available = list ? Self.availableMimes(pb) : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// `clipboard-read = ask` (or kitty read, or a protected paste): ask, then complete with what
    /// libghostty offered, or deny. The payload is copied: the question can wait for focus.
    static func confirmRead(_ ud: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                            state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let view = SurfaceView.from(ud), let surface = view.surface else { return }
        guard let c = confirm?.pointee else { ghostty_surface_deny_clipboard_request(surface, state); return }
        var reps: [Content] = []
        for i in 0..<(c.contents == nil ? 0 : c.contents_len) {
            guard let item = c.contents?[i], let mime = item.mime else { continue }
            let data = item.len > 0 && item.data != nil ? Data(bytes: item.data, count: item.len) : Data()
            reps.append(Content(mime: String(cString: mime), data: data))
        }
        var avail: [String] = []
        for i in 0..<(c.available == nil ? 0 : c.available_len) {
            if let p = c.available?[i] { avail.append(String(cString: p)) }
        }
        let accept = { [weak view] in
            guard let s = view?.surface else { return }
            complete(s, contents: reps, available: avail, state: state, confirmed: true)
        }
        let deny = { [weak view] in
            deniedCount += 1
            if let s = view?.surface { ghostty_surface_deny_clipboard_request(s, state) }
        }
        let kind: Kind
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            // clipboard-paste-protection (#72): the text would run commands as it lands.
            let text = reps.first { $0.mime == "text/plain" }.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            kind = .paste(preview: Self.preview(text))
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: kind = .write
        default: kind = .read
        }
        onMain { ask(view, kind, then: accept, otherwise: deny) }
    }

    /// What a question is about.
    enum Kind {
        case read, write, paste(preview: String)
    }

    /// At most 6 lines of 80 characters, with a note of what's left out.
    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(6).map { $0.count > 80 ? $0.prefix(79) + "…" : $0 }.joined(separator: "\n")
        if lines.count > 6 { shown += "\n… (\(lines.count - 6) more line\(lines.count == 7 ? "" : "s"))" }
        return shown
    }

    /// Self-test only: the last paste question's text.
    private(set) static var lastQuestionInfo = ""

    /// Self-test only: how many requests Dealer has denied (Cancel/Deny, or a window closed first).
    private(set) static var deniedCount = 0

    /// Writes every representation; with `confirm` (`clipboard-write = ask`) only after the user agrees.
    static func write(_ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                      content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int, confirm: Bool) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        let items: [(NSPasteboard.PasteboardType, Data)] = (0..<len).compactMap { i in
            let c = content[i]
            guard let mime = c.mime, let type = Self.pasteboardType(mime: String(cString: mime)) else { return nil }
            let data = c.len > 0 && c.data != nil ? Data(bytes: c.data, count: c.len) : Data()
            return (type, data)
        }
        guard !items.isEmpty else { return }
        let store = {
            let pb = pasteboard
            pb.declareTypes(items.map(\.0), owner: nil)
            for (type, data) in items { pb.setData(data, forType: type) }
        }
        guard confirm else { return onMain(store) }
        let view = SurfaceView.from(ud)
        onMain { ask(view, .write, then: store, otherwise: { deniedCount += 1 }) }
    }

    /// Writes `items` to `pb`, unconditionally (the self-test's direct entry).
    static func write(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int,
                      to pb: NSPasteboard) {
        let saved = pasteboard
        pasteboard = pb
        defer { pasteboard = saved }
        write(nil, location: location, content: content, len: len, confirm: false)
    }

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// The question, on the pane's window once it's key. No window (the pane is gone): denied.
    static func ask(_ view: SurfaceView?, _ kind: Kind, then accept: @escaping () -> Void, otherwise deny: @escaping () -> Void) {
        guard let view, let pane = view.pane, let window = view.window,
              let wc = window.windowController as? TerminalWindowController else { return deny() }
        guard isKey(window) else {
            pendingByWindow[ObjectIdentifier(window), default: []].append(Pending(
                retry: { [weak view] in ask(view, kind, then: accept, otherwise: deny) }, deny: deny))
            observe(window)
            return
        }
        let loc = wc.locate(pane)
        let place = loc.map { " (\($0.workspace.displayName) · \($0.tab.title))" } ?? ""
        switch kind {
        case .read:
            wc.confirm("Let “\(pane.title)” read the clipboard?",
                       info: "A program in this pane\(place) asked for the clipboard's contents. Ghostty's clipboard-read is set to ask.",
                       accept: "Allow", cancel: "Deny", then: accept, otherwise: deny)
        case .write:
            wc.confirm("Let “\(pane.title)” change the clipboard?",
                       info: "A program in this pane\(place) wants to replace the clipboard's contents. Ghostty's clipboard-write is set to ask.",
                       accept: "Allow", cancel: "Deny", then: accept, otherwise: deny)
        case .paste(let preview):
            // Ghostty.app's wording ("Warning: Potentially Unsafe Paste").
            let info = "Pasting this text\(place.isEmpty ? "" : " into the pane" + place) may be dangerous as it looks like some commands may be executed.\n\n\(preview)"
            lastQuestionInfo = info
            wc.confirm("Paste into “\(pane.title)”?", info: info, accept: "Paste", cancel: "Cancel", then: accept, otherwise: deny)
        }
    }

    /// Questions waiting for their window to become key, oldest first. A window that closes first
    /// denies them, so libghostty doesn't keep the requests alive (#72).
    private struct Pending { let retry: () -> Void; let deny: () -> Void }
    private static var pendingByWindow: [ObjectIdentifier: [Pending]] = [:]
    private static var windowObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    private static func observe(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard windowObservers[id] == nil else { return }
        let nc = NotificationCenter.default
        windowObservers[id] = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { settle(id, accepting: true) }
            },
            nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { settle(id, accepting: false) }
            },
        ]
    }

    /// The window became key (ask now) or is closing (deny).
    private static func settle(_ id: ObjectIdentifier, accepting: Bool) {
        windowObservers.removeValue(forKey: id)?.forEach { NotificationCenter.default.removeObserver($0) }
        let waiting = pendingByWindow.removeValue(forKey: id) ?? []
        waiting.forEach { accepting ? $0.retry() : $0.deny() }
    }

    /// Self-test only: how many questions wait for a key window.
    static var pendingCount: Int { pendingByWindow.values.reduce(0) { $0 + $1.count } }

    private static func complete(_ surface: ghostty_surface_t, contents: [Content], available: [String],
                                 state: UnsafeMutableRawPointer?, confirmed: Bool = false) {
        // C copies for the duration of the call.
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer { strings.forEach { free($0) }; buffers.forEach { $0.deallocate() } }
        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            strings.append(mime)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            buffers.append(buf)
            entry.data.withUnsafeBytes { if let b = $0.baseAddress { buf.copyMemory(from: b, byteCount: $0.count) } }
            cContents.append(ghostty_clipboard_content_s(mime: mime, data: buf.assumingMemoryBound(to: CChar.self),
                                                         len: entry.data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            strings.append(s)
            cAvailable.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { cb in
            cAvailable.withUnsafeBufferPointer { ab in
                var done = ghostty_clipboard_complete_s(contents: cb.baseAddress, contents_len: cb.count,
                                                        available: ab.baseAddress, available_len: ab.count,
                                                        confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    // MARK: Pasteboard helpers (NSPasteboard+Extension.swift)

    static func pasteboardType(mime: String) -> NSPasteboard.PasteboardType? {
        if mime == "text/plain" { return .string }
        guard let ut = UTType(mimeType: mime) else { return NSPasteboard.PasteboardType(mime) }
        return NSPasteboard.PasteboardType(ut.identifier)
    }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL else { return nil }
            return url
        }
    }

    /// text/plain is the "opinionated" string: copied files paste as escaped paths.
    static func data(_ pb: NSPasteboard, forMime mime: String) -> Data? {
        switch mime {
        case "text/plain":
            let strings = (pb.pasteboardItems ?? []).compactMap { item -> String? in
                if let plist = item.propertyList(forType: .fileURL),
                   let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                    return ShellEscape.escape(url.path)
                }
                return item.string(forType: .string)
            }
            return strings.isEmpty ? nil : Data(strings.joined(separator: " ").utf8)
        case "text/uri-list":
            let urls = fileURLs(pb)
            return urls.isEmpty ? nil : Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            return pasteboardType(mime: mime).flatMap { pb.data(forType: $0) }
        }
    }

    /// Declared types only, never data (mode 5522 paste events stay metadata-only).
    static func availableMimes(_ pb: NSPasteboard) -> [String] {
        let types = pb.types ?? []
        let mimeOf: (NSPasteboard.PasteboardType) -> String? = { t in
            guard let m = UTType(t.rawValue)?.preferredMIMEType else { return nil }
            return m == "text/plain;charset=utf-8" ? "text/plain" : m
        }
        var result: [String] = []
        var seen = Set<String>()
        let hasFile = types.contains(.fileURL)
        if hasFile || types.contains(where: { mimeOf($0) == "text/plain" }) { result.append("text/plain"); seen.insert("text/plain") }
        if hasFile { result.append("text/uri-list"); seen.insert("text/uri-list") }
        for t in types { if let m = mimeOf(t), seen.insert(m).inserted { result.append(m) } }
        return result
    }
}
