import AppKit
import Carbon.HIToolbox

// MARK: - Self-test section: Mark for Later (⌥⌘U, `dealer notify --hold`)

extension TerminalWindowController {
    /// Marks the focused pane *done* while the user looks at it (`Presence.override` says present),
    /// and checks the hold: looking doesn't clear it (re-focus, window key, unlock), ⌘⇧U skips it,
    /// and focus leaving the pane (another pane, another workspace) and coming back does.
    func markForLaterSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var problems: [String] = []

        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func created(_ r: [String: Any], _ name: String) {
            guard let id = (r["result"] as? [String: Any])?["pane"] as? Int, let p = ControlHandler.pane(id: id) else {
                problems.append("couldn't create \(name): \(r["error"] ?? "?")"); return
            }
            ids[name] = id
            t.named(p, name)
        }
        func all(_ p: [String?] = []) -> String? {
            let out = (problems + p.compactMap { $0 })
            problems = []
            return out.isEmpty ? nil : out.joined(separator: "; ")
        }
        func expect(_ n: String, _ a: Attention, held: Bool? = nil, _ when: String) {
            guard let p = pane(n) else { return problems.append("no pane \(n)") }
            if p.attention != a { problems.append("\(n) should be \(a.name) \(when), is \(p.attention.name)") }
            if let held, p.attentionHeld != held { problems.append("\(n) should\(held ? "" : "n't") be held \(when)") }
        }
        func present() { Presence.override = Presence.Facts(appActive: true, screenLocked: false, keyWindow: self.window) }
        func becomeKey() { self.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: self.window)) }

        t.step("mark for later: set up a workspace with two panes (la focused, lb beside it), the user present", nil, {
            all([pane("la") != nil && pane("lb") != nil ? nil : "panes weren't created",
                 self.isLookingAt(pane("la")!) ? nil : "la should be looked at"])
        }) {
            created(ControlHandler.handle(["cmd": "create", "args": ["type": "workspace", "target": "focused", "name": "later"]]), "la")
            if let a = ids["la"] {
                created(ControlHandler.handle(["cmd": "create", "caller": a, "args": ["type": "pane", "side": "right", "focus": false]]), "lb")
            }
            if let a = pane("la") { self.focus(a) }
            self.layoutNow()
            present()
        }

        t.step("mark for later: ⌥⌘U is Window › Mark for Later, and marks the pane you're looking at done", nil, {
            let owners = Self.keyedMenuItems().filter { $0.keyEquivalent.lowercased() == "u" && Self.effectiveModifiers($0) == [.command, .option] }
            return all([owners.map(\.title) == ["Mark for Later"] ? nil : "⌥⌘U belongs to \(owners.map(\.title)), expected [Mark for Later]"])
        }) {
            guard let a = pane("la") else { return }
            if !self.pressMenuKeyForTest("u", [.command, .option], keyCode: kVK_ANSI_U, surface: a.surface) {
                problems.append("⌥⌘U matched no enabled item: \(Self.menuKeyFailure)")
            }
            expect("la", .done, held: true, "after ⌥⌘U")
        }

        t.step("mark for later: looking doesn't clear it: a re-focus, the window becoming key, the screen unlocking", nil, { all() }) {
            guard let a = pane("la") else { return }
            self.focus(a)
            expect("la", .done, held: true, "after a re-focus")
            becomeKey()
            expect("la", .done, held: true, "after the window became key")
            Presence.screenUnlocked()
            expect("la", .done, held: true, "after the screen unlocked")
        }

        t.step("mark for later: ⌘⇧U from the marked pane skips it and goes to another pane's mark", nil, { all() }) {
            guard let a = pane("la"), let b = pane("lb") else { return }
            if let (_, p) = Self.nextUnread(after: a), p === a { problems.append("⌘⇧U shouldn't pick the held pane you're on") }
            self.setAttention(.failed, on: b, event: "notify")
            // Other sections' marks may outrank lb's; ask for the jump only when lb is next.
            if let (_, p) = Self.nextUnread(after: a), p === b {
                self.jumpToNextUnread(nil)
                if self.focusedPane !== b { problems.append("⌘⇧U should focus lb") }
                expect("lb", .none, "after ⌘⇧U reached it")
            } else {
                self.focus(b)
            }
            expect("la", .done, held: false, "once focus left it")
        }

        t.step("mark for later: coming back to the pane clears it", nil, { all() }) {
            guard let a = pane("la") else { return }
            self.focus(a)
            expect("la", .none, held: false, "after focus came back")
        }

        t.step("mark for later: switching workspace away and back clears it too", nil, { all() }) {
            guard let a = pane("la"), let ws = self.workspaces.first(where: { $0.name == "later" }),
                  let other = self.workspaces.first(where: { $0 !== ws }) else { return problems.append("need another workspace") }
            self.markForLater(nil)
            expect("la", .done, held: true, "after Mark for Later")
            self.activate(other)
            self.activate(ws)
            if self.focusedPane !== a { problems.append("la should be focused again") }
            expect("la", .none, held: false, "after switching back to its workspace")
        }

        t.step("mark for later: `dealer notify --state done` is skipped while you look; with --hold it's set and held", nil, { all() }) {
            guard let a = ids["la"] else { return }
            _ = ControlHandler.handle(["cmd": "notify", "caller": a, "args": ["state": "done"]])
            expect("la", .none, "after a plain notify while looking")
            let parsed = try? CLI.parse("notify", ["--state", "done", "--hold"]).1
            if parsed?["hold"] as? Bool != true { problems.append("--hold should parse to hold = true") }
            let r = ControlHandler.handle(["cmd": "notify", "caller": a, "args": parsed ?? [:]])
            if r["error"] != nil { problems.append("notify --hold failed: \(r["error"]!)") }
            expect("la", .done, held: true, "after notify --hold")
            becomeKey()
            expect("la", .done, held: true, "after the window became key")
        }

        t.step("mark for later: clean up", nil, {
            all([self.workspaces.contains { $0.name == "later" } ? "test workspace should be gone" : nil,
                 Presence.override == nil ? nil : "the override should be cleared"])
        }) {
            Presence.override = nil
            if let ws = self.workspaces.first(where: { $0.name == "later" }) { self.remove(workspace: ws) }
        }
    }
}
