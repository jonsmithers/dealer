import AppKit
import GhosttyKit

// MARK: - Self-test section: scripting CLI / control socket (issue #5)

extension TerminalWindowController {
    /// Drives every CLI command through `ControlHandler.handle` (the same function the socket
    /// calls), in a workspace of its own, then does one real socket round-trip with the binary.
    func cliSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        let tmp = NSTemporaryDirectory() + "dealer-selftest-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

        @discardableResult
        func call(_ cmd: String, _ args: [String: Any] = [:], caller: String? = nil) -> [String: Any]? {
            var req: [String: Any] = ["cmd": cmd, "args": args]
            if let caller { req["caller"] = ids[caller] }
            let r = ControlHandler.handle(req)
            guard r["ok"] as? Bool == true else {
                lastError = "\(cmd) failed: \(r["error"] ?? "?")"
                return nil
            }
            lastError = nil
            return r["result"] as? [String: Any]
        }
        func created(_ r: [String: Any]?, _ name: String) {
            guard let id = r?["pane"] as? Int, let p = ControlHandler.pane(id: id) else { return }
            ids[name] = id
            t.named(p, name)
        }
        func tree(_ e: String) -> String? {
            let got = self.describeTreeNamed(t)
            return got == e ? nil : "expected \(e)\n         got      \(got)"
        }
        func focused(_ n: String) -> String? {
            ControlHandler.focusedPane === t.pane(n) ? nil
                : "focus should be on \(n), is on \(ControlHandler.focusedPane.map(t.name) ?? "nil")"
        }
        func all(_ problems: String?...) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func node(_ n: String) -> Node<Pane>? { locate(t.pane(n))?.node }
        /// Share of `n`'s parent split held by `n`.
        func share(_ n: String) -> CGFloat {
            guard let x = node(n), let p = x.parent else { return -1 }
            return p.a === x ? p.ratio : 1 - p.ratio
        }
        /// ghostty can fail to create surfaces (no GPU/display, e.g. a locked screen); checks that
        /// need a running shell or cell metrics are skipped then, and say so.
        var live: Bool { t.pane("c0").surface.surface != nil }
        func skipped(_ what: String) -> String? {
            print("      (skipped \(what): ghostty couldn't create terminal surfaces here)")
            return nil
        }

        t.step("cli: create workspace", nil, {
            all(tree("Deck0[*c0]"), self.activeWorkspace.decks.first?.activeTab?.panes.first === ControlHandler.pane(id: ids["c0"] ?? -1) ? nil : "new workspace should be active")
        }) {
            created(call("create", ["type": "workspace", "target": "focused", "name": "cli"]), "c0")
        }
        t.step("cli: create pane --side down --size 6 --no-focus --title", nil, {
            let rows = t.pane("c1").surface.surface.map { Int(ghostty_surface_size($0).rows) } ?? -1
            return all(tree("Deck0[*Col(c0, c1)]"), focused("c0"),
                       t.pane("c1").title == "RUN make" ? nil : "title should be 'RUN make'",
                       !live ? skipped("--size in rows") : share("c1") < 0.45 ? nil : "--size 6 should give a small pane, got share \(share("c1"))",
                       !live ? nil : abs(rows - 6) <= 2 ? nil : "--size 6 gave \(rows) rows")
        }) {
            created(call("create", ["side": "down", "size": "6", "focus": false, "title": "RUN make"], caller: "c0"), "c1")
        }
        t.step("cli: create pane --side right --size 30% (takes focus)", nil, {
            all(tree("Deck0[*Col(Row(c0, c2), c1)]"), focused("c2"),
                abs(share("c2") - 0.3) < 0.01 ? nil : "share should be 0.3, is \(share("c2"))")
        }) {
            created(call("create", ["target": "pane:\(ids["c0"]!)", "side": "right", "size": "30%"]), "c2")
        }
        t.step("cli: create tab --no-focus opens in the background", nil, {
            all(tree("Deck0[*Col(Row(c0, c2), c1), c3]"), focused("c2"))
        }) {
            created(call("create", ["type": "tab", "focus": false, "title": "bg"]), "c3")
        }
        t.step("cli: create deck --side right --size 0.25 --no-focus", nil, {
            all(tree("Row(Deck0[*Col(Row(c0, c2), c1), c3], Deck1[*c4])"), focused("c2"))
        }) {
            created(call("create", ["type": "deck", "side": "right", "size": "0.25", "focus": false], caller: "c2"), "c4")
        }
        t.step("cli: focus tab:N switches tab and focuses its pane", nil, {
            all(tree("Row(Deck0[Col(Row(c0, c2), c1), *c3], Deck1[*c4])"), focused("c3"))
        }) {
            let tab = self.locate(t.pane("c3"))!.tab
            call("focus", ["target": "tab:\(tab.id)"])
        }
        t.step("cli: focus pane:N brings its tab back", nil, {
            all(tree("Row(Deck0[*Col(Row(c0, c2), c1), c3], Deck1[*c4])"), focused("c1"))
        }) {
            call("focus", ["target": "\(ids["c1"]!)"])
        }
        t.step("cli: identify reports caller and focus (synchronously)", nil, {
            let r = call("identify", caller: "c0")
            let caller = (r?["caller"] as? [String: Any])?["pane"] as? Int
            let focus = (r?["focused"] as? [String: Any])?["pane"] as? Int
            return all(caller == ids["c0"] ? nil : "caller should be c0", focus == ids["c1"] ? nil : "focused should be c1")
        }) {}
        t.step("cli: resize --to 40% then --by +10%", nil, {
            all(abs(share("c1") - 0.5) < 0.01 ? nil : "share should end at 0.5, is \(share("c1"))")
        }) {
            call("resize", ["target": "\(ids["c1"]!)", "to": "40%"])
            if abs(share("c1") - 0.4) > 0.01 { lastError = "--to 40% gave \(share("c1"))"; return }
            call("resize", ["target": "\(ids["c1"]!)", "by": "+10%"])
        }
        t.step("cli: resize a deck by cells", nil, {
            if !live { lastError = nil; return skipped("resize by cells") }
            let d = self.locate(t.pane("c4"))!.deck
            let s = self.root.flatMap { $0.node(for: d) }.map { $0.parent!.b === $0 ? 1 - $0.parent!.ratio : $0.parent!.ratio } ?? 0
            return all(s > 0.25 && s < 0.6 ? nil : "deck share should grow past 0.25, is \(s)")
        }) {
            let d = self.locate(t.pane("c4"))!.deck
            call("resize", ["target": "deck:\(d.id)", "by": "+10"])
        }
        t.step("cli: rename pane and tab", nil, {
            all(t.pane("c2").title == "editor" ? nil : "pane title should be editor",
                self.locate(t.pane("c0"))!.tab.title == "work" ? nil : "tab title should be work")
        }) {
            call("rename", ["target": "\(ids["c2"]!)", "title": "editor"])
            call("rename", ["target": "\(ids["c0"]!)", "level": "tab", "title": "work"])
        }
        t.step("cli: color a tab and its workspace (#9); none clears", nil, {
            let tab = self.locate(t.pane("c0"))!.tab, ws = self.locate(t.pane("c0"))!.workspace
            let listed = (call("list")?["windows"] as? [[String: Any]] ?? []).flatMap { $0["workspaces"] as? [[String: Any]] ?? [] }
                .first { $0["id"] as? Int == ws.id }
            return all(tab.color?.hexString == "#123456" ? nil : "tab color should be #123456",
                       ws.color == nil ? nil : "none should clear the workspace color",
                       listed?["color"] is NSNull ? nil : "list should show no workspace color",
                       ControlHandler.handle(["cmd": "color", "args": ["target": "tab:\(tab.id)", "color": "chartreuse-ish"]])["ok"] as? Bool == false
                           ? nil : "a bad color should fail",
                       (try? CLI.parse("color", ["--workspace", "teal"]).1["level"] as? String) == "workspace" ? nil : "argv parse")
        }) {
            let tab = self.locate(t.pane("c0"))!.tab
            call("color", ["target": "tab:\(tab.id)", "color": "#123456"])
            call("color", ["target": "\(ids["c0"]!)", "level": "workspace", "color": "teal"])
            call("color", ["target": "\(ids["c0"]!)", "level": "workspace", "color": "none"])
        }
        t.step("cli: send-text types into the shell; --command runs a command (through the login shell)", nil, {
            // Ghostty would start the command with Dealer's own PATH; a login shell reads the profile.
            let wrapped = ControlHandler.loginShellCommand("printf '%s' \"$HOME\"", shell: "/bin/zsh")
            let unwrapped = wrapped == #"/bin/zsh -l -c 'exec printf '\''%s'\'' "$HOME"'"# ? nil : "--command should run as `$SHELL -l -c 'exec CMD'`, got \(wrapped)"
            if !live { return all(unwrapped, skipped("shell output")) }
            let typed = tmp + "/typed", ran = tmp + "/ran"
            // `> file` creates the file before printf writes it, so wait for a whole line (#47).
            func read(_ f: String) -> String { (try? String(contentsOfFile: f, encoding: .utf8)) ?? "" }
            let ok = SelfTest.waitUntil(timeout: 15) { read(typed).hasSuffix("\n") && read(ran).hasSuffix("\n") }
            let text = read(typed)
            return all(unwrapped, ok ? nil : "shell never ran the typed/--command lines",
                       text.contains("a\\b 'q' ✅") ? nil : "typed text arrived as \(text.debugDescription)")
        }) {
            call("send-text", ["target": "\(ids["c0"]!)",
                               "items": [["text": "printf '%s\\n' 'a\\b '\"'q'\"' ✅' > \(tmp)/typed"], ["key": "enter"]]])
            created(call("create", ["target": "\(ids["c4"]!)", "focus": false,
                                    "command": "/bin/sh -c 'pwd > \(tmp)/ran; sleep 60'", "cwd": tmp]), "c5")
        }
        t.step("cli: read prints a pane's screen; --lines keeps the tail, --scrollback adds history", nil, {
            if !live { return all(skipped("reading shell output")) }
            func read(_ args: [String: Any] = [:]) -> String? {
                call("read", args.merging(["target": "\(ids["c0"]!)"]) { a, _ in a })?["text"] as? String
            }
            // The marker only appears in the output: the typed line holds $((6*7)), not 42.
            let ok = SelfTest.waitUntil(timeout: 15) { read()?.contains("read-marker-42") == true }
            let screen = read() ?? "", last = read(["lines": 1]), history = read(["scrollback": true]) ?? ""
            let gone = ControlHandler.handle(["cmd": "read", "args": ["target": "pane:999999"]])
            let zero = ControlHandler.handle(["cmd": "read", "args": ["target": "\(ids["c0"]!)", "lines": 0]])
            lastError = nil
            return all(ok ? nil : "the marker never showed: \(screen.suffix(300).debugDescription)",
                       screen.hasSuffix("\n") || screen.split(separator: "\n", omittingEmptySubsequences: false).last?.isEmpty == true
                           ? "trailing blank lines should be dropped: \(screen.suffix(80).debugDescription)" : nil,
                       screen.split(separator: "\n").contains { $0.hasSuffix(" ") } ? "trailing spaces should be dropped" : nil,
                       last.map { !$0.contains("\n") && !$0.isEmpty } == true ? nil : "--lines 1 gave \(last.debugDescription)",
                       history.hasSuffix(screen) ? nil : "--scrollback should end with the screen",
                       gone["ok"] as? Bool == false ? nil : "reading a missing pane should fail",
                       zero["ok"] as? Bool == false ? nil : "--lines 0 should fail")
        }) {
            call("send-text", ["target": "\(ids["c0"]!)", "items": [["text": "echo read-marker-$((6*7))"], ["key": "enter"]]])
        }
        t.step("cli: list shows ids, cwd and foreground processes; find matches by process", nil, {
            guard let r = call("list") else { return all() }
            if !live {
                let n = (r["windows"] as? [[String: Any]])?.count ?? 0
                return all(n > 0 ? nil : "list returned no windows", skipped("process info"))
            }
            let panes = (r["windows"] as? [[String: Any]] ?? []).flatMap { ($0["workspaces"] as? [[String: Any]] ?? []) }
                .flatMap { ($0["decks"] as? [[String: Any]] ?? []) }.flatMap { ($0["tabs"] as? [[String: Any]] ?? []) }
                .flatMap { ($0["panes"] as? [[String: Any]] ?? []) }
            let c5 = panes.first { $0["id"] as? Int == ids["c5"] }
            let procs = (c5?["processes"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            let found = call("find", ["process": "sleep 60"])?["panes"] as? [Int]
            let ran = (try? String(contentsOfFile: tmp + "/ran", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return all(c5 != nil ? nil : "c5 missing from list",
                       procs.contains { $0.contains("sleep 60") } ? nil : "c5 processes: \(procs)",
                       (c5?["foreground"] as? [String: Any])?["pid"] as? Int ?? 0 > 0 ? nil : "c5 has no foreground pid",
                       found == [ids["c5"]!] ? nil : "find --process gave \(found ?? [])",
                       ran.map { ($0 as NSString).resolvingSymlinksInPath == (tmp as NSString).resolvingSymlinksInPath } == true ? nil : "--cwd not applied: \(ran ?? "nil")")
        }) {}
        t.step("cli: notify marks the pane", nil, {
            all(t.pane("c2").attention == .done ? nil : "attention should be done, is \(t.pane("c2").attention)")
        }) {
            call("notify", ["target": "\(ids["c2"]!)", "state": "done", "title": "t", "body": "b"])
        }
        t.step("cli: notify --state failed marks the pane failed (#29)", nil, {
            all(t.pane("c2").attention == .failed ? nil : "attention should be failed, is \(t.pane("c2").attention)")
        }) {
            call("notify", ["target": "\(ids["c2"]!)", "state": "failed", "title": "t", "body": "b"])
        }
        t.step("cli: status sets OSC 7501 records (#89), list shows them, and a report the spec would discard is an error", nil, {
            let p = t.pane("c2")
            self.clearAttention(p, cause: "selftest")  // the notify steps above left it failed
            defer { ProgramStatus.receive("", on: p, source: "selftest"); self.clearAttention(p, cause: "selftest") }
            var problems: [String?] = []
            _ = call("status", ["target": "\(ids["c2"]!)", "state": "working", "id": "build", "progress": "40", "app": "cargo"])
            _ = call("status", ["target": "\(ids["c2"]!)", "state": "blocked", "id": "build/deploy", "kind": "auth", "title": "Deploy", "msg": "Sign in"])
            problems.append(p.agentState == .waiting ? nil : "blocked child: state \(p.agentState)")
            let list = ControlHandler.handle(["cmd": "list"])
            let panes = ((((list["result"] as? [String: Any])?["windows"] as? [[String: Any]]) ?? [])
                .flatMap { $0["workspaces"] as? [[String: Any]] ?? [] }.flatMap { $0["decks"] as? [[String: Any]] ?? [] }
                .flatMap { $0["tabs"] as? [[String: Any]] ?? [] }.flatMap { $0["panes"] as? [[String: Any]] ?? [] })
            let recs = panes.first { $0["id"] as? Int == ids["c2"] }?["program_status"] as? [[String: Any]] ?? []
            let deploy = recs.first { $0["id"] as? String == "build/deploy" }
            problems.append(recs.count == 2 && deploy?["app"] as? String == "cargo" && deploy?["msg"] as? String == "Sign in"
                            && deploy?["kind"] as? String == "auth" ? nil : "list --json program_status: \(recs)")
            let text = CLI.tree(list["result"] as? [String: Any] ?? [:])
            problems.append(text.contains("status blocked id=build/deploy kind=auth app=cargo \"Deploy\": Sign in") ? nil : "list text lacks the record line")
            for bad: [String: Any] in [["state": "sleeping"], ["state": "done", "id": "a//b"], ["state": "done", "kind": "x"],
                                       ["state": "done", "app": "a:b"], ["state": "done", "title": String(repeating: "t", count: 200)]] {
                let r = ControlHandler.handle(["cmd": "status", "args": bad.merging(["target": "\(ids["c2"]!)"]) { a, _ in a }])
                if r["ok"] as? Bool != false { problems.append("status \(bad) should fail") }
            }
            _ = call("status", ["target": "\(ids["c2"]!)", "state": "clear"])
            problems.append(p.programStatus.isEmpty ? nil : "status clear left records")
            let found = problems.compactMap { $0 }
            return all(found.isEmpty ? nil : found.joined(separator: "; "))
        }) {}
        t.step("cli: bad targets fail", nil, {
            let bad = ControlHandler.handle(["cmd": "focus", "args": ["target": "pane:999999"]])
            let gone = ControlHandler.handle(["cmd": "create", "caller": 999999])
            let key = ControlHandler.handle(["cmd": "send-text", "args": ["items": [["key": "hyper+q"]]]])
            return [bad, gone, key].allSatisfy { $0["ok"] as? Bool == false } ? nil : "expected errors"
        }) {}
        t.step("cli: an option a command doesn't take is a usage error; every option in `dealer help` parses", nil, {
            func rejects(_ cmd: String, _ argv: [String]) -> String? {
                do { _ = try CLI.parse(cmd, argv) } catch is CLI.Usage { return nil } catch { return "\(cmd): \(error)" }
                return "dealer \(cmd) \(argv.joined(separator: " ")) should be a usage error"
            }
            // The usage text names each command at a 6-space indent; its continuation lines are deeper.
            var cmd: String?, missing: [String] = []
            for line in CLI.usage.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                if line.hasPrefix("      "), !line.hasPrefix("       "), let w = words.first, CLI.options[w] != nil { cmd = w }
                else if !line.hasPrefix("       ") { cmd = nil }
                guard let c = cmd else { continue }
                for w in words where w.hasPrefix("--") {
                    let flag = w.trimmingCharacters(in: CharacterSet(charactersIn: "[]()|:,"))
                    if !["--json", "--socket"].contains(flag), CLI.options[c]?.contains(flag) != true { missing.append("\(c) \(flag)") }
                }
            }
            return all(rejects("notify", ["--cwd", "/tmp"]), rejects("notify", ["hello"]), rejects("status", []),
                       rejects("status", ["done", "--body", "x"]), rejects("run", ["--name", "x", "true"]),
                       rejects("create", ["--tab"]), rejects("read", ["--wait", "("]), rejects("read", ["--timeout", "soon"]),
                       (try? CLI.parse("read", ["7", "--lines", "3"]).1["target"] as? String) == "7" ? nil : "read takes a positional target",
                       missing.isEmpty ? nil : "documented but rejected: \(missing.joined(separator: ", "))",
                       (try? CLI.parse("run", ["--cwd", "/tmp", "ls", "--name"]).1["command"] as? String) == "ls --name"
                           ? nil : "run's command words should pass through, flags included")
        }) {}
        t.step("cli: real socket round-trip with the dealer binary", nil, {
            guard let socket = ControlServer.shared.path else { return "control socket isn't running" }
            func run(_ args: [String]) -> (Int32, String, String) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["DEALER_SOCKET"] = socket
                env["DEALER_PANE_ID"] = "\(ids["c0"]!)"
                env.removeValue(forKey: "DEALER_SELFTEST")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return (-1, "", "\(error)") }
                // The client blocks until main answers, so keep the run loop going meanwhile.
                _ = SelfTest.waitUntil(timeout: 10) { !p.isRunning }
                if p.isRunning { p.terminate(); return (-1, "", "timed out") }
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return (p.terminationStatus, o, e)
            }
            let (s1, o1, e1) = run(["identify", "--caller"])
            let (s2, o2, e2) = run(["create", "pane", "--side", "left", "--no-focus", "--title", "via socket"])
            let newID = Int(o2.trimmingCharacters(in: .whitespacesAndNewlines))
            let (s3, _, e3) = run(["focus", "pane:999999"])
            // `read --wait` polls from the client; the marker is already on c0's screen.
            let (s4, o4, e4) = live ? run(["read", "--wait", "read-marker-4[0-9]", "--timeout", "5"]) : (0, "read-marker-42", "")
            let (s5, o5, e5) = live ? run(["read", "--wait", "never-on-screen", "--timeout", "0.3"]) : (1, "x", "timed out")
            return all(s4 == 0 && o4.contains("read-marker-42") ? nil : "read --wait: \(s4) \(o4.suffix(200).debugDescription) \(e4)",
                       s5 == 1 && !o5.isEmpty && e5.contains("timed out") ? nil : "read --wait timeout should print the screen and exit 1: \(s5) \(e5)",
                       s1 == 0 && o1 == "\(ids["c0"]!)\n" ? nil : "identify: \(s1) \(o1.debugDescription) \(e1)",
                       s2 == 0 && newID.flatMap(ControlHandler.pane(id:))?.title == "via socket" ? nil : "create: \(s2) \(o2) \(e2)",
                       s3 == 1 && e3.contains("no pane 999999") ? nil : "bad target should exit 1 with a message: \(s3) \(e3)")
        }) {}
        var report = "", reportPath = ""
        t.step("cli: diagnose writes a memory report with counts and nothing private (#43)", nil, {
            let home = NSHomeDirectory()
            let leaked = ["RUN make", "via socket", tmp, home, "/Users/" + NSUserName()].filter { report.contains($0) }
            let paneLines = report.split(separator: "\n").filter { $0.hasPrefix("pane ") }.count
            let panes = self.workspaces.flatMap(\.panes).count
            return all(reportPath.hasPrefix(Diagnostics.directory.path) ? nil : "report at \(reportPath), not in \(Diagnostics.directory.path)",
                       ["## Versions", "## Process memory", "phys_footprint:", "## Objects", "## Panes", "## vmmap --summary", "## heap"]
                           .filter { !report.contains($0) }.map { "report lacks \($0)" }.first,
                       report.contains("## leaks") ? "leaks must be opt-in" : nil,
                       paneLines >= panes ? nil : "report lists \(paneLines) panes, the windows hold \(panes)",
                       leaked.isEmpty ? nil : "report contains private strings: \(leaked)")
        }) {
            reportPath = call("diagnose")?["path"] as? String ?? ""
            report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: reportPath)
        }
        // #60: `close tab:N` never asks (a sheet would leave the reply pending, or the tab open on
        // Cancel), and the tab is gone when the reply arrives.
        var closeTabBusy = false
        var closeTabReply: [String: Any]?
        var closeTabStillThere = false
        var closeTabAsked: [String] = []
        t.step("cli: close tab:N with a busy pane closes it without asking, before replying (#60)", nil, {
            all(closeTabReply?["tab"] == nil ? "close tab should reply with the tab id" : nil,
                closeTabStillThere ? "the tab still existed when the reply came" : nil,
                closeTabAsked.isEmpty ? nil : "close tab asked for confirmation: \(closeTabAsked)",
                !live || closeTabBusy ? nil : "`sleep 30` should have made the pane busy")
        }) {
            created(call("create", ["type": "tab", "target": "\(ids["c0"] ?? 0)", "focus": false]), "ctb")
            guard let tab = self.locate(t.pane("ctb"))?.tab else { return }
            if live {
                _ = t.pane("ctb").surface.waitForShell()  // a fresh pane (#62)
                t.pane("ctb").surface.typeText("sleep 30\r")
                closeTabBusy = SelfTest.waitUntil(timeout: 15) { t.pane("ctb").surface.needsConfirmQuit }
            } else {
                _ = skipped("a busy pane in the closed tab")
            }
            let before = Confirmation.autoAccepted.count
            closeTabReply = call("close", ["target": "tab:\(tab.id)"])
            closeTabStillThere = self.deck(of: tab) != nil
            closeTabAsked = Array(Confirmation.autoAccepted.dropFirst(before))
        }
        t.step("cli: close the test workspace", nil, {
            self.workspaces.contains { $0.name == "cli" } ? "workspace should be gone" : nil
        }) {
            if let ws = self.workspaces.first(where: { $0.name == "cli" }) { self.remove(workspace: ws) }
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    /// `describeTree` using the self-test's pane names.
    fileprivate func describeTreeNamed(_ t: SelfTestKit) -> String {
        var names: [ObjectIdentifier: String] = [:]
        for p in workspaces.flatMap(\.panes) { names[ObjectIdentifier(p)] = t.name(p) }
        return describeTree(names: names)
    }
}
