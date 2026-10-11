import AppKit
import GhosttyKit

// MARK: - Self-test section: the MIME-based clipboard callbacks (GhosttyClipboard, #43 pin bump)
//
// On a private pasteboard: the user's clipboard is never touched, so ghostty's own copy/paste
// round trip (which uses the general pasteboard) is not covered here.

extension TerminalWindowController {
    func clipboardSelfTestSteps(_ t: SelfTestKit) {
        func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let pb = NSPasteboard(name: NSPasteboard.Name("dealer-selftest-clip-\(ProcessInfo.processInfo.processIdentifier)"))
            pb.clearContents()
            fill(pb)
            return pb
        }
        func text(_ d: Data?) -> String? { d.flatMap { String(data: $0, encoding: .utf8) } }

        t.step("clipboard: reads serve text/plain (files as escaped paths), text/uri-list and other MIME types", nil, {
            var problems: [String] = []
            let plain = pasteboard { $0.setString("echo hi", forType: .string) }
            if text(GhosttyClipboard.data(plain, forMime: "text/plain")) != "echo hi" { problems.append("plain text") }
            if GhosttyClipboard.data(plain, forMime: "text/uri-list") != nil { problems.append("uri-list without files") }
            if GhosttyClipboard.availableMimes(plain) != ["text/plain"] { problems.append("available \(GhosttyClipboard.availableMimes(plain))") }
            let files = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL]) }
            let f = text(GhosttyClipboard.data(files, forMime: "text/plain"))
            if f != "/tmp/a\\ b.txt" { problems.append("file as text/plain: \(f ?? "nil")") }
            if text(GhosttyClipboard.data(files, forMime: "text/uri-list")) != "file:///tmp/a%20b.txt\r\n" { problems.append("uri-list") }
            if !GhosttyClipboard.availableMimes(files).starts(with: ["text/plain", "text/uri-list"]) { problems.append("file mimes \(GhosttyClipboard.availableMimes(files))") }
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let image = pasteboard { $0.setData(png, forType: .png) }
            if GhosttyClipboard.data(image, forMime: "image/png") != png { problems.append("image/png") }
            if !GhosttyClipboard.availableMimes(image).contains("image/png") { problems.append("image mimes \(GhosttyClipboard.availableMimes(image))") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        t.step("clipboard: a write stores every representation, binary-safe (explicit lengths)", nil, {
            let pb = pasteboard { _ in }
            let bytes: [CChar] = [0x61, 0x00, 0x62]  // "a\0b": not a C string
            let mimes = ["text/plain", "text/html"]
            let html = "<b>x</b>"
            mimes[0].withCString { m0 in mimes[1].withCString { m1 in html.withCString { h in
                bytes.withUnsafeBufferPointer { b in
                    var items = [ghostty_clipboard_content_s(mime: m0, data: b.baseAddress, len: b.count),
                                 ghostty_clipboard_content_s(mime: m1, data: h, len: html.utf8.count)]
                    GhosttyClipboard.write(location: GHOSTTY_CLIPBOARD_STANDARD, content: &items, len: items.count, to: pb)
                }
            } } }
            var problems: [String] = []
            if pb.data(forType: .string) != Data([0x61, 0x00, 0x62]) { problems.append("text/plain: \(String(describing: pb.data(forType: .string).map(Array.init)))") }
            if pb.data(forType: .html).flatMap({ String(data: $0, encoding: .utf8) }) != html { problems.append("text/html") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
    }
}
