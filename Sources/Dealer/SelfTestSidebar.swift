import AppKit

// MARK: - Self-test section: workspace sidebar (issue #6)

extension TerminalWindowController {
    private func mouseEventForTest(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// Presses on `view`, drags to `to` (window coordinates) and releases, through `window.sendEvent`.
    func dragForTest(_ view: NSView, to: CGPoint) {
        guard let window else { return }
        let from = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let events: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, from), (.leftMouseDragged, mid), (.leftMouseDragged, to), (.leftMouseUp, to)]
        for (type, p) in events {
            if let e = mouseEventForTest(type, at: p) { window.sendEvent(e) }
        }
    }

    /// Runs DragController's real tracking loop: queues the drag and release, then starts the drag.
    func dragControllerForTest(_ source: DragController.Source, from: CGPoint, to: NSView) {
        guard let window else { return }
        let target = to.convert(CGPoint(x: to.bounds.midX, y: to.bounds.midY), to: nil)
        for (type, p) in [(NSEvent.EventType.leftMouseDragged, target), (.leftMouseUp, target)] {
            if let e = mouseEventForTest(type, at: p) { window.postEvent(e, atStart: false) }
        }
        if let down = mouseEventForTest(.leftMouseDown, at: from) { drag.begin(source, event: down) }
    }

    func sidebarSelfTestSteps(_ t: SelfTestKit) {
        let sb = workspaceSidebar
        let g = Self.deckGap
        let w = Theme.Metrics.sidebarWidth
        func expect(_ e: String) -> String? {
            let got = describeWorkspaces(name: t.name)
            return got == e ? nil : "expected workspaces \(e)\n         got      \(got)"
        }
        func visible(_ n: String) -> Bool { let v = t.pane(n).view; return v.window != nil && !v.isHiddenOrHasHiddenAncestor }
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func collapsed() -> String? {
            all(sb.isHidden ? nil : "sidebar should be hidden",
                abs(deckArea.minX - g) < 0.5 ? nil : "deck area should start at the window edge (minX \(deckArea.minX))",
                decks.allSatisfy { $0.view.frame.minX >= g - 0.5 } ? nil : "a deck starts left of the deck area")
        }
        var paneWidth: CGFloat = 0
        let deep = "Row(srv2, Col(edit, test2))"

        t.step("sidebar: collapsed with one workspace; the toggle stays in the titlebar", nil, {
            all(collapsed(), self.sidebarToggle.window != nil && !self.sidebarToggle.isOn ? nil : "toggle should show, off",
                self.sidebarToggle.frame.maxY <= self.deckArea.minY ? nil : "toggle should sit in the titlebar row")
        }) {
            paneWidth = t.pane("srv").view.frame.width
        }
        t.step("sidebar: ⌃⌘S expands it; decks shrink instead of sitting under it", nil, {
            let sbRight = sb.frame.maxX
            return all(!sb.isHidden && self.sidebarToggle.isOn ? nil : "sidebar should show",
                       self.sidebarPreference == true ? nil : "the choice should stick",
                       abs(self.deckArea.minX - (g + w + g)) < 0.5 ? nil : "deck area should start right of the sidebar",
                       self.decks.allSatisfy { $0.view.frame.minX >= sbRight } ? nil : "a deck overlaps the sidebar",
                       abs(paneWidth - t.pane("srv").view.frame.width - (w + g)) < 2 ? nil
                           : "pane should narrow by the sidebar (\(paneWidth) → \(t.pane("srv").view.frame.width))",
                       sb.row(at: 0) != nil ? nil : "one row expected")
        }) {
            self.toggleSidebar(nil)
        }
        t.step("sidebar: clicking a row switches workspace", nil, {
            all(expect("*1:Deck0[*srv, db, \(deep)] | 2:Deck0[*s2]"), visible("srv") && !visible("s2") ? nil : "wrong visibility")
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "s2")
            if let r = sb.row(at: 0) { self.clickForTest(r) }
        }
        t.step("sidebar: drag a row below the next one to reorder", nil, {
            expect("1:Deck0[*s2] | *2:Deck0[*srv, db, \(deep)]")
        }) {
            guard let r0 = sb.row(at: 0), let r1 = sb.row(at: 1) else { return }
            self.dragForTest(r0, to: r1.convert(CGPoint(x: r1.bounds.midX, y: r1.bounds.maxY - 2), to: nil))
        }
        t.step("sidebar: drop a tab on a row (DragController) moves it to that workspace", nil, {
            all(expect("1:Deck0[s2, *db] | *2:Deck0[*srv, \(deep)]"), !visible("db") ? nil : "db should have left")
        }) {
            guard let tab = self.locate(t.pane("db"))?.tab, let row = sb.row(at: 0) else { return }
            let from = t.pane("srv").view.convert(CGPoint(x: 40, y: 40), to: nil)
            self.dragControllerForTest(.tab(tab), from: from, to: row)
        }
        t.step("sidebar: drop a pane on New Workspace makes one and follows", nil, {
            all(expect("1:Deck0[s2, *db] | 2:Deck0[*srv, Row(srv2, edit)] | *3:Deck0[*test2]"),
                visible("test2") ? nil : "test2 should be showing")
        }) {
            let from = t.pane("test2").view.convert(CGPoint(x: 40, y: 40), to: nil)
            self.dragControllerForTest(.pane(t.pane("test2")), from: from, to: sb.addRow)
        }
        t.step("sidebar: ⌃⌘S hides it even with several workspaces", nil, {
            all(collapsed(), self.sidebarPreference == false ? nil : "the choice should stick")
        }) {
            self.toggleSidebar(nil)
        }
        t.step("sidebar: the choice round-trips through the session; old files decode", nil, {
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(snap),
                  let back = try? JSONDecoder().decode(WindowSnapshot.self, from: data) else { return "encode failed" }
            guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "bad JSON" }
            obj["sidebar"] = nil
            let old = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder().decode(WindowSnapshot.self, from: $0) }
            return all(back.sidebar == false ? nil : "sidebar=false should round-trip",
                       old != nil && old?.sidebar == nil ? nil : "a file without the field should decode as automatic")
        }) {}
        t.step("sidebar: back to one workspace, automatic", nil, {
            all(expect("*1:Deck0[*srv, Row(srv2, edit)]"), collapsed())
        }) {
            self.sidebarPreference = nil
            if let home = self.workspace(of: t.pane("srv")) {
                self.activate(home)
                self.workspaces.filter { $0 !== home }.forEach { self.remove(workspace: $0) }
            }
        }
    }
}
