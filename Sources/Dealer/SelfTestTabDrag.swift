import AppKit

// MARK: - Self-test section: dragging a tab by its tab button onto panes and strips (issue #27)
//
// Runs each drop from a strip in its deck and from a strip in the titlebar. The press goes through
// `TabButton.mouseDown` (bottom half, the tab-drag zone of a titlebar tab), which selects the tab and
// starts DragController's real tracking loop on queued events.

extension TerminalWindowController {
    func tabDragSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        var testWorkspace: Workspace?
        var counter = 0
        func setTitlebar(_ on: Bool) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[window]\ntabs_in_titlebar = \(on)\n".write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            layoutNow()
        }
        func dropWorkspace() {
            if let ws = testWorkspace, workspaces.contains(where: { $0 === ws }) { remove(workspace: ws) }
            testWorkspace = nil
        }
        /// A fresh workspace whose one deck has tabs named a, b (b active); returns the names.
        func fresh() -> (a: String, b: String) {
            dropWorkspace()
            counter += 1
            let ws = newWorkspace()
            testWorkspace = ws
            let a = "td\(counter)a", b = "td\(counter)b"
            t.named(focusedPane, a)
            newTab(in: ws.decks[0])
            t.named(focusedPane, b)
            // Titles independent of the cwd, so tab widths (and drop points) don't vary by checkout.
            for (i, tab) in ws.decks[0].tabs.enumerated() { tab.customTitle = "drag test \(i == 0 ? "a" : "b")" }
            layoutNow()
            return (a, b)
        }
        func tab(_ pane: String) -> Tab? { locate(t.pane(pane))?.tab }
        func deck(_ pane: String) -> Deck? { locate(t.pane(pane))?.deck }
        func button(_ pane: String) -> TabButton? {
            guard let d = deck(pane), let tb = tab(pane), let i = d.index(of: tb), d.view.strip.buttons.indices.contains(i) else { return nil }
            return d.view.strip.buttons[i]
        }
        /// A point at fractions of `view`'s bounds, in window coordinates.
        func point(_ view: NSView, _ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            view.convert(CGPoint(x: view.bounds.minX + view.bounds.width * fx, y: view.bounds.minY + view.bounds.height * fy), to: nil)
        }
        /// Presses `pane`'s tab button in its bottom half and drags to `to` (window coordinates).
        func dragTab(_ pane: String, to: CGPoint) {
            guard let window, let b = button(pane) else { return }
            let from = point(b, 0.3, 0.75)
            func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            for (type, p) in [(NSEvent.EventType.leftMouseDragged, mid), (.leftMouseDragged, to), (.leftMouseUp, to)] {
                if let e = ev(type, p) { window.postEvent(e, atStart: false) }
            }
            if let down = ev(.leftMouseDown, from) { b.mouseDown(with: down) }
            layoutNow()
        }
        /// `p` moved right, if needed, out of DragController's left edge band (where a drop promotes
        /// instead), but kept in the left half of `button` so the drop still inserts before it. A
        /// tab sized to a short title (its pane's cwd, e.g. a worktree named "blur") has its whole
        /// left half inside the band, so the test's tabs get fixed titles wide enough for this.
        func clearOfEdgeBand(_ p: CGPoint, before button: NSView) -> CGPoint {
            let minX = deckArea.minX + DragController.edgeBand + 3
            let mid = button.convert(CGPoint(x: button.bounds.midX, y: 0), to: nil).x
            return CGPoint(x: min(max(p.x, minX), mid - 2), y: p.y)
        }
        func state() -> String { describeWorkspaces(name: t.name) }
        /// `deck` holds one tab whose panes are `panes`, in order.
        func split(_ panes: [String]) -> String? {
            guard let d = deck(panes[0]) else { return "\(panes[0]) is gone" }
            let got = d.tabs.first?.panes.map(t.name) ?? []
            return d.tabs.count == 1 && got == panes ? nil : "expected one tab with panes \(panes) side by side: \(state())"
        }

        for titlebar in [false, true] {
            let mode = titlebar ? "titlebar strip" : "deck strip"
            var names = (a: "", b: "")
            t.step("tab drag (\(mode)): pressing the tab's bottom half and dropping on its own deck's pane edge rejoins as a split", nil, {
                all(titlebar == (deck(names.a)?.view.stripInTitlebar ?? false) ? nil : "the strip should\(titlebar ? "" : "n't") be in the titlebar",
                    split([names.a, names.b]))
            }) {
                setTitlebar(titlebar)
                names = fresh()
                guard let d = deck(names.a) else { return }
                dragTab(names.b, to: point(d.view, 0.9, 0.6))
            }
            t.step("tab drag (\(mode)): dropped near a pane's centre it splits at the nearest edge", nil, {
                split([names.b, names.a])
            }) {
                names = fresh()
                guard let d = deck(names.a) else { return }
                dragTab(names.b, to: point(d.view, 0.4, 0.55))
            }
            t.step("tab drag (\(mode)): an inactive tab dragged out joins the tab the deck showed before the press", nil, {
                split([names.b, names.a])
            }) {
                names = fresh()
                guard let d = deck(names.a) else { return }
                dragTab(names.a, to: point(d.view, 0.9, 0.6))
            }
            t.step("tab drag (\(mode)): dropped back on its own strip it reorders and stays selected", nil, {
                guard let d = deck(names.a), let tb = tab(names.b) else { return "the tabs are gone" }
                return d.tabs.first === tb && d.activeTab === tb && d.tabs.count == 2 ? nil : "\(names.b) should be first and active: \(state())"
            }) {
                names = fresh()
                guard let ba = button(names.a) else { return }
                dragTab(names.b, to: clearOfEdgeBand(point(ba, 0.3, 0.75), before: ba))
            }
            t.step("tab drag (\(mode)): a drag that goes nowhere leaves the tab selected where it was", nil, {
                guard let d = deck(names.a), let tb = tab(names.b) else { return "the tabs are gone" }
                return d.tabs.count == 2 && d.activeTab === tb ? nil : "both tabs should stay, \(names.b) active: \(state())"
            }) {
                names = fresh()
                // Released over its own workspace's sidebar row, which is no target.
                guard let ws = testWorkspace, let sw = self.visibleWorkspaceSwitchers.first, let r = sw.rect(for: ws) else { return }
                dragTab(names.b, to: sw.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
            }
            var other = ""
            t.step("tab drag (\(mode)): dropped on another deck's strip it moves there", nil, {
                guard let d = deck(other), let tb = tab(names.b) else { return "the tabs are gone" }
                return all(d.tabs.contains { $0 === tb } ? nil : "\(names.b) should be in \(other)'s deck: \(state())",
                           titlebar == d.view.stripInTitlebar ? nil : "the target strip should\(titlebar ? "" : "n't") be in the titlebar")
            }) {
                names = fresh()
                guard let d = deck(names.a) else { return }
                self.newTab(in: d)
                other = "td\(counter)c"
                t.named(self.focusedPane, other)
                self.promote(self.locate(t.pane(other))!.node, side: .right, allowWholeDeck: true)
                self.layoutNow()
                guard let od = deck(other) else { return }
                dragTab(names.b, to: point(od.view.strip, 0.9, 0.5))
            }
            t.step("tab drag (\(mode)): dropped on another deck's pane edge it rejoins there as a split", nil, {
                split([names.b, other])
            }) {
                names = fresh()
                guard let d = deck(names.a) else { return }
                self.newTab(in: d)
                other = "td\(counter)c"
                t.named(self.focusedPane, other)
                self.promote(self.locate(t.pane(other))!.node, side: .right, allowWholeDeck: true)
                self.layoutNow()
                guard let od = deck(other) else { return }
                dragTab(names.b, to: point(od.view, 0.1, 0.6))
            }
        }
        t.step("tab drag: clean up", nil, {
            all(self.workspaces.count == 1 ? nil : "one workspace", Settings.tabsInTitlebar ? nil : "tabs_in_titlebar should be back to the default (on)")
        }) {
            dropWorkspace()
            try? FileManager.default.removeItem(at: Settings.fileURL)
            Settings.reload()
            self.sidebarPreference = nil
            self.layoutNow()
        }
    }
}
