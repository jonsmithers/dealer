import AppKit

// MARK: - Self-test section: nothing outlives a create/close cycle (issue #43)

extension TerminalWindowController {
    /// Each step runs a create/close cycle a few times and requires every `LiveObjects` count
    /// (windows, workspaces, decks, tabs, panes, their views, SurfaceViews, ghostty surfaces) to be
    /// back where it started. A leaked pane keeps its shell, its threads and its renderer memory
    /// (tens of MB at window size), so one leak per closed split adds up to gigabytes.
    /// Panes made here are never `named`: the self-test's name table holds panes strongly.
    func memorySelfTestSteps(_ t: SelfTestKit) {
        let cycles = 3
        var baseline: [LiveObjects.Kind: Int] = [:]
        var closedWindows: [WeakRef<NSWindow>] = []

        /// Compares with `baseline`, naming every count that moved.
        func unchanged(_ what: String, only kinds: [LiveObjects.Kind] = LiveObjects.Kind.allCases) -> String? {
            let now = LiveObjects.snapshot
            let moved = kinds.filter { now[$0] != baseline[$0] }
            guard !moved.isEmpty else { return nil }
            let diff = moved.map { "\($0.rawValue) \(baseline[$0] ?? 0)→\(now[$0] ?? 0)" }.joined(separator: ", ")
            return "\(what) left objects behind after \(cycles) cycles: \(diff)"
        }
        /// Runs `body` `cycles` times, each in its own autorelease pool, so released views are gone
        /// by the time the step's check runs.
        func cycle(_ body: () -> Void) {
            baseline = LiveObjects.snapshot
            for _ in 0..<cycles { autoreleasepool { body() } }
            layoutNow()
        }
        func handle(_ cmd: String, _ args: [String: Any]) -> [String: Any]? {
            let r = ControlHandler.handle(["cmd": cmd, "args": args])
            return r["ok"] as? Bool == true ? r["result"] as? [String: Any] : nil
        }

        t.step("memory: a closed split tab frees its panes and surfaces (divider closures held them)", nil, {
            unchanged("closing a split tab")
        }) {
            cycle {
                guard let deck = self.focusedDeck else { return }
                self.newTab(in: deck)
                guard let a = self.focusedPane, let tab = self.locate(a)?.tab else { return }
                self.split(a, side: .right)
                if let b = self.focusedPane { self.split(b, side: .bottom) }
                self.close(tab: tab)
            }
        }
        t.step("memory: panes closed one by one out of a split free everything", nil, {
            unchanged("closing panes of a split")
        }) {
            cycle {
                guard let deck = self.focusedDeck else { return }
                self.newTab(in: deck)
                guard let a = self.focusedPane else { return }
                self.split(a, side: .right)
                guard let b = self.focusedPane else { return }
                self.split(b, side: .bottom)
                if let c = self.focusedPane { self.remove(c) }
                self.remove(b)
                self.remove(a)
            }
        }
        t.step("memory: a promoted deck with a split, closed, frees everything", nil, {
            unchanged("closing a promoted deck")
        }) {
            cycle {
                guard let deck = self.focusedDeck else { return }
                self.newTab(in: deck)
                guard let a = self.focusedPane else { return }
                self.split(a, side: .right)
                guard let b = self.focusedPane, let node = self.locate(b)?.node else { return }
                self.promote(node, side: .right)
                self.split(b, side: .bottom)
                for p in [self.focusedPane, b, a].compactMap({ $0 }) where self.locate(p) != nil { self.remove(p) }
            }
        }
        t.step("memory: a closed workspace with splits and tabs frees everything", nil, {
            unchanged("closing a workspace")
        }) {
            cycle {
                let home = self.activeWorkspace
                let ws = self.newWorkspace()
                if let a = self.focusedPane { self.split(a, side: .right) }
                if let deck = self.focusedDeck { self.newTab(in: deck) }
                self.remove(workspace: ws)
                self.activate(home)
            }
        }
        t.step("memory: a tab moved to a new workspace, then closed, frees everything", nil, {
            unchanged("moving a tab to a new workspace and closing it")
        }) {
            cycle {
                let home = self.activeWorkspace
                guard let deck = self.focusedDeck else { return }
                self.newTab(in: deck)
                guard let a = self.focusedPane, let tab = self.locate(a)?.tab else { return }
                self.split(a, side: .right)
                if let ws = self.move(tab: tab, toWorkspace: nil) { self.remove(workspace: ws) }
                self.activate(home)
            }
        }
        t.step("memory: CLI create pane/tab/deck/workspace + close frees everything", nil, {
            unchanged("dealer create + close")
        }) {
            cycle {
                for kind in ["pane", "tab", "deck", "workspace"] {
                    guard let id = handle("create", ["type": kind, "target": "focused", "focus": false])?["pane"] as? Int else { continue }
                    _ = handle("close", ["target": "pane:\(id)"])
                }
            }
        }
        // Checked right after the closes, while AppKit still holds the closed NSWindows (its close
        // animation keeps each one about 0.3 s): their views and surfaces must already be gone.
        t.step("memory: a closed window frees its controller, workspaces, panes, views and surfaces", nil, {
            unchanged("closing a window")
        }) {
            cycle {
                AppDelegate.shared.newWindow(nil)
                guard let wc = AppDelegate.shared.windowControllers.last, wc !== self else { return }
                if let a = wc.focusedPane { wc.split(a, side: .right) }
                _ = wc.newWorkspace()
                closedWindows.append(WeakRef(wc.window))
                // No close animation, so the run doesn't depend on how fast it runs under load.
                wc.window?.animationBehavior = .none
                wc.window?.close()
            }
            self.window?.makeKeyAndOrderFront(nil)
        }
        // When AppKit frees a closed NSWindow is its business and not deterministic inside the
        // runner: at a 0.6 s step delay it's gone, at delay 0 two of three outlive even a 10 s
        // poll (held until the step's outer main-queue block returns), and animated closes take
        // seconds under load (#43). What the leak was about is checked instead: a closed window
        // that's still alive holds no deck, pane or terminal view, and the counts stay down.
        t.step("memory: …and closed windows that AppKit still holds keep no decks, panes or terminals", nil, {
            func heavy(_ v: NSView) -> Int { (v is DeckView || v is PaneView || v is SurfaceView ? 1 : 0) + v.subviews.reduce(0) { $0 + heavy($1) } }
            let held = closedWindows.compactMap(\.value).compactMap(\.contentView).map(heavy).reduce(0, +)
            let alive = closedWindows.filter { $0.value != nil }.count
            if alive > 0 { print("      (\(alive) closed NSWindow(s) not yet freed by AppKit, holding \(held) heavy views)") }
            return [unchanged("closing a window"), held == 0 ? nil : "closed windows still hold \(held) deck/pane/terminal views"]
                .compactMap { $0 }.joined(separator: "; ").nilIfEmpty
        }) {}

        // A hidden pane gives back its renderer's GPU memory (#43). libghostty since c4e16970a frees
        // the swap chain (3 window-sized render targets, plus 6 more with a custom shader) when a
        // surface is occluded; at the old pin each hidden pane kept them (about 3.7 buffers each).
        var hiddenCost: (perPane: Double, buffer: Double)?
        t.step("memory: panes in background tabs give back their renderer memory (GPU swap chain)", nil, {
            guard let c = hiddenCost else { return nil }  // skipped (printed why)
            let mb = { (b: Double) in String(format: "%.1f MB", b / 1_048_576) }
            let limit = max(1.5 * c.buffer, 8 * 1_048_576)
            return c.perPane < limit ? nil
                : "each hidden pane still costs \(mb(c.perPane)) (a window-sized buffer is \(mb(c.buffer)), limit \(mb(limit)))"
        }) {
            hiddenCost = nil
            guard let deck = self.focusedDeck else { return }
            func footprint() -> Double { Double(Diagnostics.memory().footprint) }
            var tabs: [Tab] = []
            defer { tabs.forEach { self.close(tab: $0) } }
            self.newTab(in: deck)
            guard let first = deck.activeTab, let pane = first.panes.first, pane.surface.surface != nil else {
                print("      (skipped: no live surface, screen locked?)")
                return
            }
            tabs.append(first)
            self.layoutNow()
            let px = pane.surface.convertToBacking(pane.surface.bounds.size)
            let buffer = Double(px.width * px.height * 4)
            guard buffer > 3 * 1_048_576 else { print("      (skipped: pane too small to tell, \(px))"); return }
            // Each shown pane allocates its render targets on its first frames.
            func showNewTab() {
                let before = footprint()
                self.newTab(in: deck)
                if let t = deck.activeTab { tabs.append(t) }
                self.layoutNow()
                _ = SelfTest.waitUntil(timeout: 2) { footprint() - before > 2 * buffer }
            }
            showNewTab()
            let base = footprint()  // `first` hidden, one pane shown
            let hidden = 4
            for _ in 0..<hidden { showNewTab() }
            self.select(tab: first, in: deck)
            self.layoutNow()
            // Now `hidden` + 1 panes are hidden, against `base`'s one hidden and one shown: `hidden`
            // more hidden panes. Release happens on their render threads.
            _ = SelfTest.waitUntil(timeout: 3) { (footprint() - base) / Double(hidden) < 1.5 * buffer }
            hiddenCost = (max(0, footprint() - base) / Double(hidden), buffer)
            print(String(format: "      (each hidden pane: %.1f MB; a window-sized buffer: %.1f MB)",
                         hiddenCost!.perPane / 1_048_576, buffer / 1_048_576))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
