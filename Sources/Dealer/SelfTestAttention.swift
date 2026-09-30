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

        // Across workspaces
        var ws2: Workspace?
        step("a pane in a background workspace badges it", check: {
            guard self.workspaces.count == 2, self.activeWorkspace === ws2 else { return "expected a second, active workspace" }
            return expect([("workspace 1", self.workspaces[0].attention, .waiting), ("workspace 2", ws2!.attention, .none)])
        }) {
            self.setAttention(.waiting, on: p("srv"))
            ws2 = self.newWorkspace()
        }
        step("jump to next unread switches back to that workspace", check: {
            guard self.activeWorkspace === self.workspaces.first else { return "should be back in workspace 1" }
            guard self.focusedPane === p("srv") else { return "expected focus on srv" }
            return expect([("srv", p("srv").attention, .none), ("workspace 1", self.workspaces[0].attention, .none)])
        }) { self.jumpToNextUnread(nil) }
        step("clean up the extra workspace", check: {
            self.workspaces.count == 1 ? nil : "expected one workspace"
        }) {
            if let ws2 { self.remove(workspace: ws2) }
            if let home { self.focus(home) }
        }

        // Status line
        step("the pane bar shows agent state: waiting, then running", check: {
            let e = p("edit"), t = p("test2")
            if !e.statusLine.hasPrefix("waiting") { return "edit status: \(e.statusLine)" }
            if e.view.bar.status != e.statusLine { return "edit's bar should show its status" }
            if !t.statusLine.hasPrefix("running") { return "test2 status: \(t.statusLine)" }
            return nil
        }) {
            self.setAttention(.waiting, on: p("edit"))
            p("test2").isReportingProgress = true
            self.refreshChrome()
        }
        step("clearing attention and progress leaves just the cwd", check: {
            let states = ["waiting", "running", "done"]
            return ["edit", "test2"].contains { n in states.contains { p(n).statusLine.hasPrefix($0) } } ? "state should be gone" : nil
        }) {
            self.setAttention(.none, on: p("edit"))
            p("test2").isReportingProgress = false
            self.refreshChrome()
        }
        step("git branch is read from HEAD, including worktrees", check: {
            let tmp = NSTemporaryDirectory() + "dealer-git-\(getpid())"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            let fm = FileManager.default
            try? fm.createDirectory(atPath: tmp + "/repo/.git", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: tmp + "/repo/sub/dir", withIntermediateDirectories: true)
            try? "ref: refs/heads/feature/x\n".write(toFile: tmp + "/repo/.git/HEAD", atomically: true, encoding: .utf8)
            try? fm.createDirectory(atPath: tmp + "/wtmeta", withIntermediateDirectories: true)
            try? "0123456789abcdef\n".write(toFile: tmp + "/wtmeta/HEAD", atomically: true, encoding: .utf8)
            try? fm.createDirectory(atPath: tmp + "/wt", withIntermediateDirectories: true)
            try? "gitdir: ../wtmeta\n".write(toFile: tmp + "/wt/.git", atomically: true, encoding: .utf8)
            let a = GitInfo.lookup(tmp + "/repo/sub/dir"), b = GitInfo.lookup(tmp + "/wt")
            if a?.branch != "feature/x" || a.map({ ($0.root as NSString).lastPathComponent }) != "repo" { return "repo lookup: \(String(describing: a))" }
            if b?.branch != "0123456" { return "worktree lookup: \(String(describing: b))" }
            return nil
        }) {}

        // Launch presets
        var agent: Pane?
        step("New Agent Pane splits beside the focused pane and starts the agent", check: {
            guard let agent, let loc = self.locate(agent) else { return "no agent pane" }
            if loc.tab !== tab("tests") { return "agent pane should share the tab with tests" }
            return self.focusedPane === agent ? nil : "agent pane should be focused"
        }) {
            AgentPreset.commandOverride = "true"
            self.focus(p("tests"))
            agent = self.newAgentPane(beside: p("tests"))
        }
        step("worktree preset builds a quoted shell line", check: {
            let got = AgentPreset.worktreeCommand(repoRoot: "/r/my repo", name: "agent-1")
            let want = "git -C '/r/my repo' worktree add -b 'agent-1' '/r/my repo.worktrees/agent-1' && cd '/r/my repo.worktrees/agent-1' && true"
            return got == want ? nil : "got \(got)"
        }) {
            if let agent { self.remove(agent) }
            if let home { self.focus(home) }
        }
        step("preset override is cleared", check: { nil }) { AgentPreset.commandOverride = nil }

        return steps
    }
}
