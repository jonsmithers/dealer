import AppKit

// MARK: - Self-test section: the sidebar row shows the cwd's name, the tooltip the path (issue #68)

extension TerminalWindowController {
    func sidebarLeafSelfTestSteps(_ t: SelfTestKit) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dealer-leaf-\(getpid())/projects/widget").path
        var pane: Pane?
        t.step("sidebar leaf: a row's status line shows the cwd's name and branch; its tooltip and the pane bar keep the path", nil, {
            guard let p = pane, let i = self.workspaces.firstIndex(where: { $0 === self.workspace(of: p) }),
                  let row = self.workspaceSidebar.row(at: i) as? WorkspaceRow else { return "no row for the test workspace" }
            var problems: [String] = []
            if row.detail != "widget · feature-x" { problems.append("row detail is \"\(row.detail)\", want \"widget · feature-x\"") }
            if row.toolTip != "…/projects/widget · feature-x" { problems.append("row tooltip is \(row.toolTip.map { "\"\($0)\"" } ?? "nil"), want \"…/projects/widget · feature-x\"") }
            if p.statusLine != "…/projects/widget · feature-x" { problems.append("pane bar line is \"\(p.statusLine)\", want the abbreviated path") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {
            try? FileManager.default.createDirectory(atPath: tmp + "/.git", withIntermediateDirectories: true)
            try? "ref: refs/heads/feature-x\n".write(toFile: tmp + "/.git/HEAD", atomically: true, encoding: .utf8)
            self.newWorkspace(nil)
            pane = self.focusedPane
            t.named(pane, "leaf")
            pane?.surface.pwd = tmp
            self.sidebarPreference = true
            self.refreshChrome()
            self.layoutNow()
        }
        t.step("sidebar leaf: clean up", nil, {
            self.locate(t.pane("leaf")) == nil ? nil : "the test workspace should be closed"
        }) {
            if let ws = pane.flatMap({ self.workspace(of: $0) }) { self.remove(workspace: ws) }
            self.sidebarPreference = nil
            self.layoutNow()
            try? FileManager.default.removeItem(atPath: (tmp as NSString).deletingLastPathComponent)
        }
    }
}
