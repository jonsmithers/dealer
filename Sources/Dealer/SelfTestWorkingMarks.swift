import AppKit

// MARK: - Self-test section: which working mark (#81, AgentStatus.swift, RunningSpinner.swift)
//
// Self-contained (`DEALER_SELFTEST_ONLY=marks:`): OSC 9;4 progress is anyone's, so the chrome shows
// Claude's sprite only for Claude Code (the foreground process group, else its working title), a
// turning arc for other programs and a ring for a percentage; Claude outranks the rest on a
// workspace entry and on a collapsed group's header.

extension TerminalWindowController {
    func workingMarksSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        var claudeLink: String?
        let savedSwitcher = Settings.workspaceSwitcher

        func all(_ problems: [String?]) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        @discardableResult
        func call(_ cmd: String, _ args: [String: Any] = [:], caller: String? = nil) -> [String: Any]? {
            var req: [String: Any] = ["cmd": cmd, "args": args]
            if let caller { req["caller"] = ids[caller] }
            let r = ControlHandler.handle(req)
            guard r["ok"] as? Bool == true else { lastError = "\(cmd) failed: \(r["error"] ?? "?")"; return nil }
            return r["result"] as? [String: Any]
        }
        func created(_ r: [String: Any]?, _ name: String) {
            guard let id = r?["pane"] as? Int, let p = ControlHandler.pane(id: id) else { return }
            ids[name] = id
            t.named(p, name)
        }
        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func ws(_ name: String) -> Workspace? { workspaces.first { $0.name == name } }
        func tabButton(_ p: Pane?) -> TabButton? {
            guard let p, let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return nil }
            return loc.deck.view.strip.buttons[i]
        }
        func row(_ w: Workspace?) -> WorkspaceRow? {
            guard let w, let i = workspaces.firstIndex(where: { $0 === w }) else { return nil }
            return workspaceSidebar.row(at: i) as? WorkspaceRow
        }
        func pill(_ w: Workspace?) -> WorkspaceButton? {
            guard let w, let i = workspaces.firstIndex(where: { $0 === w }) else { return nil }
            return workspaceBar.button(at: i) as? WorkspaceButton
        }
        /// A report as ghostty's PROGRESS_REPORT delivers it, with who's in the foreground faked.
        func report(_ n: String, _ active: Bool, percent: Int? = nil, claude: Bool = false) {
            guard let p = pane(n) else { return }
            ProgressSource.foregroundOverride = { _ in claude }
            _ = ProgressSource.note(p, active: active, percent: percent, foreground: 1)
            ProgressSource.foregroundOverride = nil
            refreshChrome()
            layoutNow()
        }
        func show(_ m: WorkingMark?) -> String { m.map { "\($0)" } ?? "none" }
        func want(_ what: String, _ got: WorkingMark?, _ expected: WorkingMark?) -> String? {
            got == expected ? nil : "\(what) shows \(show(got)), want \(show(expected))"
        }

        t.step("marks: Claude Code is recognized by argv and executable path, never by its process name", nil, {
            let yes: [(String, [String])] = [
                ("/Users/u/.local/share/claude/versions/2.1.304", ["claude", "--resume"]),  // native install
                ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude"]),           // npm install
                ("/usr/local/bin/node", ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
                ("/bin/zsh", ["zsh", "/Users/u/bin/claude"]),                                 // a launcher script
                ("/opt/claude-bin", ["/opt/x/claude"]),
            ]
            let no: [(String, [String])] = [
                ("/opt/homebrew/bin/cargo", ["cargo", "build"]),
                ("/opt/homebrew/bin/zig", ["zig", "build"]),
                ("/usr/bin/vim", ["vim", "claude"]),          // only an interpreter's argument names the program
                ("/bin/zsh", ["-zsh"]),
                ("/usr/local/bin/2.1.304", ["codex"]),
            ]
            var p: [String?] = []
            for (path, argv) in yes where !ProgressSource.isClaude(path: path, argv: argv) { p.append("missed Claude: \(argv)") }
            for (path, argv) in no where ProgressSource.isClaude(path: path, argv: argv) { p.append("took \(argv) for Claude") }
            return all(p)
        }) {}

        t.step("marks: a roll-up shows the strongest mark: Claude over an arc over a ring, the least complete ring", nil, {
            let s: ([WorkingMark]) -> WorkingMark? = { WorkingMark.strongest($0) }
            return all([want("[ring 40, claude, arc]", s([.ring(40), .claude, .arc]), .claude),
                        want("[ring 40, arc]", s([.ring(40), .arc]), .arc),
                        want("[ring 70, ring 20, ring 90]", s([.ring(70), .ring(20), .ring(90)]), .ring(20)),
                        want("[]", s([]), nil)])
        }) {}

        t.step("marks: a percentage draws a ring, other programs an arc, Claude its sprite; the tab follows its pane, the workspace entry ranks Claude first", nil, {
            guard let a = pane("mk-a"), let b = pane("mk-b") else { return all(["setup failed"]) }
            let w = self.locate(a)?.workspace
            return all([want("the Claude pane", a.workingMark, .claude),
                        want("the cargo-like pane", b.workingMark, .ring(40)),
                        want("the Claude tab", tabButton(a)?.working, .claude),
                        want("the ring tab", tabButton(b)?.working, .ring(40)),
                        want("the sidebar row", row(w)?.working, .claude),
                        want("the pill", pill(w)?.working, .claude),
                        b.statusLine.hasPrefix("running") ? nil : "the ring pane's bar should say running: \(b.statusLine)"])
        }) {
            created(call("create", ["type": "workspace", "target": "focused", "name": "marks"]), "mk-a")
            created(call("create", ["type": "tab", "focus": false], caller: "mk-a"), "mk-b")
            report("mk-a", true, claude: true)
            report("mk-b", true, percent: 40)
        }

        t.step("marks: without Claude the entry shows an arc over a ring; a new percentage redraws the ring; clearing drops every mark", nil, {
            guard let a = pane("mk-a"), let b = pane("mk-b") else { return all(["setup failed"]) }
            let w = self.locate(a)?.workspace
            var p: [String?] = [want("the row with an arc and a ring", row(w)?.working, .arc)]
            report("mk-a", false)
            p.append(want("the row with only a ring", row(w)?.working, .ring(40)))
            report("mk-b", true, percent: 75)
            p.append(want("the ring tab after 75%", tabButton(b)?.working, .ring(75)))
            report("mk-b", false)
            p.append(want("the row at rest", row(w)?.working, nil))
            p.append(want("the ring tab at rest", tabButton(b)?.working, nil))
            p.append(b.progressPercent == nil ? nil : "a cleared report should drop the percentage")
            return all(p)
        }) {
            report("mk-a", true)  // the same pane, now some other program
        }

        t.step("marks: Claude's working title (◐/◑) makes the mark Claude's when the process table can't say", nil, {
            guard let a = pane("mk-a") else { return all(["setup failed"]) }
            var p: [String?] = [want("a pane titled ◐", a.workingMark, .claude),
                                a.title == "task" ? nil : "the glyph should still be stripped from the title (\(a.title))"]
            a.surface.onTitle?("✳ task")
            p.append(want("the same pane titled ✳", a.workingMark, .arc))
            report("mk-a", false)
            return all(p)
        }) {
            report("mk-a", true)
            pane("mk-a")?.surface.onTitle?("◐ task")
        }

        t.step("marks: a collapsed group's header shows its members' strongest mark, Claude first, in the sidebar and the top bar", nil, {
            guard let g = self.groups.first(where: { $0.name == "Marks" }), let h = self.workspaceSidebar.header(for: g)
            else { return all(["setup failed: no group header"]) }
            var p: [String?] = [want("the collapsed header", h.working, .claude)]
            Settings.workspaceSwitcher = .top
            self.refreshChrome(); self.layoutNow()
            p.append(want("the collapsed label pill", self.workspaceBar.label(for: g)?.working, .claude))
            report("mk-a", false)
            p.append(want("the label pill without Claude", self.workspaceBar.label(for: g)?.working, .arc))
            Settings.workspaceSwitcher = savedSwitcher
            self.setCollapsed(g, false)
            self.refreshChrome(); self.layoutNow()
            p.append(want("the expanded header", h.working, nil))
            return all(p)
        }) {
            // Two workspaces in one group: "marks" (Claude) and "marks 2" (some other program).
            created(call("create", ["type": "workspace", "target": "focused", "name": "marks 2", "focus": false], caller: "mk-a"), "mk-c")
            if let m = ws("marks"), let m2 = ws("marks 2") {
                let g = self.moveToNewGroup(m, name: "Marks")
                self.move(m2, toGroup: g)
                // Collapse with the active workspace outside it, so the header stands in for both.
                if let other = self.workspaces.first(where: { $0.group == nil }) { self.activate(other) }
                self.setCollapsed(g, true)
            }
            report("mk-a", true, claude: true)
            report("mk-c", true)
            self.refreshChrome()
            self.layoutNow()
        }

        // The drawing: the arc leaves a quarter open and turns; the ring fills clockwise from 12.
        t.step("marks: the arc turns with a quarter open; the ring fills clockwise from 12 o'clock over a faint track (2x and 1x)", nil, {
            let problems = PixelProbe.atEachScale { _ in
                var p: [String] = []
                let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
                tab.isActive = true
                let box = tab.spinnerBox
                let stroke = box.width * RunningSpinner.strokeFraction
                let r = (box.width - stroke) / 2
                /// The strongest ink near the circle at `turns` past 12 o'clock, clockwise on screen.
                func ink(at turns: CGFloat) -> CGFloat {
                    let a = turns * 2 * .pi
                    let up: CGFloat = tab.isFlipped ? -1 : 1
                    let c = CGPoint(x: box.midX + r * sin(a), y: box.midY + up * r * cos(a))
                    let spot = CGRect(x: c.x - stroke / 2, y: c.y - stroke / 2, width: stroke, height: stroke)
                    return PixelProbe.samples(tab, in: spot)
                        .compactMap { PixelProbe.coverage(of: Theme.text, on: Theme.surface, in: $0) }.max() ?? 0
                }
                RunningSpinner.phaseOverride = 0
                tab.working = .arc
                // At phase 0 the arc runs from 12 o'clock clockwise through 3, 6 and 9; 10:30 is open.
                for t in [0.25, 0.5, 0.65] as [CGFloat] where ink(at: t) < 0.75 { p.append("arc: no ink at \(t) turns (\(ink(at: t)))") }
                if ink(at: 0.875) > 0.2 { p.append("arc: ink in the open quarter (\(ink(at: 0.875)))") }
                let first = PixelProbe.pixels(tab, rect: box)
                RunningSpinner.phaseOverride = 0.2
                if first == nil || first == PixelProbe.pixels(tab, rect: box) { p.append("arc: phase 0 and 0.2 draw the same pixels") }
                RunningSpinner.phaseOverride = 0
                tab.working = .ring(50)
                if ink(at: 0.25) < 0.75 { p.append("ring 50%: the right half isn't filled (\(ink(at: 0.25)))") }
                let track = ink(at: 0.75)
                if abs(track - RunningSpinner.ringTrackOpacity) > 0.15 { p.append("ring 50%: the left half's track is \(track), want about \(RunningSpinner.ringTrackOpacity)") }
                tab.working = .ring(100)
                if ink(at: 0.75) < 0.75 { p.append("ring 100%: the left half isn't filled (\(ink(at: 0.75)))") }
                tab.working = .ring(0)
                if ink(at: 0.25) > RunningSpinner.ringTrackOpacity + 0.15 { p.append("ring 0%: more than the track at 3 o'clock (\(ink(at: 0.25)))") }
                RunningSpinner.phaseOverride = nil
                return p
            }
            return all(problems)
        }) {}

        // End to end: real OSC 9;4 from a shell, and from a process whose argv says `claude`.
        t.step("marks: live: a shell's 9;4;3 is an arc and 9;4;1;40 a ring; the same from a process named claude is Claude's", nil, {
            guard let c = pane("mk-c") else { return all(["setup failed"]) }
            guard c.surface.surface != nil else {
                print("      (skipped the live working-mark check: ghostty couldn't create terminal surfaces here)")
                return all([])
            }
            var p: [String?] = []
            c.surface.typeText("printf '\\033]9;4;3\\007'\r")
            p.append(SelfTest.waitUntil("the shell's 9;4;3 to show an arc", timeout: 10) { c.workingMark == .arc })
            c.surface.typeText("printf '\\033]9;4;1;40\\007'\r")
            p.append(SelfTest.waitUntil("the shell's 9;4;1;40 to show a ring", timeout: 10) { c.workingMark == .ring(40) })
            c.surface.typeText("printf '\\033]9;4;0\\007'\r")
            p.append(SelfTest.waitUntil("9;4;0 to clear it", timeout: 10) { c.workingMark == nil })
            if let link = claudeLink {
                // `claude` is a link to /bin/sh: its argv[0] says claude, and it sends the report itself.
                c.surface.typeText("'\(link)' -c \"printf '\\033]9;4;3\\007'; sleep 30\"\r")
                p.append(SelfTest.waitUntil("a process named claude to show Claude's mark", timeout: 10) { c.workingMark == .claude })
                c.surface.typeText("\u{03}")
                c.surface.typeText("printf '\\033]9;4;0\\007'\r")
                p.append(SelfTest.waitUntil("its progress to clear", timeout: 10) { c.workingMark == nil })
            } else {
                p.append("couldn't make the claude link")
            }
            return all(p)
        }) {
            let dir = NSTemporaryDirectory() + "dealer-marks-\(getpid())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let link = dir + "/claude"
            try? FileManager.default.removeItem(atPath: link)
            if (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/sh")) != nil { claudeLink = link }
            if let m2 = ws("marks 2") { self.activate(m2) }
            report("mk-c", false)
            self.layoutNow()
            pane("mk-c")?.surface.waitForShell()
        }

        t.step("marks: clean up", nil, {
            all([self.workspaces.contains { $0.name?.hasPrefix("marks") == true } ? "the test workspaces should be gone" : nil,
                 ProgressSource.foregroundOverride == nil ? nil : "the foreground override should be cleared"])
        }) {
            Settings.workspaceSwitcher = savedSwitcher
            for n in ["marks", "marks 2"] { if let w = ws(n) { self.remove(workspace: w) } }
            if let link = claudeLink { try? FileManager.default.removeItem(atPath: (link as NSString).deletingLastPathComponent) }
            ProgressSource.foregroundOverride = nil
            RunningSpinner.phaseOverride = nil
            self.layoutNow()
            lastError = nil
        }
    }
}
