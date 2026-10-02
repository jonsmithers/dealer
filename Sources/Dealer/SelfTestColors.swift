import AppKit

// MARK: - Self-test section: workspace and tab colors (issue #9)

extension TerminalWindowController {
    func colorsSelfTestSteps(_ t: SelfTestKit) {
        let sb = workspaceSidebar
        let bar = workspaceBar
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }

        func shows(_ v: NSView?, _ rect: CGRect?, _ c: NSColor, _ what: String) -> String? {
            guard let v, let rect else { return "\(what): no view" }
            let px = PixelProbe.sample(v, at: CGPoint(x: rect.midX, y: rect.midY))
            return PixelProbe.matches(px, c) ? nil : "\(what) should be \(c.hexString), is \(px?.hexString ?? "nil")"
        }
        func outlined(_ v: NSView?) -> Bool { PixelProbe.isWaitingOutlined(v) }
        func tabButton(_ pane: String) -> TabButton? {
            guard let loc = locate(t.pane(pane)), let i = loc.deck.index(of: loc.tab) else { return nil }
            let b = loc.deck.view.strip.buttons
            return b.indices.contains(i) ? b[i] : nil
        }
        func row(_ i: Int) -> WorkspaceRow? { sb.row(at: i) as? WorkspaceRow }
        func chip(_ i: Int) -> CGRect? { row(i).map { WorkspaceRow.chipRect(in: $0.bounds) } }
        let teal = NSColor(hex: "#11a08f")!, red = NSColor(hex: "#d03040")!

        t.step("colors: a workspace color shows on its sidebar row, plus an accent while it's active", nil, {
            all(row(0)?.color?.sameColor(as: teal) == true ? nil : "row 1 should carry the color",
                row(1)?.color == nil ? nil : "row 2 should stay neutral",
                shows(row(0), chip(0), teal, "row 1's chip"),
                !self.workspaceAccent.isHidden && self.workspaceAccent.layer?.backgroundColor.map { NSColor(cgColor: $0)?.sameColor(as: teal) == true } == true
                    ? nil : "the deck-area accent should show in the workspace color")
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "k2")
            self.activateWorkspace(index: 0)
            self.setColor(teal, workspace: self.workspaces[0])
        }
        t.step("colors: the accent follows the active workspace", nil, {
            self.workspaceAccent.isHidden ? nil : "no accent for an uncolored workspace"
        }) {
            self.activateWorkspace(index: 1)
        }
        t.step("colors: in top-bar mode the pill shows the color", nil, {
            all(bar.isHidden ? "pills should show" : nil,
                (bar.button(at: 0) as? WorkspaceButton)?.color?.sameColor(as: teal) == true ? nil : "pill 1 should carry the color",
                shows(bar.button(at: 0), (bar.button(at: 0) as? WorkspaceButton)?.chipRect, teal, "pill 1's chip"))
        }) {
            self.activateWorkspace(index: 0)
            Settings.workspaceSwitcher = .top
        }
        t.step("colors: a tab color replaces the deck underline on its tab", nil, {
            all(tabButton("srv")?.color?.sameColor(as: red) == true ? nil : "srv's tab should carry the color",
                shows(tabButton("srv"), tabButton("srv")?.underlineRect, red, "srv's tab underline"),
                tabButton("k3")?.color == nil ? nil : "other tabs stay neutral")
        }) {
            Settings.workspaceSwitcher = .sidebar
            self.setColor(red, tab: self.locate(t.pane("srv"))!.tab)
            self.newTab(nil)
            t.named(self.focusedPane, "k3")
            self.focus(t.pane("srv"))
        }
        t.step("colors: the tab's color follows it to another workspace", nil, {
            all(self.locate(t.pane("srv"))?.workspace === self.workspaces[1] ? nil : "srv's tab should be in workspace 2",
                tabButton("srv")?.color?.sameColor(as: red) == true ? nil : "the moved tab keeps its color",
                shows(tabButton("srv"), tabButton("srv")?.underlineRect, red, "moved tab's underline"),
                self.workspaces[0].color?.sameColor(as: teal) == true ? nil : "workspace 1 keeps its own color")
        }) {
            self.move(tab: self.locate(t.pane("srv"))!.tab, toWorkspace: self.workspaces[1])
            self.focus(t.pane("srv"))
        }
        t.step("colors: colors round-trip through the session; older files load without", nil, {
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(snap),
                  let back = try? JSONDecoder().decode(WindowSnapshot.self, from: data) else { return "encode failed" }
            let restored = self.restoreWorkspaces(back)
            defer { restored.flatMap(\.panes).forEach { $0.view.removeFromSuperview() } }
            var old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if var wss = old["workspaces"] as? [[String: Any]] {
                for i in wss.indices { wss[i]["color"] = nil }
                old["workspaces"] = wss
            }
            let legacy = (try? JSONSerialization.data(withJSONObject: old)).flatMap { try? JSONDecoder().decode(WindowSnapshot.self, from: $0) }
            return all(restored.first?.color?.sameColor(as: teal) == true ? nil : "workspace color lost",
                       restored.flatMap(\.tabs).contains { $0.color?.sameColor(as: red) == true } ? nil : "tab color lost",
                       legacy != nil && legacy!.allWorkspaces.allSatisfy { $0.color == nil } ? nil : "a file without colors should load")
        }) {}
        t.step("colors: a blue workspace or tab never looks like waiting attention", nil, {
            all(outlined(row(0)) ? "a blue workspace row must not get the waiting outline" : nil,
                outlined(tabButton("k3")) ? "a blue tab must not get the waiting outline" : nil)
        }) {
            self.activateWorkspace(index: 1)
            self.setColor(Theme.attentionWaiting, workspace: self.workspaces[0])
            self.setColor(Theme.attentionWaiting, tab: self.locate(t.pane("k3"))!.tab)
        }
        t.step("colors: …and waiting attention on it still shows its outline", nil, {
            outlined(row(0)) ? nil : "the waiting outline should show on the blue row"
        }) {
            self.setAttention(.waiting, on: t.pane("k3"))
        }
        t.step("colors: None restores the default look", nil, {
            all(row(0)?.color == nil && row(1)?.color == nil ? nil : "rows should be neutral",
                self.workspaceAccent.isHidden ? nil : "accent should be gone",
                tabButton("srv")?.color == nil ? nil : "srv's tab should be neutral",
                PixelProbe.matches(PixelProbe.sample(row(0), at: CGPoint(x: chip(0)?.midX ?? 0, y: chip(0)?.midY ?? 0)),
                                   NSColor(hex: "#ff0000"), tolerance: 0.2) ? "row 1's chip should be gone" : nil)
        }) {
            self.setAttention(.none, on: t.pane("k3"))
            self.workspaces.forEach { self.setColor(nil, workspace: $0) }
            self.setColor(nil, tab: self.locate(t.pane("srv"))!.tab)
            self.setColor(nil, tab: self.locate(t.pane("k3"))!.tab)
            self.activateWorkspace(index: 0)
        }
        t.step("colors: [colors] auto_assign gives new workspaces the next unused palette color", nil, {
            all(self.workspaces.last?.color?.hexString == "#00ff00" ? nil : "new workspace should get #00ff00, got \(self.workspaces.last?.color?.hexString ?? "nil")",
                Theme.swatches.map(\.name) == ["1", "2"] ? nil : "the palette should replace the swatches",
                Settings.problems.isEmpty ? nil : "problems: \(Settings.problems)")
        }) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[colors]\nauto_assign = true\npalette = [\"#ff0000\", \"#00ff00\"]\n".write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            self.setColor(NSColor(hex: "#ff0000"), workspace: self.workspaces[0])
            self.setColor(nil, workspace: self.workspaces[1])
            self.move(workspace: self.workspaces[1], to: 0)
            self.activateWorkspace(index: 1)
            self.newWorkspace(nil)
            self.move(workspace: self.activeWorkspace, to: self.workspaces.count - 1)
        }
        t.step("colors: a bad palette entry is reported", nil, {
            Settings.problems.contains { $0.contains("colors.palette") } ? nil : "expected a palette problem, got \(Settings.problems)"
        }) {
            try? "[colors]\npalette = [\"#ff0000\", \"nope\"]\n".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload()
        }
        t.step("colors: clean up", nil, {
            all(self.workspaces.count == 1 ? nil : "one workspace expected",
                self.workspaces.allSatisfy { $0.color == nil } ? nil : "no colors expected")
        }) {
            try? FileManager.default.removeItem(at: Settings.fileURL)
            Settings.reload()
            if let home = self.workspace(of: t.pane("srv")) {
                self.activate(home)
                self.workspaces.filter { $0 !== home }.forEach { self.remove(workspace: $0) }
                home.color = nil
                home.tabs.forEach { $0.color = nil }
                self.refreshChrome()
            }
        }
    }
}
