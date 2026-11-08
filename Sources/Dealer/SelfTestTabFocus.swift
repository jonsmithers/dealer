import AppKit

// MARK: - Self-test section: tabs remember their focused pane (#101)
//
// Self-contained (`DEALER_SELFTEST_ONLY=tab focus:`). Two decks of two tabs, each tab two panes,
// each tab remembering its *second* pane. Every way back to a tab must land on the pane it
// remembers, and must leave every other tab's memory alone.
//
// The cause (#101): AppKit gives first responder to the next key view when the focused view is
// hidden, and the key-view loop it builds when a window first shows ran through every terminal
// there (a restored session). Hiding the focused pane on a tab or workspace switch so focused a
// terminal in another deck, which counted as the user focusing it: that tab's memory, the
// workspace's focused pane, its attention mark and Go to Pane's recency were all overwritten.
// The self-test window first showed with one pane, so the setup rebuilds the loop the way a
// restored window's would be built. Clicks go through `window.sendEvent` and keys through the main
// menu from the focused terminal (`pressMenuKeyForTest`); real pointer and key presses aren't covered.

extension TerminalWindowController {
    func tabFocusSelfTestSteps(_ t: SelfTestKit) {
        var ws: Workspace?
        var top: Deck?, bottom: Deck?
        /// Tab name → (tab, the pane it should remember).
        var memory: [(String, Tab, Pane)] = []
        var problem: String?

        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func pane(_ n: String) -> Pane { t.pane("tf-" + n) }
        func tab(_ n: String) -> Tab? { memory.first { $0.0 == n }?.1 }
        func name(_ p: Pane?) -> String { p.map(t.name) ?? "nil" }
        /// Focus is on `p` in the model and in AppKit, and every tab still remembers its pane.
        func focused(on p: Pane) -> String? {
            let fr = window?.firstResponder
            let frName = (fr as? SurfaceView).flatMap { s in memory.map(\.2).first { $0.surface === s } }.map(t.name)
                ?? fr.map { "\(type(of: $0))" } ?? "nil"
            var problems: [String] = []
            if focusedPane !== p { problems.append("focus should be on \(t.name(p)), is on \(name(focusedPane))") }
            if fr !== p.surface { problems.append("first responder should be \(t.name(p))'s terminal, is \(frName)") }
            for (n, tab, want) in memory where tab.lastFocused !== want {
                problems.append("\(n) should remember \(t.name(want)), remembers \(name(tab.lastFocused))")
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }
        /// A click through the window's event routing. The release is queued first, so the tracking
        /// loop a tab press starts (DragController) dequeues it and can't wait forever.
        func click(_ view: NSView?) {
            guard let view, let window, !view.isHiddenOrHasHiddenAncestor else { problem = problem ?? "nothing to click"; return }
            let at = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.height * 0.75), to: nil)
            if let up = mouseEventForTest(.leftMouseUp, at: at) { window.postEvent(up, atStart: false) }
            if let down = mouseEventForTest(.leftMouseDown, at: at) { window.sendEvent(down) }
        }
        func button(_ n: String) -> TabButton? {
            guard let tab = tab(n), let d = deck(of: tab), let i = d.index(of: tab) else { return nil }
            return d.view.strip.buttons.indices.contains(i) ? d.view.strip.buttons[i] : nil
        }
        func key(_ k: String, _ mods: NSEvent.ModifierFlags, _ code: Int) {
            guard let p = focusedPane else { problem = problem ?? "no focused pane"; return }
            if !pressMenuKeyForTest(k, mods, keyCode: code, surface: p.surface) {
                problem = problem ?? "\(k) with \(mods) should match an enabled menu item (\(Self.menuKeyFailure))"
            }
        }
        /// Checks focus part-way through a step, keeping the first problem.
        func midway(_ what: String, _ p: Pane) {
            if problem == nil, let f = focused(on: p) { problem = "after \(what): \(f)" }
        }
        func remember(_ n: String, _ p: Pane) {
            if let i = memory.firstIndex(where: { $0.0 == n }) { memory[i].2 = p }
        }

        /// A step whose action starts with no problem noted.
        func step(_ title: String, _ check: @escaping () -> String?, _ action: @escaping () -> Void) {
            t.step(title, nil, check) { problem = nil; action() }
        }

        step("tab focus: two decks of two tabs, each tab remembering its second pane", {
            all(top == nil || bottom == nil || top === bottom ? "expected two decks" : nil,
                memory.count == 4 ? nil : "expected four tabs",
                focused(on: pane("b")))
        }) {
            ws = self.newWorkspace(name: "tab-focus")
            func make(_ n: String) -> Pane? {
                guard let p = self.focusedPane else { return nil }
                t.named(p, "tf-" + n)
                p.customTitle = "tf-" + n
                return p
            }
            // Top deck: t1 = Row(a, b), t2 = Row(c, d). Bottom deck: t3 = Row(e, f), t4 = Row(g, h).
            guard let a = make("a") else { return }
            self.split(a, side: .right)
            guard let b = make("b") else { return }
            self.split(b, side: .bottom)
            guard let e = make("e"), let en = self.locate(e)?.node, self.promote(en, side: .bottom) else { return }
            top = self.locate(a)?.deck; bottom = self.locate(e)?.deck
            self.split(e, side: .right)
            guard let f = make("f"), let bottom else { return }
            self.newTab(in: bottom)
            guard let g = make("g") else { return }
            self.split(g, side: .right)
            guard let h = make("h"), let top else { return }
            self.focus(b)
            self.newTab(in: top)
            guard let c = make("c") else { return }
            self.split(c, side: .right)
            guard let d = make("d") else { return }
            for (n, last) in [("t1", b), ("t2", d), ("t3", f), ("t4", h)] {
                if let tab = self.locate(last)?.tab { memory.append((n, tab, last)) }
            }
            self.select(tab: bottom.tabs[0], in: bottom)
            self.select(tab: top.tabs[0], in: top)
            // AppKit builds this loop when a window first shows; ours showed with one pane.
            self.window?.recalculateKeyViewLoop()
        }
        step("tab focus: a click on a titlebar tab lands on the pane that tab remembers", {
            all(problem, top?.view.stripInTitlebar == true ? nil : "the top deck's strip should be in the titlebar", focused(on: pane("d")))
        }) {
            click(button("t2"))
        }
        step("tab focus: a click back on the first titlebar tab returns to its pane", { all(problem, focused(on: pane("b"))) }) {
            click(button("t1"))
        }
        step("tab focus: a click on a tab in a deck's own strip, from the other deck, lands on its pane", {
            all(problem, bottom?.view.stripInTitlebar == false ? nil : "the bottom deck's strip should be in the deck", focused(on: pane("h")))
        }) {
            click(button("t4"))
        }
        step("tab focus: and a click back on its other tab", { all(problem, focused(on: pane("f"))) }) {
            click(button("t3"))
        }
        step("tab focus: ⌘⇧] and ⌘⇧[ (Next/Previous Tab) come back to the pane", { all(problem, focused(on: pane("f"))) }) {
            key("]", [.command, .shift], 30)
            midway("⌘⇧]", pane("h"))
            key("[", [.command, .shift], 33)
        }
        step("tab focus: ⌘2 and ⌘1 come back to the pane", { all(problem, focused(on: pane("f"))) }) {
            key("2", .command, 19)
            midway("⌘2", pane("h"))
            key("1", .command, 18)
        }
        step("tab focus: a click on the other deck's tab and back on this one", { all(problem, focused(on: pane("f"))) }) {
            click(button("t2"))
            midway("clicking t2", pane("d"))
            click(button("t3"))
        }
        step("tab focus: a workspace switch (⌃1) and back (a sidebar row) returns to the pane", {
            all(problem, self.activeWorkspace === ws ? nil : "tab-focus should be active again", focused(on: pane("f")))
        }) {
            key("1", .control, 18)
            if problem == nil, self.activeWorkspace === ws { problem = "⌃1 should leave the tab-focus workspace" }
            let row = self.workspaceSidebar.subviews.compactMap { $0 as? WorkspaceRow }.first { $0.workspace === ws }
            if let row { self.clickForTest(row) } else { problem = problem ?? "no sidebar row for tab-focus" }
        }
        step("tab focus: ⌘⇧U into a background tab, then a click back", { all(problem, focused(on: pane("f"))) }) {
            self.setAttention(.waiting, on: pane("c"), event: "selftest")
            // The menu's action itself: a synthesized ⌘⇧U ("U" + ⇧) doesn't match the "u" + ⇧ item.
            self.jumpToNextUnread(nil)
            remember("t2", pane("c"))
            midway("⌘⇧U", pane("c"))
            click(button("t3"))
        }
        step("tab focus: Go to Pane (⌘⇧A) into a background tab, then a click back", { all(problem, focused(on: pane("f"))) }) {
            key("a", [.command, .shift], 0)
            let picker = PanePicker.shared
            if let editor = picker.field.currentEditor() as? NSTextView {
                editor.insertText("tf-g", replacementRange: editor.selectedRange())
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                picker.close(restoreFocus: false)
                problem = problem ?? "Go to Pane's field should be editing"
            }
            remember("t4", pane("g"))
            midway("Go to Pane", pane("g"))
            click(button("t3"))
        }
        step("tab focus: closing the tab you're in returns to the pane the next tab remembers", {
            all(problem, focused(on: pane("f")))
        }) {
            click(button("t4"))
            midway("clicking t4", pane("g"))
            if let tab = tab("t4") { self.close(tab: tab) }
            memory.removeAll { $0.0 == "t4" }
        }
        step("tab focus: a saved session keeps what every tab remembers, and older files decode", {
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(snap),
                  let back = try? JSONDecoder().decode(WindowSnapshot.self, from: data),
                  let i = self.workspaces.firstIndex(where: { $0 === ws }), back.allWorkspaces.indices.contains(i)
            else { return "the snapshot didn't round-trip" }
            let restored = self.restoreWorkspaces(WindowSnapshot(frame: .zero, workspaces: [back.allWorkspaces[i]], activeWorkspace: 0))
            defer { restored.flatMap(\.panes).forEach { $0.view.removeFromSuperview() } }
            guard let rws = restored.first, let ows = ws else { return "nothing restored" }
            let oldTabs = ows.decks.flatMap(\.tabs), newTabs = rws.decks.flatMap(\.tabs)
            guard oldTabs.count == newTabs.count else { return "restored \(newTabs.count) tabs, expected \(oldTabs.count)" }
            var problems: [String] = []
            for (o, n) in zip(oldTabs, newTabs) {
                let want = o.lastFocused.flatMap { p in o.panes.firstIndex { $0 === p } }
                let got = n.lastFocused.flatMap { p in n.panes.firstIndex { $0 === p } }
                if want != got { problems.append("a restored tab remembers pane \(got.map(String.init) ?? "nil"), expected \(want.map(String.init) ?? "nil")") }
            }
            func index(_ w: Workspace, _ tabs: [Tab]) -> Int? { w.validFocusedPane.flatMap { p in tabs.flatMap(\.panes).firstIndex { $0 === p } } }
            if index(rws, newTabs) != index(ows, oldTabs) { problems.append("the restored workspace should focus the same pane") }
            let old = try? JSONDecoder().decode(TabSnapshot.self, from: Data(#"{"root":{"leaf":{"_0":{"focused":false}}}}"#.utf8))
            if old == nil { problems.append("a tab snapshot without a remembered pane should decode") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
    }
}
