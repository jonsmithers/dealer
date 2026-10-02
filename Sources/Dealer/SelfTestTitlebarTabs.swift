import AppKit
import GhosttyKit

// MARK: - Self-test section: tab strips in the titlebar (issue #16)

extension TerminalWindowController {
    func titlebarTabsSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func setTabsInTitlebar(_ on: Bool) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[window]\ntabs_in_titlebar = \(on)\n".write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            self.layoutNow()
        }
        func deck(_ pane: String) -> Deck { locate(t.pane(pane))!.deck }
        func up(_ pane: String) -> Bool { let d = deck(pane); return d.view.stripInTitlebar && d.view.strip.superview === contentView }
        func inDeck(_ pane: String) -> Bool { let d = deck(pane); return !d.view.stripInTitlebar && d.view.strip.superview === d.view }
        /// Aligned: the titlebar strip ends where its deck ends and starts at the deck or the clear line.
        func aligned(_ pane: String) -> String? {
            let d = deck(pane), s = d.view.strip.frame, r = d.view.frame
            let ok = abs(s.maxX - r.maxX) < 0.5 && abs(s.minX - max(r.minX, self.titlebarClearX)) < 0.5
                && s.minY == 0 && abs(s.height - self.deckArea.minY) < 0.5
            return ok ? nil : "\(pane)'s strip \(s) isn't aligned to its deck \(r)"
        }
        /// Nothing in the titlebar row overlaps the traffic lights, the sidebar toggle, the sidebar,
        /// the pill segment, or another strip.
        func overlaps() -> String? {
            var keepOut: [(String, CGRect)] = []
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let v = self.window?.standardWindowButton(b), v.superview != nil { keepOut.append(("traffic light", v.convert(v.bounds, to: self.contentView))) }
            }
            if !self.sidebarToggle.isHidden { keepOut.append(("sidebar toggle", self.sidebarToggle.frame)) }
            if !self.workspaceSidebar.isHidden { keepOut.append(("sidebar", self.workspaceSidebar.frame)) }
            if !self.workspaceBar.isHidden { keepOut.append(("pill segment", self.workspaceBar.frame)) }
            let strips = self.titlebarStripDecks.map { ("strip of \(t.name($0.activeTab!.focusTarget!))", $0.view.strip.frame) }
            var problems: [String] = []
            for (i, (name, f)) in strips.enumerated() {
                for (k, r) in keepOut + strips.enumerated().filter { $0.offset != i }.map(\.element) where f.intersects(r) {
                    problems.append("\(name) overlaps \(k)")
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }
        var surfaces: [ObjectIdentifier: ghostty_surface_t?] = [:]
        func recordSurfaces() { for p in allDecks.flatMap(\.tabs).flatMap(\.panes) { surfaces[ObjectIdentifier(p)] = p.surface.surface } }
        func surfacesKept() -> String? {
            allDecks.flatMap(\.tabs).flatMap(\.panes).allSatisfy { p in surfaces[ObjectIdentifier(p)].map { $0 == p.surface.surface } ?? true }
                ? nil : "a surface was recreated"
        }
        var tree = ""

        t.step("titlebar tabs: off by default, every strip in its deck", nil, {
            all(Settings.tabsInTitlebar ? "default should be off" : nil, inDeck("srv") ? nil : "srv's strip should be in its deck")
        }) {}
        t.step("titlebar tabs: turning it on moves the top deck's strip into the titlebar row, live", nil, {
            all(up("srv") ? nil : "srv's strip should be in the titlebar", aligned("srv"),
                deck("srv").view.content.frame.minY == 0 ? nil : "the deck card should start under the titlebar",
                surfacesKept(), overlaps())
        }) {
            recordSurfaces()
            setTabsInTitlebar(true)
        }
        t.step("titlebar tabs: a deck promoted to the right gets its own aligned titlebar strip", nil, {
            all(up("tt2") ? nil : "tt2's deck should have its strip in the titlebar", aligned("tt2"), aligned("srv"), overlaps())
        }) {
            self.newTab(nil); t.named(self.focusedPane, "tt2")
            self.promote(self.locate(t.pane("tt2"))!.node, side: .right, allowWholeDeck: true)
        }
        t.step("titlebar tabs: a deck below keeps its strip in the deck", nil, {
            all(inDeck("tt3") ? nil : "the lower deck keeps its strip",
                deck("tt3").view.frame.minY > self.deckArea.minY + 1 ? nil : "tt3's deck should be lower down",
                up("srv") && up("tt2") ? nil : "top decks keep titlebar strips", overlaps())
        }) {
            self.focus(t.pane("srv"))
            self.newTab(nil); t.named(self.focusedPane, "tt3")
            self.promote(self.locate(t.pane("tt3"))!.node, side: .bottom, allowWholeDeck: true)
        }
        t.step("titlebar tabs: zooming the lower deck to the window moves its strip up; the hidden decks' leave", nil, {
            all(up("tt3") ? nil : "the zoomed deck's strip should be in the titlebar",
                inDeck("srv") && inDeck("tt2") ? nil : "hidden decks' strips should be back in their decks",
                self.contentView.subviews.compactMap { $0 as? TabStripView }.count == 1 ? nil : "one titlebar strip expected", overlaps())
        }) {
            self.focus(t.pane("tt3"))
            self.toggleZoom(nil)
        }
        t.step("titlebar tabs: un-zooming restores the layout", nil, {
            all(up("srv") && up("tt2") && inDeck("tt3") ? nil : "back to two titlebar strips and an in-deck one", overlaps())
        }) {
            self.toggleZoom(nil)
        }
        t.step("titlebar tabs: a tab dropped on a titlebar strip moves there (DragController)", nil, {
            all(deck("tt3") === deck("tt2") ? nil : "tt3's tab should now be in tt2's deck",
                self.decks.count == 2 ? nil : "the emptied lower deck should be gone",
                self.contentView.subviews.compactMap { $0 as? TabStripView }.count == 2 ? nil : "no orphan strips in the titlebar",
                up("tt3") ? nil : "tt3's deck is a top deck", overlaps())
        }) {
            let tab = self.locate(t.pane("tt3"))!.tab
            let from = t.pane("tt3").view.convert(CGPoint(x: 40, y: 40), to: nil)
            self.dragControllerForTest(.tab(tab), from: from, to: deck("tt2").view.strip)
        }
        func tt2Button() -> TabButton? {
            let b = deck("tt2").view.strip.buttons
            guard let i = deck("tt2").index(of: self.locate(t.pane("tt2"))!.tab), b.indices.contains(i) else { return nil }
            return b[i]
        }
        t.step("titlebar tabs: a tab color renders on a titlebar tab", nil, {
            guard let b = tt2Button() else { return "no tab button" }
            return PixelProbe.matches(PixelProbe.sample(b, at: CGPoint(x: b.underlineRect.midX, y: b.underlineRect.midY)), NSColor(hex: "#d03040"))
                ? nil : "the tab color underline should show on a titlebar tab"
        }) {
            let tab = self.locate(t.pane("tt2"))!.tab
            self.setColor(NSColor(hex: "#d03040"), tab: tab)
            self.select(tab: tab, in: deck("tt2"))  // active, so its underline is full strength
            self.focus(t.pane("srv"))
        }
        t.step("titlebar tabs: the waiting outline renders on a titlebar tab (drawn over the underline)", nil, {
            PixelProbe.isWaitingOutlined(tt2Button()) ? nil : "the waiting outline should show on a titlebar tab"
        }) {
            self.setAttention(.waiting, on: t.pane("tt2"))
        }
        t.step("titlebar tabs: folding a deck takes its strip out of the titlebar", nil, {
            all(self.decks.count == 1 ? nil : "one deck expected",
                self.contentView.subviews.compactMap { $0 as? TabStripView }.count == 1 ? nil : "only srv's strip should be in the titlebar",
                up("srv") && aligned("srv") == nil ? nil : "srv's strip should span its now-wider deck")
        }) {
            self.setAttention(.none, on: t.pane("tt2"))
            self.setColor(nil, tab: self.locate(t.pane("tt2"))!.tab)
            _ = self.fold(deck("tt2"))
        }
        t.step("titlebar tabs: empty titlebar strip space is a window-drag area, not a tab; tabs still hit", nil, {
            let s = deck("srv").view.strip
            guard let frameView = self.window?.contentView?.superview else { return "no frame view" }
            func hit(_ p: CGPoint) -> NSView? { frameView.hitTest(frameView.convert(s.convert(p, to: nil), from: nil)) }
            // Midway between the last control ("+") and the strip's end.
            let lastControl = s.subviews.map(\.frame.maxX).max() ?? 0
            guard s.bounds.maxX - lastControl > 8 else { return "no empty strip space to test (\(s.bounds.maxX - lastControl)pt)" }
            let empty = hit(CGPoint(x: (lastControl + s.bounds.maxX) / 2, y: s.bounds.midY))
            let tab = hit(CGPoint(x: s.tabFrame(0).midX, y: s.tabFrame(0).midY))
            return all(empty === s ? nil : "empty space hit \(empty.map { "\(type(of: $0))" } ?? "nothing"), not the strip",
                       s.mouseDownCanMoveWindow ? nil : "the strip should let the window be dragged",
                       tab is TabButton ? nil : "a tab in the titlebar should still be hit (got \(tab.map { "\(type(of: $0))" } ?? "nothing"))")
        }) {}
        t.step("titlebar tabs: with the sidebar shown, strips stay clear of it", nil, {
            all(!self.workspaceSidebar.isHidden ? nil : "sidebar should show", up("srv") ? nil : "srv's strip in the titlebar",
                aligned("srv"), overlaps())
        }) {
            self.newWorkspace(nil); t.named(self.focusedPane, "tt4")
            self.activateWorkspace(index: 0)
        }
        t.step("titlebar tabs: in top-bar mode the pills keep the left segment and strips start after it", nil, {
            all(!self.workspaceBar.isHidden ? nil : "pills should show",
                abs(self.workspaceBar.frame.width - self.workspaceBar.contentWidth) < 0.5 ? nil : "the pill bar should shrink to its pills",
                deck("srv").view.strip.frame.minX >= self.workspaceBar.frame.maxX + 8 - 0.5 ? nil : "srv's strip should start after the pills",
                aligned("srv"), overlaps())
        }) {
            Settings.workspaceSwitcher = .top
        }
        t.step("titlebar tabs: turning it off puts strips back in their decks, tree and surfaces kept", nil, {
            all(inDeck("srv") ? nil : "srv's strip should be back in its deck",
                self.contentView.subviews.contains { $0 is TabStripView } ? "no strips should remain in the titlebar" : nil,
                deck("srv").view.content.frame.minY == DeckView.stripHeight ? nil : "the card should sit under its strip again",
                self.describeWorkspaces(name: t.name) == tree ? nil : "tree changed: \(self.describeWorkspaces(name: t.name)) vs \(tree)",
                surfacesKept())
        }) {
            tree = self.describeWorkspaces(name: t.name)
            recordSurfaces()
            setTabsInTitlebar(false)
        }
        t.step("titlebar tabs: clean up", nil, {
            all(self.workspaces.count == 1 ? nil : "one workspace", Settings.tabsInTitlebar ? "setting should be off" : nil)
        }) {
            Settings.workspaceSwitcher = .sidebar
            try? FileManager.default.removeItem(at: Settings.fileURL)
            Settings.reload()
            if let home = self.workspace(of: t.pane("srv")) {
                self.activate(home)
                self.workspaces.filter { $0 !== home }.forEach { self.remove(workspace: $0) }
            }
            for p in ["tt2", "tt3"] where self.locate(t.pane(p)) != nil { self.remove(t.pane(p)) }
        }
    }
}
