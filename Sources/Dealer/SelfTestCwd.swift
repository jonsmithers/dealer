import AppKit
import GhosttyKit

// MARK: - Self-test section: new panes inherit the working directory (issue #32)

extension TerminalWindowController {
    /// A pane `cd`s into a temp dir (a real shell, reported through OSC 7). Then a split, a tab, a
    /// workspace and a window made from it must start there, both as passed to ghostty and as the
    /// new shell's real cwd. Without live surfaces (locked screen) or OSC 7, the source pane's
    /// starting directory stands in, and only what Dealer passes to ghostty is checked.
    func cwdSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "dealer-cwd-\(getpid())"
        let start = base + "/start", moved = base + "/moved here"
        for d in [start, moved] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        var ids: [String: Int] = [:]
        var want = start
        var reported = false
        var extraWindow: TerminalWindowController?

        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func canonical(_ p: String?) -> String? { p.map(ControlJobs.canonical) }
        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func name(_ p: Pane?, _ n: String) {
            guard let p else { return }
            ids[n] = p.id
            t.named(p, n)
        }
        func wait(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !cond() && Date() < end {
                // ghostty's actions (OSC 7 → pwd) are delivered from ghostty_app_tick, which the
                // wakeup callback schedules on the main queue; that doesn't drain inside this
                // nested wait, so tick here.
                GhosttyRuntime.shared.tick()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return cond()
        }
        var live: Bool { pane("c0")?.surface.surface != nil }
        /// The new pane starts in `want`: as passed to ghostty (its initial `pwd`), and, with a live
        /// shell, as the real cwd of the process running in it.
        func startsInWant(_ n: String, passed: String?) -> String? {
            guard canonical(passed) == canonical(want) else {
                return "\(n) was created in \(passed ?? "nil"), expected \(want)"
            }
            guard live, reported, let p = pane(n) ?? (n == "win" ? extraWindow?.focusedPane : nil) else { return nil }
            var real: String?
            let ok = wait(15) {
                guard let s = p.surface.surface else { return false }
                let pid = Int32(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
                real = pid > 0 ? ProcessTree.cwd(of: pid) : nil
                return canonical(real) == canonical(want)
            }
            return ok ? nil : "\(n)'s shell runs in \(real ?? "?"), expected \(want)"
        }
        var passed: [String: String?] = [:]
        /// Records the directory a pane was created with (SurfaceView.pwd starts as that).
        func made(_ p: Pane?, _ n: String) {
            name(p, n)
            passed[n] = p?.pwd
        }

        t.step("cwd: a pane cd's into a directory (reported by its shell)", nil, {
            if !live {
                print("      (skipped the real shell: ghostty couldn't create terminal surfaces here; inheriting the starting directory)")
                return nil
            }
            reported = wait(15) { canonical(pane("c0")?.pwd) == canonical(moved) }
            if reported { want = moved } else {
                print("      (c0's shell never reported its cwd (no OSC 7 / shell integration?); inheriting the starting directory)")
            }
            return nil
        }) {
            let r = ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "cwd", "cwd": start]])
            name(((r["result"] as? [String: Any])?["pane"] as? Int).flatMap(ControlHandler.pane(id:)), "c0")
            if let p = pane("c0"), p.surface.surface != nil {
                _ = ControlHandler.handle(["cmd": "send-text", "args": ["target": "\(p.id)",
                                           "items": [["text": "cd '\(moved)'"], ["key": "enter"]]]])
            }
        }
        t.step("cwd: ⌘D splits in the source pane's directory", nil, { startsInWant("split", passed: passed["split"] ?? nil) }) {
            guard let c0 = pane("c0") else { return }
            self.focus(c0)
            self.split(c0, side: .right)
            made(self.focusedPane, "split")
        }
        t.step("cwd: ⌘T opens a tab in the focused pane's directory", nil, { startsInWant("tab", passed: passed["tab"] ?? nil) }) {
            guard let c0 = pane("c0"), let deck = self.locate(c0)?.deck else { return }
            self.focus(c0)
            self.newTab(in: deck)
            made(self.focusedPane, "tab")
        }
        t.step("cwd: ⌘⌃N opens a workspace in the focused pane's directory", nil, { startsInWant("ws", passed: passed["ws"] ?? nil) }) {
            guard let c0 = pane("c0") else { return }
            self.focus(c0)
            // Activated, as ⌘⌃N does: an inactive workspace's panes aren't laid out yet, so their
            // shells haven't started.
            let ws = self.newWorkspace(name: "cwd-new", activate: true)
            made(ws.panes.first, "ws")
        }
        t.step("cwd: ⌘N opens a window in the front window's focused directory", nil, {
            startsInWant("win", passed: passed["win"] ?? nil)
        }) {
            guard let c0 = pane("c0") else { return }
            self.focus(c0)
            self.window?.makeKeyAndOrderFront(nil)
            let before = AppDelegate.shared.windowControllers
            AppDelegate.shared.newWindow(nil)
            extraWindow = AppDelegate.shared.windowControllers.first { w in !before.contains { $0 === w } }
            passed["win"] = extraWindow?.focusedPane?.pwd
            self.window?.makeKeyAndOrderFront(nil)
        }
        t.step("cwd: with split-inherit-working-directory = false a split gets ghostty's default", nil, {
            passed["nosplit"] == .some(nil) ? nil : "split should start with no directory, got \(String(describing: passed["nosplit"]))"
        }) {
            extraWindow?.window?.close()
            extraWindow = nil
            guard let c0 = pane("c0") else { return }
            let saved = WorkingDirectory.configBool
            WorkingDirectory.configBool = { $0 == "split-inherit-working-directory" ? false : saved($0) }
            defer { WorkingDirectory.configBool = saved }
            self.focus(c0)
            self.split(c0, side: .bottom)
            made(self.focusedPane, "nosplit")
        }
        t.step("cwd: dealer create without --cwd starts in the target's directory", nil, {
            all(startsInWant("cli-pane", passed: passed["cli-pane"] ?? nil), startsInWant("cli-tab", passed: passed["cli-tab"] ?? nil))
        }) {
            guard let c0 = pane("c0") else { return }
            for (type, n) in [("pane", "cli-pane"), ("tab", "cli-tab")] {
                let r = ControlHandler.handle(["cmd": "create", "args": ["type": type, "target": "\(c0.id)", "focus": false]])
                made(((r["result"] as? [String: Any])?["pane"] as? Int).flatMap(ControlHandler.pane(id:)), n)
            }
        }
        t.step("cwd: clean up", nil, {
            self.workspaces.contains { ["cwd", "cwd-new"].contains($0.name ?? "") } ? "test workspaces should be gone" : nil
        }) {
            for n in ["cwd", "cwd-new"] {
                if let ws = self.workspaces.first(where: { $0.name == n }) { self.remove(workspace: ws) }
            }
            try? fm.removeItem(atPath: base)
        }

    }
}
