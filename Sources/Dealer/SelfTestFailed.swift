import AppKit

// MARK: - Self-test section: the failed (red) attention state (issue #29)

extension TerminalWindowController {
    func failedSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func tabButton(_ p: Pane) -> TabButton? {
            guard let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return nil }
            return loc.deck.view.strip.buttons[i]
        }
        func ring(_ p: Pane) -> NSColor? {
            (p.view.layer?.sublayers?.first { $0.name == "dealer.attentionRing" }?.borderColor).flatMap { NSColor(cgColor: $0) }
        }
        func hex(_ c: NSColor?) -> String { c?.hexString ?? "nil" }
        /// Two panes the user isn't looking at, in one tab, plus one in another tab.
        var a: Pane?, b: Pane?, other: Pane?, home: Pane?

        t.step("failed: red ring on the pane, red outline and a `!` dot on its tab (exact pixels)", nil, {
            guard let a, let btn = tabButton(a) else { return "no unfocused pane to mark" }
            let outline = PixelProbe.sample(btn, at: PixelProbe.outlinePoint(in: btn))
            let dot = btn.attentionDotRect
            let bang = PixelProbe.sample(btn, at: CGPoint(x: dot.midX, y: dot.minY + dot.height * 0.35))
            let dotRed = PixelProbe.sample(btn, at: CGPoint(x: dot.minX + dot.width * 0.22, y: dot.midY))
            return all(a.attention == .failed ? nil : "pane is \(a.attention.name)",
                       PixelProbe.matches(ring(a), Theme.attentionFailed) ? nil : "pane ring is \(hex(ring(a))), want \(hex(Theme.attentionFailed))",
                       PixelProbe.isFailedOutlined(btn) ? nil : "tab outline is \(hex(outline)), want \(hex(Theme.attentionFailed))",
                       PixelProbe.isWaitingOutlined(btn) ? "failed must not draw the waiting blue" : nil,
                       PixelProbe.matches(dotRed, Theme.attentionFailed) ? nil : "dot is \(hex(dotRed)), want red",
                       PixelProbe.matches(bang, Theme.chrome) ? nil : "the dot's `!` is \(hex(bang)), want \(hex(Theme.chrome))")
        }) {
            home = self.focusedPane
            // A tab other than the focused one, with at least two panes.
            let tabs = self.decks.flatMap(\.tabs).filter { $0.panes.count >= 2 && !$0.panes.contains { $0 === home } }
            guard let tab = tabs.first else { return }
            a = tab.panes[0]; b = tab.panes[1]
            other = self.decks.flatMap(\.tabs).first { $0 !== tab && !$0.panes.contains { $0 === home } }?.panes.first
            self.setAttention(.failed, on: a!, title: "t", body: "b")
        }

        t.step("failed: red in both themes, never the swatch red, and done/waiting unchanged", nil, {
            var problems: [String] = []
            for (name, bg, swatch) in [("dark", NSColor(hex: "#282c34")!, NSColor(hex: "#e06c75")!),
                                       ("light", NSColor(hex: "#fafafa")!, NSColor(hex: "#c8414c")!)] {
                Theme.withBackground(bg) {
                    let btn = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
                    btn.title = "tab"
                    btn.attention = .failed
                    let px = PixelProbe.sample(btn, at: PixelProbe.outlinePoint(in: btn))
                    if !PixelProbe.matches(px, Theme.attentionFailed) { problems.append("\(name): outline \(hex(px)), want \(hex(Theme.attentionFailed))") }
                    if PixelProbe.distance(Theme.attentionFailed, swatch) < 0.2 { problems.append("\(name): failed red is too close to the red swatch") }
                    btn.attention = .waiting
                    if !PixelProbe.isWaitingOutlined(btn) { problems.append("\(name): waiting outline changed") }
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        t.step("failed: outranks waiting in roll-up; clearing it leaves the tab waiting (blue)", nil, {
            guard let a, let b, let btn = tabButton(a), let loc = self.locate(a) else { return "setup failed" }
            return all(loc.tab.attention == .failed ? nil : "tab should roll up to failed, is \(loc.tab.attention.name)",
                       loc.workspace.attention == .failed ? nil : "workspace should be failed, is \(loc.workspace.attention.name)",
                       PixelProbe.isFailedOutlined(btn) ? nil : "tab should be red while one pane is failed",
                       b.attention == .waiting ? nil : "b should be waiting")
        }) {
            if let b { self.setAttention(.waiting, on: b) }
        }
        t.step("failed: …and once the failed pane is cleared the tab shows waiting", nil, {
            guard let a, let btn = tabButton(a) else { return "setup failed" }
            return all(PixelProbe.isWaitingOutlined(btn) ? nil : "tab should be blue now",
                       ring(a) == nil ? nil : "a's ring should be gone")
        }) {
            if let a { self.setAttention(.none, on: a) }
        }

        t.step("failed: ⌘⇧U goes to a failed pane before a waiting one", nil, {
            self.focusedPane === other ? nil : "first jump should land on the failed pane"
        }) {
            // b is waiting (from above); `other`, in another tab, fails.
            if let other { self.setAttention(.failed, on: other) }
            self.jumpToNextUnread(nil)
        }
        t.step("failed: focusing it cleared it; the next jump reaches the waiting pane", nil, {
            all(other?.attention == Attention.none ? nil : "focus should clear failed",
                other.flatMap { ring($0) } == nil ? nil : "the ring should be gone",
                other.flatMap(tabButton).map { PixelProbe.isFailedOutlined($0) ? "tab still red" : nil } ?? nil,
                self.focusedPane === b ? nil : "second jump should land on the waiting pane")
        }) { self.jumpToNextUnread(nil) }

        var ws2: Workspace?
        t.step("failed: the workspace's sidebar row gets the red outline", nil, {
            let row = self.workspaceSidebar.row(at: 0)
            let px = row.map { PixelProbe.sample($0, at: PixelProbe.outlinePoint(in: $0)) } ?? nil
            return all(row != nil ? nil : "no sidebar row",
                       PixelProbe.isFailedOutlined(row) ? nil : "row outline is \(hex(px)), want \(hex(Theme.attentionFailed))",
                       PixelProbe.isFailedOutlined(self.workspaceSidebar.row(at: 1)) ? "the other workspace's row should not be red" : nil)
        }) {
            if let home { self.focus(home) }
            if let a { self.setAttention(.failed, on: a) }
            ws2 = self.newWorkspace(activate: false)
            self.refreshChrome()
        }
        t.step("failed: …and so does its top-bar pill", nil, {
            let pill = self.workspaceBar.button(at: 0)
            let px = pill.map { PixelProbe.sample($0, at: PixelProbe.outlinePoint(in: $0)) } ?? nil
            return all(pill != nil ? nil : "no pill",
                       PixelProbe.isFailedOutlined(pill) ? nil : "pill outline is \(hex(px)), want \(hex(Theme.attentionFailed))")
        }) {
            Settings.workspaceSwitcher = .top
        }
        t.step("failed: clean up", nil, {
            all(self.workspaces.count == 1 ? nil : "extra workspace left",
                [a, b, other].allSatisfy { ($0?.attention ?? Attention.none) == Attention.none } ? nil : "attention left set")
        }) {
            Settings.workspaceSwitcher = .sidebar
            if let ws2 { self.remove(workspace: ws2) }
            for p in [a, b, other] { if let p { self.setAttention(.none, on: p) } }
            if let home { self.focus(home) }
        }

        t.step("failed: a shell command's non-zero exit maps to failed; the setting turns it off", nil, {
            let f = TerminalWindowController.commandFinishedAttention
            return all(f(1, 1_000_000, true) == .failed ? nil : "quick failure should be failed",
                       f(1, 1_000_000, false) == nil ? nil : "with failed_commands off, a quick failure marks nothing",
                       f(2, 20_000_000_000, false) == .unread ? nil : "with it off, a long failure is unread as before",
                       f(0, 20_000_000_000, true) == .unread ? nil : "a long success stays unread",
                       f(0, 1_000_000, true) == nil ? nil : "a quick success marks nothing",
                       f(-1, 1_000_000, true) == nil ? nil : "an unknown exit code isn't a failure",
                       Settings.attentionFailedCommands ? nil : "failed_commands should default to true",
                       Settings.agentErrorsAsFailed ? nil : "errors_as_failed should default to true")
        }) {}
    }
}
