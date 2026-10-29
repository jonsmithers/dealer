import AppKit

// MARK: - Self-test section: connected vs pill tabs (#84, TabShape.swift)
//
// `[tabs] style` parses and switches live; a connected active tab covers its card's top border (no
// seam) and sits on square card corners, in a deck and in the titlebar; its attention outline is
// open at the bottom; the overlap row belongs to the pane outside the active tab. Each pixel check
// also runs in pill mode, where it must come out the other way, so it can't pass vacuously.
// #86: with several decks a connected active tab underlines in its deck's accent (or its own
// `Tab.color`) along its bottom edge, over the overlap row, in a deck and in the titlebar, also
// under a waiting outline and on a translucent window.
// Self-contained (`DEALER_SELFTEST_ONLY=tab style:`); restores the default settings and config.

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
        func hex(_ c: NSColor?) -> String {
            guard let c = c?.usingColorSpace(.sRGB) else { return "nil" }
            return c.hexString + (c.alphaComponent < 1 ? String(format: "@%.2f", c.alphaComponent) : "")
        }
        let red = NSColor(hex: "#d03040") ?? .systemRed
        /// A ghostty config of the section's own, for the translucent steps (as SelfTestTransparency).
        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("dealer-selftest-tabstyle-\(getpid())", isDirectory: true)
        func loadConfig(_ text: String?) {
            if let text {
                let file = configDir.appendingPathComponent("config")
                try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
                GhosttyRuntime.configFileOverride = file.path
            } else {
                GhosttyRuntime.configFileOverride = nil
                try? FileManager.default.removeItem(at: configDir)
            }
            GhosttyRuntime.shared.reloadConfig()
            layoutNow()
            refreshChrome()
        }

        /// Where the underline sits: the bottom of the tab's body (the overlap row included when
        /// connected and active), 2pt tall.
        func placement(_ b: TabButton, _ connected: Bool) -> String? {
            let want = connected ? b.bounds.maxY : b.bodyHeight
            return b.underlineRect.maxY == want && b.underlineRect.height == 2 ? nil
                : "the underline \(b.underlineRect) should end at \(want) (bounds \(b.bounds), connected \(connected))"
        }
        /// #86: the active tab's underline in `want`, at its body's bottom: for a connected tab that is
        /// the overlap row over the card's border, so the line meets the terminal. `onCard` samples
        /// that row in the view the strip sits on (the deck view, or the content view in the titlebar).
        /// Above the 2pt line the tab is its fill again (`above`, after any tint), so it's a line.
        func underline(_ want: NSColor, above: NSColor? = nil) -> String? {
            guard let d = deck(), let b = active() else { return "no test deck" }
            let s = d.view.strip
            guard let host = s.superview else { return "the strip has no superview" }
            let connected = b.style == .connected
            let problems = PixelProbe.atEachScale { _ in
                let u = b.underlineRect
                let mid = PixelProbe.sample(b, at: CGPoint(x: u.midX, y: u.midY))
                let row = PixelProbe.sample(host, at: b.convert(CGPoint(x: u.midX, y: b.bounds.maxY - 0.25), to: host))
                let over = PixelProbe.sample(b, at: CGPoint(x: u.midX, y: u.minY - 1.5))
                return [
                    PixelProbe.matches(mid, want) ? nil : "the underline is \(hex(mid)), want \(hex(want))",
                    !connected || PixelProbe.matches(row, want) ? nil
                        : "the overlap row under the tab is \(hex(row)), want the underline's \(hex(want)) down to the terminal",
                    above.map { PixelProbe.matches(over, $0) } ?? true ? nil : "above the 2pt underline is \(hex(over)), want \(hex(above))",
                ].compactMap { $0 }
            }
            return all([placement(b, connected), problems.isEmpty ? nil : problems.joined(separator: "; ")])
        }

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
                // Left of the underline (#86), which covers this row under the middle of the tab.
                let seam = PixelProbe.sample(dv, at: CGPoint(x: tab.minX + 5, y: top + 0.25))
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
        t.step("tab style: connected in a deck: the active tab's deck accent underline runs along its bottom edge, over the card's border row; a pill's sits in the pill (#86)", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            guard self.decks.count >= 2, b.color == nil, let acc = b.accent, acc.hexString == d.color.hexString else {
                return "with two decks the uncolored tab should carry its deck's accent \(hex(d.color)), got \(hex(b.accent)) (\(self.decks.count) decks)"
            }
            let connected = underline(acc, above: Theme.surface)
            set(.pill, titlebar: false)
            let pill = underline(acc)
            // A pill doesn't reach the card: its border row under the tab isn't the accent.
            let row = active().flatMap { pb -> NSColor? in
                let x = pb.convert(CGPoint(x: pb.underlineRect.midX, y: 0), to: d.view).x
                return PixelProbe.sample(d.view, at: CGPoint(x: x, y: d.view.content.frame.minY + 0.25))
            }
            set(.connected, titlebar: false)
            return all([connected, pill.map { "pill: " + $0 },
                        PixelProbe.matches(row, acc) ? "a pill tab's underline shouldn't reach the card's border row" : nil])
        }) {
            self.split(t.pane("ts2"), side: .right)
            t.named(self.focusedPane, "ts3")
            _ = self.promote(self.locate(t.pane("ts3"))!.node, side: .right)
            self.focus(t.pane("ts2"))
            self.layoutNow()
            self.refreshChrome()
        }
        t.step("tab style: a waiting outline neither hides nor doubles a connected tab's underline (#86)", nil, {
            guard let b = active(), let acc = b.accent else { return "no active tab with an accent" }
            // The outline's 10% tint lies over the whole tab, the line included; its stroke leaves
            // the bottom open, so nothing else is drawn on or next to the underline.
            let tint = Theme.attentionWaiting
            return all([PixelProbe.isWaitingOutlined(b) ? nil : "the tab should be waiting-outlined",
                        underline(acc.mixed(with: tint, 0.10), above: Theme.surface.mixed(with: tint, 0.10))])
        }) {
            self.setAttention(.waiting, on: t.pane("ts2"))
            self.refreshChrome()
        }
        t.step("tab style: a tab color overrides the deck accent in a connected tab's underline (#86)", nil, {
            guard let b = active() else { return "no active tab" }
            return all([b.color?.hexString == red.hexString && b.accent != nil ? nil : "the tab should have its color and a deck accent",
                        underline(red)])
        }) {
            self.setAttention(.none, on: t.pane("ts2"))
            if let tab = self.locate(t.pane("ts2"))?.tab { self.setColor(red, tab: tab) }
            self.refreshChrome()
        }
        t.step("tab style: on a translucent window the underline stays opaque on a connected tab that matches its terminal (#86)", nil, {
            guard let b = active(), let acc = b.accent else { return "no active tab with an accent" }
            let fill = TabButton.connectedFill
            let translucent = all([Theme.transparency.isTranslucent && TabStyle.connectedMatchesTerminal && fill.alphaComponent < 1 ? nil
                                       : "the connected tab's fill should be translucent, got \(hex(fill))",
                                   underline(acc)])
            loadConfig("background-opacity = 0.85\nbackground-blur = macos-glass-regular\n")
            let glass = all([TabButton.connectedFill.alphaComponent < 0.01 ? nil : "under glass the tab's fill should be clear",
                             underline(acc)])
            return all([translucent, glass.map { "glass: " + $0 }])
        }) {
            if let tab = self.locate(t.pane("ts2"))?.tab { self.setColor(nil, tab: tab) }
            loadConfig("background-opacity = 0.85\n")
        }
        t.step("tab style: connected in the titlebar: the active tab covers the card's border row, the rest of that row stays clear", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            let s = d.view.strip
            guard d.view.stripInTitlebar, s.superview === self.contentView else { return "the strip should be in the titlebar" }
            let subs = self.contentView.subviews
            let problems = PixelProbe.atEachScale { _ in
                let y = s.bounds.maxY - 0.25
                let under = PixelProbe.sample(s, at: CGPoint(x: b.frame.minX + 5, y: y))  // left of the underline
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
            loadConfig(nil)
            set(.connected, titlebar: true)
        }
        t.step("tab style: connected in the titlebar: the deck accent underline runs along the active tab's bottom edge into the card (#86)", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            guard d.view.stripInTitlebar, let acc = b.accent else { return "the strip should be in the titlebar, with a deck accent" }
            return all([Theme.transparency.isTranslucent ? "the window should be opaque again" : nil,
                        underline(acc, above: Theme.surface)])
        }) {}
        t.step("tab style: a tab color overrides the deck accent in a connected titlebar tab's underline (#86)", nil, {
            guard let d = deck(), let b = active() else { return "no test deck" }
            return all([d.view.stripInTitlebar ? nil : "the strip should be in the titlebar", b.accent != nil ? nil : "the tab should have a deck accent",
                        underline(red)])
        }) {
            if let tab = self.locate(t.pane("ts2"))?.tab { self.setColor(red, tab: tab) }
            self.refreshChrome()
        }
        t.step("tab style: pill in the titlebar: the strip fills only the row, and the card keeps its corners", nil, {
            guard let d = deck() else { return "no test deck" }
            let s = d.view.strip
            return all([d.view.stripInTitlebar ? nil : "the strip should be in the titlebar",
                        abs(s.frame.maxY - d.view.frame.minY) < 0.5 ? nil : "a pill strip \(s.frame) should end at its deck \(d.view.frame)",
                        !d.view.squareTop ? nil : "the card should keep rounded top corners",
                        active()?.accent.map { underline($0).map { "pill: " + $0 } } ?? "the pill tab should have a deck accent"])
        }) {
            if let tab = self.locate(t.pane("ts2"))?.tab { self.setColor(nil, tab: tab) }
            set(.pill, titlebar: true)
        }
        t.step("tab style: clean up (default settings)", nil, {
            all([self.locate(t.pane("ts2")) == nil && self.locate(t.pane("ts3")) == nil ? nil : "ts2 and ts3 should be closed",
                 Settings.tabStyle == .connected && Settings.tabsInTitlebar ? nil : "settings should be back to the defaults",
                 GhosttyRuntime.configFileOverride == nil ? nil : "the launch config should be back"])
        }) {
            self.remove(t.pane("ts2"))
            self.remove(t.pane("ts3"))
            if GhosttyRuntime.configFileOverride != nil { loadConfig(nil) }
            write("")
        }
    }
}

extension TerminalWindowController {
    /// #86: a one-deck window's active tab underlines in its deck's color too, connected (at its
    /// bottom edge) and pill (at the pill's bottom), wherever the strip sits. Called from the
    /// walkthrough while it has one deck; puts the settings file back as it found it.
    func singleDeckUnderlineProblem() -> String? {
        guard decks.count == 1, let d = decks.first else { return "expected one deck, got \(decks.count)" }
        let url = Settings.fileURL
        let saved = try? String(contentsOf: url, encoding: .utf8)
        if saved?.contains("[tabs]") == true { return "the settings file already has a [tabs] table" }
        func apply(_ text: String?) {
            if let text {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            Settings.reload()
            layoutNow()
            refreshChrome()
        }
        defer { apply(saved) }
        var problems: [String] = []
        for style in [TabStyle.connected, .pill] {
            apply((saved ?? "") + "\n[tabs]\nstyle = \"\(style.rawValue)\"\n")
            let buttons = d.view.strip.buttons
            guard buttons.indices.contains(d.activeIndex) else { problems.append("\(style): no active tab button"); continue }
            let b = buttons[d.activeIndex]
            guard b.style == style, b.color == nil else { problems.append("\(style): the button should be \(style) and uncolored"); continue }
            let bottom = style == .connected ? b.bounds.maxY : b.bodyHeight
            if b.underlineRect.maxY != bottom { problems.append("\(style): the underline \(b.underlineRect) should end at \(bottom)") }
            problems += PixelProbe.atEachScale { _ in
                let px = PixelProbe.sample(b, at: CGPoint(x: b.underlineRect.midX, y: b.underlineRect.midY))
                return PixelProbe.matches(px, d.color) ? []
                    : ["\(style): the underline is \(px?.hexString ?? "nil"), want the deck's \(d.color.hexString) (accent \(b.accent?.hexString ?? "nil"))"]
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }
}
