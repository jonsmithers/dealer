import AppKit

// MARK: - Self-test section: progress nobody clears (#83, `ProgressSource.armTimeout`)
//
// Self-contained (`DEALER_SELFTEST_ONLY=progress timeout:`). The timeout is on with a short interval
// here only. After it runs out without a new report, progress stays while the process group that
// sent the last report is still the terminal's foreground, and is dropped otherwise.

extension TerminalWindowController {
    func progressTimeoutSelfTestSteps(_ t: SelfTestKit) {
        var id: Int?
        var lastError: String?
        let saved = (ProgressSource.timeout, ProgressSource.timeoutEnabled)
        let short: TimeInterval = 1

        func pane() -> Pane? { id.flatMap(ControlHandler.pane(id:)) }
        func all(_ problems: [String?]) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func live(_ p: Pane) -> Bool {
            guard p.surface.surface != nil else {
                print("      (skipped a live progress-timeout check: ghostty couldn't create terminal surfaces here)")
                return false
            }
            return true
        }
        func spins(_ p: Pane) -> Bool {
            guard let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return false }
            return loc.deck.view.strip.buttons[i].isRunning
        }
        func report(_ p: Pane, foreground: Int32) {
            if ProgressSource.note(p, active: true, percent: nil, foreground: foreground) { refreshChrome() }
        }

        t.step("progress timeout: setup, a live shell, the timeout on at \(short) s", nil, {
            guard let p = pane() else { return all(["no pane created"]) }
            guard p.surface.surface != nil else { return all([]) }
            return all([p.surface.waitForShell() ? nil : "the shell didn't start"])
        }) {
            let r = ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "progress timeout"]])
            guard r["ok"] as? Bool == true, let pid = (r["result"] as? [String: Any])?["pane"] as? Int else {
                lastError = "create failed: \(r["error"] ?? "?")"; return
            }
            id = pid
            if let p = ControlHandler.pane(id: pid) { t.named(p, "pt") }
            ProgressSource.timeout = short
            ProgressSource.timeoutEnabled = true
        }

        t.step("progress timeout: a fresh report restarts the timer, so the first deadline passes with the progress kept; a gone reporter is then dropped", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            // The reporter (group 1) is never the foreground here: only the timer can keep it.
            ProgressSource.currentForegroundOverride = { _ in 999_999 }
            defer { ProgressSource.currentForegroundOverride = nil }
            let start = Date()
            report(p, foreground: 1)
            guard let first = p.progressTimer?.fireDate else { return all(["no timer after a report"]) }
            var problems: [String?] = [abs(first.timeIntervalSince(start) - short) < 0.25 ? nil : "the timer fires \(first.timeIntervalSince(start)) s after the report, want \(short)"]
            problems.append(SelfTest.waitUntil("half the timeout to pass") { Date() >= start.addingTimeInterval(short / 2) })
            report(p, foreground: 1)
            let second = p.progressTimer?.fireDate ?? .distantPast
            problems.append(second > first.addingTimeInterval(short / 4) ? nil : "the second report didn't move the deadline (\(first) → \(second))")
            problems.append(SelfTest.waitUntil("the first deadline to pass") { Date() > first.addingTimeInterval(0.1) })
            problems.append(p.isReportingProgress ? nil : "progress was dropped at the first deadline, although a later report restarted the timer")
            problems.append(SelfTest.waitUntil("the progress to be dropped after the second deadline", timeout: 3 * short) { !p.isReportingProgress })
            problems.append(p.progressTimer == nil ? nil : "a timer is left after the drop")
            return all(problems)
        }) {}

        t.step("progress timeout: a stale report from a process that exited goes idle, and its tab stops spinning", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            guard live(p) else { return all([]) }
            // `/bin/sh` is its own job: it reports, lingers long enough to be seen as the reporter,
            // exits, and the shell is the foreground again.
            p.surface.typeText("/bin/sh -c \"printf '\\033]9;4;3\\007'; sleep 0.3\"\r")
            let on = SelfTest.waitUntil("the report to arrive", timeout: 10) { p.isReportingProgress }
            let wasSpinning = spins(p)
            let off = SelfTest.waitUntil("the stale progress to be dropped", timeout: 4 * short + 2) { !p.isReportingProgress }
            return all([on, wasSpinning ? nil : "the tab should spin while the report is fresh", off,
                        p.workingMark == nil ? nil : "the pane still shows \(String(describing: p.workingMark))",
                        spins(p) ? "the tab still spins" : nil])
        }) {}

        t.step("progress timeout: a reporter still in the foreground keeps its mark past the timeout; when it ends, the progress goes", nil, {
            guard let p = pane() else { return all(["setup failed"]) }
            guard live(p) else { return all([]) }
            p.surface.typeText("/bin/sh -c \"printf '\\033]9;4;3\\007'; sleep 30\"\r")
            var problems: [String?] = [SelfTest.waitUntil("the report to arrive", timeout: 10) { p.isReportingProgress }]
            let first = p.progressTimer?.fireDate ?? .distantFuture
            // The check ran and kept it: it re-armed the timer with a later deadline.
            problems.append(SelfTest.waitUntil("the timeout to run out and keep the progress", timeout: 4 * short + 2) {
                (p.progressTimer?.fireDate ?? .distantPast) > first.addingTimeInterval(short / 2)
            })
            problems.append(p.isReportingProgress && p.workingMark == .arc && spins(p) ? nil
                            : "past the timeout the busy reporter lost its mark (progress \(p.isReportingProgress), mark \(String(describing: p.workingMark)))")
            p.surface.typeText("\u{03}")
            problems.append(SelfTest.waitUntil("the progress to go once the reporter ended", timeout: 4 * short + 2) { !p.isReportingProgress })
            return all(problems)
        }) {}

        t.step("progress timeout: clean up", nil, {
            all([self.workspaces.contains { $0.name == "progress timeout" } ? "the test workspace should be gone" : nil,
                 ProgressSource.timeoutEnabled == saved.1 ? nil : "the timeout switch should be restored"])
        }) {
            ProgressSource.timeout = saved.0
            ProgressSource.timeoutEnabled = saved.1
            ProgressSource.currentForegroundOverride = nil
            if let w = self.workspaces.first(where: { $0.name == "progress timeout" }) { self.remove(workspace: w) }
            self.layoutNow()
            lastError = nil
        }
    }
}
