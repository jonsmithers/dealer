import AppKit
import GhosttyKit

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
        var lastRoute: [String: Any]?
        var jbGone = false

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
        var live: Bool { pane("j0")?.surface.surface != nil }
        /// Waits for the job's shell to report, or reports for it when there's no shell.
        func outcome(_ job: String, status: Int, until cond: () -> Bool) -> String? {
            if live {
                return SelfTest.waitUntil(timeout: 20, cond) ? nil : "the job's shell never reported back (status \(status))"
            }
            print("      (no live shell: reporting job-done \(status) through the handler; the typed tail wasn't exercised)")
            let r = call("job-done", ["status": status], caller: job)
            if status == 0, r?["close"] as? Bool == true, let p = pane(job) { self.remove(p) }
            return cond() ? nil : "state after job-done \(status) is wrong"
        }
        /// `[jobs] size` defaults to 12 rows (needs a live surface for cell metrics).
        func rows(_ n: String, near want: Int) -> String? {
            guard live, let s = pane(n)?.surface.surface else { return nil }
            let got = Int(ghostty_surface_size(s).rows)
            return abs(got - want) <= 2 ? nil : "\(n) should be about \(want) rows, is \(got)"
        }
        /// A pane out of view still has its real size (#45): a frame, and with a live surface a real grid.
        func sized(_ n: String) -> String? {
            guard let p = pane(n) else { return "\(n) is gone" }
            let f = p.view.frame
            guard f.width > 200, f.height > 100 else { return "\(n) (out of view) has frame \(f.size)" }
            guard let s = p.surface.surface else { return nil }
            let z = ghostty_surface_size(s)
            return z.columns > 20 && z.rows > 5 ? nil : "\(n) (out of view) has a \(z.columns)x\(z.rows) grid"
        }
        /// Runs the real CLI binary as a client of this instance, from `dir`, as if called in `caller`.
        func cli(_ args: [String], from dir: String, caller: String = "j0") -> (status: Int32, out: String, err: String) {
            guard let socket = ControlServer.shared.path else { return (-1, "", "no socket") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            var env = ProcessInfo.processInfo.environment
            env["DEALER_SOCKET"] = socket
            env["DEALER_PANE_ID"] = "\(ids[caller] ?? 0)"
            env["PWD"] = dir
            env.removeValue(forKey: "DEALER_SELFTEST")
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return (-1, "", "\(error)") }
            _ = SelfTest.waitUntil(timeout: 10) { !p.isRunning }
            if p.isRunning { p.terminate(); return (-1, "", "timed out") }
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        func workspace(_ name: String) -> Workspace? { self.workspaces.first { $0.name == name } }
        func routed(_ r: [String: Any]?) -> String? { (r?["route"] as? [String: Any])?["outcome"] as? String }
        func skipped(_ what: String) -> String? {
            print("      (skipped \(what): ghostty couldn't create terminal surfaces here)")
            return nil
        }
        /// Once the kept job "jc" has reported, its whole typed line has finished too. Shell
        /// integration reports that line's exit status (COMMAND_FINISHED) at the next prompt, and a
        /// non-zero one marks the pane failed (`failed_commands`). #50: the tail used to end
        /// `job-done $? && exit`, where job-done exited 1 to keep the shell, so a kept success
        /// went red. Typing a marker and waiting for its output gets past that prompt first.
        func keptLineFinished() -> String? {
            guard let p = pane("jc") else { return "no kept job pane" }
            guard live, let s = p.surface.surface else { return skipped("the kept job's line status") }
            p.surface.perform("text:" + ControlHandler.escapeForBinding(" echo kept-$((40+2))"))
            try? ControlHandler.parseKey("enter").send(to: s)
            guard SelfTest.waitUntil(timeout: 10, { p.surface.screenText.contains("kept-42\n") }) else {
                return "the kept job's shell didn't come back to a prompt: \(p.surface.screenText.debugDescription)"
            }
            return all(eq(p.attention, Attention.none, "kept job's attention"),
                       p.surface.screenText.contains("&& exit") ? "the kept job's line still ends in && exit" : nil)
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
                eq(Settings.jobPlacement, "split", "default placement"),
                rows("ja", near: 12))
        }) {
            created(call("run", ["command": "false", "cwd": tmp], caller: "j0"), "ja")
        }
        t.step("jobs: a failed job stays open, retitled and marked failed (red, #29)", nil, {
            all(outcome("ja", status: 1) { pane("ja")?.customTitle == "FAILED (1) false" },
                tree("Deck0[*Col(j0, ja)]"), marked("ja", .failed), focused("j0"))
        }) {}
        // #45: a pane created out of view used to have no frame, so its surface was 1×1 cells and a
        // background job's output was gone once the tab was shown at its real size.
        t.step("jobs: --tab: the background job's pane is sized while hidden and keeps its output when shown", nil, {
            guard let p = pane("jt"), let l = self.locate(p) else { return all("no --tab job") }
            let hidden = all(sized("jt"), p.view.isHidden ? nil : "jt's tab should be in the background")
            guard live, let s = p.surface.surface else {
                return all(hidden, skipped("--tab job output"))
            }
            let reported = SelfTest.waitUntil(timeout: 20) { ControlJobs.job(for: p)?.status != nil }
            _ = SelfTest.waitUntil(timeout: 3) { p.surface.screenText.contains("hello hello\n") }
            // Sized while hidden, so showing the tab doesn't resize the grid (#45), and the output
            // read below is what the user sees, with no resize still to come.
            let hiddenGrid = ghostty_surface_size(s)
            self.select(tab: l.tab, in: l.deck)
            let shownGrid = ghostty_surface_size(s)
            func visible(_ t: String) -> Bool { t.contains("echo hello hello && false") && t.contains("hello hello\n") }
            SelfTest.waitUntil(timeout: 3) { visible(p.surface.screenText) }
            let text = p.surface.screenText
            let shown = all(reported ? nil : "the job's shell never reported back",
                            (hiddenGrid.columns, hiddenGrid.rows) == (shownGrid.columns, shownGrid.rows) ? nil
                                : "showing the tab resized its grid \(hiddenGrid.columns)x\(hiddenGrid.rows) → \(shownGrid.columns)x\(shownGrid.rows)",
                            visible(text) ? nil : "after showing the tab its screen is \(text.debugDescription)")
            pane("j0").map { self.focus($0) }
            self.remove(p)
            return all(hidden, shown)
        }) {
            created(call("run", ["command": "echo hello hello && false", "cwd": tmp, "placement": "tab"], caller: "j0"), "jt")
        }
        t.step("jobs: [jobs] placement = \"tab\" puts the next job in a background tab", nil, {
            all(tree("Deck0[*Col(j0, ja), jb]"), focused("j0"),
                eq(self.locate(pane("jb")!)?.tab.title, "RUN true", "tab title"))
        }) {
            // The directory exists only if an earlier section made it (not under DEALER_SELFTEST_ONLY).
            try? FileManager.default.createDirectory(at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[jobs]\nplacement = \"tab\"\n".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload(force: true)
            created(call("run", ["command": "true", "cwd": tmp], caller: "j0"), "jb")
        }
        t.step("jobs: a successful job reports success and marks the caller done", nil, {
            all(outcome("jb", status: 0) { pane("jb").flatMap { ControlJobs.job(for: $0)?.status } == 0 || pane("jb") == nil },
                marked("j0", .done), focused("j0"))
        }) {}
        // Dealer closes a successful job's pane itself (the shell doesn't `exit`), on the main queue
        // right after replying to job-done.
        var j0AfterClose: Attention?
        var j0Looked = false
        t.step("jobs: ...and Dealer closes its pane", nil, {
            SelfTest.waitUntil(timeout: 10) { pane("jb") == nil } ? nil : "jb's pane should have closed"
        }) {}
        // #50: a kept success marks the job pane, which stays and is out of focus. It used to mark
        // the caller, which the user is usually still looking at, so nothing showed and no
        // notification was posted. The caller stays focused (and, in front, looked at) here.
        t.step("jobs: --keep: a successful job stays and marks its own pane done, not the caller", nil, {
            all(j0Looked || j0AfterClose == .done ? nil : "j0's done mark should survive the job pane closing, is \(j0AfterClose?.name ?? "nil")",
                outcome("jk", status: 0) { pane("jk")?.customTitle == "DONE true" },
                eq(pane("jk")?.attention, Attention.done, "kept job's attention"),
                eq(pane("j0")?.attention, Attention.none, "caller attention"), focused("j0"))
        }) {
            j0AfterClose = pane("j0")?.attention
            j0Looked = pane("j0").map { self.isLookingAt($0) } ?? false
            pane("j0").map { self.clearAttention($0, cause: "self-test") }
            created(call("run", ["command": "true", "cwd": tmp, "close": false, "placement": "split", "size": "20%"],
                         caller: "j0"), "jk")
        }
        t.step("jobs: --keep --quiet: a successful job stays, retitled, and nothing is marked", nil, {
            all(outcome("jc", status: 0) { pane("jc")?.customTitle == "DONE true" },
                eq(pane("jc")?.attention, Attention.none, "quiet kept job's attention"),
                eq(pane("j0")?.attention, Attention.none, "caller attention"),
                keptLineFinished())
        }) {
            pane("jk").map { self.remove($0) }
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
            env.removeValue(forKey: "DEALER_SELFTEST")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            do { try p.run() } catch { return "can't run the CLI: \(error)" }
            _ = SelfTest.waitUntil(timeout: 10) { !p.isRunning }
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
        // Route by cwd (#21): the deepest pane directory containing $PWD wins; ties go to the
        // caller's workspace; nothing containing it makes a workspace named after the directory.
        let solo = NSTemporaryDirectory() + "dealer-jobs-solo-\(getpid())"
        let sleeper = "sleep 30"
        t.step("jobs: route: a deeper pane in another workspace wins, focus and workspace stay", nil, {
            guard let jp = pane("r1"), let l = self.locate(jp) else { return all("no routed job") }
            return all(eq(routed(lastRoute), "other", "outcome"), eq(l.workspace.name, "deep", "workspace"),
                       l.node.sibling?.leaf === pane("rb") ? nil : "job should be split beside rb",
                       eq(self.activeWorkspace.name, "jobs", "active workspace"), focused("j0"), sized("r1"))
        }) {
            for d in ["/a/b/c", "/x", "/y"] { try? fm.createDirectory(atPath: tmp + d, withIntermediateDirectories: true) }
            try? fm.createDirectory(atPath: solo, withIntermediateDirectories: true)
            created(call("create", ["type": "workspace", "target": "focused", "name": "deep", "cwd": tmp + "/a/b", "focus": false]), "rb")
            let r = call("run", ["command": sleeper, "cwd": tmp + "/a/b/c", "placement": "split"], caller: "j0")
            lastRoute = r
            created(r, "r1")
        }
        t.step("jobs: route: the caller's own workspace when it owns $PWD most deeply", nil, {
            all(eq(routed(lastRoute), "caller", "outcome"), eq(pane("r2").flatMap { self.locate($0)?.workspace.name }, "jobs", "workspace"))
        }) {
            let r = call("run", ["command": sleeper, "cwd": tmp + "/a", "placement": "split"], caller: "j0")
            lastRoute = r
            created(r, "r2")
        }
        t.step("jobs: route: ties go to the caller's workspace, whichever it is", nil, {
            all(eq(pane("r3").flatMap { self.locate($0)?.workspace.name }, "tie", "from the tie workspace's pane"),
                eq(pane("r4").flatMap { self.locate($0)?.workspace.name }, "jobs", "from j0"), focused("j0"))
        }) {
            created(call("create", ["type": "workspace", "target": "focused", "name": "tie", "cwd": tmp, "focus": false]), "rt")
            created(call("run", ["command": sleeper, "cwd": tmp + "/x", "placement": "split"], caller: "rt"), "r3")
            // Not /x: r3 now sits there, deeper than either caller.
            created(call("run", ["command": sleeper, "cwd": tmp + "/y", "placement": "split"], caller: "j0"), "r4")
        }
        t.step("jobs: route: -t and --here skip routing", nil, {
            all(eq(pane("r5").flatMap { self.locate($0)?.workspace.name }, "jobs", "--here"), eq(routed(lastRoute), nil, "no route info"))
        }) {
            let r = call("run", ["command": sleeper, "cwd": tmp + "/a/b/c", "placement": "split", "route": false], caller: "j0")
            lastRoute = r
            created(r, "r5")
        }
        t.step("jobs: route: nothing owns $PWD, so `dealer run` makes a workspace named after it, logged on stderr", nil, {
            let (st, out, err) = cli(["run", "--", sleeper], from: solo)
            let name = (solo as NSString).lastPathComponent
            guard let id = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)), let jp = ControlHandler.pane(id: id),
                  let l = self.locate(jp) else { return "run printed \(out.debugDescription) (\(st)) \(err)" }
            return all(eq(l.workspace.name, name, "new workspace name"), eq(l.workspace.panes.count, 1, "panes in it"),
                       err.contains("no workspace owned") && err.contains(name) ? nil : "stderr: \(err.debugDescription)",
                       eq(self.activeWorkspace.name, "jobs", "active workspace"), focused("j0"))
        }) {}
        t.step("jobs: route: the CLI logs re-use of a deeper workspace", nil, {
            // rb (in "deep") is at a/b; "jobs" only reaches a/b via r2 at a.
            let (_, _, err) = cli(["run", "--", sleeper], from: tmp + "/a/b")
            return err.contains("re-using workspace") && err.contains("\"deep\"") ? nil : "stderr: \(err.debugDescription)"
        }) {}

        // Quoting (#21): `b() { dealer run -- "$@"; }`. Several args are quoted word by word; one
        // arg is a shell string. Checked in a real shell when there is one.
        let shot = tmp + "/Screenshot 2024-12-10 at 3.52.12 PM.png"
        t.step("jobs: quoting: a path with spaces, quotes, $ and globs survive; a single string is a pipeline", nil, {
            guard live else { return all(skipped("real-shell quoting")) }
            // `> file` creates the file before the command writes it, so wait for whole lines, not
            // just the files (an empty `piped` read here made this step flaky).
            func read(_ f: String) -> String { (try? String(contentsOfFile: tmp + "/" + f, encoding: .utf8)) ?? "" }
            let ok = SelfTest.waitUntil(timeout: 20) {
                fm.fileExists(atPath: tmp + "/copied.png") && read("words").hasSuffix("\n") && read("piped").hasSuffix("\n")
            }
            let words = read("words"), piped = read("piped")
            return all(ok ? nil : "jobs didn't all produce their files and contents (copied.png, words, piped)",
                       eq(words, "it's\n$HOME\n*.png\n\"q\"\n", "words"),
                       eq(piped, "A B\n", "pipeline"))
        }) {
            fm.createFile(atPath: shot, contents: Data("png".utf8))
            for args in [["run", "--", "cp", shot, "copied.png"],
                         ["run", "--", "sh", "-c", "printf '%s\\n' \"$@\" > words", "sh", "it's", "$HOME", "*.png", "\"q\""],
                         ["run", "--", "printf 'a b\\n' | tr a-z A-Z > piped"]] {
                let r = cli(args, from: tmp)
                if r.status != 0 { lastError = "\(args): \(r.status) \(r.err)"; return }
            }
        }
        t.step("jobs: close the test workspace", nil, {
            // Checked this late because the close arrives on the main queue, between steps.
            all(eq(jbGone, true, "jb closed by Dealer on success"),
                self.workspaces.contains { ["jobs", "deep", "tie"].contains($0.name ?? "") } ? "test workspaces should be gone" : nil)
        }) {
            jbGone = ids["jb"].flatMap(ControlHandler.pane(id:)) == nil
            for n in ["jobs", "deep", "tie", (solo as NSString).lastPathComponent] {
                if let ws = workspace(n) { self.remove(workspace: ws) }
            }
            try? fm.removeItem(atPath: solo)
            if let s = savedSettings { try? s.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload(force: true)
            try? fm.removeItem(atPath: tmp)
        }
    }
}

extension SurfaceView {
    /// Everything on the screen and in scrollback, as Ghostty's own app reads it.
    var screenText: String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}
