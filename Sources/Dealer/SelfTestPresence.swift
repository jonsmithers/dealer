import AppKit
import UserNotifications

// MARK: - Self-test section: is the user there? (#71)

extension TerminalWindowController {
    /// Drives `Presence.override` (app active or not, screen locked or not, which window is key)
    /// and checks marks, clears and the desktop-notification decision through the notification log.
    /// Self-test mode never posts a real banner, and an unbundled run has no notification center, so
    /// "would post" shows as passing the in-front check and stopping at "unbundled".
    func presenceSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        var ids: [String: Int] = [:]
        var savedSettings: String?
        var problems: [String] = []

        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func created(_ r: [String: Any], _ name: String) {
            guard let id = (r["result"] as? [String: Any])?["pane"] as? Int, let p = ControlHandler.pane(id: id) else {
                problems.append("couldn't create \(name): \(r["error"] ?? "?")"); return
            }
            ids[name] = id
            t.named(p, name)
        }
        func lines() -> [String] {
            NotificationLog.flush()
            return ((try? String(contentsOfFile: NotificationLog.path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func has(_ fragments: String...) -> String? {
            lines().contains { l in fragments.allSatisfy(l.contains) } ? nil
                : "no log line with \(fragments.map(\.debugDescription).joined(separator: " + ")); log:\n           "
                    + lines().suffix(6).joined(separator: "\n           ")
        }
        func lacks(_ fragments: String...) -> String? {
            guard let l = lines().first(where: { l in fragments.allSatisfy(l.contains) }) else { return nil }
            return "unexpected log line: \(l)"
        }
        func all(_ p: [String?]) -> String? {
            let out = (problems + p.compactMap { $0 })
            problems = []
            return out.isEmpty ? nil : out.joined(separator: "; ")
        }
        func resetLog() {
            NotificationLog.flush()
            try? fm.removeItem(atPath: NotificationLog.path)
        }
        func who(_ n: String) -> String { "pane=\(ids[n] ?? -1) " }
        func facts(active: Bool, locked: Bool = false, key: NSWindow?) {
            Presence.override = Presence.Facts(appActive: active, screenLocked: locked, keyWindow: key)
        }

        t.step("presence: set up a workspace with two panes (pa focused, pb beside it) and the notification log on", nil, {
            all([pane("pa") != nil && pane("pb") != nil ? nil : "panes weren't created",
                 Settings.notificationLog ? nil : "the log should be on"])
        }) {
            savedSettings = try? String(contentsOf: Settings.fileURL, encoding: .utf8)
            try? fm.createDirectory(at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[notifications]\nlog = true\n".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload(force: true)
            created(ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "presence"]]), "pa")
            if let a = ids["pa"] {
                created(ControlHandler.handle(["cmd": "create", "caller": a, "args": ["type": "pane", "side": "right", "focus": false]]), "pb")
            }
            if let a = pane("pa") { self.focus(a) }
            self.layoutNow()
        }

        t.step("presence: away (Dealer not active): focus moved to a marked pane keeps the mark; the window becoming key clears it", nil, {
            all([has("focus attention:kept", who("pb"), "focus moved here while you weren't looking", "app inactive"),
                 has("window-became-key attention:cleared", who("pb"), "waiting → none")])
        }) {
            resetLog()
            guard let b = pane("pb"), let a = pane("pa") else { return }
            facts(active: false, key: self.window)
            self.setAttention(.waiting, on: b, event: "notify")
            self.focus(b)  // e.g. a pane closing, or `dealer focus` from a script
            if b.attention != .waiting { problems.append("pb's mark should survive a focus change while away, is \(b.attention.name)") }
            // Back at the machine: Dealer comes forward and the window becomes key.
            facts(active: true, key: self.window)
            self.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: self.window))
            if b.attention != .none { problems.append("pb should clear when the user is back, is \(b.attention.name)") }
            self.focus(a)
        }

        t.step("presence: present and unlocked, the focused pane is looked at, so no mark", nil, {
            all([has("notify attention:skipped", who("pa"), "you're looking at it"),
                 pane("pa")?.attention == Attention.none ? nil : "pa shouldn't be marked"])
        }) {
            resetLog()
            guard let a = pane("pa") else { return }
            facts(active: true, key: self.window)
            self.setAttention(.done, on: a, event: "notify")
        }

        t.step("presence: a locked screen is away: the focused pane is marked and the banner isn't held back; unlocking clears it", nil, {
            all([has("claude:stop attention:set", who("pa"), "none → done"),
                 has("claude:stop notification:suppressed", who("pa"), "reason=\"unbundled"),
                 lacks("claude:stop notification:suppressed", "Dealer is the active app"),
                 has("screen-unlocked attention:cleared", who("pa"), "done → none")])
        }) {
            resetLog()
            guard let a = pane("pa") else { return }
            facts(active: true, locked: true, key: self.window)
            self.setAttention(.done, on: a, event: "claude:stop")
            if a.attention != .done { problems.append("pa should be marked done while the screen is locked, is \(a.attention.name)") }
            facts(active: true, locked: false, key: self.window)
            Presence.screenUnlocked()
            if a.attention != .none { problems.append("pa should clear on unlock, is \(a.attention.name)") }
        }

        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        otherWindow.isReleasedWhenClosed = false
        t.step("presence: Dealer active with another window key: the pane is marked, and no banner", nil, {
            all([has("claude:permission attention:set", who("pb"), "none → waiting"),
                 has("claude:permission notification:suppressed", who("pb"), "Dealer is the active app (another Dealer window is key)")])
        }) {
            resetLog()
            guard let b = pane("pb") else { return }
            facts(active: true, key: otherWindow)
            self.setAttention(.waiting, on: b, event: "claude:permission")
        }

        t.step("presence: notification permission is re-read on app activation (refresh path; real authorization needs the bundle)", nil, {
            let n = AttentionNotifier.shared
            n.statusReader = { $0(.authorized) }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            let granted = SelfTest.waitUntil(timeout: 5) { n.authorized }
            n.statusReader = { $0(.denied) }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            let revoked = SelfTest.waitUntil(timeout: 5) { !n.authorized }
            n.statusReader = nil
            return all([granted ? nil : "allowing notifications should take effect on the next activation",
                        revoked ? nil : "turning them off should take effect on the next activation",
                        has("authorization status", "→ authorized; posting allowed"),
                        has("authorization status", "→ denied; posting not allowed")])
        }) { resetLog() }

        t.step("presence: clean up", nil, {
            all([self.workspaces.contains { $0.name == "presence" } ? "test workspace should be gone" : nil,
                 Presence.override == nil ? nil : "the override should be cleared"])
        }) {
            Presence.override = nil
            if let ws = self.workspaces.first(where: { $0.name == "presence" }) { self.remove(workspace: ws) }
            if let s = savedSettings { try? s.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload(force: true)
            resetLog()
        }
    }
}
