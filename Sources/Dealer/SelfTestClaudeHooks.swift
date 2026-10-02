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

        t.step("claude hooks: the bundled plugin is present and valid", nil, {
            guard let dir = ClaudeHooks.pluginDirectory else { return "plugin directory not found" }
            guard let data = fm.contents(atPath: dir + "/hooks/hooks.json"),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hooks = obj["hooks"] as? [String: Any] else { return "hooks.json doesn't parse" }
            let want: Set = ["PermissionRequest", "Notification", "Stop", "StopFailure"]
            return all(Set(hooks.keys) == want ? nil : "hooks.json events: \(hooks.keys.sorted())",
                       fm.isExecutableFile(atPath: dir + "/hooks/dealer-hook.sh") ? nil : "dealer-hook.sh isn't executable",
                       fm.fileExists(atPath: dir + "/.claude-plugin/plugin.json") ? nil : "plugin.json missing")
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
                       pane["DEALER_CLI"] != nil ? nil : "pane env lacks DEALER_CLI")
        }) {
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let stub = tmp + "/stub-dealer"
            try? "#!/bin/sh\necho \"$*\" > \"$STUB_OUT\"\n".write(toFile: stub, atomically: true, encoding: .utf8)
            chmod(stub, 0o755)
        }

        t.step("claude hooks: the hook script maps events to dealer notify and respects its guards", nil, {
            let pane = ["DEALER_PANE_ID": "7", "CLAUDE_CODE_ENTRYPOINT": "cli"]
            let perm = runHook("permission", stdin: #"{"tool_name":"Bash"}"#, env: pane)
            let note = runHook("notification", stdin: #"{"message":"Claude needs your permission","notification_type":"permission_prompt"}"#, env: pane)
            let stop = runHook("stop", stdin: "{}", env: pane)
            let fail = runHook("stop-failure", stdin: #"{"error":"rate_limit"}"#, env: pane)
            let outside = runHook("stop", stdin: "{}", env: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
            let nested = runHook("stop", stdin: "{}", env: ["DEALER_PANE_ID": "7", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"])
            let optedOut = runHook("stop", stdin: "{}", env: pane.merging(["DEALER_CLAUDE_HOOKS": "0"]) { $1 })
            return all(perm == "notify --state waiting --title Claude Code --body Permission: Bash" ? nil : "permission: \(perm)",
                       note == "notify --state waiting --title Claude Code --body Claude needs your permission" ? nil : "notification: \(note)",
                       stop == "notify --state done --title Claude Code --body Finished" ? nil : "stop: \(stop)",
                       fail == "notify --state waiting --title Claude Code --body Error: rate_limit" ? nil : "stop-failure: \(fail)",
                       outside.isEmpty ? nil : "outside Dealer it must do nothing: \(outside)",
                       nested.isEmpty ? nil : "a nested `claude -p` (sdk-cli) must not notify: \(nested)",
                       optedOut.isEmpty ? nil : "DEALER_CLAUDE_HOOKS=0 must do nothing: \(optedOut)")
        }) {}

        // End to end: a plain `claude` typed into a real pane's shell. The stub `claude` does what
        // Claude Code does with CLAUDE_CODE_PLUGIN_DIRS: runs the plugin's PermissionRequest hook,
        // which calls the real `dealer` CLI over the real socket.
        var target: Pane?
        t.step("claude hooks: a plain `claude` typed in a pane marks it waiting (stub claude, real shell + socket)", nil, {
            guard let target else { return "no unfocused pane with a live shell to type into" }
            let end = Date().addingTimeInterval(10)
            while target.attention != .waiting && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return target.attention == .waiting ? nil : "pane attention is \(target.attention.name), expected waiting"
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
            target.surface.typeText("PATH='\(stubDir)':\"$PATH\" command claude\r")
        }
        t.step("claude hooks: a parent Claude session's identity variables don't reach pane shells", nil, {
            let leftInApp = ClaudeHooks.inheritedSessionVariables.filter { getenv($0) != nil }
            if !leftInApp.isEmpty { return "still in the app's environment: \(leftInApp)" }
            guard target != nil else { return "no scratch pane" }
            let out = tmp + "/pane-env.txt"
            let end = Date().addingTimeInterval(10)
            func text() -> String { (try? String(contentsOfFile: out, encoding: .utf8)) ?? "" }
            while !text().contains("END") && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            let lines = text().split(separator: "\n").filter { $0 != "END" }
            return text().contains("END") ? (lines.isEmpty ? nil : "pane shell inherited: \(lines)") : "pane never wrote its environment"
        }) {
            guard let target else { return }
            let names = ClaudeHooks.inheritedSessionVariables.joined(separator: "|")
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
