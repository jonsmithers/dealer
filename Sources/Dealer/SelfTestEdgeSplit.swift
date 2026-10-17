import AppKit

// MARK: - Self-test section: a tab dropped at the window edge splits the decks evenly (issue #31)

extension TerminalWindowController {
    /// Runs DragController's real tracking loop from the centre of `view` to `to` (window coordinates).
    func dragControllerForTest(_ source: DragController.Source, from view: NSView, toWindowPoint to: CGPoint) {
        guard let window else { return }
        let from = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        for (type, p) in [(NSEvent.EventType.leftMouseDragged, mid), (.leftMouseDragged, to), (.leftMouseUp, to)] {
            if let e = event(type, p) { window.postEvent(e, atStart: false) }
        }
        if let down = event(.leftMouseDown, from) { drag.begin(source, event: down) }
    }

    func edgeSplitSelfTestSteps(_ t: SelfTestKit) {
        struct Mode {
            let name: String
            let sidebarOpen: Bool
            let topBar: Bool
            let titlebarTabs: Bool
        }
        let modes = [
            Mode(name: "sidebar closed", sidebarOpen: false, topBar: false, titlebarTabs: false),
            Mode(name: "sidebar open", sidebarOpen: true, topBar: false, titlebarTabs: false),
            Mode(name: "top-bar mode", sidebarOpen: false, topBar: true, titlebarTabs: false),
            Mode(name: "tabs in titlebar, sidebar closed", sidebarOpen: false, topBar: false, titlebarTabs: true),
            Mode(name: "tabs in titlebar, sidebar open", sidebarOpen: true, topBar: false, titlebarTabs: true),
        ]
        var counter = 0
        var testWorkspace: Workspace?
        var dragged: Tab?

        func apply(_ m: Mode) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = "[window]\ntabs_in_titlebar = \(m.titlebarTabs)\n\n[workspaces]\nswitcher = \"\(m.topBar ? "top" : "sidebar")\"\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            sidebarPreference = m.sidebarOpen
            layoutNow()
        }
        func dropRemove() {
            if let ws = testWorkspace, workspaces.contains(where: { $0 === ws }) { remove(workspace: ws) }
            testWorkspace = nil
        }
        /// A fresh workspace with one deck; returns that deck.
        func freshWorkspace() -> Deck {
            dropRemove()
            let ws = newWorkspace()
            testWorkspace = ws
            counter += 1
            t.named(focusedPane, "es\(counter)")
            return ws.decks[0]
        }
        /// Opens a tab in `deck` and drags it, by its tab button, to the window's `side` edge.
        func dragNewTab(in deck: Deck, to side: Side) {
            newTab(in: deck)
            counter += 1
            t.named(focusedPane, "es\(counter)")
            layoutNow()
            guard let tab = deck.activeTab, let i = deck.index(of: tab) else { return }
            dragged = tab
            let button = deck.view.strip.buttons[i]
            dragControllerForTest(.tab(tab), from: button, toWindowPoint: contentView.convert(edgePoint(side), to: nil))
            layoutNow()
        }
        /// The decks' sizes along `axis`, when every deck of the test workspace lies on that one axis.
        func sizes(_ axis: Axis) -> [CGFloat] {
            (testWorkspace?.decks ?? []).map { axis == .row ? $0.view.frame.width : $0.view.frame.height }
        }
        func even(_ expected: Int, _ axis: Axis) -> String? {
            let s = sizes(axis)
            guard s.count == expected else { return "expected \(expected) decks, got \(s.count): \(describeWorkspaces(name: t.name))" }
            guard let lo = s.min(), let hi = s.max() else { return "no decks" }
            // Rounding in Node.layout can leave a 1pt difference.
            return hi - lo <= 1.5 ? nil : "decks should share the \(axis == .row ? "width" : "height") evenly, got \(s.map { Int($0) }) in \(Int(axis == .row ? deckArea.width : deckArea.height))"
        }
        func landedAt(_ side: Side) -> String? {
            guard let tab = dragged, let deck = self.deck(of: tab), let ws = testWorkspace, let root = ws.root else { return "the tab is gone" }
            guard deck.tabs.count == 1 else { return "the tab should be alone in a new deck: \(describeWorkspaces(name: t.name))" }
            return root.node(for: deck)?.outermostSide == side ? nil : "the new deck should sit at the \(side) edge: \(describeWorkspaces(name: t.name))"
        }
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }

        for m in modes {
            for side in [Side.left, .right, .top, .bottom] {
                // The top edge is the titlebar row. Pills (top-bar mode) and titlebar strips cover it,
                // and dropping there targets them instead, so it is a promote band only otherwise.
                if side == .top && (m.topBar || m.titlebarTabs) { continue }
                t.step("edge split (\(m.name)): a tab dropped at the \(side) edge halves the window", nil, {
                    all(landedAt(side), even(2, side.axis))
                }) {
                    let deck = freshWorkspace()
                    apply(m)
                    dragNewTab(in: deck, to: side)
                }
            }
            t.step("edge split (\(m.name)): a second tab at the right edge makes three even columns", nil, {
                all(landedAt(.right), even(3, .row))
            }) {
                let deck = freshWorkspace()
                apply(m)
                dragNewTab(in: deck, to: .right)
                dragNewTab(in: deck, to: .right)
            }
            t.step("edge split (\(m.name)): a second tab at the bottom edge makes three even rows", nil, {
                all(landedAt(.bottom), even(3, .col))
            }) {
                let deck = freshWorkspace()
                apply(m)
                dragNewTab(in: deck, to: .bottom)
                dragNewTab(in: deck, to: .bottom)
            }
        }

        t.step("edge split: menu Promote (⌘⇧P) of a whole tab splits evenly too", nil, {
            all(landedAt(.right), even(2, .row))
        }) {
            let deck = freshWorkspace()
            apply(modes[0])
            self.newTab(in: deck)
            counter += 1
            t.named(self.focusedPane, "es\(counter)")
            dragged = deck.activeTab
            self.layoutNow()
            self.promoteToDeck(nil)
        }
        var paneWidth: CGFloat = 0
        t.step("edge split: menu Promote of a split pane still keeps the pane's width", nil, {
            let w = self.locate(t.pane("es\(counter)")).map { $0.deck.view.frame.width } ?? 0
            return abs(w - paneWidth) <= 1.5 ? nil : "the promoted pane's deck should keep its width (\(paneWidth) → \(w))"
        }) {
            _ = freshWorkspace()
            apply(modes[0])
            self.split(self.focusedPane!, side: .right)
            self.split(self.focusedPane!, side: .right)
            counter += 1
            t.named(self.focusedPane, "es\(counter)")
            self.layoutNow()
            paneWidth = self.focusedPane!.view.frame.width + DeckView.chromeSize.width
            self.promoteToDeck(nil)
        }

        t.step("edge split: clean up", nil, {
            all(self.workspaces.count == 1 ? nil : "one workspace",
                Settings.tabsInTitlebar ? nil : "tabs_in_titlebar should be back to the default (on)",
                Settings.workspaceSwitcher == .sidebar ? nil : "switcher should be the sidebar")
        }) {
            dropRemove()
            try? FileManager.default.removeItem(at: Settings.fileURL)
            Settings.reload()
            self.sidebarPreference = nil
            self.layoutNow()
        }
    }

    /// A point just inside the window's `side` edge, where a drop promotes (content-view coordinates).
    private func edgePoint(_ side: Side) -> CGPoint {
        let a = deckArea
        switch side {
        case .left: return CGPoint(x: a.minX + 6, y: a.midY)
        case .right: return CGPoint(x: a.maxX - 6, y: a.midY)
        case .top: return CGPoint(x: a.midX, y: a.minY / 2)
        case .bottom: return CGPoint(x: a.midX, y: a.maxY - 6)
        }
    }
}
