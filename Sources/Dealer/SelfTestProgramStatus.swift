import AppKit

// MARK: - Self-test section: Program Status Protocol (OSC 7501, #89)
//
// Self-contained (`DEALER_SELFTEST_ONLY=program status:`). The parser and the record store are
// checked without a surface, so most of this runs on a locked screen too. Records reach a pane
// through `ProgramStatus.receive`, the same call GHOSTTY_ACTION_PROGRAM_STATUS makes; the `live`
// steps send real sequences from a shell (Dealer's runtime patch to libghostty) and skip without one.

extension TerminalWindowController {
    func programStatusSelfTestSteps(_ t: SelfTestKit) {
        var id: Int?
        var lastError: String?
        let dir = NSTemporaryDirectory() + "dealer-ps-\(getpid())"
        let savedMax = ProgramStatus.maxRecords
        let savedExit = (ProgramStatus.exitCheckEnabled, ProgramStatus.exitCheckInterval)

        func pane() -> Pane? { id.flatMap(ControlHandler.pane(id:)) }
        func all(_ problems: [String?]) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        func parse(_ body: String) -> ProgramStatus.Report? { try? ProgramStatus.parse(body).get() }
        func error(_ body: String) -> ProgramStatus.ParseError? {
            if case .failure(let e) = ProgramStatus.parse(body) { return e }
            return nil
        }
        /// Nobody is looking: marks are set (the window isn't key).
        func away() { Presence.override = Presence.Facts(appActive: false, screenLocked: false, keyWindow: nil) }
        /// The user is looking at `p`.
        func looking(at p: Pane) {
            reveal(p, cause: "selftest")
            Presence.override = Presence.Facts(appActive: true, screenLocked: false, keyWindow: window)
        }
        func send(_ p: Pane, _ body: String) { ProgramStatus.receive(body, on: p, source: "selftest") }
        /// Starts a pane from scratch: no records, no attention, 9;4 counting again.
        func fresh(_ p: Pane) {
            away()
            send(p, "")
            clearAttention(p, cause: "selftest")
            p.programAttention = .none
            _ = ProgressSource.note(p, active: false, percent: nil, foreground: 0)
        }
        func live(_ p: Pane) -> Bool {
            guard p.surface.surface != nil else {
                print("      (skipped a live OSC 7501 check: ghostty couldn't create terminal surfaces here)")
                return false
            }
            return true
        }
        /// Writes `body` to a script in the temp dir and runs it in `p`'s shell.
        func run(_ p: Pane, _ name: String, _ body: String, interpreter: String = "/bin/sh", args: String = "") {
            let path = "\(dir)/\(name)"
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
            p.surface.typeText("\(interpreter) \(path)\(args.isEmpty ? "" : " " + args)\r")
        }

        // MARK: Parser (no surface)

        t.step("program status: the parser reads every state and key, skips malformed pairs and unknown keys, and the last value wins", nil, {
            var problems: [String?] = []
            for s in ProgramStatus.State.allCases {
                problems.append(parse("state=\(s.rawValue)")?.state == s ? nil : "state=\(s.rawValue) not read")
            }
            let r = parse("state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform:title=\(b64("Plan")):msg=\(b64("Apply 3 changes?"))")
            problems.append(r == ProgramStatus.Report(state: .blocked, id: "tf/plan", kind: .permission, progress: 42, app: "terraform",
                                                      title: "Plan", msg: "Apply 3 changes?") ? nil : "all keys: got \(String(describing: r))")
            problems.append(parse("state=idle:future=yes:oops::=x")?.state == .idle ? nil : "a malformed pair or unknown key discarded the report")
            problems.append(parse("state=idle:app=a:state=done:app=b").map { $0.state == .done && $0.app == "b" } == true ? nil : "last value should win")
            problems.append(parse(" state = working :\tapp=cargo\t")?.app == "cargo" ? nil : "whitespace around keys and values")
            problems.append(parse("state=done:msg=\(b64("Plan").replacingOccurrences(of: "=", with: ""))")?.msg == "Plan" ? nil : "base64 padding should be optional")
            problems.append(parse("state=working:kind=auth")?.kind == nil ? nil : "kind is only read for blocked")
            problems.append(parse("state=done:progress=40")?.progress == nil ? nil : "progress is only read for working and blocked")
            problems.append(parse("state=working:progress=101")?.progress == nil ? nil : "progress over 100 reads as indeterminate")
            problems.append(parse("state=working:progress=007")?.progress == 7 ? nil : "progress 007")
            problems.append(parse("state=working:app=a b") .map { $0.app == nil } == true ? nil : "an app with a space should read as absent")
            return all(problems)
        }) {}

        t.step("program status: a missing state, bad base64, a control character, a bad id or a broken limit discards the report", nil, {
            let long = { (n: Int) in String(repeating: "a", count: n) }
            let cases: [(String, ProgramStatus.ParseError)] = [
                ("id=x", .invalidState),
                ("state=sleeping", .invalidState),
                ("state=done:msg=A", .invalidText("msg")),
                ("state=done:msg=\(b64("one\ntwo"))", .invalidText("msg")),
                ("state=done:title=\(b64("bell\u{7}"))", .invalidText("title")),
                ("state=done:msg=\(b64("c1\u{9b}"))", .invalidText("msg")),
                ("state=clear:id=a//b", .invalidId),
                ("state=clear:id=a/b c", .invalidId),
                ("state=done:id=" + Array(repeating: "a", count: 9).joined(separator: "/"), .tooLong("id")),
                ("state=done:id=" + long(33), .tooLong("id")),
                ("state=done:app=" + long(33), .tooLong("app")),
                ("state=done:" + long(17) + "=1", .tooLong("a key")),
                ("state=done:title=" + b64(long(193)), .tooLong("title")),
                ("state=done:msg=" + b64(long(2049)), .tooLong("msg")),
                ("state=done:x=" + long(ProgramStatus.maxBodyBytes), .tooLong("report")),
                // Even a value a later pair replaces counts against its limit.
                ("state=done:app=" + long(33) + ":app=ok", .tooLong("app")),
            ]
            let wrong = cases.compactMap { body, want -> String? in
                let got = error(body)
                return got == want ? nil : "\(body.prefix(40)): want \(want), got \(got.map(\.description) ?? "a valid report")"
            }
            return all(wrong)
        }) {}

        t.step("program status: text is sanitized in one place: bidi and invisible formatting characters are removed", nil, {
            let tricky = "safe\u{202E}txt.exe\u{200B}\u{2066}x\u{2069}\u{FEFF}"
            let r = parse("state=done:msg=\(b64(tricky)):title=\(b64("\u{200F}T"))")
            return all([r?.msg == "safetxt.exex" ? nil : "msg: \(String(describing: r?.msg?.unicodeScalars.map { String($0.value, radix: 16) }))",
                        r?.title == "T" ? nil : "title: \(String(describing: r?.title))",
                        ProgramStatus.sanitize("a\u{2028}b") == "a b" ? nil : "a line separator should become a space"])
        }) {}

        // MARK: Record store (no surface)

        t.step("program status: each report replaces its record whole; clear removes a record and its children, or all", nil, {
            let s = ProgramStatusStore()
            var problems: [String?] = []
            s.apply(parse("state=working:app=cargo:progress=10:msg=\(b64("x"))")!)
            s.apply(parse("state=working")!)
            let root = s.records[""]
            problems.append(root?.app == nil && root?.progress == nil && root?.msg == nil ? nil : "keys not resent should be gone: \(String(describing: root))")
            for i in ["build", "build/test", "build/test/unit", "builder", "lint"] { s.apply(parse("state=working:id=\(i)")!) }
            s.apply(parse("state=clear:id=build/test")!)
            problems.append(Set(s.records.keys) == ["", "build", "builder", "lint"] ? nil : "clear build/test left \(s.records.keys.sorted())")
            s.apply(parse("state=clear:id=build")!)
            problems.append(Set(s.records.keys) == ["", "builder", "lint"] ? nil : "clear build left \(s.records.keys.sorted()) (a sibling with the same prefix must stay)")
            s.apply(parse("state=clear")!)
            problems.append(s.isEmpty ? nil : "clear without an id left \(s.records.keys.sorted())")
            problems.append(s.inUse ? nil : "the store should remember that 7501 was used")
            s.reset()
            problems.append(!s.inUse ? nil : "a full reset should forget it")
            return all(problems)
        }) {}

        t.step("program status: child records roll up (error > blocked > done > working > idle) and inherit app", nil, {
            let s = ProgramStatusStore()
            var problems: [String?] = []
            func top() -> ProgramStatus.State? { s.summary?.state }
            s.apply(parse("state=idle:app=deploy")!)
            problems.append(top() == .idle ? nil : "idle")
            s.apply(parse("state=working:id=us-east")!)
            problems.append(top() == .working ? nil : "working beats idle")
            problems.append(s.app(of: "us-east") == "deploy" ? nil : "a child should inherit the root's app")
            s.apply(parse("state=working:id=us-east/db:app=postgres")!)
            problems.append(s.app(of: "us-east/db") == "postgres" && s.app(of: "us-east/db/x") == "postgres" ? nil : "nearest ancestor's app")
            s.apply(parse("state=done:id=eu")!)
            problems.append(top() == .done ? nil : "done beats working")
            s.apply(parse("state=blocked:id=ap:kind=auth")!)
            problems.append(top() == .blocked && s.attentionLevel == .waiting ? nil : "blocked beats done")
            s.apply(parse("state=error:id=us-east/db")!)
            problems.append(top() == .error && s.attentionLevel == .failed ? nil : "error beats everything")
            s.dropTransient()
            problems.append(Set(s.records.keys) == ["", "eu", "us-east/db"] ? nil : "dropTransient should keep idle, done and error: \(s.records.keys.sorted())")
            s.dismissFinished()
            problems.append(Set(s.records.keys) == [""] ? nil : "dismissFinished should drop done and error: \(s.records.keys.sorted())")
            return all(problems)
        }) {}

        t.step("program status: the record cap evicts the least recently updated record", nil, {
            let s = ProgramStatusStore()
            ProgramStatus.maxRecords = 256
            for i in 0..<256 { s.apply(parse("state=working:id=r\(i)")!) }
            s.apply(parse("state=done:id=r0")!)          // r0 is now the most recent
            s.apply(parse("state=working:id=r256")!)     // evicts r1, the least recently updated
            ProgramStatus.maxRecords = savedMax
            return all([s.records.count == 256 ? nil : "\(s.records.count) records, want 256",
                        s.records["r1"] == nil ? nil : "r1 should have been evicted",
                        s.records["r0"] != nil && s.records["r256"] != nil ? nil : "r0 and r256 should be kept"])
        }) {}

        // MARK: Mapping onto a pane

        t.step("program status: setup, a pane in its own workspace", nil, {
            guard pane() != nil else { return all(["no pane created"]) }
            return all([])
        }) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let r = ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "program status"]])
            guard r["ok"] as? Bool == true, let pid = (r["result"] as? [String: Any])?["pane"] as? Int else {
                lastError = "create failed: \(r["error"] ?? "?")"; return
            }
            id = pid
            if let p = ControlHandler.pane(id: pid) { t.named(p, "ps") }
        }

        t.step("program status: working spins (arc, ring for a percentage, Claude's mark for app=claude-code); blocked waits, with kind and msg in the status line", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            var problems: [String?] = []
            send(p, "state=working")
            problems.append(p.agentState == .running && p.workingMark == .arc ? nil : "working: \(p.agentState), \(String(describing: p.workingMark))")
            send(p, "state=working:progress=40")
            problems.append(p.workingMark == .ring(40) ? nil : "progress=40: \(String(describing: p.workingMark))")
            send(p, "state=working:app=claude-code")
            problems.append(p.workingMark == .claude ? nil : "app=claude-code: \(String(describing: p.workingMark))")
            send(p, "state=blocked:kind=permission:msg=\(b64("Apply 3 changes?"))")
            problems.append(p.attention == .waiting && p.agentState == .waiting ? nil : "blocked: attention \(p.attention), state \(p.agentState)")
            problems.append(p.statusLine.hasPrefix("waiting (permission) · Apply 3 changes?") ? nil : "status line: \(p.statusLine)")
            problems.append(!p.isWorking ? nil : "a blocked pane isn't working")
            return all(problems)
        }) {}

        t.step("program status: 7501's attention is a level: blocked → working lowers waiting, done and error mark, idle and clear lower them", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            var problems: [String?] = []
            send(p, "state=blocked:kind=question")
            problems.append(p.attention == .waiting ? nil : "blocked should mark waiting, got \(p.attention)")
            send(p, "state=working")
            problems.append(p.attention == .none && p.agentState == .running ? nil : "working should lower waiting: \(p.attention), \(p.agentState)")
            send(p, "state=done")
            problems.append(p.attention == .done && p.agentState == .done ? nil : "done: \(p.attention), \(p.agentState)")
            send(p, "state=error")
            problems.append(p.attention == .failed && p.agentState == .failed ? nil : "error: \(p.attention), \(p.agentState)")
            send(p, "state=done")
            problems.append(p.attention == .done ? nil : "error → done should lower failed to done, got \(p.attention)")
            send(p, "state=idle")
            problems.append(p.attention == .none && p.agentState == .idle ? nil : "idle: \(p.attention), \(p.agentState)")
            send(p, "state=blocked")
            send(p, "state=clear")
            problems.append(p.attention == .none && p.programStatus.isEmpty ? nil : "clear: \(p.attention), \(p.programStatus.records.count) records")
            return all(problems)
        }) {}

        t.step("program status: 7501 never lowers another source's mark", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            self.setAttention(.failed, on: p, event: "selftest:notify")
            send(p, "state=blocked")
            send(p, "state=working")
            return all([p.attention == .failed ? nil : "a failed mark from `dealer notify` was lowered to \(p.attention)"])
        }) {}

        t.step("program status: blocked shows in the status line while the user is looking (no mark); done seen while looking is dismissed", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            looking(at: p)
            defer { away() }
            var problems: [String?] = [self.isLookingAt(p) ? nil : "the self-test can't look at the pane"]
            send(p, "state=blocked:kind=permission")
            problems.append(p.attention == .none ? nil : "no mark while looking, got \(p.attention)")
            problems.append(p.agentState == .waiting && p.statusLine.hasPrefix("waiting (permission)") ? nil : "status line while looking: \(p.statusLine)")
            send(p, "state=done")
            problems.append(p.attention == .none && p.programStatus.isEmpty && p.agentState == .idle
                            ? nil : "done while looking: attention \(p.attention), \(p.programStatus.records.count) records, \(p.agentState)")
            return all(problems)
        }) {}

        t.step("program status: clearing the mark (focusing the pane) dismisses done and error records, but keeps blocked", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            var problems: [String?] = []
            send(p, "state=done:id=a")
            send(p, "state=error:id=b")
            self.clearAttention(p, cause: "selftest")
            problems.append(p.programStatus.isEmpty && p.agentState == .idle ? nil : "done/error kept after the mark was cleared: \(p.programStatus.records.keys.sorted())")
            send(p, "state=blocked:id=c")
            self.clearAttention(p, cause: "selftest")
            problems.append(p.agentState == .waiting ? nil : "blocked should stay after the mark is cleared, state \(p.agentState)")
            send(p, "state=blocked:id=c:msg=\(b64("still"))")
            problems.append(p.attention == .none ? nil : "a blocked record that was already seen shouldn't mark again")
            send(p, "state=working:id=c")
            send(p, "state=blocked:id=c")
            problems.append(p.attention == .waiting ? nil : "a new blocked after working should mark again, got \(p.attention)")
            return all(problems)
        }) {}

        t.step("program status: child records roll up to the pane, tab and workspace", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            send(p, "state=working:id=build")
            send(p, "state=error:id=build/test")
            let tab = self.locate(p)?.tab
            var problems: [String?] = [p.agentState == .failed && p.attention == .failed ? nil : "error child: \(p.agentState), \(p.attention)"]
            problems.append(tab?.attention == .failed ? nil : "the tab should roll up failed")
            send(p, "state=clear:id=build")
            problems.append(p.programStatus.isEmpty && p.attention == .none ? nil : "clear id=build: \(p.programStatus.records.keys.sorted()), \(p.attention)")
            return all(problems)
        }) {}

        t.step("program status: the 9;4 hand-off: 7501 drops a pane's 9;4 progress and replaces it until a full reset", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            var problems: [String?] = []
            _ = ProgressSource.note(p, active: true, percent: 30, foreground: 0)
            problems.append(p.workingMark == .ring(30) ? nil : "9;4 alone should show its ring")
            send(p, "state=idle")
            problems.append(!p.isReportingProgress && p.agentState == .idle && p.programStatus.inUse ? nil : "7501 should drop the 9;4 progress: \(p.agentState)")
            send(p, "")
            problems.append(!p.programStatus.inUse && p.programStatus.isEmpty ? nil : "a full reset should end the hand-off")
            return all(problems)
        }) {}

        t.step("program status: the next prompt drops working and blocked records, keeps done, error and idle", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            send(p, "state=idle")
            send(p, "state=working:id=w")
            send(p, "state=blocked:id=b")
            send(p, "state=done:id=d")
            ProgramStatus.promptReturned(p)
            return all([Set(p.programStatus.records.keys) == ["", "d"] ? nil : "after the prompt: \(p.programStatus.records.keys.sorted())",
                        p.attention == .done ? nil : "the waiting mark should give way to done, got \(p.attention)"])
        }) {}

        t.step("program status: when the reporting program leaves the foreground, its working and blocked records go", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            ProgramStatus.exitCheckEnabled = true
            ProgramStatus.exitCheckInterval = 0.2
            var fg: Int32 = 4242
            ProgressSource.currentForegroundOverride = { _ in fg }
            defer {
                ProgressSource.currentForegroundOverride = nil
                (ProgramStatus.exitCheckEnabled, ProgramStatus.exitCheckInterval) = savedExit
            }
            send(p, "state=blocked")
            send(p, "state=done:id=d")
            var problems: [String?] = [p.programReporter == 4242 ? nil : "the reporter's group wasn't recorded"]
            let kept = SelfTest.waitUntil(timeout: 0.6) { p.programStatus.records[""] == nil }
            problems.append(!kept ? nil : "dropped while the reporter was still in the foreground")
            fg = 99
            problems.append(SelfTest.waitUntil("the blocked record to go", timeout: 3) { p.programStatus.records[""] == nil })
            problems.append(p.programStatus.records["d"] != nil ? nil : "the done record should stay")
            return all(problems)
        }) {}

        // MARK: Live, through libghostty

        t.step("program status: live: a report from a shell reaches the pane (done survives the prompt, blocked doesn't)", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            guard live(p) else { return all([]) }
            var problems: [String?] = [p.surface.waitForShell() ? nil : "the shell didn't start"]
            run(p, "report.sh", #"printf '\033]7501;state=blocked:kind=question\033\\'; printf '\033]7501;state=done:id=d:msg=%s\033\\' "$(printf 'All set' | base64)"; sleep 0.5"# + "\n")
            problems.append(SelfTest.waitUntil("both reports to arrive", timeout: 10) {
                p.programStatus.records[""]?.state == .blocked && p.programStatus.records["d"] != nil
            })
            problems.append(p.programStatus.records["d"]?.msg == "All set" ? nil : "done record: \(String(describing: p.programStatus.records["d"]))")
            problems.append(SelfTest.waitUntil("the prompt to drop the blocked record (shell integration's COMMAND_FINISHED)", timeout: 10) {
                p.programStatus.records[""] == nil
            })
            problems.append(p.programStatus.records["d"] != nil ? nil : "the done record should survive the prompt")
            return all(problems)
        }) {}

        t.step("program status: live: a malformed report and an unknown state change nothing; 9;4 is ignored after 7501", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            guard live(p) else { return all([]) }
            send(p, "state=idle")  // the pane has used 7501
            run(p, "bad.sh", #"printf '\033]7501;state=done:msg=A\033\\\033]7501;state=sleeping\033\\\033]9;4;1;50\007\033]7501;state=done:id=sync\033\\'"# + "\n")
            var problems: [String?] = [SelfTest.waitUntil("the sync report", timeout: 10) { p.programStatus.records["sync"] != nil }]
            problems.append(p.programStatus.records[""]?.state == .idle ? nil : "a malformed report was applied: \(String(describing: p.programStatus.records[""]))")
            problems.append(!p.isReportingProgress ? nil : "9;4 should be ignored once the pane used 7501")
            return all(problems)
        }) {}

        t.step("program status: live: a full reset (RIS) clears the records and 9;4 counts again", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            guard live(p) else { return all([]) }
            send(p, "state=done:id=x")
            run(p, "ris.sh", #"printf '\033c'; printf '\033]9;4;1;50\007'; sleep 1"# + "\n")
            return all([SelfTest.waitUntil("the reset to clear the records and the 9;4 report to count", timeout: 10) {
                p.programStatus.isEmpty && !p.programStatus.inUse && p.isReportingProgress
            }])
        }) {}

        t.step("program status: live: the support query gets its reply before the reply to the CSI c that follows it", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            fresh(p)
            guard live(p) else { return all([]) }
            let out = "\(dir)/query.out"
            try? FileManager.default.removeItem(atPath: out)
            run(p, "query.pl", #"""
                use strict; my $out = shift;
                system("stty raw -echo"); $| = 1;
                print "\e]7501;?\e\\\e[c";
                my ($buf, $rin) = ("", "");
                vec($rin, fileno(STDIN), 1) = 1;
                while ($buf !~ /\e\[\?[0-9;]*c/) {
                  my $n = select(my $r = $rin, undef, undef, 3);
                  last if $n <= 0;
                  sysread(STDIN, $buf, 512, length $buf) or last;
                }
                system("stty sane");
                open(my $f, ">", $out) or die; print $f $buf; close $f;
                """# + "\n", interpreter: "/usr/bin/perl", args: out)
            var problems: [String?] = [SelfTest.waitUntil("the query's replies", timeout: 10) { FileManager.default.fileExists(atPath: out) }]
            let got = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            let reply = "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\"
            let da1 = got.range(of: "\u{1b}[?")
            problems.append(got.hasPrefix(reply) && da1 != nil
                            ? nil : "want the 7501 reply first, then DA1; got \(got.debugDescription)")
            return all(problems)
        }) {
            // Cleanup is the next step's; this one only checks.
        }

        t.step("program status: cleanup", nil, { all([]) }) {
            if let p = pane() { fresh(p) }
            Presence.override = nil
            ProgramStatus.maxRecords = savedMax
            (ProgramStatus.exitCheckEnabled, ProgramStatus.exitCheckInterval) = savedExit
            try? FileManager.default.removeItem(atPath: dir)
        }
    }
}
