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
        // #27: a click must go through the window's real event routing (NSWindow.sendEvent), which
        // starts a window drag instead of delivering mouseDown when the clicked view says
        // mouseDownCanMoveWindow. Hit-testing alone said yes here while real clicks did nothing.
        var clickTab: Tab?
        func sendClick(_ view: NSView, at p: CGPoint? = nil) {
            guard let window = self.window else { return }
            let at = view.convert(p ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func ev(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // Queue the release first: whatever tracking loop the press starts (tab drag or window
            // drag) dequeues it, so neither can wait forever.
            if let up = ev(.leftMouseUp) { window.postEvent(up, atStart: false) }
            if let down = ev(.leftMouseDown) { window.sendEvent(down) }
        }
        t.step("titlebar tabs: a real click (window.sendEvent) on a titlebar tab selects it (#27)", nil, {
            let d = deck("srv")
            return all(d.view.stripInTitlebar ? nil : "srv's strip should be in the titlebar",
                       d.activeTab === clickTab ? nil : "clicking the titlebar tab should select it")
        }) {
            let d = deck("srv")
            self.newTab(in: d); t.named(self.focusedPane, "tt5")
            clickTab = d.activeTab
            if let first = d.tabs.first { self.select(tab: first, in: d) }
            self.layoutNow()
            if let i = d.index(of: clickTab!), d.view.strip.buttons.indices.contains(i) { sendClick(d.view.strip.buttons[i]) }
        }
        // Drag zones (#27 reopened): top half of a titlebar tab drags the window, bottom half drags the tab.
        func tabButton(_ tab: Tab?) -> TabButton? {
            guard let tab, let d = self.deck(of: tab), let i = d.index(of: tab), d.view.strip.buttons.indices.contains(i) else { return nil }
            return d.view.strip.buttons[i]
        }
        func moved(_ b: TabButton, _ fy: CGFloat) -> NSEvent? {
            guard let window = self.window else { return nil }
            let p = b.convert(CGPoint(x: b.bounds.width * 0.4, y: b.bounds.height * fy), to: nil)
            return NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        }
        t.step("titlebar tabs: a tab's top half is a window-drag zone, its bottom half and × a tab-drag zone (#27)", nil, {
            guard let window = self.window else { return "no window" }
            var problems: [String] = []
            for b in deck("srv").view.strip.buttons {
                func zone(_ fx: CGFloat, _ fy: CGFloat) -> TabButton.TitlebarZone? {
                    b.titlebarZone(at: b.convert(CGPoint(x: b.bounds.width * fx, y: b.bounds.height * fy), to: nil))
                }
                if zone(0.4, 0.2) != .window { problems.append("top of \(b.title) should drag the window") }
                if zone(0.4, 0.8) != .tab { problems.append("bottom of \(b.title) should drag the tab") }
                if b.titlebarZone(at: b.convert(CGPoint(x: b.closeRect.midX, y: b.closeRect.minY + 1), to: nil)) != .tab {
                    problems.append("the × of \(b.title) should stay clickable")
                }
                if b.mouseDownCanMoveWindow { problems.append("\(b.title) must not answer mouseDownCanMoveWindow") }
            }
            // What the window server reads: isMovable follows the pointer's zone, and leaving restores it.
            if let b = deck("srv").view.strip.buttons.first, let bottom = moved(b, 0.8), let top = moved(b, 0.2) {
                b.mouseMoved(with: bottom)
                if window.isMovable { problems.append("over a tab's bottom half the window should not be movable") }
                b.mouseMoved(with: top)
                if !window.isMovable { problems.append("over a tab's top half the window should be movable") }
                b.mouseMoved(with: bottom)
                b.mouseExited(with: top)
                if !window.isMovable { problems.append("leaving the tab should make the window movable again") }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
        t.step("titlebar tabs: a real click on a tab's top half still selects it", nil, {
            deck("srv").activeTab === clickTab ? nil : "a top-half click should select the tab"
        }) {
            let d = deck("srv")
            if let first = d.tabs.first { self.select(tab: first, in: d) }
            self.layoutNow()
            if let b = tabButton(clickTab) { sendClick(b, at: CGPoint(x: b.bounds.width * 0.4, y: b.bounds.height * 0.2)) }
        }
        t.step("titlebar tabs: no view under a titlebar tab or the + lets a press move the window (#27)", nil, {
            // The real pointer's press never reaches the app when the window server treats it as a
            // window drag, which it decides from `mouseDownCanMoveWindow` of the view under the
            // pointer. An in-process sendEvent can't reproduce that, so assert the input it uses.
            let s = deck("srv").view.strip
            guard let frameView = self.window?.contentView?.superview else { return "no frame view" }
            var problems: [String] = []
            for v in s.subviews where !v.isHidden {
                for fx in [0.2, 0.5, 0.8] {
                    let p = v.convert(CGPoint(x: v.bounds.width * fx, y: v.bounds.midY), to: nil)
                    guard let hit = frameView.hitTest(frameView.convert(p, from: nil)) else { continue }
                    if hit.mouseDownCanMoveWindow { problems.append("\(type(of: hit)) at \(Int(fx * 100))% of \(type(of: v)) would move the window") }
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
        t.step("titlebar tabs: empty titlebar strip space still lets a press move the window", nil, {
            // The other half of the same rule: the window server drags the window (and handles the
            // double-click) where the view under the pointer says mouseDownCanMoveWindow.
            let s = deck("srv").view.strip
            guard let frameView = self.window?.contentView?.superview else { return "no frame view" }
            let lastControl = s.subviews.map(\.frame.maxX).max() ?? 0
            guard s.bounds.maxX - lastControl > 8 else { return "no empty strip space to test" }
            let p = s.convert(CGPoint(x: (lastControl + s.bounds.maxX) / 2, y: s.bounds.midY), to: nil)
            let hit = frameView.hitTest(frameView.convert(p, from: nil))
            return hit === s && s.mouseDownCanMoveWindow ? nil : "empty strip space should be a window-drag area (hit \(hit.map { "\(type(of: $0))" } ?? "nil"))"
        }) {}
        t.step("titlebar tabs: a tab dragged from its bottom half goes through the drag loop (to the window's bottom edge: new deck)", nil, {
            guard let tab = clickTab, let d = self.deck(of: tab) else { return "tt5's tab is gone" }
            return d !== deck("srv") ? nil : "tt5 should have left srv's deck"
        }) {
            guard let tab = clickTab, let d = self.deck(of: tab), let i = d.index(of: tab), let window = self.window else { return }
            let b = d.view.strip.buttons[i]
            // From the tab's bottom half: the tab-drag zone (#27).
            let from = b.convert(CGPoint(x: b.bounds.width * 0.4, y: b.bounds.height * 0.8), to: nil)
            let a = self.deckArea
            let to = self.contentView.convert(CGPoint(x: a.midX, y: a.maxY - 6), to: nil)
            for (type, p) in [(NSEvent.EventType.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)),
                              (.leftMouseDragged, to), (.leftMouseUp, to)] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.postEvent(e, atStart: false)
                }
            }
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: from, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(down)
            }
        }
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
            for p in ["tt2", "tt3", "tt5"] where self.locate(t.pane(p)) != nil { self.remove(t.pane(p)) }
        }
    }
}
