import AppKit

// MARK: - Self-test section: titles programs set (#75)

extension TerminalWindowController {
    /// Claude Code's working prefix (`◐ ` / `◑ `, alternating) is dropped where ghostty's SET_TITLE
    /// comes in (`Pane.terminalTitle`), so the pane, its tab and `dealer list` all show the bare
    /// title. Driven by a live shell emitting OSC 0. A glyph mid-title and the idle `✳ ` stay.
    /// Self-contained (`DEALER_SELFTEST_ONLY=titles:`); removes its workspace.
    func titlesSelfTestSteps(_ t: SelfTestKit) {
        var id: Int?
        var lastError: String?
        func pane() -> Pane? { id.flatMap(ControlHandler.pane(id:)) }
        /// The pane's title as `dealer list` reports it.
        func listed() -> String? {
            guard let id, let r = ControlHandler.handle(["cmd": "list", "args": [String: Any]()])["result"] else { return nil }
            func find(_ v: Any) -> String? {
                if let d = v as? [String: Any] {
                    if d["id"] as? Int == id, d["custom_title"] != nil, let title = d["title"] as? String { return title }
                    for x in d.values { if let f = find(x) { return f } }
                } else if let a = v as? [Any] {
                    for x in a { if let f = find(x) { return f } }
                }
                return nil
            }
            return find(r)
        }
        /// Emits `title` with OSC 0 from the live shell, then sleeps so shell integration's precmd
        /// doesn't replace it before we look; expects every view to show `want`.
        func emit(_ title: String, want: String) -> String? {
            guard let p = pane() else { return "no pane" }
            p.surface.typeText("\u{03}")  // end the previous sleep, if any
            p.surface.typeText("printf '\\e]0;\(title)\\a'; sleep 30\r")
            let wait = SelfTest.waitUntil { p.title == want }
                ? nil : "the shell's title \"\(title)\" should show as \"\(want)\", but the pane's title is \"\(p.title)\""
            let tab = locate(p)?.tab.title
            let list = listed()
            return [wait,
                    tab == want ? nil : "tab title \(tab.map { "\"\($0)\"" } ?? "nil"), want \"\(want)\"",
                    list == want ? nil : "dealer list title \(list.map { "\"\($0)\"" } ?? "nil"), want \"\(want)\""]
                .compactMap { $0 }.first
        }

        t.step("titles: setup, a live shell in its own workspace", nil, {
            if let lastError { return lastError }
            guard let p = pane() else { return "no pane created" }
            guard p.surface.surface != nil else { return nil }
            return SelfTest.waitUntil("the shell to start (pwd)", timeout: 10) { p.pwd != nil }
        }) {
            let r = ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "titles"]])
            guard r["ok"] as? Bool == true, let pid = (r["result"] as? [String: Any])?["pane"] as? Int else {
                lastError = "create failed: \(r["error"] ?? "?")"; return
            }
            id = pid
        }

        t.step("titles: Claude Code's working ◐/◑ prefix is dropped; a glyph mid-title and the idle ✳ stay", nil, {
            guard let p = pane() else { return "setup failed" }
            guard p.surface.surface != nil else {
                print("      (skipped the live OSC 0 title check: ghostty couldn't create terminal surfaces here)")
                return nil
            }
            return emit("◐ Fix bug", want: "Fix bug")
                ?? emit("◑ Next step", want: "Next step")
                ?? emit("Fix ◐ bug", want: "Fix ◐ bug")
                ?? emit("◐Fix", want: "◐Fix")
                ?? emit("✳ Fix bug", want: "✳ Fix bug")
        }) {}

        t.step("titles: cleanup", nil, {
            self.workspaces.contains(where: { $0.name == "titles" }) ? "the titles workspace is still open" : nil
        }) {
            pane()?.surface.typeText("\u{03}")
            if let ws = self.workspaces.first(where: { $0.name == "titles" }) { self.remove(workspace: ws) }
            self.layoutNow()
        }
    }
}
