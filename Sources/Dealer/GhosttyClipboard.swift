import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// libghostty's clipboard callbacks: a trimmed port of `Ghostty.App.readClipboard`,
/// `confirmReadClipboard` and `writeClipboard` and of `NSPasteboard+Extension.swift` in
/// ghostty-org/ghostty (at the pinned commit). Reads are MIME based: libghostty asks for
/// representations (text/plain for a paste, others for OSC 52/kitty reads) and may ask for the
/// list of available types. Only the standard pasteboard is served (no selection clipboard).
enum GhosttyClipboard {
    struct Content { let mime: String; let data: Data }

    static func read(_ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                     state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?,
                     mimesLen: Int, list: Bool) -> ghostty_clipboard_read_result_e {
        guard let surface = SurfaceView.from(ud)?.surface,
              location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let pb = NSPasteboard.general
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

    /// No confirmation UI: accept what libghostty would hand over (Dealer's behavior since the
    /// start; Ghostty.app shows a dialog here).
    static func confirmRead(_ ud: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                            state: UnsafeMutableRawPointer?) {
        guard let surface = SurfaceView.from(ud)?.surface else { return }
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
        complete(surface, contents: reps, available: avail, state: state, confirmed: true)
    }

    /// Writes every representation (the confirm flag is ignored, as before: no dialog).
    static func write(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int,
                      to pb: NSPasteboard = .general) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        let items: [(NSPasteboard.PasteboardType, Data)] = (0..<len).compactMap { i in
            let c = content[i]
            guard let mime = c.mime, let type = Self.pasteboardType(mime: String(cString: mime)) else { return nil }
            let data = c.len > 0 && c.data != nil ? Data(bytes: c.data, count: c.len) : Data()
            return (type, data)
        }
        guard !items.isEmpty else { return }
        pb.declareTypes(items.map(\.0), owner: nil)
        for (type, data) in items { pb.setData(data, forType: type) }
    }

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
