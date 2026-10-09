import AppKit

// MARK: - Self-test section: dropping files, URLs and text onto a pane (#51)

extension TerminalWindowController {
    func fileDropSelfTestSteps(_ t: SelfTestKit) {
        func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let pb = NSPasteboard(name: NSPasteboard.Name("dealer-selftest-drop-\(ProcessInfo.processInfo.processIdentifier)"))
            pb.clearContents()
            fill(pb)
            return pb
        }

        t.step("file drop: shell escaping matches Ghostty's", nil, {
            let cases: [(String, String)] = [
                ("hello", "hello"), ("", ""), ("file name", "file\\ name"), ("a\\b", "a\\\\b"),
                ("(foo)", "\\(foo\\)"), ("[bar]", "\\[bar\\]"), ("{baz}", "\\{baz\\}"), ("<qux>", "\\<qux\\>"),
                ("say\"hi\"", "say\\\"hi\\\""), ("it's", "it\\'s"), ("`cmd`", "\\`cmd\\`"), ("wow!", "wow\\!"),
                ("#comment", "\\#comment"), ("$HOME", "\\$HOME"), ("a&b", "a\\&b"), ("a;b", "a\\;b"),
                ("a|b", "a\\|b"), ("*.txt", "\\*.txt"), ("file?.log", "file\\?.log"), ("col1\tcol2", "col1\\\tcol2"),
                ("$(echo 'hi')", "\\$\\(echo\\ \\'hi\\'\\)"), ("/tmp/my file (1).txt", "/tmp/my\\ file\\ \\(1\\).txt"),
                ("/tmp/café ünï", "/tmp/café\\ ünï"),
            ]
            let bad = cases.filter { ShellEscape.escape($0.0) != $0.1 }
            return bad.isEmpty ? nil : bad.map { "escape(\($0.0.debugDescription)) = \(ShellEscape.escape($0.0).debugDescription), want \($0.1.debugDescription)" }.joined(separator: "; ")
        }) {}

        t.step("file drop: files become escaped paths, URLs are escaped, plain text isn't", nil, {
            var problems: [String] = []
            let files = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL, URL(fileURLWithPath: "/tmp/it's") as NSURL]) }
            let got = SurfaceView.dropText(from: files)
            if got != "/tmp/a\\ b.txt /tmp/it\\'s" { problems.append("two files gave \(got.debugDescription)") }
            let url = pasteboard { $0.setString("https://example.com/?a=1&b=2", forType: .URL) }
            if SurfaceView.dropText(from: url) != "https://example.com/\\?a=1\\&b=2" {
                problems.append("URL gave \(SurfaceView.dropText(from: url).debugDescription)")
            }
            let text = pasteboard { $0.setString("ls -la | wc -l", forType: .string) }
            if SurfaceView.dropText(from: text) != "ls -la | wc -l" { problems.append("string gave \(SurfaceView.dropText(from: text).debugDescription)") }
            let none = pasteboard { $0.setData(Data([1]), forType: .tiff) }
            if let s = SurfaceView.dropText(from: none) { problems.append("tiff gave \(s.debugDescription)") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        t.step("file drop: only the terminal surface accepts drops (pane bars and strips don't)", nil, {
            guard let pane = self.focusedPane else { return "no focused pane" }
            let registered = Set(pane.surface.registeredDraggedTypes)
            if registered != SurfaceView.dropTypes { return "surface registered \(registered)" }
            let others = pane.view.subviews.filter { $0 !== pane.surface && !$0.registeredDraggedTypes.isEmpty }
            return others.isEmpty ? nil : "other pane views accept drops: \(others)"
        }) {}

        var target: Pane?
        t.step("file drop: a drop focuses the pane it lands on", nil, {
            guard let target else { return "no target" }
            return SelfTest.waitUntil("the drop target to take focus") { self.focusedPane === target }
        }) {
            guard let source = self.focusedPane else { return }
            self.split(source, side: .right)
            target = self.focusedPane
            self.focus(source)
            target?.surface.receiveDrop("")
        }
    }
}
