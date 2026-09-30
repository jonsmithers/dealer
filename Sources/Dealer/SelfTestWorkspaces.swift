import AppKit

// MARK: - Self-test section: workspaces (issue #1)

extension TerminalWindowController {
    /// Every workspace, e.g. `1:Deck0[*srv] | *2:Row(Deck0[*a], Deck1[*b])`; `*` marks the active one.
    func describeWorkspaces(name: (Pane) -> String) -> String {
        func pane(_ n: Node<Pane>) -> String {
            if let p = n.leaf { return name(p) }
            return "\(n.axis == .row ? "Row" : "Col")(\(pane(n.a!)), \(pane(n.b!)))"
        }
        func deck(_ n: Node<Deck>) -> String {
            if let d = n.leaf {
                let tabs = d.tabs.enumerated().map { (i, t) in (i == d.activeIndex ? "*" : "") + pane(t.root) }
                return "Deck\(d.colorIndex)[\(tabs.joined(separator: ", "))]"
            }
            return "\(n.axis == .row ? "Row" : "Col")(\(deck(n.a!)), \(deck(n.b!)))"
        }
        return workspaces.enumerated().map { i, ws in
            (ws === activeWorkspace ? "*" : "") + "\(i + 1):" + (ws.root.map(deck) ?? "<empty>")
        }.joined(separator: " | ")
    }

    /// Sends a real left click through the window's event routing (titlebar included).
    func clickForTest(_ view: NSView) {
        guard let window else { return }
        let p = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
        }
    }

    func workspaceSelfTestSteps(_ t: SelfTestKit) {
        func ws() -> String { describeWorkspaces(name: t.name) }
        func expect(_ e: String) -> String? { ws() == e ? nil : "expected workspaces \(e)\n         got      \(ws())" }
        func visible(_ n: String) -> Bool { let v = t.pane(n).view; return v.window != nil && !v.isHiddenOrHasHiddenAncestor }
        func focused(_ n: String) -> String? {
            focusedPane === t.pane(n) ? nil : "focus should be on \(n), is on \(focusedPane.map(t.name) ?? "nil")"
        }
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        let deep = "Row(srv2, Col(edit, Row(log2, test2)))"

        t.step("⌘⌃N creates a workspace and switches to it", nil, {
            all(expect("1:Deck0[srv, db, \(deep), *tests] | *2:Deck0[*w2]"),
                visible("w2") && !visible("tests") ? nil : "only the new workspace should be visible",
                self.workspaceBar.button(at: 1) != nil ? nil : "switcher should show two workspaces",
                focused("w2"))
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "w2")
        }
        t.step("inactive workspace's decks are parked, not removed", nil, {
            let d = self.workspaces[0].decks[0]
            return d.view.superview === self.contentView && d.view.isHidden
                && self.locate(t.pane("tests"))?.workspace === self.workspaces[0] ? nil : "deck view should stay in the window, hidden"
        }) {}
        t.step("clicking pill 1 in the switcher goes back", nil, {
            all(expect("*1:Deck0[srv, db, \(deep), *tests] | 2:Deck0[*w2]"),
                visible("tests") && !visible("w2") ? nil : "workspace 1 should be showing",
                focused("tests"))
        }) {
            if let b = self.workspaceBar.button(at: 0) { self.clickForTest(b) }
        }
        t.step("⌃2 switches by number", nil, { all(expect("1:Deck0[srv, db, \(deep), *tests] | *2:Deck0[*w2]"), focused("w2")) }) {
            self.activateWorkspace(index: 1)
        }
        t.step("rename a workspace", nil, {
            self.activeWorkspace.displayName == "api" ? nil : "name should be api"
        }) {
            self.rename(workspace: self.activeWorkspace, to: " api ")
        }
        t.step("move a pane into another workspace: it becomes a tab there; the view stays", nil, {
            all(expect("*1:Deck0[srv, db, *Row(srv2, Col(edit, test2)), tests] | 2:Deck0[w2, *log2]"),
                !visible("log2") ? nil : "moved pane should be hidden with its workspace",
                focused("test2"))
        }) {
            self.activateWorkspace(index: 0)
            self.focus(t.pane("log2"))
            self.move(self.locate(t.pane("log2"))!.node, toWorkspace: self.workspaces[1])
        }
        t.step("move a tab into a new workspace and follow it", nil, {
            all(expect("1:Deck0[srv, db, *Row(srv2, Col(edit, test2))] | *2:Deck0[*tests] | 3:Deck0[w2, *log2]"),
                visible("tests") ? nil : "tests should be visible", focused("tests"))
        }) {
            self.move(tab: self.locate(t.pane("tests"))!.tab, toWorkspace: nil, follow: true)
        }
        t.step("moving a workspace's only deck away closes that workspace", nil, {
            all(expect("1:Deck0[srv, db, *Row(srv2, Col(edit, test2))] | *2:Row(Deck0[w2, *log2], Deck1[*tests])"),
                visible("tests") && visible("log2") ? nil : "both decks should show", focused("tests"),
                self.activeWorkspace.displayName == "api" ? nil : "should have landed in api")
        }) {
            self.move(deck: self.locate(t.pane("tests"))!.deck, toWorkspace: self.workspaces[2])
        }
        t.step("reorder workspaces", nil, {
            expect("*1:Row(Deck0[w2, *log2], Deck1[*tests]) | 2:Deck0[srv, db, *Row(srv2, Col(edit, test2))]")
        }) {
            self.move(workspace: self.activeWorkspace, to: 0)
        }
        t.step("focusing a pane in another workspace switches to it", nil, {
            all(expect("1:Row(Deck0[w2, *log2], Deck1[*tests]) | *2:Deck0[*srv, db, Row(srv2, Col(edit, test2))]"),
                visible("srv") && !visible("tests") ? nil : "wrong visibility", focused("srv"))
        }) {
            self.focus(t.pane("srv"))
        }
        t.step("workspaces round-trip through a snapshot; old files migrate", nil, {
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(snap),
                  let back = try? JSONDecoder().decode(WindowSnapshot.self, from: data) else { return "encode failed" }
            var problems: [String] = []
            if back.allWorkspaces.count != 2 || back.activeWorkspace != 1 { problems.append("wrong workspace count/active") }
            if back.allWorkspaces.map(\.name) != ["api", nil] { problems.append("names lost") }
            // A pre-workspace file: {"frame": …, "root": …}.
            if var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let wss = obj["workspaces"] as? [[String: Any]] {
                obj["root"] = wss[1]["root"]
                obj["workspaces"] = nil
                obj["activeWorkspace"] = nil
                let legacy = try? JSONSerialization.data(withJSONObject: obj)
                let old = legacy.flatMap { try? JSONDecoder().decode(WindowSnapshot.self, from: $0) }
                if old?.allWorkspaces.count != 1 { problems.append("legacy file should load as one workspace") }
            } else {
                problems.append("snapshot JSON has no workspaces")
            }
            let restored = self.restoreWorkspaces(back)
            let shape = { (w: Workspace) in w.decks.map { "\($0.tabs.count)" }.joined(separator: ",") }
            if restored.map(shape) != self.workspaces.map(shape) { problems.append("restored shape differs") }
            restored.flatMap(\.panes).forEach { $0.view.removeFromSuperview() }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
        t.step("closing the last pane of a workspace closes the workspace", nil, {
            expect("1:Row(Deck0[w2, *log2], Deck1[*tests]) | *2:Deck0[*srv, db, Row(srv2, Col(edit, test2))]")
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "w4")
            self.remove(t.pane("w4"))
        }
        t.step("close a workspace", nil, {
            all(expect("*1:Deck0[*srv, db, Row(srv2, Col(edit, test2))]"),
                self.workspaceBar.button(at: 1) == nil ? nil : "switcher should show one workspace",
                focused("srv"))
        }) {
            self.remove(workspace: self.workspaces[0])
        }
    }
}
