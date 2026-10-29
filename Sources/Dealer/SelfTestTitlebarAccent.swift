import AppKit

// MARK: - Self-test section: titlebar tab strips keep the per-deck accent underline (issue #59)

extension TerminalWindowController {
    func titlebarAccentSelfTestSteps(_ t: SelfTestKit) {
        /// The accent shows on pill tabs, and on connected ones (#84, the default) along the active
        /// tab's bottom edge (#86).
        func setTabsInTitlebar(_ on: Bool, style: TabStyle? = nil) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tabs = style.map { "[tabs]\nstyle = \"\($0.rawValue)\"\n" } ?? ""
            try? "[window]\ntabs_in_titlebar = \(on)\n\(tabs)".write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            self.layoutNow()
        }
        func activeButton(_ d: Deck) -> TabButton? {
            let b = d.view.strip.buttons
            return b.indices.contains(d.activeIndex) ? b[d.activeIndex] : nil
        }

        t.step("titlebar accent: with several decks, an uncolored active pill tab in a titlebar strip underlines in its deck's color, at 2x and 1x", nil, {
            let up = self.decks.filter { $0.view.stripInTitlebar && $0.view.strip.superview === self.contentView }
            guard up.count >= 2 else { return "expected two decks with titlebar strips, got \(up.count)" }
            let problems = PixelProbe.atEachScale { _ in
                up.compactMap { d -> String? in
                    guard let b = activeButton(d) else { return "a titlebar strip has no active tab button" }
                    if b.color != nil { return "the test tab shouldn't have a tab color" }
                    let px = PixelProbe.sample(b, at: CGPoint(x: b.underlineRect.midX, y: b.underlineRect.midY))
                    return PixelProbe.matches(px, d.color) ? nil
                        : "underline is \(px?.hexString ?? "nil"), want the deck's \(d.color.hexString) (accent \(b.accent?.hexString ?? "nil"))"
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {
            setTabsInTitlebar(true, style: .pill)
            self.newTab(nil)
            t.named(self.focusedPane, "ta2")
            _ = self.promote(self.locate(t.pane("ta2"))!.node, side: .right, allowWholeDeck: true)
            self.layoutNow()
            self.refreshChrome()  // reloads the strips after they moved into the titlebar
        }
        t.step("titlebar accent: a connected active tab underlines in its deck's color along its bottom edge, where it meets the card (#86), at 2x and 1x", nil, {
            let up = self.decks.filter { $0.view.stripInTitlebar && $0.view.strip.superview === self.contentView }
            guard up.count >= 2 else { return "expected two decks with titlebar strips, got \(up.count)" }
            let problems = PixelProbe.atEachScale { _ in
                up.compactMap { d -> String? in
                    guard let b = activeButton(d) else { return "a titlebar strip has no active tab button" }
                    guard b.style == .connected, b.accent != nil, b.color == nil else { return "the tab should be connected, uncolored, with an accent" }
                    let px = PixelProbe.sample(b, at: CGPoint(x: b.underlineRect.midX, y: b.underlineRect.midY))
                    let edge = PixelProbe.sample(b, at: CGPoint(x: b.underlineRect.midX, y: b.bounds.maxY - 0.25))
                    let p = [PixelProbe.matches(px, d.color) ? nil
                                : "underline is \(px?.hexString ?? "nil"), want the deck's \(d.color.hexString)",
                            PixelProbe.matches(edge, d.color) ? nil
                                : "the tab's bottom edge (the overlap row) is \(edge?.hexString ?? "nil"), want the deck's \(d.color.hexString)"]
                        .compactMap { $0 }
                    return p.isEmpty ? nil : p.joined(separator: ", ")
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {
            setTabsInTitlebar(true)
            self.refreshChrome()
        }
        t.step("titlebar accent: clean up", nil, {
            !Settings.tabsInTitlebar && self.locate(t.pane("ta2")) == nil ? nil : "titlebar tabs should be off and ta2 gone"
        }) {
            self.remove(t.pane("ta2"))
            setTabsInTitlebar(false)
        }
    }
}
