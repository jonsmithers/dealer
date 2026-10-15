import AppKit
import GhosttyKit

// MARK: - Self-test section: background-opacity, background-blur (#67, WindowTransparency.swift)

extension TerminalWindowController {
    /// ghostty's `background-opacity` / `background-blur` from a temp config (through
    /// `GhosttyRuntime.configFileOverride` and ⌘⇧,'s reload path): the `Theme.transparency` read,
    /// the window's opacity and background, the chrome drawn at the background's alpha around holes
    /// for the deck cards (PixelProbe on chrome views; terminals are Metal), and the way back to
    /// opaque rendering byte for byte as before. The blur itself is the window server's:
    /// screenshots only.
    /// Self-contained (`DEALER_SELFTEST_ONLY=transparency:`); restores the launch config.
    func transparencySelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dealer-selftest-transparency-\(getpid())", isDirectory: true)
        let file = dir.appendingPathComponent("config")
        // Catppuccin Frappé's background and foreground, set directly (no theme lookup).
        let colors = "background = #303446\nforeground = #c6d0f5\n"
        func load(_ extra: String) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? (colors + extra).write(to: file, atomically: true, encoding: .utf8)
            GhosttyRuntime.configFileOverride = file.path
            GhosttyRuntime.shared.reloadConfig()
            layoutNow()
        }
        func hex(_ c: NSColor?) -> String {
            guard let c = c?.usingColorSpace(.sRGB) else { return "nil" }
            return c.hexString + String(format: "@%.2f", c.alphaComponent)
        }
        /// Same color and alpha within the probe's tolerance (alpha gets one more step: 8-bit storage).
        func same(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let x = a?.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
            if y.alphaComponent < 0.01 { return x.alphaComponent < 0.01 }
            return PixelProbe.matches(x.withAlphaComponent(1), y.withAlphaComponent(1), tolerance: PixelProbe.tolerance * 2)
                && abs(x.alphaComponent - y.alphaComponent) <= PixelProbe.tolerance * 1.5
        }
        func expect(_ what: String, _ got: NSColor?, _ want: NSColor) -> String? {
            same(got, want) ? nil : "\(what) \(hex(got)) ≠ \(hex(want))"
        }

        var tab: Tab?
        func paneA() -> Pane { t.pane("tpA") }
        func paneB() -> Pane { t.pane("tpB") }
        func deckView() -> DeckView? { tab.flatMap { self.deck(of: $0) }?.view }
        func activeRow() -> WorkspaceRow? {
            (0..<workspaces.count).compactMap { self.workspaceSidebar.row(at: $0) as? WorkspaceRow }.first { $0.isActive }
        }
        func paneDividers() -> [DividerView] { deckView()?.content.subviews.compactMap { $0 as? DividerView } ?? [] }
        func gapLayer(_ d: DividerView) -> CALayer? { d.layer?.sublayers?.first { $0.name == "dealer.gapFill" } }

        /// The chrome a translucent window shows, at alpha `a` (1 = today's opaque colors), sampled
        /// where nothing else draws: the active tab, the strip past its "+", the sidebar row, the
        /// pane bar's right end, the 1pt gap between the two panes.
        func chromePixels(alpha a: CGFloat) -> String? {
            guard let dv = deckView() else { return "test tab is gone" }
            func at(_ c: NSColor) -> NSColor { c.withAlphaComponent(c.alphaComponent * a) }
            var p: [String?] = []
            if let b = dv.strip.buttons.first(where: { $0.isActive }) {
                p.append(expect("active tab", PixelProbe.sample(b, at: CGPoint(x: 4, y: b.bounds.midY)), at(Theme.surface)))
            } else { p.append("no active tab button") }
            let past = dv.strip.convert(CGPoint(x: dv.strip.addButton.frame.maxX + 12, y: dv.strip.bounds.midY), to: contentView)
            p.append(expect("strip chrome", PixelProbe.sample(contentView, at: past), at(Theme.chrome)))
            if let row = activeRow() {
                p.append(expect("sidebar row", PixelProbe.sample(row, at: CGPoint(x: row.bounds.maxX - 4, y: row.bounds.midY)), at(Theme.workspaceSelection)))
            } else { p.append("no active sidebar row") }
            let bar = paneA().view.bar
            p.append(expect("pane bar", PixelProbe.sample(bar, at: CGPoint(x: bar.bounds.maxX - 3, y: bar.bounds.midY)), at(Theme.paneBar)))
            let gapX = paneA().view.frame.maxX + 0.5
            p.append(expect("pane gap", PixelProbe.sample(dv.content, at: CGPoint(x: gapX, y: paneA().view.frame.midY)), at(Theme.divider)))
            return all(p.compactMap { $0 }.isEmpty ? nil : p.compactMap { $0 }.joined(separator: "; "))
        }
        /// Inside the deck card the window draws nothing under a terminal: the chrome fill has a hole
        /// at a pane's centre. (The content view itself can't be sampled there: a live surface's
        /// layer may or may not show up offscreen.)
        func cardIsHole() -> String? {
            let b = paneB().view, fill = contentView.backdrop.chrome
            let centre = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: fill)
            let c = PixelProbe.sample(fill, at: centre)
            return (c?.alphaComponent ?? 1) < 0.02 ? nil : "under a terminal the window should draw nothing, got \(hex(c))"
        }
        func windowIs(opaque: Bool) -> String? {
            guard let w = window else { return "no window" }
            if opaque {
                return all(w.isOpaque ? nil : "the window should be opaque",
                           expect("window background", w.backgroundColor, Theme.chrome),
                           contentView.backdrop.isHidden ? nil : "the backdrop should be hidden",
                           contentView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map { same($0, Theme.chrome) } == true
                               ? nil : "the content view should be filled with the chrome color",
                           deckView()?.content.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map { same($0, Theme.divider) } == true
                               ? nil : "the deck card should show the divider color",
                           paneB().view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map { same($0, Theme.background) } == true
                               ? nil : "a pane should be backed by the terminal background",
                           paneDividers().contains { gapLayer($0).map { !$0.isHidden } ?? false } ? "no pane divider should paint its gap" : nil)
            }
            return all(w.isOpaque ? "the window should be non-opaque" : nil,
                       w.backgroundColor.alphaComponent <= 0.01 ? nil : "the window background should be (almost) clear, got \(hex(w.backgroundColor))",
                       contentView.backdrop.isHidden ? "the backdrop should show" : nil,
                       contentView.layer?.backgroundColor == nil ? nil : "the content view should have no fill of its own",
                       deckView()?.content.layer?.backgroundColor == nil ? nil : "the deck card should be clear",
                       paneB().view.layer?.backgroundColor == nil ? nil : "a pane should have no background of its own",
                       contentView.backdrop.chrome.holes.count == decks.count ? nil
                           : "one hole per deck card expected, got \(contentView.backdrop.chrome.holes.count) for \(decks.count)",
                       paneDividers().isEmpty ? "the split should have a divider" : nil,
                       paneDividers().allSatisfy { gapLayer($0).map { !$0.isHidden } ?? false } ? nil : "every pane divider should paint its gap")
        }
        func blurRadius() -> Int? { window.flatMap { WindowBlur.lastRadius[$0.windowNumber] } }
        func read(_ want: Transparency) -> String? {
            Theme.transparency == want ? nil : "Theme.transparency should be \(want), got \(Theme.transparency)"
        }

        var opaqueBytes: [Data?] = []
        func chromeBytes() -> [Data?] {
            guard let dv = deckView() else { return [] }
            return [PixelProbe.pixels(dv.strip), activeRow().flatMap { PixelProbe.pixels($0) }, PixelProbe.pixels(paneA().view.bar)]
        }

        t.step("transparency: without background-opacity the window stays opaque, chrome as before", nil, {
            all(read(Transparency()), windowIs(opaque: true), chromePixels(alpha: 1),
                { let c = Theme.chrome; return Theme.fill(c) === c }() ? nil : "Theme.fill must hand back the color itself when opaque")
        }) {
            load("")
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "tpA")
            tab = deck.activeTab
            self.split(paneA(), side: .right)
            t.named(self.focusedPane, "tpB")
            self.sidebarPreference = true
            self.layoutNow()
            opaqueBytes = chromeBytes()
        }
        t.step("transparency: background-opacity = 0.85 makes the window translucent, chrome at 0.85", nil, {
            all(read(Transparency(opacity: 0.85, blur: .off)), windowIs(opaque: false), chromePixels(alpha: 0.85), cardIsHole())
        }) {
            load("background-opacity = 0.85\n")
        }
        t.step("transparency: text and the attention outline stay opaque over translucent chrome", nil, {
            guard let b = deckView()?.strip.buttons.first(where: { $0.isActive }) else { return "no active tab" }
            let edge = PixelProbe.sample(b, at: PixelProbe.outlinePoint(in: b))
            return all(edge.map { $0.alphaComponent > 0.99 } == true ? nil : "the outline should be opaque, got \(hex(edge))",
                       PixelProbe.isWaitingOutlined(b) ? nil : "the tab should read as waiting-outlined")
        }) {
            self.setAttention(.waiting, on: paneA())
            self.refreshChrome()
        }
        t.step("transparency: background-blur = 20 and = true read as radius blurs", nil, {
            read(Transparency(opacity: 0.85, blur: .radius(20)))
        }) {
            self.setAttention(.none, on: paneA())
            load("background-opacity = 0.85\nbackground-blur = 20\n")
        }
        t.step("transparency: background-blur = true is ghostty's radius 20; = 7 is 7", nil, {
            let t7 = Theme.transparency
            load("background-opacity = 0.85\nbackground-blur = true\n")
            return all(t7 == Transparency(opacity: 0.85, blur: .radius(7)) ? nil : "blur 7 read as \(t7)",
                       read(Transparency(opacity: 0.85, blur: .radius(20))), windowIs(opaque: false))
        }) {
            load("background-opacity = 0.85\nbackground-blur = 7\n")
        }
        t.step("transparency: the glass styles get a radius-20 blur for now, the window translucent", nil, {
            all(read(Transparency(opacity: 0.85, blur: .glassRegular)), windowIs(opaque: false), chromePixels(alpha: 0.85), cardIsHole(),
                blurRadius() == Transparency.glassFallbackRadius ? nil : "the blur radius should be \(Transparency.glassFallbackRadius), got \(blurRadius().map(String.init) ?? "none")")
        }) {
            load("background-opacity = 0.85\nbackground-blur = macos-glass-regular\n")
        }
        t.step("transparency: reloading back to no opacity renders as before, byte for byte", nil, {
            let now = chromeBytes()
            return all(read(Transparency()), windowIs(opaque: true), chromePixels(alpha: 1),
                       now.count == 3 && !now.contains(nil) && now == opaqueBytes ? nil : "the strip, sidebar row and pane bar should render exactly as before")
        }) {
            load("")
        }
        t.step("transparency: clean up (back to the launch config)", nil, {
            tab.flatMap { self.deck(of: $0) } == nil ? nil : "test tab should be closed"
        }) {
            if let tab { self.close(tab: tab) }
            self.sidebarPreference = nil
            GhosttyRuntime.configFileOverride = nil
            try? fm.removeItem(at: dir)
            GhosttyRuntime.shared.reloadConfig()
            self.layoutNow()
        }
    }
}
