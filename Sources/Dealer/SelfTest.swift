import AppKit

/// `DEALER_SELFTEST=1` replays the walkthrough from the Panes and Decks design through the
/// controller, asserting the resulting tree after every step. Set it to `quit` to exit afterwards.
/// Session files are neither read nor written in this mode.
enum SelfTest {
    /// Reads `DEALER_<name>`.
    static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment["DEALER_" + name]
    }
    static var enabled: Bool { env("SELFTEST") != nil }
    static var quitWhenDone: Bool { env("SELFTEST") == "quit" }
    /// Pause between steps. 0 by default (#47): a step that needs time waits for its own
    /// condition with `waitUntil`. Set `DEALER_SELFTEST_DELAY` (seconds) to watch the UI by eye.
    static var stepDelay: TimeInterval {
        Double(env("SELFTEST_DELAY") ?? "") ?? 0
    }

    /// The one way a step waits for something asynchronous (#47): a shell, ghostty's actions, an
    /// animation's end, AppKit's deferred release. Spins the main run loop in ~15 ms slices
    /// (ticking ghostty, whose wakeups would otherwise only arrive between steps) until `cond`
    /// holds, and gives up after `timeout`. Returns whether `cond` held. Never wait a fixed time
    /// instead; a timeout only costs time when the behavior is broken.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            guard Date() < end else { return false }
            GhosttyRuntime.shared.tick()
            RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.015)))
        }
        return true
    }

    /// `waitUntil` as a check result: nil when `cond` held, else a failure naming `what`.
    static func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) -> String? {
        waitUntil(timeout: timeout, cond) ? nil : "timed out after \(timeout) s waiting for \(what)"
    }

    /// A sheet or app-modal window that is open now, described for a failure message (#38).
    /// Self-test mode never shows confirmations (`Confirmation.autoAccept`), so one left open by
    /// a step is a bug, and it would swallow every later click and drag.
    static func openModal() -> String? {
        func text(_ w: NSWindow) -> String {
            func labels(_ v: NSView) -> [String] {
                ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels)
            }
            let alert = w.contentView.map(labels)?.filter { !$0.isEmpty } ?? []
            return alert.isEmpty ? "\(type(of: w))" : "\"\(alert.joined(separator: " / "))\""
        }
        if let m = NSApp.modalWindow { return "app-modal window \(text(m))" }
        if let w = NSApp.windows.first(where: { $0.attachedSheet != nil }), let sheet = w.attachedSheet {
            return "sheet \(text(sheet)) on window \"\(w.title)\""
        }
        return nil
    }

    /// Cancels whatever `openModal()` found, so one bad step doesn't fail the rest.
    static func dismissModals() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet, returnCode: .cancel) } }
    }

    /// Why click/drag steps may fail for reasons outside the code: a sleeping display (no active
    /// displays) or a locked screen. Printed with failures so a cascade isn't mistaken for a bug.
    static func environmentNote() -> String? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let notes = (count == 0 ? ["display asleep"] : []) + (locked ? ["screen locked"] : [])
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
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

        // #47: steps start from a run-loop timer, so a check's wait sees main-queue work (ghostty's
        // actions, socket replies hopping to main), and a timeout names its condition.
        step("runner: a step's waitUntil drains the main queue, and a timeout says what it waited for", check: {
            var delivered = false
            DispatchQueue.main.async { delivered = true }
            let drained = SelfTest.waitUntil("main-queue work", timeout: 2) { delivered }
            let timedOut = SelfTest.waitUntil("a condition that never holds", timeout: 0.05) { false }
            return [drained, timedOut?.contains("waiting for a condition that never holds") == true ? nil
                        : "a timeout should name its condition, got \(timedOut ?? "nil")"].compactMap { $0 }.first
        }) {}

        // Feature sections live in their own files and append steps through this kit.
        let kit = SelfTestKit(step: { step($0, expect: $1, check: $2, $3) }, named: named, pane: p,
                              name: { names[ObjectIdentifier($0)] ?? $0.title })
        pixelSelfTestSteps(kit)
        failedSelfTestSteps(kit)
        fadeSelfTestSteps(kit)
        workspaceSelfTestSteps(kit)
        shortcutsSelfTestSteps(kit)
        sidebarSelfTestSteps(kit)
        switcherSelfTestSteps(kit)
        selectionSelfTestSteps(kit)
        attentionStyleSelfTestSteps(kit)
        spinnerSelfTestSteps(kit)
        settingsSelfTestSteps(kit)
        colorsSelfTestSteps(kit)
        titlebarTabsSelfTestSteps(kit)
        titlebarAccentSelfTestSteps(kit)
        tabDragSelfTestSteps(kit)
        tabFitSelfTestSteps(kit)
        fileDropSelfTestSteps(kit)
        clipboardSelfTestSteps(kit)
        searchSelfTestSteps(kit)
        cliSelfTestSteps(kit)
        jobsSelfTestSteps(kit)
        cwdSelfTestSteps(kit)
        claudeHooksSelfTestSteps(kit)
        paneCloseSelfTestSteps(kit)
        themeSelfTestSteps(kit)
        dragSettleSelfTestSteps(kit)
        edgeSplitSelfTestSteps(kit)
        reloadSelfTestSteps(kit)
        ghosttyVersionSelfTestSteps(kit)
        ghosttyResourcesSelfTestSteps(kit)
        modalsSelfTestSteps(kit)
        memorySelfTestSteps(kit)
        occlusionSelfTestSteps(kit)
        notificationLogSelfTestSteps(kit)

        // `DEALER_SELFTEST_ONLY=<prefix>` keeps only the steps whose title starts with it, for a
        // quick run of one self-contained section (e.g. `memory:`). Merges always run them all.
        if let only = SelfTest.env("SELFTEST_ONLY"), !only.isEmpty {
            steps = steps.filter { $0.title.hasPrefix(only) }
        }

        // #43: `byName` keeps every named pane alive, and a closed pane's terminal costs ~50 MB of
        // GPU memory plus a shell; ~120 of them made each run ~6 GB, and parallel runs then
        // starved the GPU (a close hung in ghostty_surface_free). Free the terminal of a named pane
        // that has been in no window for two step ends; the Pane object stays for lookups.
        var closedLastStep: Set<ObjectIdentifier> = []
        func freeClosedTerminals() {
            let open = Set(AppDelegate.shared.windowControllers.flatMap(\.allDecks).flatMap(\.tabs)
                .flatMap(\.panes).map(ObjectIdentifier.init))
            let closed = byName.values.filter { !open.contains(ObjectIdentifier($0)) && $0.surface.surface != nil }
            for p in closed where closedLastStep.contains(ObjectIdentifier(p)) { p.surface.freeSurface() }
            closedLastStep = Set(closed.map(ObjectIdentifier.init))
        }

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
            // #38: a step must not leave a modal behind; name it here, then clear it.
            if let modal = SelfTest.openModal() {
                problems.append("this step left a modal open: \(modal)")
                SelfTest.dismissModals()
            }
            if !problems.isEmpty, let note = SelfTest.environmentNote() { problems.append("(environment: \(note))") }
            if !problems.isEmpty { failures += 1 }
            print("[\(problems.isEmpty ? "ok" : "FAIL")] \(i + 1). \(s.title)\n      \(tree)")
            problems.forEach { print("      !! \($0)") }
            // #43: `DEALER_SELFTEST_LIVE=1` prints live object counts after each step, to find a leak.
            if SelfTest.env("SELFTEST_LIVE") != nil { print("      live: \(LiveObjects.summary) windowsOpen=\(AppDelegate.shared.windowControllers.count) panesInTrees=\(AppDelegate.shared.windowControllers.flatMap(\.allDecks).flatMap(\.tabs).flatMap(\.panes).count)") }
            fflush(stdout)
            freeClosedTerminals()
            next(i + 1, after: SelfTest.stepDelay)
        }
        // Steps start from a run-loop timer, not a main-queue block (#47): inside a main-queue
        // block the main queue can't drain, so a step's `waitUntil` would never see ghostty's
        // actions or anything else the app delivers with `DispatchQueue.main.async`.
        func next(_ i: Int, after delay: TimeInterval) {
            RunLoop.main.add(Timer(timeInterval: delay, repeats: false) { _ in run(i) }, forMode: .default)
        }
        if let note = SelfTest.environmentNote() {
            print("SELFTEST NOTE: \(note) at start; click/drag/shell steps may skip or fail")
        }
        next(0, after: 1)
    }
}
