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
        t.step("memory: a closed window frees its controller, workspaces and panes", nil, {
            unchanged("closing a window", only: [.window, .workspace, .deck, .tab, .pane])
        }) {
            cycle {
                AppDelegate.shared.newWindow(nil)
                guard let wc = AppDelegate.shared.windowControllers.last, wc !== self else { return }
                if let a = wc.focusedPane { wc.split(a, side: .right) }
                _ = wc.newWorkspace()
                closedWindows.append(WeakRef(wc.window))
                wc.window?.close()
            }
            self.window?.makeKeyAndOrderFront(nil)
        }
        // AppKit lets go of a closed window's views a run-loop turn later, so check them here.
        t.step("memory: …and, a moment later, its views and surfaces", nil, {
            let open = closedWindows.filter { $0.value != nil }.count
            let windows = open == 0 ? nil : "\(open) closed NSWindow(s) still alive"
            return [unchanged("closing a window"), windows].compactMap { $0 }.joined(separator: "; ").nilIfEmpty
        }) {}
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
