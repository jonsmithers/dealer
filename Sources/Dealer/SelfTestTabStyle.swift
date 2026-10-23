import AppKit

// MARK: - Self-test section: connected vs pill tabs (#84, TabShape.swift)
//
// `[tabs] style` parses and switches live; a connected active tab covers its card's top border (no
// seam) and sits on square card corners, in a deck and in the titlebar; its attention outline is
// open at the bottom; the overlap row belongs to the pane outside the active tab. Each pixel check
// also runs in pill mode, where it must come out the other way, so it can't pass vacuously.
// Self-contained (`DEALER_SELFTEST_ONLY=tab style:`); restores the default settings.

extension TerminalWindowController {
    func tabStyleSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: [String?]) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func write(_ text: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            layoutNow()
            refreshChrome()
        }
        func set(_ style: TabStyle?, titlebar: Bool) {
            write("[window]\ntabs_in_titlebar = \(titlebar)\n" + (style.map { "[tabs]\nstyle = \"\($0.rawValue)\"\n" } ?? ""))
        }
        func deck() -> Deck? { locate(t.pane("ts2")).map(\.deck) }
        func active() -> TabButton? {
            guard let d = deck() else { return nil }
            let b = d.view.strip.buttons
            return b.indices.contains(d.activeIndex) ? b[d.activeIndex] : nil
        }
        func hex(_ c: NSColor?) -> String { c?.hexString ?? "nil" }

        /// In a deck: the card's top border row under the active tab is the tab's fill when
        /// connected (no seam), the border when pill. The card's corners are checked on its layer:
        /// PixelProbe's offscreen render (`cacheDisplay`) rounds every corner of a `cornerRadius`
        /// layer and ignores `maskedCorners`, which the window server honors (see #84's screenshots).
        func inDeckLook(_ style: TabStyle) -> String? {
            guard let d = deck(), let b = active() else { return "no test deck" }
            let dv = d.view
            guard !dv.stripInTitlebar, dv.strip.superview === dv else { return "the strip should be in its deck" }
            let problems = PixelProbe.atEachScale { _ in
                let tab = b.convert(b.bounds, to: dv), top = dv.content.frame.minY
                let seam = PixelProbe.sample(dv, at: CGPoint(x: tab.midX, y: top + 0.25))
                let connected = style == .connected
                return [
                    PixelProbe.matches(seam, Theme.surface) == connected ? nil
                        : connected ? "a seam under the active tab: \(hex(seam)), want the tab's fill \(hex(Theme.surface))"
                        : "a pill tab shouldn't cover the card's border (\(hex(seam)))",
                    dv.content.layer?.maskedCorners == (connected ? DeckView.bottomCorners : DeckView.allCorners) ? nil
                        : "the card should round \(connected ? "only its bottom corners" : "all four corners")",
                ].compactMap { $0 }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }

        var defaultStyle: TabStyle?
        t.step("tab style: [tabs] style defaults to connected and reports a bad value", nil, {
            all([defaultStyle == .connected ? nil : "the default should be connected, got \(defaultStyle.map(\.rawValue) ?? "nil")",
                 Settings.tabStyle == .connected ? nil : "a bad value should read as the default",
                 Settings.problems.contains { $0.contains("tabs.style") } ? nil : "a bad style should be reported",
                 deck()?.view.strip.style == .connected ? nil : "a bad value should fall back to connected"])
        }) {
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "ts2")
            set(nil, titlebar: false)
            defaultStyle = Settings.tabStyle
            write("[window]\ntabs_in_titlebar = false\n[tabs]\nstyle = \"square\"\n")
        }
        t.step("tab style: switching to pill restyles open strips live, with the card's corners", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            return all([Settings.tabStyle == .pill ? nil : "style should read pill",
                        d.view.strip.style == .pill && b.style == .pill ? nil : "the strip and its buttons should be pill",
                        !d.view.squareTop ? nil : "a pill deck's card should keep its top corners",
                        b.frame.height == Theme.Metrics.tabHeight ? nil : "a pill tab should be \(Theme.Metrics.tabHeight)pt tall, got \(b.frame.height)",
                        d.view.strip.frame.height == DeckView.stripHeight ? nil : "a pill strip should be the row's height"])
        }) {
            set(.pill, titlebar: false)
        }
        t.step("tab style: pill in a deck: the card's border shows under the active tab, its corners are rounded", nil, {
            inDeckLook(.pill)
        }) {}
        t.step("tab style: connected in a deck: no seam under the active tab, square card corners", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            return all([d.view.squareTop ? nil : "the card's top corners should be square",
                        b.frame.maxY == d.view.strip.bounds.maxY ? nil : "a connected tab should run to the strip's bottom",
                        d.view.strip.frame.maxY == d.view.content.frame.minY + 1 ? nil : "the strip should reach 1pt over the card",
                        inDeckLook(.connected)])
        }) {
            set(.connected, titlebar: false)
        }
        t.step("tab style: a connected tab's waiting outline is open at the bottom; a pill's is closed", nil, {
            guard let b = active() else { return "no active tab" }
            func bottomOutlined() -> Bool {
                PixelProbe.matches(PixelProbe.sample(b, at: CGPoint(x: b.bounds.midX, y: b.bodyRect.maxY - AttentionStyle.outlineWidth / 2)),
                                   Theme.attentionWaiting)
            }
            let connected = (PixelProbe.isWaitingOutlined(b), bottomOutlined())
            set(.pill, titlebar: false)
            let pill = (PixelProbe.isWaitingOutlined(b), bottomOutlined())
            set(.connected, titlebar: false)
            return all([connected.0 ? nil : "the connected tab should be waiting-outlined at the top",
                        !connected.1 ? nil : "the connected tab's outline should leave the bottom open",
                        pill.0 && pill.1 ? nil : "a pill's outline should be closed (top \(pill.0), bottom \(pill.1))"])
        }) {
            self.setAttention(.waiting, on: t.pane("ts2"))
            self.refreshChrome()
        }
        t.step("tab style: the overlap row hits the pane, except under the active tab", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            let s = d.view.strip, y = s.bounds.maxY - 0.5
            let under = s.convert(CGPoint(x: b.frame.midX, y: y), to: s.superview)
            let past = s.convert(CGPoint(x: s.addButton.frame.maxX + 12, y: y), to: s.superview)
            let above = s.convert(CGPoint(x: s.addButton.frame.maxX + 12, y: s.bounds.midY), to: s.superview)
            return all([s.hitTest(under) === b ? nil : "the overlap under the active tab should hit it",
                        s.hitTest(past) == nil ? nil : "the overlap past the tabs should fall through to the pane",
                        s.hitTest(above) === s ? nil : "the strip row itself should still hit the strip"])
        }) {
            self.setAttention(.none, on: t.pane("ts2"))
            self.refreshChrome()
        }
        t.step("tab style: connected in the titlebar: the active tab covers the card's border row, the rest of that row stays clear", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            let s = d.view.strip
            guard d.view.stripInTitlebar, s.superview === self.contentView else { return "the strip should be in the titlebar" }
            let subs = self.contentView.subviews
            let problems = PixelProbe.atEachScale { _ in
                let y = s.bounds.maxY - 0.25
                let under = PixelProbe.sample(s, at: CGPoint(x: b.frame.midX, y: y))
                let past = PixelProbe.sample(s, at: CGPoint(x: s.addButton.frame.maxX + 12, y: y))
                return [PixelProbe.matches(under, Theme.surface) ? nil : "the overlap under the active tab is \(hex(under)), want \(hex(Theme.surface))",
                        (past?.alphaComponent ?? 1) < 0.02 ? nil : "the strip should draw nothing over the card past its tabs, got \(hex(past))"]
                    .compactMap { $0 }
            }
            return all([abs(s.frame.maxY - (d.view.frame.minY + 1)) < 0.5 ? nil : "the strip \(s.frame) should reach 1pt over its deck \(d.view.frame)",
                        d.view.squareTop ? nil : "the card's top corners should be square",
                        (subs.firstIndex(of: s) ?? -1) > (subs.firstIndex(of: d.view) ?? Int.max) ? nil : "the strip should sit above its deck view",
                        problems.isEmpty ? nil : problems.joined(separator: "; ")])
        }) {
            set(.connected, titlebar: true)
        }
        t.step("tab style: pill in the titlebar: the strip fills only the row, and the card keeps its corners", nil, {
            guard let d = deck() else { return "no test deck" }
            let s = d.view.strip
            return all([d.view.stripInTitlebar ? nil : "the strip should be in the titlebar",
                        abs(s.frame.maxY - d.view.frame.minY) < 0.5 ? nil : "a pill strip \(s.frame) should end at its deck \(d.view.frame)",
                        !d.view.squareTop ? nil : "the card should keep rounded top corners"])
        }) {
            set(.pill, titlebar: true)
        }
        t.step("tab style: clean up (default settings)", nil, {
            all([self.locate(t.pane("ts2")) == nil ? nil : "ts2 should be closed",
                 Settings.tabStyle == .connected && Settings.tabsInTitlebar ? nil : "settings should be back to the defaults"])
        }) {
            self.remove(t.pane("ts2"))
            write("")
        }
    }
}
