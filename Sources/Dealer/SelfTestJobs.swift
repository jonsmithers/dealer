import AppKit

// MARK: - Self-test section: `dealer run` jobs (issue #21)

extension TerminalWindowController {
    /// Drives `run` / `job-done` through `ControlHandler.handle` in a workspace of its own. With live
    /// surfaces the job's real shell reports back over the socket (`$DEALER_CLI job-done $?`); without
    /// them (locked screen) the report is made through the handler instead, and that is said.
    func jobsSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "dealer-jobs-\(getpid())"
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var savedSettings: String?

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
        func tree(_ e: String) -> String? {
            var names: [ObjectIdentifier: String] = [:]
            for p in workspaces.flatMap(\.panes) { names[ObjectIdentifier(p)] = t.name(p) }
            let got = describeTree(names: names)
            return got == e ? nil : "expected \(e)\n         got      \(got)"
        }
        func focused(_ n: String) -> String? {
            ControlHandler.focusedPane === pane(n) ? nil
                : "focus should stay on \(n), is on \(ControlHandler.focusedPane.map(t.name) ?? "nil")"
        }
        func all(_ problems: String?...) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func eq<T: Equatable>(_ a: T?, _ b: T, _ what: String) -> String? { a == b ? nil : "\(what): \(a.map { "\($0)" } ?? "nil") ≠ \(b)" }
        func wait(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return cond()
        }
        var live: Bool { pane("j0")?.surface.surface != nil }
        /// Waits for the job's shell to report, or reports for it when there's no shell.
        func outcome(_ job: String, status: Int, until cond: () -> Bool) -> String? {
            if live {
                return wait(20, cond) ? nil : "the job's shell never reported back (status \(status))"
            }
            print("      (no live shell: reporting job-done \(status) through the handler; the typed tail wasn't exercised)")
            let r = call("job-done", ["status": status], caller: job)
            if status == 0, r?["close"] as? Bool == true, let p = pane(job) { self.remove(p) }
            return cond() ? nil : "state after job-done \(status) is wrong"
        }
        /// Marks only show when the user isn't looking at the pane (Attention.swift).
        func marked(_ n: String, _ a: Attention) -> String? {
            guard let p = pane(n) else { return "\(n) is gone" }
            if p.attention == a || (a != .none && self.isLookingAt(p)) { return nil }
            return "\(n) should be marked \(a.name), is \(p.attention.name)"
        }

        t.step("jobs: a workspace to run in", nil, { all(tree("Deck0[*j0]")) }) {
            savedSettings = try? String(contentsOf: Settings.fileURL, encoding: .utf8)
            try? fm.removeItem(at: Settings.fileURL)
            Settings.reload(force: true)
            created(call("create", ["type": "workspace", "target": "focused", "name": "jobs", "cwd": tmp]), "j0")
        }
        t.step("jobs: run (default split) opens a short titled pane below and keeps focus", nil, {
            all(tree("Deck0[*Col(j0, ja)]"), focused("j0"), eq(pane("ja")?.title, "RUN false", "title"),
                pane("ja").flatMap { ControlJobs.job(for: $0) } != nil ? nil : "ja should be registered as a job",
                eq(Settings.jobPlacement, "split", "default placement"))
        }) {
            created(call("run", ["command": "false", "cwd": tmp], caller: "j0"), "ja")
        }
        t.step("jobs: a failed job stays open, retitled and marked waiting", nil, {
            all(outcome("ja", status: 1) { pane("ja")?.customTitle == "FAILED (1) false" },
                tree("Deck0[*Col(j0, ja)]"), marked("ja", .waiting), focused("j0"))
        }) {}
        t.step("jobs: [jobs] placement = \"tab\" puts the next job in a background tab", nil, {
            all(tree("Deck0[*Col(j0, ja), jb]"), focused("j0"),
                eq(self.locate(pane("jb")!)?.tab.title, "RUN true", "tab title"))
        }) {
            try? "[jobs]\nplacement = \"tab\"\n".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload(force: true)
            created(call("run", ["command": "true", "cwd": tmp], caller: "j0"), "jb")
        }
        t.step("jobs: a successful job closes its pane and marks the caller done", nil, {
            all(outcome("jb", status: 0) { pane("jb") == nil }, tree("Deck0[*Col(j0, ja)]"), marked("j0", .done), focused("j0"))
        }) {}
        t.step("jobs: --keep --quiet: a successful job stays, retitled, and nothing is marked", nil, {
            all(outcome("jc", status: 0) { pane("jc")?.customTitle == "DONE true" },
                eq(pane("j0")?.attention, Attention.none, "caller attention"))
        }) {
            pane("j0").map { self.clearAttention($0) }
            created(call("run", ["command": "true", "cwd": tmp, "close": false, "notify": false, "placement": "split", "size": "20%"],
                         caller: "j0"), "jc")
        }
        t.step("jobs: bad requests fail; job-done outside a job keeps the shell", nil, {
            let empty = ControlHandler.handle(["cmd": "run", "args": ["command": "  "]])
            let badDir = ControlHandler.handle(["cmd": "run", "args": ["command": "true", "cwd": "/no/such/dir"]])
            let notJob = call("job-done", ["status": 0], caller: "j0")
            return all(empty["ok"] as? Bool == false ? nil : "empty command should fail",
                       badDir["ok"] as? Bool == false ? nil : "missing cwd should fail",
                       eq(notJob?["close"] as? Bool, false, "job-done in a non-job pane"))
        }) {}
        t.step("jobs: `dealer run` over the socket quotes several words and uses the caller's $PWD", nil, {
            guard let socket = ControlServer.shared.path else { return "control socket isn't running" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            p.arguments = ["run", "--quiet", "printf", "%s\\n", "a b", "it's"]
            p.currentDirectoryURL = URL(fileURLWithPath: tmp)
            var env = ProcessInfo.processInfo.environment
            env["DEALER_SOCKET"] = socket
            env["DEALER_PANE_ID"] = "\(ids["j0"]!)"
            env["PWD"] = tmp
            for k in ["DEALER_SELFTEST", "MYTERM_SELFTEST"] { env.removeValue(forKey: k) }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            do { try p.run() } catch { return "can't run the CLI: \(error)" }
            _ = wait(10) { !p.isRunning }
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let id = Int(o.trimmingCharacters(in: .whitespacesAndNewlines)), let jp = ControlHandler.pane(id: id) else {
                return "run printed \(o.debugDescription), status \(p.terminationStatus)"
            }
            t.named(jp, "jd")
            ids["jd"] = id
            let job = ControlJobs.job(for: jp)
            let cwd = job?.cwd
            return all(eq(job?.command, "printf '%s\\n' 'a b' 'it'\\''s'", "quoted command"),
                       eq(job?.notify, false, "--quiet"),
                       cwd.map { ($0 as NSString).resolvingSymlinksInPath == (tmp as NSString).resolvingSymlinksInPath } == true
                           ? nil : "job cwd \(cwd ?? "nil") should be \(tmp)")
        }) {}
        t.step("jobs: close the test workspace", nil, {
            self.workspaces.contains { $0.name == "jobs" } ? "workspace should be gone" : nil
        }) {
            if let ws = self.workspaces.first(where: { $0.name == "jobs" }) { self.remove(workspace: ws) }
            if let s = savedSettings { try? s.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload(force: true)
            try? fm.removeItem(atPath: tmp)
        }
    }
}
