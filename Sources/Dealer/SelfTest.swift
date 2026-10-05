import AppKit

/// `DEALER_SELFTEST=1` replays the walkthrough from the Panes and Decks design through the
/// controller, asserting the resulting tree after every step. Set it to `quit` to exit afterwards.
/// Session files are neither read nor written in this mode.
enum SelfTest {
    /// Reads `DEALER_<name>`, falling back to the pre-rename `MYTERM_<name>`.
    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        return e["DEALER_" + name] ?? e["MYTERM_" + name]
    }
    static var enabled: Bool { env("SELFTEST") != nil }
    static var quitWhenDone: Bool { env("SELFTEST") == "quit" }
    static var stepDelay: TimeInterval {
        Double(env("SELFTEST_DELAY") ?? "") ?? 0.6
    }
}

/// Lets a feature's self-test section (in its own file) add steps to the shared run.
struct SelfTestKit {
    /// (title, expected `describeTree` or nil, extra check returning a problem or nil, action)
    let step: (String, String?, (() -> String?)?, @escaping () -> Void) -> Void
    /// Gives a pane a short name for tree descriptions.
    let named: (Pane?, String) -> Void
    /// Looks a named pane up.
    let pane: (String) -> Pane
    /// A pane's short name.
    let name: (Pane) -> String
}

extension TerminalWindowController {
    /// Compact text form of the whole tree, e.g. `Row(Deck0[*Row(srv, log), db], Deck1[*log])`.
    func describeTree(names: [ObjectIdentifier: String]) -> String {
        func name(_ p: Pane) -> String { names[ObjectIdentifier(p)] ?? p.title }
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
        return root.map(deck) ?? "<empty>"
    }

    func runSelfTest(done: @escaping (Bool) -> Void) {
        var names: [ObjectIdentifier: String] = [:]
        var byName: [String: Pane] = [:]
        func named(_ p: Pane?, _ n: String) {
            guard let p else { return }
            names[ObjectIdentifier(p)] = n
            byName[n] = p
        }
        func p(_ n: String) -> Pane { byName[n]! }
        func node(_ n: String) -> Node<Pane> { locate(p(n))!.node }
        func tab(named n: String) -> Tab { decks.flatMap(\.tabs).first { $0.root.leaf === byName[n] }! }
        func visible(_ n: String) -> Bool { p(n).view.window != nil && !p(n).view.isHiddenOrHasHiddenAncestor }

        typealias Step = (title: String, run: () -> Void, expect: String?, check: (() -> String?)?)
        var steps: [Step] = []
        func step(_ title: String, expect: String? = nil, check: (() -> String?)? = nil, _ run: @escaping () -> Void) {
            steps.append((title, run, expect, check))
        }

        named(decks.first?.activeTab?.panes.first, "srv")

        // 1 · Tabs
        step("⌘T opens a tab", expect: "Deck0[srv, *db]") {
            self.newTab(nil)
            named(self.focusedPane, "db")
        }
        step("⌘1 switches back", expect: "Deck0[*srv, db]") { self.gotoTab(index: 0) }

        // 2 · Panes
        step("⌘D splits the tab into panes", expect: "Deck0[*Row(srv, log), db]",
             check: { p("log").view.showsBar && p("srv").view.showsBar ? nil : "pane bars should show" }) {
            self.splitRight(nil)
            named(self.focusedPane, "log")
        }
        step("⌘2 hides both panes", expect: "Deck0[Row(srv, log), *db]",
             check: { !visible("srv") && !visible("log") && visible("db") ? nil : "wrong visibility" }) {
            self.gotoTab(index: 1)
        }
        step("⌘1 brings them back", expect: "Deck0[*Row(srv, log), db]",
             check: { visible("srv") && visible("log") ? nil : "panes should be visible" }) {
            self.gotoTab(index: 0)
        }

        // 3 · Rearrange
        step("drop pane on bottom edge: side by side becomes stacked", expect: "Deck0[*Col(srv, log), db]") {
            self.move(node("log"), besidePane: p("srv"), side: .bottom)
        }
        step("drop pane on tab strip: becomes a tab", expect: "Deck0[srv, db, *log]",
             check: { p("log").view.showsBar ? "a single-pane tab has no bar" : nil }) {
            self.moveToNewTab(node("log"), deck: self.decks[0], index: 2)
        }
        step("⌘1", expect: "Deck0[*srv, db, log]") { self.gotoTab(index: 0) }
        step("drop tab on pane edge: rejoins as a split", expect: "Deck0[*Row(srv, log), db]") {
            self.merge(tab: tab(named: "log"), besidePane: p("srv"), side: .right)
        }

        // 4 · Decks
        step("drop pane on window edge: promote to deck", expect: "Row(Deck0[*srv, db], Deck1[*log])",
             check: { self.decks[0].view.showsColor ? nil : "decks should be tinted once there are two" }) {
            self.promote(node("log"), side: .right, allowWholeDeck: true)
        }
        step("⌘T opens in the focused deck", expect: "Row(Deck0[*srv, db], Deck1[log, *tests])") {
            self.newTab(nil)
            named(self.focusedPane, "tests")
        }
        step("switching tabs on the left leaves the right deck alone", expect: "Row(Deck0[srv, *db], Deck1[log, *tests])",
             check: { visible("tests") && visible("db") ? nil : "right deck should stay visible" }) {
            self.focus(p("srv"))
            self.gotoTab(index: 1)
        }

        // 5 · Deep promote
        var deckWidth: CGFloat = 0
        step("build a deep split", expect: "Row(Deck0[srv, db, *Row(edit, Col(srv2, Row(log2, test2)))], Deck1[log, *tests])") {
            self.focus(p("db"))
            self.newTab(nil)
            named(self.focusedPane, "edit")
            self.splitRight(nil); named(self.focusedPane, "srv2")
            self.splitDown(nil); named(self.focusedPane, "log2")
            self.splitRight(nil); named(self.focusedPane, "test2")
        }
        step("⌘⇧P hoists it to the window edge; its neighbour fills the gap",
             expect: "Row(Row(Deck0[srv, db, *Row(edit, Col(srv2, log2))], Deck1[log, *tests]), Deck2[*test2])",
             check: {
                 let w = self.decks[2].view.frame.width
                 return abs(w - deckWidth) < 40 ? nil : "promoted deck should keep its width (\(deckWidth) → \(w))"
             }) {
            deckWidth = p("test2").view.frame.width + 8
            self.focus(p("test2"))
            self.promoteToDeck(nil)
        }
        step("⌘⇧F folds it back where it came from",
             expect: "Row(Deck0[srv, db, *Row(edit, Col(srv2, Row(log2, test2)))], Deck1[log, *tests])") {
            self.focus(p("test2"))
            self.foldDeck(nil)
        }
        step("Select parent + promote moves a group",
             expect: "Row(Row(Deck0[srv, db, *Row(edit, srv2)], Deck1[log, *tests]), Deck2[*Row(log2, test2)])") {
            self.focus(p("log2"))
            self.selectParent(nil)
            self.promoteToDeck(nil)
        }
        step("fold the group back",
             expect: "Row(Deck0[srv, db, *Row(edit, Col(srv2, Row(log2, test2)))], Deck1[log, *tests])") {
            self.focus(p("log2"))
            self.foldDeck(nil)
        }

        // Focus, zoom, swap
        step("⌘⌥→ crosses into the right deck by geometry", check: {
            self.focusedPane === p("tests") ? nil : "expected tests, got \(self.focusedPane.map { names[ObjectIdentifier($0)] ?? "?" } ?? "nil")"
        }) {
            self.focus(p("test2"))
            self.moveFocus(.right)
        }
        step("⌘⌥← comes back", check: { self.focusedPane === p("test2") ? nil : "expected test2" }) {
            self.moveFocus(.left)
        }
        step("zoom fills the deck", check: {
            visible("test2") && !visible("edit") && visible("tests") ? nil : "level 1 zoom should hide siblings only"
        }) { self.toggleZoom(nil) }
        step("zoom again fills the window", check: {
            visible("test2") && !visible("tests") ? nil : "level 2 zoom should hide other decks"
        }) { self.toggleZoom(nil) }
        step("un-zoom", check: { visible("edit") && visible("tests") ? nil : "everything should be back" }) {
            self.toggleZoom(nil)
        }
        step("drop pane on centre: swap",
             expect: "Row(Deck0[srv, db, *Row(srv2, Col(edit, Row(log2, test2)))], Deck1[log, *tests])") {
            self.swap(p("edit"), p("srv2"))
        }

        // Whole-tab promote and fold
        step("promoting the only pane in a tab moves the tab out",
             expect: "Row(Deck2[*db], Row(Deck0[srv, *Row(srv2, Col(edit, Row(log2, test2)))], Deck1[log, *tests]))") {
            self.focus(p("db"))
            self.promoteToDeck(nil)
        }
        step("folding it puts the tab back in its strip",
             expect: "Row(Deck0[srv, *db, Row(srv2, Col(edit, Row(log2, test2)))], Deck1[log, *tests])") {
            self.focus(p("db"))
            self.foldDeck(nil)
        }
        step("a deck with several tabs folds into its neighbour's strip",
             expect: "Deck0[srv, db, Row(srv2, Col(edit, Row(log2, test2))), log, *tests]") {
            self.focus(p("tests"))
            self.foldDeck(nil)
        }
        step("drag a tab to the window edge: new deck",
             expect: "Col(Deck0[srv, db, Row(srv2, Col(edit, Row(log2, test2))), *tests], Deck1[*log])") {
            self.promote(tab(named: "log").root, side: .bottom, allowWholeDeck: true)
        }
        step("drag the last tab out of a deck removes the deck",
             expect: "Deck0[srv, db, Row(srv2, Col(edit, Row(log2, test2))), tests, *log]") {
            self.move(tab: tab(named: "log"), to: self.decks[0], index: 5)
        }
        step("closing the last pane of a tab closes the tab",
             expect: "Deck0[srv, db, Row(srv2, Col(edit, Row(log2, test2))), *tests]") {
            self.remove(p("log"))
        }
        step("snapshot round-trips", check: {
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(snap),
                  let back = try? JSONDecoder().decode(WindowSnapshot.self, from: data) else { return "encode failed" }
            guard let first = back.allWorkspaces.first else { return "no workspaces in snapshot" }
            let (root, _) = self.restoreTree(first.root)
            let shape = { (n: Node<Deck>) -> String in n.leaves.map { "\($0.tabs.count)" }.joined(separator: ",") }
            let ok = shape(root) == shape(self.root!)
            root.leaves.flatMap(\.tabs).flatMap(\.panes).forEach { $0.view.removeFromSuperview() }
            return ok ? nil : "restored shape differs"
        }) {}

        // Attention and jump to next unread (#4): SelfTestAttention.swift.
        steps += attentionSelfTestSteps(pane: p).map { s in (s.title, s.run, nil, s.check) }

        // Feature sections live in their own files and append steps through this kit.
        let kit = SelfTestKit(step: { step($0, expect: $1, check: $2, $3) }, named: named, pane: p,
                              name: { names[ObjectIdentifier($0)] ?? $0.title })
        pixelSelfTestSteps(kit)
        failedSelfTestSteps(kit)
        workspaceSelfTestSteps(kit)
        sidebarSelfTestSteps(kit)
        switcherSelfTestSteps(kit)
        settingsSelfTestSteps(kit)
        colorsSelfTestSteps(kit)
        titlebarTabsSelfTestSteps(kit)
        cliSelfTestSteps(kit)
        jobsSelfTestSteps(kit)
        claudeHooksSelfTestSteps(kit)
        paneCloseSelfTestSteps(kit)
        themeSelfTestSteps(kit)
        dragSettleSelfTestSteps(kit)

        var failures = 0
        func run(_ i: Int) {
            guard i < steps.count else {
                print("SELFTEST \(failures == 0 ? "PASS" : "FAIL") \(steps.count - failures)/\(steps.count)")
                fflush(stdout)
                done(failures == 0)
                return
            }
            let s = steps[i]
            s.run()
            layoutNow()
            let tree = describeTree(names: names)
            var problems: [String] = []
            if let e = s.expect, e != tree { problems.append("expected \(e)") }
            if let c = s.check?() { problems.append(c) }
            if !problems.isEmpty { failures += 1 }
            print("[\(problems.isEmpty ? "ok" : "FAIL")] \(i + 1). \(s.title)\n      \(tree)")
            problems.forEach { print("      !! \($0)") }
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + SelfTest.stepDelay) { run(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(0) }
    }
}
