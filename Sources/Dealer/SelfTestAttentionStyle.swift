import AppKit

// MARK: - Self-test section: the [attention] done / unread look (#61)

extension TerminalWindowController {
    /// By default *done* looks exactly like *waiting* (blue ring, tab and workspace outline);
    /// `[attention] done = "dot"` brings back the muted dot, `unread = "outline"` outlines *unread*,
    /// and a settings reload restyles marks that are already there. Exact pixels via PixelProbe,
    /// at 2x and 1x (the outline is a 1.5pt stroke).
    func attentionStyleSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        var savedSettings: String?
        var ids: [String: Int] = [:]
        var lastError: String?
        var redrawn = false

        func all(_ problems: [String?]) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func hex(_ c: NSColor?) -> String { c?.hexString ?? "nil" }
        @discardableResult
        func call(_ cmd: String, _ args: [String: Any] = [:], caller: String? = nil) -> [String: Any]? {
            var req: [String: Any] = ["cmd": cmd, "args": args]
            if let caller { req["caller"] = ids[caller] }
            let r = ControlHandler.handle(req)
            guard r["ok"] as? Bool == true else { lastError = "\(cmd) failed: \(r["error"] ?? "?")"; return nil }
            return r["result"] as? [String: Any]
        }
        func created(_ r: [String: Any]?, _ name: String) {
            guard let id = r?["pane"] as? Int, let p = ControlHandler.pane(id: id) else { return }
            ids[name] = id
            t.named(p, name)
        }
        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func setAttentionSettings(_ body: String?) {
            try? fm.createDirectory(at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let body { try? body.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload()
        }
        func tabButton(_ p: Pane) -> TabButton? {
            guard let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return nil }
            return loc.deck.view.strip.buttons[i]
        }
        func row(_ p: Pane) -> NSView? {
            guard let ws = locate(p)?.workspace, let i = workspaces.firstIndex(where: { $0 === ws }) else { return nil }
            return workspaceSidebar.row(at: i)
        }
        func ring(_ p: Pane) -> NSColor? {
            (p.view.layer?.sublayers?.first { $0.name == "dealer.attentionRing" }?.borderColor).flatMap { NSColor(cgColor: $0) }
        }
        /// The blue look, on the live pane, its tab and its workspace row (selected: the
        /// workspace is active), on the top and left edges so no neutral stroke hides under it.
        func blue(_ p: Pane, _ what: String) -> [String?] {
            var out: [String?] = [PixelProbe.matches(ring(p), Theme.attentionWaiting) ? nil
                                  : "\(what): pane ring is \(hex(ring(p))), want \(hex(Theme.attentionWaiting))"]
            out += PixelProbe.atEachScale { _ in
                var e: [String] = []
                if let b = tabButton(p) {
                    if !PixelProbe.isWaitingOutlined(b) { e.append("\(what): tab outline reads \(hex(PixelProbe.sample(b, at: PixelProbe.outlinePoint(in: b))))") }
                } else { e.append("\(what): no tab button") }
                if let r = row(p) {
                    // #91: the sidebar shows it as the large blue dot, never an outline.
                    if !PixelProbe.hasWaitingDot(r) {
                        e.append("\(what): selected workspace row's dot reads \(hex(PixelProbe.sidebarDot(r))), want a large \(hex(Theme.attentionWaiting)) dot and no outline")
                    }
                } else { e.append("\(what): no workspace row") }
                return e
            }
            return out
        }
        /// The dot look: no ring, no blue outline, and the tab's dot in the muted done colour.
        func dot(_ p: Pane, _ what: String) -> [String?] {
            var out: [String?] = [ring(p) == nil ? nil : "\(what): pane should have no ring, has \(hex(ring(p)))"]
            out += PixelProbe.atEachScale { _ in
                guard let b = tabButton(p), let r = row(p) else { return ["\(what): no tab button or row"] }
                let d = b.attentionDotRect
                let dotPx = PixelProbe.sample(b, at: CGPoint(x: d.midX, y: d.midY))
                let rowDot = PixelProbe.sidebarDot(r)
                return [PixelProbe.isWaitingOutlined(b) ? "\(what): tab still outlined blue" : nil,
                        PixelProbe.isWaitingOutlined(r) ? "\(what): workspace row outlined blue" : nil,
                        PixelProbe.matches(rowDot, Theme.attentionDone) ? nil : "\(what): row's large dot reads \(hex(rowDot)), want \(hex(Theme.attentionDone))",
                        PixelProbe.matches(dotPx, Theme.attentionDone) ? nil : "\(what): tab dot reads \(hex(dotPx)), want \(hex(Theme.attentionDone))"]
                    .compactMap { $0 }
            }
            return out
        }

        t.step("attention style: by default done looks exactly like waiting: blue pane ring, tab and selected workspace outline, at 2x and 1x", nil, {
            guard let b = pane("as-b") else { return all(["setup failed"]) }
            return all([Settings.attentionDoneOutlined ? nil : "done should be outlined by default",
                        Settings.attentionUnreadOutlined ? "unread should be a dot by default" : nil,
                        b.attention == .done ? nil : "pane is \(b.attention.name), want done"] + blue(b, "default done"))
        }) {
            savedSettings = try? String(contentsOf: Settings.fileURL, encoding: .utf8)
            setAttentionSettings(nil)
            created(call("create", ["type": "workspace", "target": "focused", "name": "astyle"]), "as-a")
            created(call("create", ["type": "tab", "focus": false], caller: "as-a"), "as-b")
            if let a = pane("as-a") { self.focus(a) }
            if let b = pane("as-b") { self.setAttention(.done, on: b) }
            self.layoutNow()
        }

        t.step("attention style: done = \"dot\" (live reload) brings back the muted dot on the existing mark", nil, {
            guard let b = pane("as-b") else { return all(["setup failed"]) }
            return all([Settings.attentionDoneOutlined ? "the setting didn't apply" : nil,
                        redrawn ? nil : "the reload didn't mark the tab and workspace row for redraw (their mark is unchanged, only its look)"]
                       + dot(b, "done = dot"))
        }) {
            // PixelProbe renders on demand, so also check the on-screen views were told to redraw
            // (their layers; NSView.needsDisplay doesn't read back reliably for these layer-backed views).
            self.window?.displayIfNeeded()
            setAttentionSettings("[attention]\ndone = \"dot\"\n")
            if let b = pane("as-b") { redrawn = (tabButton(b)?.layer?.needsDisplay() ?? false) && (row(b)?.layer?.needsDisplay() ?? false) }
            self.layoutNow()
        }

        t.step("attention style: removing the setting again (live) outlines the existing done mark", nil, {
            guard let b = pane("as-b") else { return all(["setup failed"]) }
            return all(blue(b, "back to default"))
        }) {
            setAttentionSettings(nil)
            self.layoutNow()
        }

        t.step("attention style: unread = \"outline\" outlines unread like waiting; by default unread is a dot", nil, {
            guard let b = pane("as-b") else { return all(["setup failed"]) }
            var p: [String?] = [b.attention == .unread ? nil : "pane is \(b.attention.name), want unread"]
            p += blue(b, "unread = outline")
            // Detached elements in dark and light themes: unread is a dot by default.
            setAttentionSettings(nil)
            for (name, bg) in [("dark", NSColor(hex: "#282c34")!), ("light", NSColor(hex: "#fafafa")!)] {
                p += PixelProbe.atEachScale { _ in Theme.withBackground(bg) {
                    let btn = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
                    btn.title = "tab"
                    btn.attention = .unread
                    return PixelProbe.isWaitingOutlined(btn) ? ["\(name): default unread must not be outlined"] : []
                } }
            }
            return all(p)
        }) {
            setAttentionSettings("[attention]\nunread = \"outline\"\n")
            if let b = pane("as-b") { self.setAttention(.unread, on: b) }
            self.layoutNow()
        }

        t.step("attention style: a selected pill marked done shows blue on every edge; a selected row keeps its neutral outline and shows the large blue dot (dark and light, 2x and 1x)", nil, {
            var p: [String] = []
            for (name, bg) in [("dark", NSColor(hex: "#303446")!), ("light", NSColor(hex: "#eff1f5")!)] {
                p += PixelProbe.atEachScale { _ in Theme.withBackground(bg) {
                    let row = WorkspaceRow(frame: CGRect(x: 0, y: 0, width: Theme.Metrics.sidebarWidth, height: Theme.Metrics.sidebarRowHeight))
                    row.number = "1"; row.title = "ws"
                    let pill = WorkspaceButton(frame: CGRect(x: 0, y: 0, width: 120, height: WorkspaceBarView.pillHeight))
                    pill.number = "1"; pill.title = "ws"
                    row.isActive = true; pill.isActive = true
                    row.attention = .done; pill.attention = .done
                    let pillEdges = [PixelProbe.outlinePoint(in: pill), CGPoint(x: 0.25, y: pill.bounds.midY)].map { PixelProbe.sample(pill, at: $0) }
                    let rowEdges = [PixelProbe.outlinePoint(in: row), CGPoint(x: 0.25, y: row.bounds.midY)].map { PixelProbe.sample(row, at: $0) }
                    return [pillEdges.allSatisfy { PixelProbe.matches($0, Theme.attentionWaiting) } ? nil
                                : "\(name): a selected done pill reads \(pillEdges.map(hex)), want \(hex(Theme.attentionWaiting))",
                            rowEdges.allSatisfy { PixelProbe.matches($0, Theme.text) } ? nil
                                : "\(name): a selected done row's edges read \(rowEdges.map(hex)), want the neutral \(hex(Theme.text))",
                            PixelProbe.matches(PixelProbe.sidebarDot(row), Theme.attentionWaiting) ? nil
                                : "\(name): a selected done row's large dot reads \(hex(PixelProbe.sidebarDot(row)))"].compactMap { $0 }
                } }
            }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}

        t.step("attention style: an invalid value is reported in the settings banner and falls back to the default (outline)", nil, {
            guard let b = pane("as-b") else { return all(["setup failed"]) }
            let reported = Settings.problems.contains { $0.contains("attention.done") }
            return all([reported ? nil : "problems: \(Settings.problems)",
                        self.settingsBanner.window != nil && !self.settingsBanner.isHidden ? nil : "the banner should show",
                        Settings.attentionDoneOutlined ? nil : "a bad value should fall back to outline"] + blue(b, "invalid → default"))
        }) {
            setAttentionSettings("[attention]\ndone = \"blue\"\n")
            if let b = pane("as-b") { self.setAttention(.done, on: b) }
            self.layoutNow()
        }

        t.step("attention style: clean up", nil, {
            all([self.workspaces.contains { $0.name == "astyle" } ? "test workspace should be gone" : nil,
                 Settings.problems.isEmpty ? nil : "problems left: \(Settings.problems)"])
        }) {
            if let ws = self.workspaces.first(where: { $0.name == "astyle" }) { self.remove(workspace: ws) }
            if let s = savedSettings { try? s.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload(force: true)
            self.settingsBanner.dismiss()
            self.layoutNow()
            lastError = nil
        }
    }
}
