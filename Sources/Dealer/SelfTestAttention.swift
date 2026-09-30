import AppKit

/// Self-test section for issue #4: attention propagation, clearing, and jump to next unread.
/// Runs after the main walkthrough and leaves the tree and focus the way it found them.
extension TerminalWindowController {
    func attentionSelfTestSteps(pane p: @escaping (String) -> Pane) -> [(title: String, run: () -> Void, check: () -> String?)] {
        var steps: [(title: String, run: () -> Void, check: () -> String?)] = []
        func step(_ title: String, check: @escaping () -> String?, _ run: @escaping () -> Void) {
            steps.append((title, run, check))
        }
        func tab(_ n: String) -> Tab { locate(p(n))!.tab }
        func deck(_ n: String) -> Deck { locate(p(n))!.deck }
        func expect(_ pairs: [(String, Attention, Attention)]) -> String? {
            for (what, got, want) in pairs where got != want { return "\(what): expected \(want.name), got \(got.name)" }
            return nil
        }
        var home: Pane?
        // What the chrome shows: the tab's badge and the pane's ring.
        func badge(_ n: String) -> Attention {
            let d = deck(n)
            guard let i = d.index(of: tab(n)), d.view.strip.buttons.indices.contains(i) else { return .none }
            return d.view.strip.buttons[i].attention
        }
        func ring(_ n: String) -> Bool {
            p(n).view.layer?.sublayers?.contains { $0.name == "dealer.attentionRing" } ?? false
        }

        step("a bell in a background tab badges the pane, its tab and its deck", check: {
            expect([("srv", p("srv").attention, .unread), ("srv's tab", tab("srv").attention, .unread),
                    ("deck", deck("srv").attention, .unread), ("workspace", self.locate(p("srv"))!.workspace.attention, .unread),
                    ("tests", p("tests").attention, .none),
                    ("tests' tab", tab("tests").attention, .none), ("srv's tab badge", badge("srv"), .unread),
                    ("tests' tab badge", badge("tests"), .none)])
                ?? (ring("srv") ? nil : "srv should have a ring")
        }) {
            home = self.focusedPane
            self.setAttention(.unread, on: p("srv"), raiseOnly: true)
        }
        step("waiting beats unread, and a later bell doesn't downgrade it", check: {
            expect([("log2", p("log2").attention, .waiting), ("log2's tab", tab("log2").attention, .waiting),
                    ("deck", deck("log2").attention, .waiting), ("log2's tab badge", badge("log2"), .waiting)])
        }) {
            self.setAttention(.waiting, on: p("log2"))
            self.setAttention(.unread, on: p("log2"), raiseOnly: true)
        }
        step("jump to next unread goes to the waiting pane first and clears it", check: {
            guard self.focusedPane === p("log2") else { return "expected focus on log2" }
            return expect([("log2", p("log2").attention, .none), ("log2's tab", tab("log2").attention, .none),
                           ("deck", deck("log2").attention, .unread), ("log2's tab badge", badge("log2"), .none)])
                ?? (ring("log2") ? "log2's ring should be gone" : nil)
        }) { self.jumpToNextUnread(nil) }
        step("jump again reaches the unread pane in the other tab", check: {
            guard self.focusedPane === p("srv") else { return "expected focus on srv" }
            return expect([("srv", p("srv").attention, .none), ("deck", deck("srv").attention, .none),
                           ("workspace", self.locate(p("srv"))!.workspace.attention, .none)])
        }) { self.jumpToNextUnread(nil) }
        step("with nothing unread, jump stays put", check: {
            self.focusedPane === p("srv") ? nil : "focus should not move"
        }) { self.jumpToNextUnread(nil) }
        step("done, then an explicit none, clears a pane", check: {
            expect([("edit", p("edit").attention, .none), ("deck", deck("edit").attention, .none)])
        }) {
            self.setAttention(.done, on: p("edit"))
            self.setAttention(.none, on: p("edit"))
        }
        step("focusing a marked pane clears it", check: {
            expect([("tests", p("tests").attention, .none), ("deck", deck("tests").attention, .none)])
        }) {
            self.setAttention(.done, on: p("tests"))
            if let home { self.focus(home) }
        }
        return steps
    }
}
