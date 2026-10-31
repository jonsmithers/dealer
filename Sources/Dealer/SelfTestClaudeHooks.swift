import AppKit

// MARK: - Self-test section: automatic Claude Code hooks (issue #12)

extension TerminalWindowController {
    func claudeHooksSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "dealer-claude-hooks-\(getpid())"
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        /// Runs the plugin's hook script synchronously with a stub `dealer` that records its argv.
        /// No socket is involved, so blocking the main thread here is safe.
        func runHook(_ event: String, stdin: String, env: [String: String]) -> String {
            guard let plugin = ClaudeHooks.pluginDirectory else { return "<no plugin>" }
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
            do { try p.run() } catch { return "<spawn failed: \(error)>" }
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            return (try? String(contentsOfFile: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        /// Runs the SessionStart hook with the same stub `dealer` and returns what it prints, which
        /// Claude Code adds to the session's context.
        func runSessionStart(env: [String: String]) -> String {
            guard let plugin = ClaudeHooks.pluginDirectory else { return "<no plugin>" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: plugin + "/hooks/session-start.sh")
            var e = ["PATH": "/usr/bin:/bin", "DEALER_CLI": tmp + "/stub-dealer", "STUB_OUT": tmp + "/stub-dealer.out"]
            e.merge(env) { $1 }
            p.environment = e
            let pipe = Pipe()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = pipe
            do { try p.run() } catch { return "<spawn failed: \(error)>" }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: out, as: UTF8.self)
        }

        t.step("claude hooks: the bundled plugin is present and valid", nil, {
            guard let dir = ClaudeHooks.pluginDirectory else { return "plugin directory not found" }
            guard let data = fm.contents(atPath: dir + "/hooks/hooks.json"),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hooks = obj["hooks"] as? [String: Any] else { return "hooks.json doesn't parse" }
            let want: Set = ["SessionStart", "PermissionRequest", "Notification", "Stop", "StopFailure"]
            let skill = (try? String(contentsOfFile: dir + "/skills/dealer/SKILL.md", encoding: .utf8)) ?? ""
            return all(Set(hooks.keys) == want ? nil : "hooks.json events: \(hooks.keys.sorted())",
                       fm.isExecutableFile(atPath: dir + "/hooks/dealer-hook.sh") ? nil : "dealer-hook.sh isn't executable",
                       fm.isExecutableFile(atPath: dir + "/hooks/session-start.sh") ? nil : "session-start.sh isn't executable",
                       fm.fileExists(atPath: dir + "/.claude-plugin/plugin.json") ? nil : "plugin.json missing",
                       skill.hasPrefix("---\nname: dealer\ndescription: ") ? nil : "skills/dealer/SKILL.md is missing or lacks its name/description frontmatter")
        }) {}

        t.step("claude hooks: pane env names the plugin, appends to the user's dirs, and honors the off switch", nil, {
            let v = ClaudeHooks.pluginDirsVariable
            let fresh = ClaudeHooks.environment(inherited: [:], enabled: true, plugin: "/p", blocked: false)
            let appended = ClaudeHooks.environment(inherited: [v: "/mine"], enabled: true, plugin: "/p", blocked: false)
            let again = ClaudeHooks.environment(inherited: [v: "/mine:/p"], enabled: true, plugin: "/p", blocked: false)
            let off = ClaudeHooks.environment(inherited: [:], enabled: false, plugin: "/p", blocked: false)
            let managed = ClaudeHooks.environment(inherited: [:], enabled: true, plugin: "/p", blocked: true)
            let pane = Pane.childEnvironment(999)
            return all(fresh[v] == "/p" ? nil : "fresh: \(fresh)",
                       appended[v] == "/mine:/p" ? nil : "append: \(appended)",
                       again[v] == "/mine:/p" ? nil : "no duplicate: \(again)",
                       off.isEmpty ? nil : "off switch should add nothing: \(off)",
                       managed.isEmpty ? nil : "disableSideloadFlags should add nothing: \(managed)",
                       pane[v]?.split(separator: ":").last.map(String.init) == ClaudeHooks.pluginDirectory ? nil : "pane env: \(pane[v] ?? "nil")",
                       pane["DEALER_CLI"] != nil ? nil : "pane env lacks DEALER_CLI",
                       pane[ClaudeHooks.errorStateVariable] == "failed" ? nil : "DEALER_CLAUDE_ERROR_STATE should default to failed (#29)")
        }) {
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let stub = tmp + "/stub-dealer"
            // Records its argv; `identify` also answers like the real CLI, for the SessionStart hook.
            try? """
            #!/bin/sh
            echo "$*" > "$STUB_OUT"
            [ "$1" = identify ] && printf 'caller  pane:7 tab:2 deck:1 workspace:1 window:1\\nfocused pane:3 tab:1 deck:1 workspace:1 window:1\\n'
            exit 0

            """.write(toFile: stub, atomically: true, encoding: .utf8)
            chmod(stub, 0o755)
            try? fm.createDirectory(atPath: tmp + "/cli-bin", withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: tmp + "/cli-bin/dealer", withDestinationPath: stub)
        }

        t.step("claude hooks: SessionStart tells Claude its pane and the dealer skill, only in a Dealer pane", nil, {
            let pane = ["DEALER_PANE_ID": "7"]
            let onPath = runSessionStart(env: pane.merging(["PATH": tmp + "/cli-bin:/usr/bin:/bin"]) { $1 })
            let offPath = runSessionStart(env: pane)
            let unreachable = runSessionStart(env: pane.merging(["DEALER_CLI": tmp + "/no-such-dealer"]) { $1 })
            // `claude -p` gets the context too: it marks nothing, unlike dealer-hook.sh.
            let nested = runSessionStart(env: pane.merging(["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]) { $1 })
            let outside = runSessionStart(env: [:])
            let optedOut = runSessionStart(env: pane.merging(["DEALER_CLAUDE_HOOKS": "0"]) { $1 })
            return all(onPath.contains("Its own pane: pane:7 tab:2 deck:1 workspace:1 window:1 ") ? nil : "pane IDs from identify: \(onPath.debugDescription)",
                       onPath.contains("`dealer` drives Dealer") ? nil : "with dealer on PATH it should name `dealer`: \(onPath.debugDescription)",
                       onPath.contains("dealer skill") ? nil : "it should point at the dealer skill: \(onPath.debugDescription)",
                       offPath.contains("`\"$DEALER_CLI\"` drives Dealer") ? nil : "without dealer on PATH it should name \"$DEALER_CLI\": \(offPath.debugDescription)",
                       unreachable.contains("Its own pane: pane:7 (") ? nil : "with Dealer unreachable it should fall back to $DEALER_PANE_ID: \(unreachable.debugDescription)",
                       nested == offPath ? nil : "a `claude -p` should get the same context: \(nested.debugDescription)",
                       outside.isEmpty ? nil : "outside Dealer it must print nothing: \(outside.debugDescription)",
                       optedOut.isEmpty ? nil : "DEALER_CLAUDE_HOOKS=0 must print nothing: \(optedOut.debugDescription)")
        }) {}

        t.step("claude hooks: the hook script maps events to dealer notify and respects its guards", nil, {
            let pane = ["DEALER_PANE_ID": "7", "CLAUDE_CODE_ENTRYPOINT": "cli"]
            let perm = runHook("permission", stdin: #"{"tool_name":"Bash"}"#, env: pane)
            let note = runHook("notification", stdin: #"{"message":"Claude needs your permission","notification_type":"permission_prompt"}"#, env: pane)
            let stop = runHook("stop", stdin: "{}", env: pane)
            let fail = runHook("stop-failure", stdin: #"{"error":"rate_limit"}"#, env: pane)
            let failAsWaiting = runHook("stop-failure", stdin: #"{"error":"rate_limit"}"#,
                                        env: pane.merging(["DEALER_CLAUDE_ERROR_STATE": "waiting"]) { $1 })
            let outside = runHook("stop", stdin: "{}", env: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
            let nested = runHook("stop", stdin: "{}", env: ["DEALER_PANE_ID": "7", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"])
            let optedOut = runHook("stop", stdin: "{}", env: pane.merging(["DEALER_CLAUDE_HOOKS": "0"]) { $1 })
            return all(perm == "notify --state waiting --title Claude Code --body Permission: Bash --internal-log-source claude:permission" ? nil : "permission: \(perm)",
                       note == "notify --state waiting --title Claude Code --body Claude needs your permission --internal-log-source claude:notification" ? nil : "notification: \(note)",
                       stop == "notify --state done --title Claude Code --body Finished --internal-log-source claude:stop" ? nil : "stop: \(stop)",
                       fail == "notify --state failed --title Claude Code --body Error: rate_limit --internal-log-source claude:stop-failure" ? nil : "stop-failure: \(fail)",
                       failAsWaiting == "notify --state waiting --title Claude Code --body Error: rate_limit --internal-log-source claude:stop-failure" ? nil : "stop-failure with errors_as_failed off: \(failAsWaiting)",
                       outside.isEmpty ? nil : "outside Dealer it must do nothing: \(outside)",
                       nested.isEmpty ? nil : "a nested `claude -p` (sdk-cli) must not notify: \(nested)",
                       optedOut.isEmpty ? nil : "DEALER_CLAUDE_HOOKS=0 must do nothing: \(optedOut)")
        }) {}

        // End to end: a plain `claude` typed into a real pane's shell. The stub `claude` does what
        // Claude Code does with CLAUDE_CODE_PLUGIN_DIRS: runs the plugin's PermissionRequest hook,
        // which calls the real `dealer` CLI over the real socket.
        var target: Pane?
        var shellReady = false
        t.step("claude hooks: a plain `claude` typed in a pane marks it waiting (stub claude, real shell + socket)", nil, {
            guard let target else {
                // Locked screen: ghostty can't create surfaces, so there's no shell to type into.
                print("      (skipped the typed-claude round trip: ghostty couldn't create terminal surfaces here)")
                return nil
            }
            // 20 s like other shell steps: under a loaded full run the stub, the hook script and a
            // cold start of the dealer CLI all come after the shell (#62).
            SelfTest.waitUntil(timeout: 20) { target.attention == .waiting }
            guard target.attention != .waiting else { return nil }
            // Say what the pane shows, so a failure tells a lost line from a hook that never arrived.
            return "pane attention is \(target.attention.name), expected waiting"
                + (shellReady ? "" : " (its shell never echoed back before `claude` was typed)")
                + "; the pane's last lines: \(String(target.surface.screenText.suffix(400)).debugDescription)"
        }) {
            // A fresh pane beside the focused one, then focus goes back, so the target isn't the
            // pane the user is looking at (setAttention ignores that one).
            guard let home = self.focusedPane else { return }
            self.split(home, side: .right)
            target = self.focusedPane === home ? nil : self.focusedPane
            self.focus(home)
            guard let target, target.surface.surface != nil else { target = nil; return }
            let stubDir = tmp + "/bin"
            try? fm.createDirectory(atPath: stubDir, withIntermediateDirectories: true)
            let stub = """
            #!/bin/sh
            IFS=:
            for d in $CLAUDE_CODE_PLUGIN_DIRS; do
              printf '{"tool_name":"Bash"}' | CLAUDE_CODE_ENTRYPOINT=cli "$d/hooks/dealer-hook.sh" permission
            done

            """
            try? stub.write(toFile: stubDir + "/claude", atomically: true, encoding: .utf8)
            chmod(stubDir + "/claude", 0o755)
            // #62: in a full run, a line typed into a brand-new pane before its shell was ready
            // sometimes never ran. Wait until the shell echoes back first.
            shellReady = target.surface.waitForShell()
            target.surface.typeText("PATH='\(stubDir)':\"$PATH\" command claude\r")
        }
        t.step("claude hooks: a parent terminal's (cmux) and Claude session's identity don't reach pane shells", nil, {
            let env = ProcessInfo.processInfo.environment
            let leftInApp = ClaudeHooks.inheritedSessionVariables.filter { getenv($0) != nil } + env.keys.filter { $0.hasPrefix("CMUX_") }.sorted()
            if !leftInApp.isEmpty { return "still in the app's environment: \(leftInApp)" }
            if (env["PATH"] ?? "").contains("cmux-cli-shims") { return "a cmux shim directory is still on PATH" }
            guard target != nil else {
                print("      (skipped the pane-shell half: ghostty couldn't create terminal surfaces here)")
                return nil
            }
            let out = tmp + "/pane-env.txt"
            func text() -> String { (try? String(contentsOfFile: out, encoding: .utf8)) ?? "" }
            SelfTest.waitUntil(timeout: 10) { text().contains("END") }
            let lines = text().split(separator: "\n").filter { $0 != "END" }
            return text().contains("END") ? (lines.isEmpty ? nil : "pane shell inherited: \(lines)") : "pane never wrote its environment"
        }) {
            guard let target else { return }
            let names = (ClaudeHooks.inheritedSessionVariables + ["CMUX_[A-Z_]*"]).joined(separator: "|")
            target.surface.typeText("env | grep -E '^(\(names))=' | cut -d= -f1 > '\(tmp)/pane-env.txt'; echo END >> '\(tmp)/pane-env.txt'\r")
        }
        t.step("claude hooks: clean up", nil, {
            target.map { self.locate($0) == nil ? nil : "scratch pane should be gone" } ?? nil
        }) {
            if let target { self.setAttention(.none, on: target); self.remove(target) }
            try? fm.removeItem(atPath: tmp)
        }
    }
}
