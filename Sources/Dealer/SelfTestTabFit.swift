import AppKit

// MARK: - Self-test section: tabs sized to their titles (#46, experiment)

extension TerminalWindowController {
    func tabFitSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        let minW = Theme.Metrics.tabMinWidth
        func text(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: Theme.Fonts.tabActive]).width) }
        func writeSettings(_ body: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            self.layoutNow()
        }
        var ws: Workspace?
        var widthsBefore: [CGFloat] = []
        var deck: Deck? { ws?.root?.leaves.first }
        /// Sets every tab's title in order (custom titles, so shells can't change them mid-check).
        func titles(_ ts: [String]) {
            guard let deck else { return }
            while deck.tabs.count < ts.count { self.newTab(in: deck) }
            for (tab, s) in zip(deck.tabs, ts) { tab.customTitle = s }
            self.refreshChrome()
            self.layoutNow()
            deck.view.strip.layoutSubtreeIfNeeded()
        }
        func widths() -> [CGFloat] { deck?.view.strip.buttons.map(\.frame.width) ?? [] }
        func available() -> CGFloat {
            guard let s = deck?.view.strip else { return 0 }
            let n = CGFloat(s.buttons.count)
            return s.bounds.width - 4 - 26 - n * Theme.Metrics.tabSpacing  // inset ×2, "+", spacing
        }
        /// Buttons laid out left to right with the strip spacing, "+" right after the last one.
        func contiguous() -> String? {
            guard let s = deck?.view.strip else { return "no strip" }
            var x = s.buttons.first?.frame.minX ?? 0
            for (i, b) in s.buttons.enumerated() {
                if abs(b.frame.minX - x) > 0.5 { return "tab \(i + 1) starts at \(b.frame.minX), want \(x)" }
                if b.frame != s.tabFrame(i) { return "tab \(i + 1)'s frame \(b.frame) isn't tabFrame \(s.tabFrame(i))" }
                x = b.frame.maxX + Theme.Metrics.tabSpacing
            }
            return abs(s.addButton.frame.minX - x) < 0.5 ? nil : "\"+\" at \(s.addButton.frame.minX), want \(x)"
        }

        t.step("tab fit: the water-level shrink cuts the widest first and keeps short tabs whole", nil, {
            let a = TabStripView.fit([40, 100, 300], available: 300)
            let b = TabStripView.fit([60, 60], available: 500)
            let c = TabStripView.fit([200, 200, 200], available: 90)
            let d = TabStripView.fit([50, 180, 170], available: 300)
            return all(a == [40, 100, 160] ? nil : "fit([40,100,300], 300) = \(a)",
                       b == [60, 60] ? nil : "fitting tabs shouldn't change: \(b)",
                       c == [minW, minW, minW] ? nil : "below the minimum every tab is minimum (overflow): \(c)",
                       d == [50, 125, 125] ? nil : "fit([50,180,170], 300) = \(d)")
        }) {}

        t.step("tab fit: each tab is as wide as its title plus fixed padding", nil, {
            guard let deck else { return "no deck" }
            let ts = deck.tabs.map(\.title), w = widths()
            var problems: [String?] = []
            for (i, s) in ts.enumerated() {
                let want = max(text(s) + TabButton.chromeWidth, minW)
                problems.append(abs(w[i] - want) < 0.5 ? nil : "\"\(s)\" is \(w[i])pt, want \(want)")
                let b = deck.view.strip.buttons[i]
                problems.append(b.titleRect.width + 0.5 >= text(s) || w[i] == minW ? nil : "\"\(s)\" would truncate (\(b.titleRect.width) < \(text(s)))")
            }
            problems.append(w[0] == minW ? nil : "a one-letter tab should take the minimum width \(minW), is \(w[0])")
            problems.append(w[2] > w[1] + 40 ? nil : "the long tab should be much wider than the short one: \(w)")
            problems.append(contiguous())
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {
            ws = self.newWorkspace(name: "tabfit")
            titles(["1", "zsh", "nvim Views.swift — dealer"])
        }

        t.step("tab fit: hover never resizes: the ×/dot slot is reserved beside the title", nil, {
            guard let deck else { return "no deck" }
            var problems: [String] = []
            for (i, b) in deck.view.strip.buttons.enumerated() {
                if b.closeRect.minX < b.titleRect.maxX { problems.append("tab \(i + 1): × overlaps the title") }
                if !b.bounds.insetBy(dx: AttentionStyle.outlineWidth, dy: AttentionStyle.outlineWidth).contains(b.closeRect) { problems.append("tab \(i + 1): × leaves the tab") }
                if !b.closeRect.contains(b.attentionDotRect) { problems.append("tab \(i + 1): the dot isn't in the × slot") }
            }
            return problems.first
        }) {}

        t.step("tab fit: selecting another tab (medium weight) doesn't resize any tab", nil, {
            let w = widths()
            return w == widthsBefore ? nil : "widths \(widthsBefore) became \(w)"
        }) {
            widthsBefore = widths()
            if let deck { self.select(tab: deck.tabs[0], in: deck) }
            deck?.view.strip.layoutSubtreeIfNeeded()
        }

        t.step("tab fit: a long title is capped at the default maximum and truncated", nil, {
            let w = widths()
            return all(w.last == Theme.Metrics.tabMaxWidth ? nil : "the long tab is \(w.last ?? 0), want \(Theme.Metrics.tabMaxWidth)",
                       contiguous())
        }) {
            titles(["1", "zsh", String(repeating: "very long title ", count: 20)])
        }

        t.step("tab fit: overflowing tabs shrink widest first; short ones stay whole; the row fits", nil, {
            guard let deck else { return "no deck" }
            let w = widths(), avail = available()
            let natural = deck.tabs.map { TabStripView.naturalWidth($0.title) }
            guard natural.reduce(0, +) > avail else { return "the test titles should overflow (\(natural.reduce(0, +)) ≤ \(avail))" }
            let longs = w.enumerated().filter { natural[$0.offset] > w[$0.offset] }.map(\.element)
            return all(w.reduce(0, +) <= avail + 0.5 ? nil : "row \(w.reduce(0, +)) overflows \(avail)",
                       w[0] == natural[0] && w[1] == natural[1] ? nil : "short tabs were shrunk: \(w.prefix(2)) vs \(natural.prefix(2))",
                       !longs.isEmpty && Set(longs).count == 1 ? nil : "shrunk tabs should share one width: \(w)",
                       (longs.first ?? 0) >= minW ? nil : "shrunk below the minimum",
                       (deck.view.strip.addButton.frame.maxX <= deck.view.strip.bounds.maxX + 0.5) ? nil : "\"+\" fell off the strip",
                       contiguous())
        }) {
            writeSettings("")
            titles(["1", "zsh"] + (1...10).map { "~/git/project-\($0) — long running build" })
        }

        t.step("tab fit: titlebar tabs follow the same rules, drag zones kept", nil, {
            guard let deck else { return "no deck" }
            let s = deck.view.strip, w = widths()
            guard s.isInTitlebar else { return "the strip should be in the titlebar" }
            let problems: [String?] = [
                w == ["1", "zsh", "make"].map { max(text($0) + TabButton.chromeWidth, minW) } ? nil : "titlebar widths \(w)",
                contiguous(),
            ] + s.buttons.map { b in
                let top = b.convert(CGPoint(x: b.titleRect.midX, y: b.bounds.height * 0.2), to: nil)
                let bottom = b.convert(CGPoint(x: b.titleRect.midX, y: b.bounds.height * 0.8), to: nil)
                let x = b.convert(CGPoint(x: b.closeRect.midX, y: b.closeRect.minY + 1), to: nil)
                return b.titlebarZone(at: top) == .window && b.titlebarZone(at: bottom) == .tab && b.titlebarZone(at: x) == .tab
                    ? nil : "\"\(b.title)\": zones top/bottom/× are wrong"
            }
            return problems.compactMap { $0 }.first
        }) {
            while (deck?.tabs.count ?? 0) > 3, let d = deck, let last = d.tabs.last { self.close(tab: last) }
            writeSettings("[window]\ntabs_in_titlebar = true\n")
            titles(["1", "zsh", "make"])
        }

        t.step("tab fit: clean up", nil, {
            all(self.workspaces.contains { $0.name == "tabfit" } ? "the test workspace should be gone" : nil,
                Settings.tabsInTitlebar ? nil : "titlebar tabs should be back to the default (on)")
        }) {
            try? FileManager.default.removeItem(at: Settings.fileURL)
            Settings.reload()
            if let ws { self.remove(workspace: ws) }
            ws = nil
            self.layoutNow()
        }
    }
}
