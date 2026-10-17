import AppKit

// MARK: - Self-test section: the notification decision log (#56)

extension TerminalWindowController {
    /// `[notifications] log`: with it on, the representative inputs (`dealer notify`, a Claude hook
    /// through the real script and CLI, a `dealer run` failure) each write their decision line,
    /// "no"s carry reasons, clears say what cleared them, the file rotates at its cap, and nothing
    /// is written with it off. The log goes to a temp path (`NotificationLog.path`), never /tmp's.
    func notificationLogSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "dealer-notify-log-\(getpid())"
        var savedSettings: String?
        var hook: (status: Int32, err: String)?

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
        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func all(_ problems: String?...) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func setLog(_ on: Bool) {
            try? fm.createDirectory(at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[notifications]\nlog = \(on)\n".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload()
        }
        func resetFile() {
            NotificationLog.flush()
            try? fm.removeItem(atPath: NotificationLog.path)
            try? fm.removeItem(atPath: NotificationLog.path + ".1")
        }
        func lines() -> [String] {
            NotificationLog.flush()
            return ((try? String(contentsOfFile: NotificationLog.path, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        /// The first line containing every fragment, or a problem naming what's missing.
        func line(_ fragments: String...) -> (String?, String?) {
            if let l = lines().first(where: { l in fragments.allSatisfy(l.contains) }) { return (l, nil) }
            return (nil, "no log line with \(fragments.map(\.debugDescription).joined(separator: " + ")); log:\n           "
                + lines().suffix(8).joined(separator: "\n           "))
        }
        func has(_ fragments: String...) -> String? {
            lines().contains { l in fragments.allSatisfy(l.contains) } ? nil
                : "no log line with \(fragments.map(\.debugDescription).joined(separator: " + ")); log:\n           "
                    + lines().suffix(8).joined(separator: "\n           ")
        }
        func waitFor(_ fragments: String..., timeout: TimeInterval = 10) -> String? {
            SelfTest.waitUntil(timeout: timeout) { lines().contains { l in fragments.allSatisfy(l.contains) } } ? nil
                : "timed out waiting for a log line with \(fragments.map(\.debugDescription).joined(separator: " + ")); log:\n           "
                    + lines().suffix(8).joined(separator: "\n           ")
        }
        func who(_ n: String) -> String { "pane=\(ids[n] ?? -1) ws=\"notify-log\"" }

        t.step("notify-log: set up a workspace with two panes (nl-a focused, nl-b beside it)", nil, {
            all(pane("nl-a") != nil && pane("nl-b") != nil ? nil : "panes weren't created",
                NotificationLog.path == NotificationLog.defaultPath ? "the self-test must not write the user's /tmp log" : nil)
        }) {
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            savedSettings = try? String(contentsOf: Settings.fileURL, encoding: .utf8)
            created(call("create", ["type": "workspace", "target": "focused", "name": "notify-log", "cwd": tmp]), "nl-a")
            created(call("create", ["type": "pane", "side": "right", "focus": false, "cwd": tmp], caller: "nl-a"), "nl-b")
            if let a = pane("nl-a") { self.focus(a) }
        }

        t.step("notify-log: with [notifications] log off (the default), nothing is written", nil, {
            all(Settings.notificationLog ? "the setting should default to off" : nil,
                fm.fileExists(atPath: NotificationLog.path) ? "log written while off:\n           " + lines().joined(separator: "\n           ") : nil)
        }) {
            try? fm.removeItem(at: Settings.fileURL)
            Settings.reload(force: true)
            resetFile()
            call("notify", ["state": "done", "title": "off", "body": "nothing"], caller: "nl-b")
            if let b = pane("nl-b") { self.setAttention(.unread, on: b, raiseOnly: true, event: "bell") }
            call("job-done", ["status": 1], caller: "nl-b")
            if let b = pane("nl-b") { self.focus(b) }
            if let a = pane("nl-a") { self.focus(a) }
            lastError = nil  // job-done from a non-job pane isn't an error; nothing else should be
        }

        t.step("notify-log: turning it on writes a header; `dealer notify` logs the mark and the suppressed notification's reason", nil, {
            let (posted, p1) = line("notify attention:set", who("nl-b"), "reason=\"none → done\"", "title=\"Build\"", "body=\"All green\"")
            let (sup, p2) = line("notify notification:suppressed", who("nl-b"))
            // Self-test runs are unbundled; if the run happens to be frontmost, the active-app reason applies (worded by #71).
            let reasonOK = sup.map { $0.contains("reason=\"unbundled") || $0.contains("reason=\"Dealer is the active app") } ?? false
            return all(waitFor("log started", "reason=\"log turned on"), p1, p2,
                       posted == nil || posted!.contains("tab=\"") ? nil : "lines name the tab too",
                       sup == nil || reasonOK ? nil : "unexpected suppress reason: \(sup!)")
        }) {
            resetFile()
            setLog(true)
            call("notify", ["state": "done", "title": "Build", "body": "All green"], caller: "nl-b")
        }

        t.step("notify-log: a raise-only source on a stronger state is a skipped change, with its reason", nil, {
            all(has("bell attention:skipped", who("nl-b"), "reason=\"wanted unread: already waiting, which outranks it"),
                has("notify attention:set", who("nl-b"), "reason=\"done → waiting\""))
        }) {
            call("notify", ["state": "waiting"], caller: "nl-b")
            if let b = pane("nl-b") { self.setAttention(.unread, on: b, raiseOnly: true, event: "bell") }
        }

        t.step("notify-log: a Claude hook (the plugin's script → dealer CLI → socket) is logged by its event", nil, {
            guard let hook else { return "the hook script couldn't run" }
            return all(hook.status == 0 ? nil : "hook script exited \(hook.status): \(hook.err)",
                       has("claude:stop attention:set", who("nl-a"), "reason=\"none → done\"", "title=\"Claude Code\"", "body=\"Finished\""))
        }) {
            guard let plugin = ClaudeHooks.pluginDirectory, let socket = ControlServer.shared.path, let a = ids["nl-a"] else { return }
            // nl-a is focused, but this isn't the key window of an active app in a self-test run unless
            // it's frontmost; focus nl-b so nl-a can't count as looked at either way.
            if let b = pane("nl-b") { self.focus(b) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: plugin + "/hooks/dealer-hook.sh")
            p.arguments = ["stop"]
            p.environment = ["PATH": "/usr/bin:/bin", "DEALER_PANE_ID": "\(a)", "DEALER_SOCKET": socket,
                             "CLAUDE_CODE_ENTRYPOINT": "cli",
                             "DEALER_CLI": URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path]
            let input = Pipe(), err = Pipe()
            p.standardInput = input
            p.standardError = err
            do { try p.run() } catch { return }
            input.fileHandleForWriting.write(Data("{}".utf8))
            try? input.fileHandleForWriting.close()
            // The CLI blocks until main answers, so keep the run loop going meanwhile.
            _ = SelfTest.waitUntil(timeout: 10) { !p.isRunning }
            if p.isRunning { p.terminate() }
            _ = SelfTest.waitUntil(timeout: 5) { lines().contains { $0.contains("claude:stop") } }
            hook = (p.isRunning ? -1 : p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        var live = false
        t.step("notify-log: a `dealer run` failure logs job-done with its status; job-done outside a job is ignored with a reason", nil, {
            guard let job = pane("nl-job") else { return all("the job pane wasn't created") }
            if live {
                if let p = waitFor("job-done(status=3) attention:set", "pane=\(job.id)", "reason=\"none → failed\"", timeout: 20) {
                    return p
                }
            } else {
                print("      (no live shell: reporting job-done 3 through the handler; the typed tail wasn't exercised)")
                call("job-done", ["status": 3], caller: "nl-job")
            }
            return all(has("job-done(status=3) attention:set", "pane=\(job.id)", "reason=\"none → failed\""),
                       has("job-done(status=1) ignored", who("nl-b"), "reason=\"not a dealer run job pane\""))
        }) {
            created(call("run", ["command": "(exit 3)", "cwd": tmp, "placement": "split", "size": "20%", "target": "pane:\(ids["nl-a"] ?? -1)"]), "nl-job")
            live = pane("nl-job")?.surface.surface != nil
            call("job-done", ["status": 1], caller: "nl-b")
            lastError = nil
        }

        t.step("notify-log: clears say what cleared them (focus, a notification click's reveal, ⌘⇧U)", nil, {
            all(has("focus attention:cleared", who("nl-a"), "reason=\"done → none (focus moved to the pane"),
                has("notification-click attention:cleared", who("nl-b"), "reason=\"waiting → none"),
                has("jump-to-next-unread attention:cleared"))
        }) {
            // nl-a is marked done (the hook step). Focus clears it.
            if let a = pane("nl-a") { self.focus(a) }
            // The click handler reveals the pane it names; this is that call.
            call("notify", ["state": "waiting"], caller: "nl-b")
            if let b = pane("nl-b") { self.reveal(b, cause: "notification-click") }
            // ⌘⇧U goes to the most urgent pane anywhere: mark nl-a so there's at least one.
            call("notify", ["state": "waiting"], caller: "nl-a")
            self.jumpToNextUnread(nil)
        }

        t.step("notify-log: the file is renamed to .1 past its size cap", nil, {
            let size = (try? fm.attributesOfItem(atPath: NotificationLog.path)[.size] as? Int) ?? nil
            let old = (try? fm.attributesOfItem(atPath: NotificationLog.path + ".1")[.size] as? Int) ?? nil
            return all(old == nil ? "no .1 file after passing the cap" : nil,
                       (old ?? 0) <= 2_000 ? nil : ".1 is \(old!) bytes, over the 2000-byte cap",
                       (size ?? 0) <= 2_000 ? nil : "the current file is \(size ?? -1) bytes, over the cap")
        }) {
            resetFile()
            let cap = NotificationLog.maxBytes
            NotificationLog.maxBytes = 2_000
            for i in 0..<30 {
                call("notify", ["state": i % 2 == 0 ? "done" : "unread", "body": String(repeating: "x", count: 40)], caller: "nl-b")
            }
            NotificationLog.flush()
            NotificationLog.maxBytes = cap
        }

        t.step("notify-log: dealer diagnose's summary names the log, on or off", nil, {
            let s = Diagnostics.notificationLogSummary
            return all(s.hasPrefix("on") && s.contains(NotificationLog.path) ? nil : "summary: \(s)")
        }) {}

        t.step("notify-log: turned off again, nothing more is written; clean up", nil, {
            all(fm.fileExists(atPath: NotificationLog.path) ? "log written after turning it off:\n           " + lines().joined(separator: "\n           ") : nil,
                self.workspaces.contains { $0.name == "notify-log" } ? "test workspace should be gone" : nil)
        }) {
            setLog(false)
            resetFile()
            call("notify", ["state": "failed", "title": "off again"], caller: "nl-b")
            if let ws = self.workspaces.first(where: { $0.name == "notify-log" }) { self.remove(workspace: ws) }
            if let s = savedSettings { try? s.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload(force: true)
            NotificationLog.flush()
            try? fm.removeItem(atPath: tmp)
            lastError = nil
        }
    }
}
