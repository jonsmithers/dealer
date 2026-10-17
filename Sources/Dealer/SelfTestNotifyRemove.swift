import AppKit

// MARK: - Self-test section: withdrawing a pane's banner when its attention clears (#78)

extension TerminalWindowController {
    /// A pane's macOS notification is withdrawn the moment its attention clears in the model (focus,
    /// ⌘⇧U, a notification click, the screen unlocking), and when the pane closes; only panes that
    /// got a banner are withdrawn. Self-test and unbundled runs never post, so each step stands in
    /// for the post with `notePosted` and checks `AttentionNotifier.withdrawals` and the log; the
    /// real Notification Center call is a hand check in the bundled app.
    func notifyRemoveSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        let n = AttentionNotifier.shared
        var ids: [String: Int] = [:]
        var savedSettings: String?
        var problems: [String] = []
        var mark = 0  // withdrawals.count at the start of a step

        func pane(_ name: String) -> Pane? { ids[name].flatMap(ControlHandler.pane(id:)) }
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
        func resetLog() {
            NotificationLog.flush()
            try? fm.removeItem(atPath: NotificationLog.path)
        }
        func begin() {
            resetLog()
            mark = n.withdrawals.count
            Presence.override = Presence.Facts(appActive: true, screenLocked: false, keyWindow: self.window)
        }
        /// The withdrawals since `begin()`, as "pane-N event".
        func since() -> [String] { n.withdrawals.dropFirst(mark).map { "\($0.id) \($0.event)" } }
        func withdrew(_ name: String, by event: String) -> String? {
            let want = "\(AttentionNotifier.requestID(ids[name] ?? -1)) \(event)"
            return since() == [want] ? nil : "expected exactly [\(want)] withdrawn, got \(since())"
        }
        func all(_ p: [String?]) -> String? {
            let out = problems + p.compactMap { $0 }
            problems = []
            return out.isEmpty ? nil : out.joined(separator: "; ")
        }
        /// Marks `p` (not looked at, so the mark sticks) and stands in for its banner going out.
        func announce(_ p: Pane, _ a: Attention = .waiting) {
            setAttention(a, on: p, event: "notify")
            if p.attention != a { problems.append("\(p.title) should be marked \(a.name), is \(p.attention.name)") }
            n.notePosted(p)
        }

        t.step("notify-remove: set up a workspace with three panes (nr-a focused, nr-b, nr-c) and the log on", nil, {
            all([pane("nr-a") != nil && pane("nr-b") != nil && pane("nr-c") != nil ? nil : "panes weren't created"])
        }) {
            savedSettings = try? String(contentsOf: Settings.fileURL, encoding: .utf8)
            try? fm.createDirectory(at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[notifications]\nlog = true\n".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload(force: true)
            created(ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "notify-remove"]]), "nr-a")
            if let a = ids["nr-a"] {
                created(ControlHandler.handle(["cmd": "create", "caller": a, "args": ["type": "pane", "side": "right", "focus": false]]), "nr-b")
                created(ControlHandler.handle(["cmd": "create", "caller": a, "args": ["type": "pane", "side": "down", "focus": false]]), "nr-c")
            }
            if let a = pane("nr-a") { self.focus(a) }
        }

        t.step("notify-remove: a pane that got no banner withdraws nothing when its attention clears", nil, {
            all([since().isEmpty ? nil : "nothing was posted, but withdrew \(since())",
                 lines().contains { $0.contains("notification:withdrawn") } ? "unexpected withdrawal line" : nil,
                 pane("nr-b")?.attention == Attention.none ? nil : "nr-b should have cleared"])
        }) {
            begin()
            guard let b = pane("nr-b"), let a = pane("nr-a") else { return }
            self.setAttention(.waiting, on: b, event: "notify")
            self.focus(b)
            self.focus(a)
        }

        t.step("notify-remove: focusing the pane withdraws its banner at the model clear, before the ring's fade ends", nil, {
            all([withdrew("nr-b", by: "focus"),
                 has("focus notification:withdrawn", "pane=\(ids["nr-b"] ?? -1) ", "id pane-\(ids["nr-b"] ?? -1): the pane's attention cleared"),
                 n.posted.contains(ids["nr-b"] ?? -1) ? "nr-b should no longer count as posted" : nil])
        }) {
            begin()
            guard let b = pane("nr-b") else { return }
            announce(b)
            AttentionFade.enabled = true
            defer { AttentionFade.enabled = false }
            self.focus(b)
            if since().isEmpty { problems.append("the withdrawal should happen in the clear itself") }
            if !b.view.attentionFade.isFading { problems.append("the ring should still be fading (the withdrawal mustn't wait for it)") }
            if let a = pane("nr-a") { self.focus(a) }
        }

        t.step("notify-remove: ⌘⇧U (Jump to Next Unread) withdraws the pane it jumps to", nil, {
            all([withdrew("nr-c", by: "jump-to-next-unread"),
                 has("jump-to-next-unread notification:withdrawn", "pane=\(ids["nr-c"] ?? -1) ")])
        }) {
            begin()
            guard let c = pane("nr-c") else { return }
            // Nothing else may outrank it: ⌘⇧U goes to the most urgent pane anywhere.
            Pane.all.forEach { if $0.1.attention != .none && $0.1 !== c { $0.0.clearAttention($0.1, cause: "notify-remove-setup") } }
            mark = n.withdrawals.count
            announce(c, .failed)
            self.jumpToNextUnread(nil)
            if let a = pane("nr-a") { self.focus(a) }
        }

        t.step("notify-remove: clicking the notification (its reveal) withdraws it", nil, {
            all([withdrew("nr-b", by: "notification-click"),
                 has("notification-click notification:withdrawn", "pane=\(ids["nr-b"] ?? -1) ")])
        }) {
            begin()
            guard let b = pane("nr-b") else { return }
            announce(b)
            self.reveal(b, cause: "notification-click")
            if let a = pane("nr-a") { self.focus(a) }
        }

        t.step("notify-remove: unlocking the screen with the pane looked at withdraws it", nil, {
            all([withdrew("nr-a", by: "screen-unlocked"),
                 has("screen-unlocked notification:withdrawn", "pane=\(ids["nr-a"] ?? -1) ")])
        }) {
            begin()
            guard let a = pane("nr-a") else { return }
            Presence.override = Presence.Facts(appActive: true, screenLocked: true, keyWindow: self.window)
            announce(a, .done)
            Presence.override = Presence.Facts(appActive: true, screenLocked: false, keyWindow: self.window)
            Presence.screenUnlocked()
        }

        t.step("notify-remove: `dealer notify --state none` (an explicit clear) withdraws it too", nil, {
            all([since().count == 1 && since()[0].hasPrefix("\(AttentionNotifier.requestID(ids["nr-c"] ?? -1)) ")
                    ? nil : "expected nr-c withdrawn once, got \(since())"])
        }) {
            begin()
            guard let c = pane("nr-c") else { return }
            announce(c)
            _ = ControlHandler.handle(["cmd": "notify", "caller": c.id, "args": ["state": "none"]])
        }

        t.step("notify-remove: closing a pane with its banner up withdraws it; one already withdrawn isn't withdrawn again", nil, {
            let closed = SelfTest.waitUntil("nr-c's withdrawal", timeout: 5) { !since().isEmpty }
            return all([closed, withdrew("nr-c", by: "pane-closed"),
                        has("pane-closed notification:withdrawn", "id pane-\(ids["nr-c"] ?? -1): pane \(ids["nr-c"] ?? -1) closed"),
                        n.posted.contains(ids["nr-c"] ?? -1) ? "nr-c should no longer count as posted" : nil])
        }) {
            begin()
            guard let b = pane("nr-b"), let c = pane("nr-c") else { return }
            announce(b)
            self.focus(b)  // withdrawn here, so its close below withdraws nothing more
            mark = n.withdrawals.count
            announce(c)
            self.remove(b)
            self.remove(c)
        }

        t.step("notify-remove: closing the workspace withdraws its panes' banners", nil, {
            let closed = SelfTest.waitUntil("nr-a's withdrawal", timeout: 5) { !since().isEmpty }
            return all([closed, withdrew("nr-a", by: "pane-closed"),
                        self.workspaces.contains { $0.name == "notify-remove" } ? "test workspace should be gone" : nil])
        }) {
            begin()
            guard let a = pane("nr-a") else { return }
            if let b = self.allPanes.first(where: { $0 !== a }) { self.focus(b) }  // nr-a not looked at
            announce(a)
            if let ws = self.workspaces.first(where: { $0.name == "notify-remove" }) { self.remove(workspace: ws) }
        }

        t.step("notify-remove: clean up", nil, {
            all([Presence.override == nil ? nil : "the override should be cleared"])
        }) {
            Presence.override = nil
            if let s = savedSettings { try? s.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload(force: true)
            resetLog()
        }
    }
}
