import AppKit

// MARK: - Self-test section: resuming Claude Code sessions on relaunch (issue #93)

extension TerminalWindowController {
    func sessionRestoreSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "dealer-session-restore-\(getpid())"
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }

        /// Runs the plugin's hook script with a stub `dealer` that records its argv. Returns that argv
        /// and the script's exit status.
        func runHook(_ event: String, stdin: String, env: [String: String]) -> (argv: String, status: Int32) {
            guard let plugin = ClaudeHooks.pluginDirectory else { return ("<no plugin>", -1) }
            let out = tmp + "/stub-dealer.out"
            try? fm.removeItem(atPath: out)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: plugin + "/hooks/dealer-hook.sh")
            p.arguments = [event]
            var e = ["PATH": "/usr/bin:/bin", "DEALER_CLI": tmp + "/stub-dealer", "STUB_OUT": out]
            e.merge(env) { $1 }
            p.environment = e
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return ("<spawn failed: \(error)>", -1) }
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            let argv = (try? String(contentsOfFile: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (argv, p.terminationStatus)
        }

        t.step("session restore: the hook reports SessionStart and SessionEnd to dealer agent-session", nil, {
            let pane = ["DEALER_PANE_ID": "7", "CLAUDE_CODE_ENTRYPOINT": "cli"]
            let start = #"{"session_id":"0a1b-2c","transcript_path":"/t/0a1b-2c.jsonl","source":"startup","hook_event_name":"SessionStart"}"#
            let end = #"{"session_id":"0a1b-2c","reason":"prompt_input_exit","hook_event_name":"SessionEnd"}"#
            let s = runHook("session-start", stdin: start, env: pane)
            let e = runHook("session-end", stdin: end, env: pane)
            let noID = runHook("session-start", stdin: #"{"source":"startup"}"#, env: pane)
            let nested = runHook("session-start", stdin: start, env: ["DEALER_PANE_ID": "7", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"])
            let outside = runHook("session-start", stdin: start, env: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
            let optedOut = runHook("session-end", stdin: end, env: pane.merging(["DEALER_CLAUDE_HOOKS": "0"]) { $1 })
            let unreachable = runHook("session-start", stdin: start, env: pane.merging(["DEALER_CLI": tmp + "/no-such-dealer"]) { $1 })
            let plugin = ClaudeHooks.pluginDirectory ?? ""
            let hooks = (fm.contents(atPath: plugin + "/hooks/hooks.json").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["hooks"] as? [String: Any]
            func commands(_ event: String) -> [String] {
                (hooks?[event] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            }
            return all(s == ("agent-session claude 0a1b-2c --transcript /t/0a1b-2c.jsonl", 0) ? nil : "session-start: \(s)",
                       e == ("agent-session --end claude 0a1b-2c", 0) ? nil : "session-end: \(e)",
                       noID == ("", 0) ? nil : "no session_id must report nothing: \(noID)",
                       nested == ("", 0) ? nil : "a nested `claude -p` (sdk-cli) must not replace the pane's session: \(nested)",
                       outside == ("", 0) ? nil : "outside Dealer it must do nothing: \(outside)",
                       optedOut == ("", 0) ? nil : "DEALER_CLAUDE_HOOKS=0 must do nothing: \(optedOut)",
                       unreachable.status == 0 ? nil : "with Dealer unreachable the hook must still exit 0, got \(unreachable.status)",
                       commands("SessionStart").contains { $0.hasSuffix("dealer-hook.sh\" session-start") } ? nil : "hooks.json SessionStart: \(commands("SessionStart"))",
                       commands("SessionEnd").contains { $0.hasSuffix("dealer-hook.sh\" session-end") } ? nil : "hooks.json SessionEnd: \(commands("SessionEnd"))")
        }) {
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let stub = tmp + "/stub-dealer"
            try? "#!/bin/sh\necho \"$*\" > \"$STUB_OUT\"\nexit 0\n".write(toFile: stub, atomically: true, encoding: .utf8)
            chmod(stub, 0o755)
        }

        t.step("session restore: dealer agent-session records, replaces and forgets a pane's session", nil, {
            guard let p = self.focusedPane else { return "no focused pane" }
            func call(_ args: [String: Any]) -> [String: Any] { ControlHandler.handle(["cmd": "agent-session", "args": args, "caller": p.id]) }
            func ok(_ r: [String: Any]) -> Bool { r["ok"] as? Bool == true }
            let a = AgentSession(agent: "claude", id: "aaaa-1", transcript: "/t/aaaa-1.jsonl")
            let b = AgentSession(agent: "claude", id: "bbbb-2", transcript: nil)
            var problems: [String?] = []
            problems.append(ok(call(["agent": "claude", "id": "aaaa-1", "transcript": "/t/aaaa-1.jsonl"])) && p.agentSession == a
                            ? nil : "record: \(String(describing: p.agentSession))")
            let listed = (ControlHandler.list([:])["windows"] as? [[String: Any]]).map { "\($0)" } ?? ""
            problems.append(listed.contains("aaaa-1") ? nil : "dealer list should show the pane's agent_session")
            // /clear: SessionStart with the new id replaces it; the old id's SessionEnd may come either side.
            problems.append(ok(call(["agent": "claude", "id": "bbbb-2", "transcript": ""])) && p.agentSession == b ? nil : "replace: \(String(describing: p.agentSession))")
            problems.append(ok(call(["agent": "claude", "id": "aaaa-1", "end": true])) && p.agentSession == b ? nil : "a stale end must not clear the newer session")
            let query = call([:])
            problems.append(((query["result"] as? [String: Any])?["session"] as? [String: Any])?["id"] as? String == "bbbb-2" ? nil : "query: \(query)")
            problems.append(ok(call(["agent": "claude", "id": "bbbb-2", "end": true])) && p.agentSession == nil ? nil : "end: \(String(describing: p.agentSession))")
            problems.append(!ok(call(["agent": "codex", "id": "x"])) ? nil : "an unknown agent should be refused")
            problems.append(!ok(call(["agent": "claude", "id": "x'; rm -rf ~"])) && p.agentSession == nil ? nil : "a bad id should be refused")
            let parsed = try? CLI.parse("agent-session", ["claude", "cc-3", "--transcript", "/t/cc-3.jsonl"]).1
            let parsedEnd = try? CLI.parse("agent-session", ["--end", "claude", "cc-3"]).1
            let oneArg: String? = { do { _ = try CLI.parse("agent-session", ["cc-3"]); return "one argument should be a usage error" } catch { return nil } }()
            problems.append(parsed?["agent"] as? String == "claude" && parsed?["id"] as? String == "cc-3"
                            && parsed?["transcript"] as? String == "/t/cc-3.jsonl" ? nil : "argv parse: \(String(describing: parsed))")
            problems.append(parsedEnd?["end"] as? Bool == true && parsedEnd?["id"] as? String == "cc-3" ? nil : "argv parse --end: \(String(describing: parsedEnd))")
            problems.append(oneArg)
            p.agentSession = nil
            return problems.compactMap { $0 }.isEmpty ? nil : problems.compactMap { $0 }.joined(separator: "; ")
        }) {}

        t.step("session restore: the snapshot keeps a pane's session, and older session files decode", nil, {
            guard let p = self.focusedPane else { return "no focused pane" }
            let s = AgentSession(agent: "claude", id: "dddd-4", transcript: "/t/dddd-4.jsonl")
            p.agentSession = s
            defer { p.agentSession = nil }
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(SessionSnapshot(windows: [snap])),
                  let back = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return "snapshot didn't round-trip" }
            var found: [AgentSession] = []
            func panes(_ n: TreeSnapshot<PaneSnapshot>) {
                switch n { case let .leaf(ps): ps.agentSession.map { found.append($0) }; case let .split(_, _, a, b): panes(a); panes(b) }
            }
            func decks(_ n: TreeSnapshot<DeckSnapshot>) {
                switch n { case let .leaf(d): d.tabs.forEach { panes($0.root) }; case let .split(_, _, a, b): decks(a); decks(b) }
            }
            back.windows.flatMap(\.allWorkspaces).forEach { decks($0.root) }
            let old = try? JSONDecoder().decode(PaneSnapshot.self, from: Data(#"{"pwd":"/tmp","title":"zsh","focused":true}"#.utf8))
            let plain = String(decoding: (try? JSONEncoder().encode(PaneSnapshot(pwd: nil, title: nil, focused: false))) ?? Data(), as: UTF8.self)
            return all(found == [s] ? nil : "the saved session holds \(found), expected only \(s)",
                       old.map { $0.agentSession == nil && $0.focused } == true ? nil : "an older pane snapshot should decode without agentSession",
                       plain.contains("agentSession") ? "a plain shell should save no agentSession: \(plain)" : nil)
        }) {}

        t.step("session restore: the resume line follows the setting, the agent command and the transcript", nil, {
            let s = AgentSession(agent: "claude", id: "eeee-5", transcript: "/t/eeee-5.jsonl")
            let exists: (String) -> Bool = { $0 == "/t/eeee-5.jsonl" }
            func line(_ s: AgentSession?, enabled: Bool = true, command: String = "claude") -> String? {
                AgentSession.resumeLine(for: s, enabled: enabled, agentCommand: command, fileExists: exists)
            }
            let noTranscript = AgentSession(agent: "claude", id: "eeee-5", transcript: nil)
            let gone = AgentSession(agent: "claude", id: "ffff-6", transcript: "/t/ffff-6.jsonl")
            let quoted = AgentSession(agent: "claude", id: "it's", transcript: nil)
            return all(line(s) == "claude --resume 'eeee-5'" ? nil : "plain: \(line(s) ?? "nil")",
                       line(s, command: "~/bin/claude --model opus") == "~/bin/claude --resume 'eeee-5'" ? nil : "the agent command's executable: \(line(s, command: "~/bin/claude --model opus") ?? "nil")",
                       line(s, command: "codex") == nil ? nil : "a non-Claude agent command must not resume",
                       line(s, command: "FOO=1 claude") == nil ? nil : "an agent command not starting with claude must not resume",
                       line(s, enabled: false) == nil ? nil : "[agent] restore_sessions = false must not resume",
                       line(nil) == nil ? nil : "no session, no line",
                       line(noTranscript) == "claude --resume 'eeee-5'" ? nil : "an unknown transcript should still resume",
                       line(gone) == nil ? nil : "a missing transcript must not resume",
                       line(quoted) == nil ? nil : "an id that isn't one Claude writes must not be typed",
                       Settings.agentRestoreSessions ? nil : "[agent] restore_sessions should default to true")
        }) {}

        // End to end: a restored workspace whose pane ran a Claude session. The fake `claude` records
        // its argv and, like Claude Code resuming, runs the plugin's SessionStart hook, which calls the
        // real `dealer` over the real socket. The restored pane starts without the record (it isn't
        // carried over), so getting it back proves the hook round trip.
        var restored: Workspace?
        var home: (ws: Workspace, pane: Pane?)?
        var resumed: Pane?, gone: Pane?
        let argsFile = tmp + "/claude-args.txt"
        func argsText() -> String { (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? "" }
        t.step("session restore: a restored pane resumes its Claude session (fake claude, real shell + socket)", nil, {
            guard let resumed, let gone, resumed.surface.surface != nil else {
                print("      (skipped the restored-pane resume: ghostty couldn't create terminal surfaces here)")
                return nil
            }
            SelfTest.waitUntil(timeout: 20) { resumed.agentSession?.id == "1111-aaaa" }
            // The gone pane's shell has read everything typed before this echo (the pty is FIFO), so
            // a resume typed at its start would have run by now.
            let goneShell = gone.surface.waitForShell()
            let text = argsText()
            return all(text.contains("--resume 1111-aaaa") ? nil : "fake claude never ran with --resume 1111-aaaa; it saw: \(text.debugDescription); the pane shows: \(String(resumed.surface.screenText.suffix(300)).debugDescription)",
                       resumed.agentSession == AgentSession(agent: "claude", id: "1111-aaaa", transcript: tmp + "/1111-aaaa.jsonl")
                           ? nil : "the resumed session's SessionStart should have recorded it again: \(String(describing: resumed.agentSession))",
                       goneShell ? nil : "the pane whose transcript is gone never reached a prompt",
                       text.contains("2222-bbbb") ? "a pane whose transcript is gone must not resume: \(text.debugDescription)" : nil)
        }) {
            home = (self.activeWorkspace, self.focusedPane)
            let bin = tmp + "/bin"
            try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try? "{}\n".write(toFile: tmp + "/1111-aaaa.jsonl", atomically: true, encoding: .utf8)
            try? """
            #!/bin/sh
            echo "$*" >> '\(argsFile)'
            IFS=:
            for d in $CLAUDE_CODE_PLUGIN_DIRS; do
              printf '{"session_id":"%s","transcript_path":"%s","source":"resume"}' "$2" '\(tmp)/'"$2.jsonl" | CLAUDE_CODE_ENTRYPOINT=cli "$d/hooks/dealer-hook.sh" session-start
            done

            """.write(toFile: bin + "/claude", atomically: true, encoding: .utf8)
            chmod(bin + "/claude", 0o755)
            AgentPreset.commandOverride = bin + "/claude"
            defer { AgentPreset.commandOverride = nil }
            func leaf(_ id: String, focused: Bool) -> TreeSnapshot<PaneSnapshot> {
                .leaf(PaneSnapshot(pwd: tmp, title: nil, focused: focused,
                                   agentSession: AgentSession(agent: "claude", id: id, transcript: tmp + "/\(id).jsonl")))
            }
            let tab = TabSnapshot(customTitle: nil, color: nil,
                                  root: .split(axis: .row, ratio: 0.5, a: leaf("1111-aaaa", focused: true), b: leaf("2222-bbbb", focused: false)))
            let snap = WindowSnapshot(frame: self.window?.frame ?? .zero,
                                      workspaces: [WorkspaceSnapshot(name: "restored", color: nil, root: .leaf(DeckSnapshot(tabs: [tab], activeIndex: 0, colorIndex: 0)))],
                                      activeWorkspace: 0)
            guard let ws = self.restoreWorkspaces(snap).first, let panes = ws.decks.first?.activeTab?.panes, panes.count == 2 else { return }
            restored = ws
            (resumed, gone) = (panes[0], panes[1])
            t.named(panes[0], "resumed")
            t.named(panes[1], "gone")
            self.insert(workspace: ws, at: self.workspaces.count)
            self.activate(ws)
        }
        t.step("session restore: clean up", nil, {
            all(restored.map { ws in self.workspaces.contains { $0 === ws } ? "the restored workspace should be gone" : nil } ?? nil,
                home.map { $0.ws === self.activeWorkspace ? nil : "the original workspace should be active again" } ?? nil)
        }) {
            if let restored { self.remove(workspace: restored) }
            if let home {
                self.activate(home.ws)
                if let p = home.pane, self.locate(p) != nil { self.focus(p) }
            }
            try? fm.removeItem(atPath: tmp)
        }
    }
}
