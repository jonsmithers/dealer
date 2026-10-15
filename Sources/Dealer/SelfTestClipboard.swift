import AppKit
import GhosttyKit

// MARK: - Self-test section: the clipboard callbacks (GhosttyClipboard, #43 pin bump, #55)
//
// On a private pasteboard (`GhosttyClipboard.pasteboard` swapped for the OSC 52 steps): the user's
// clipboard is never touched. ⌘C/⌘V through ghostty aren't covered; OSC 52 reads and writes from
// a real shell are, under each clipboard-read / clipboard-write setting.

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

        // MARK: OSC 52 through a real shell, under ghostty's clipboard-read / clipboard-write (#55)
        //
        // libghostty applies the policy; Dealer asks for `ask`. A bash one-liner sends the OSC 52
        // query and prints what came back between markers, so each check sees the real reply.
        let cbConfig = NSTemporaryDirectory() + "dealer-selftest-clipboard-\(getpid()).ghostty"
        let osc = pasteboard { $0.setString("osc52-ok", forType: .string) }
        let okB64 = Data("osc52-ok".utf8).base64EncodedString()
        var keyNow = true
        var probe = 0
        var live = false
        var problem: String?
        func pane() -> Pane { t.pane("cb") }
        func use(read: String, write: String) {
            try? "clipboard-read = \(read)\nclipboard-write = \(write)\n".write(toFile: cbConfig, atomically: true, encoding: .utf8)
            GhosttyRuntime.configFileOverride = cbConfig
            _ = GhosttyRuntime.shared.reloadConfig()
        }
        func asked() -> Int { Confirmation.autoAccepted.filter { $0.hasPrefix("Let “") }.count }
        /// Types the read probe; returns its marker. The reply (base64) lands between "GOTn:" and ":END".
        func startRead(timeout: Int = 3) -> String {
            probe += 1
            let m = "GOT\(probe)"
            pane().surface.typeText("/bin/bash --norc --noprofile -c 'printf \"\\033]52;c;?\\007\"; IFS= read -r -s -t \(timeout) -d \"\\\\\" r; r=${r//[[:cntrl:]]/}; echo \"\(m.prefix(1))\"\"\(m.dropFirst()):${r#*;c;}:E\"\"ND\"'\r")
            return m
        }
        func readResult(_ m: String, timeout: TimeInterval = 10) -> String? {
            var got: String?
            _ = SelfTest.waitUntil(timeout: timeout) {
                let text = pane().surface.screenText
                guard let r = text.range(of: m + ":"), let e = text.range(of: ":END", range: r.upperBound..<text.endIndex) else { return false }
                got = String(text[r.upperBound..<e.lowerBound])
                return true
            }
            return got
        }
        /// Types an OSC 52 write of `value`, then a marker; waits for the marker.
        func write(_ value: String) {
            probe += 1
            let m = "WROTE\(probe)"
            let b64 = Data(value.utf8).base64EncodedString()
            pane().surface.typeText("printf '\\033]52;c;\(b64)\\007'; echo \(m)-$((1+1))\r")
            _ = SelfTest.waitUntil(timeout: 10) { pane().surface.screenText.contains("\(m)-2") }
            // The IO thread queued the write for the app thread before it printed the marker; drain
            // that mailbox now, so the next config change can't overtake it.
            GhosttyRuntime.shared.tick()
        }
        func skippedLive(_ what: String) -> String? {
            print("      (skipped \(what): ghostty couldn't create terminal surfaces here)")
            return nil
        }

        t.step("clipboard: a pane for OSC 52, a private pasteboard, a test ghostty config", nil, {
            live ? nil : skippedLive("the OSC 52 steps")
        }) {
            osc.clearContents()
            osc.setString("osc52-ok", forType: .string)
            GhosttyClipboard.pasteboard = osc
            GhosttyClipboard.isKey = { _ in keyNow }
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "cb")
            live = pane().surface.surface != nil
            if live { _ = SelfTest.waitUntil(timeout: 10) { !pane().surface.screenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        }
        t.step("clipboard: clipboard-read = allow returns the contents without asking", nil, {
            problem
        }) {
            guard live else { problem = nil; return }
            use(read: "allow", write: "allow")
            let before = asked()
            let got = readResult(startRead())
            problem = got == okB64 && asked() == before ? nil : "got \(got ?? "no reply line"), \(asked() - before) question(s)"
        }
        t.step("clipboard: clipboard-read = deny returns nothing and never asks", nil, {
            problem
        }) {
            guard live else { problem = nil; return }
            use(read: "deny", write: "allow")
            let before = asked()
            let got = readResult(startRead(timeout: 2))
            problem = got == "" && asked() == before && SelfTest.openModal() == nil ? nil
                : "got \(got ?? "no reply line"), \(asked() - before) question(s)"
        }
        t.step("clipboard: clipboard-read = ask asks (through Confirmation), then returns the contents", nil, {
            problem
        }) {
            guard live else { problem = nil; return }
            use(read: "ask", write: "allow")
            let before = asked()
            let got = readResult(startRead())
            let q = Confirmation.autoAccepted.last ?? ""
            problem = got == okB64 && asked() == before + 1 && q.hasSuffix("read the clipboard?") ? nil
                : "got \(got ?? "no reply line"), \(asked() - before) question(s), last: \(q)"
        }
        t.step("clipboard: an ask on a window that isn't key waits until it is", nil, {
            problem
        }) {
            guard live else { problem = nil; return }
            use(read: "ask", write: "allow")
            keyNow = false
            let before = asked()
            let m = startRead(timeout: 8)
            let waited = SelfTest.waitUntil(timeout: 5) { GhosttyClipboard.pendingCount == 1 }
            let early = asked() != before || pane().surface.screenText.contains(m + ":")
            keyNow = true
            if let w = pane().view.window { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w) }
            let got = readResult(m)
            problem = waited && !early && got == okB64 && asked() == before + 1 && GhosttyClipboard.pendingCount == 0 ? nil
                : "waited \(waited), asked early \(early), got \(got ?? "no reply line"), \(asked() - before) question(s)"
        }
        t.step("clipboard: clipboard-write = allow / deny / ask behave the same way", nil, {
            problem
        }) {
            guard live else { problem = nil; return }
            var bad: [String] = []
            let before = asked()
            use(read: "ask", write: "allow")
            write("w-allow")
            _ = SelfTest.waitUntil(timeout: 3) { osc.string(forType: .string) == "w-allow" }
            if osc.string(forType: .string) != "w-allow" || asked() != before { bad.append("allow: \(osc.string(forType: .string) ?? "nil"), \(asked() - before) question(s)") }
            use(read: "ask", write: "deny")
            write("w-deny")
            if osc.string(forType: .string) != "w-allow" || asked() != before { bad.append("deny: \(osc.string(forType: .string) ?? "nil"), \(asked() - before) question(s)") }
            use(read: "ask", write: "ask")
            write("w-ask")
            _ = SelfTest.waitUntil(timeout: 3) { osc.string(forType: .string) == "w-ask" }
            let q = Confirmation.autoAccepted.last ?? ""
            if osc.string(forType: .string) != "w-ask" || asked() != before + 1 || !q.hasSuffix("change the clipboard?") {
                bad.append("ask: \(osc.string(forType: .string) ?? "nil"), \(asked() - before) question(s), last: \(q)")
            }
            problem = bad.isEmpty ? nil : bad.joined(separator: "; ")
        }
        t.step("clipboard: clean up (the launch config, the general pasteboard)", nil, {
            GhosttyRuntime.configFileOverride == nil && GhosttyClipboard.pasteboard == NSPasteboard.general ? nil : "not restored"
        }) {
            GhosttyClipboard.pasteboard = .general
            GhosttyClipboard.isKey = { $0.isKeyWindow }
            GhosttyRuntime.configFileOverride = nil
            _ = GhosttyRuntime.shared.reloadConfig()
            try? FileManager.default.removeItem(atPath: cbConfig)
            if let tab = self.locate(pane())?.tab { self.remove(tab: tab) }
        }
    }
}
