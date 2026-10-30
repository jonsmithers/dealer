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
        let teal = NSColor(hex: "#11a08f")!, red = NSColor(hex: "#d03040")!

        // #90: the selected row shows its color as the selection bar, plus the tint; there are no chips.
        t.step("colors: a workspace color shows on its sidebar row", nil, {
            all(row(0)?.color?.sameColor(as: teal) == true ? nil : "row 1 should carry the color",
                row(1)?.color == nil ? nil : "row 2 should stay neutral",
                shows(row(0), row(0)?.selectionBarRect, teal, "row 1's selection bar"))
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "k2")
            self.activateWorkspace(index: 0)
            self.setColor(teal, workspace: self.workspaces[0])
        }

        // #15: everything except the sidebar row renders byte-for-byte the same with and without
        // the workspace color: the band above the decks, each tab strip and each tab button. The scene has two decks (two deck-color underlines), an
        // inactive tab, and a tab with its own color.
        var renders: [String: (Data?, Data?)] = [:]
        var pillsShown = false
        func capture(_ into: Int) {
            self.layoutNow()
            func put(_ key: String, _ d: Data?) {
                var pair = renders[key] ?? (nil, nil)
                if into == 0 { pair.0 = d } else { pair.1 = d }
                renders[key] = pair
            }
            let area = self.deckArea
            put("deck-area top band", PixelProbe.pixels(self.contentView, rect: CGRect(x: area.minX - 6, y: area.minY - 8, width: area.width + 12, height: 14)))
            for (i, deck) in self.decks.enumerated() {
                // The strip, not the whole deck: a deck view also contains the terminals' Metal layers,
                // which ghostty's renderer thread can update between the two captures (cursor blink).
                put("deck \(i + 1) tab strip", PixelProbe.pixels(deck.view.strip))
                for (j, b) in deck.view.strip.buttons.enumerated() { put("deck \(i + 1) tab \(j + 1)", PixelProbe.pixels(b)) }
            }
            put("sidebar row 1 (control)", PixelProbe.pixels(row(0)))
        }
        func compare() -> String? {
            var problems: [String] = []
            for (key, pair) in renders.sorted(by: { $0.key < $1.key }) {
                guard let a = pair.0, let b = pair.1, !a.isEmpty else { problems.append("\(key): nothing rendered"); continue }
                let same = a == b
                if key.hasSuffix("(control)") { if same { problems.append("the sidebar row should change with the color") } }
                else if !same { problems.append("\(key) changes with the workspace color") }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }
        t.step("colors: a workspace color touches nothing but its sidebar row: deck area, decks and every tab render identically", nil, {
            all(self.decks.count == 2 && self.decks.flatMap(\.tabs).count == 3 ? nil : "scene: expected 2 decks, 3 tabs",
                renders.count >= 6 ? nil : "expected deck, tab and band renders, got \(renders.keys.sorted())",
                compare())
        }) {
            self.newTab(nil); t.named(self.focusedPane, "k5")
            self.newTab(nil); t.named(self.focusedPane, "k6")
            self.setColor(red, tab: self.locate(t.pane("k6"))!.tab)
            self.promote(self.locate(t.pane("k5"))!.node, side: .right, allowWholeDeck: true)
            self.focus(t.pane("srv"))
            renders = [:]
            self.setColor(nil, workspace: self.workspaces[0])
            capture(0)
            self.setColor(teal, workspace: self.workspaces[0])
            capture(1)
        }
        // #18: the workspace's entry is colored in both switcher modes: the row in the sidebar and
        // the pill in the top bar. A pill in the waiting blue still doesn't read as outlined.
        var pillBar: NSColor?, pillTintDiffers = false, bluePillOutlined = true
        t.step("colors: in top-bar mode the workspace's pill shows its color", nil, {
            all(pillsShown ? nil : "pills should have been showing",
                PixelProbe.matches(pillBar, teal) ? nil : "pill 1's selection bar should be \(teal.hexString), is \(pillBar?.hexString ?? "nil")",
                pillTintDiffers ? nil : "pill 1 should be tinted (it renders the same as uncolored)",
                bluePillOutlined ? "a waiting-blue pill must not read as outlined" : nil)
        }) {
            Settings.workspaceSwitcher = .top
            self.layoutNow()
            pillsShown = !bar.isHidden && bar.button(at: 1) != nil
            let pill = bar.button(at: 0) as? WorkspaceButton
            self.setColor(nil, workspace: self.workspaces[0])
            self.layoutNow()
            let plain = PixelProbe.pixels(pill)
            self.setColor(teal, workspace: self.workspaces[0])
            self.layoutNow()
            pillBar = pill.flatMap { p in PixelProbe.sample(p, at: CGPoint(x: p.selectionBarRect.midX, y: p.selectionBarRect.midY)) }
            pillTintDiffers = PixelProbe.pixels(pill) != plain
            self.setColor(Theme.attentionWaiting, workspace: self.workspaces[0])
            self.layoutNow()
            bluePillOutlined = PixelProbe.isWaitingOutlined(pill)
            self.setColor(teal, workspace: self.workspaces[0])
            Settings.workspaceSwitcher = .sidebar
            for p in ["k5", "k6"] { self.remove(t.pane(p)) }
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
                tabButton("srv")?.color == nil ? nil : "srv's tab should be neutral",
                shows(row(0), row(0)?.selectionBarRect, Theme.text, "row 1's selection bar, back to the text color"))
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
