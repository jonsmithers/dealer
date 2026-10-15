import AppKit

// MARK: - Self-test section: keep the display awake while agents work (#69, Caffeinate.swift)

extension TerminalWindowController {
    /// `[power] caffeinate`: a working pane (the spinner's condition) holds a display-sleep power
    /// assertion, checked against IOKit's own list for this process, named for the number of
    /// working panes; every window shows the titlebar cup while it's held; ending the work keeps
    /// both through a (shortened) grace, then lets go; off holds nothing, and a live reload to off
    /// releases at once. The cup's reserved space keeps it clear of titlebar strips and pills.
    /// Self-contained (`DEALER_SELFTEST_ONLY=caffeinate:`); leaves the setting off and nothing held.
    func caffeinateSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        var second: TerminalWindowController?
        var graceStarted: Date?
        let grace: TimeInterval = 1.5

        func all(_ problems: [String?]) -> String? {
            let p = ([lastError] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        @discardableResult
        func call(_ cmd: String, _ args: [String: Any] = [:], caller: String? = nil) -> [String: Any]? {
            var req: [String: Any] = ["cmd": cmd, "args": args]
            if let caller { req["caller"] = ids[caller] }
            let r = ControlHandler.handle(req)
            guard r["ok"] as? Bool == true else { lastError = "\(cmd) failed: \(r["error"] ?? "?")"; return nil }
            return r["result"] as? [String: Any]
        }
        func created(_ r: [String: Any]?, _ name: String) {
            guard let id = r?["pane"] as? Int, let p = ControlHandler.pane(id: id) else { return }
            ids[name] = id
            t.named(p, name)
        }
        func pane(_ n: String) -> Pane? { ids[n].flatMap(ControlHandler.pane(id:)) }
        func progress(_ n: String, _ on: Bool) {
            pane(n)?.isReportingProgress = on
            refreshChrome()
            layoutNow()
        }
        func settings(_ text: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload(force: true)
            for wc in AppDelegate.shared.windowControllers { wc.layoutNow() }
        }
        let others = Caffeinate.countWorking  // panes earlier sections may have left working
        func expectedName(_ n: Int) -> String { "Dealer: \(n) agent\(n == 1 ? "" : "s") working" }
        /// IOKit's view, not ours: this process's display-sleep assertions.
        func held(_ name: String) -> String? {
            SelfTest.waitUntil("IOKit to list our assertion \"\(name)\" (has \(Caffeinate.ownAssertionNames()))") {
                Caffeinate.ownAssertionNames() == [name]
            }
        }
        func nothingHeld() -> String? {
            [Caffeinate.shared.isHeld ? "Caffeinate says it holds an assertion" : nil,
             SelfTest.waitUntil("IOKit to list no display assertion of ours (has \(Caffeinate.ownAssertionNames()))") {
                 Caffeinate.ownAssertionNames().isEmpty
             }].compactMap { $0 }.first
        }
        /// The cup in every window: shown, laid out in the titlebar row at the right end, with the
        /// tooltip naming N.
        func cupsShown(_ label: String) -> [String?] {
            AppDelegate.shared.windowControllers.flatMap { wc -> [String?] in
                let icon = wc.caffeineIcon, f = icon.frame
                return [icon.superview === wc.contentView && !icon.isHidden ? nil : "window \(wc.id): the cup isn't showing",
                        f.minY == 0 && abs(f.height - wc.deckArea.minY) < 0.5 ? nil : "window \(wc.id): the cup \(f) isn't in the titlebar row",
                        abs(f.maxX - (wc.contentView.bounds.width - Self.deckGap)) < 0.5 ? nil : "window \(wc.id): the cup \(f) isn't at the right end",
                        icon.toolTip == "Keeping the display awake: \(label)" ? nil : "window \(wc.id): tooltip is \(icon.toolTip ?? "nil")"]
            }
        }
        func cupsHidden() -> String? {
            let shown = AppDelegate.shared.windowControllers.filter { !$0.caffeineIcon.isHidden }
            return shown.isEmpty ? nil : "the cup still shows in \(shown.count) window(s)"
        }
        /// Nothing else in the titlebar row overlaps the cup, and the cup is what a press there hits.
        func cupClear(_ what: String) -> [String?] {
            let icon = caffeineIcon, f = icon.frame
            var problems: [String?] = []
            for d in titlebarStripDecks where d.view.strip.frame.intersects(f) {
                problems.append("\(what): a titlebar strip \(d.view.strip.frame) overlaps the cup \(f)")
            }
            if !workspaceBar.isHidden, workspaceBar.frame.intersects(f) {
                problems.append("\(what): the pill bar \(workspaceBar.frame) overlaps the cup \(f)")
            }
            if let sv = contentView.superview {
                let hit = contentView.hitTest(contentView.convert(CGPoint(x: f.midX, y: f.midY), to: sv))
                if hit !== icon { problems.append("\(what): a press on the cup hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")") }
            }
            return problems
        }

        t.step("caffeinate: off by default, a working pane holds nothing and shows no cup", nil, {
            all([Settings.caffeinate ? "the default should be off" : nil,
                 pane("cf-a")?.isWorking == true ? nil : "cf-a should be working",
                 nothingHeld(), cupsHidden(),
                 self.titlebarTrailingReserve == 0 ? nil : "nothing should be reserved in the titlebar when off"])
        }) {
            Caffeinate.graceOverride = grace
            settings("")
            created(call("create", ["type": "workspace", "target": "focused", "name": "caffeine"]), "cf-a")
            progress("cf-a", true)
        }

        t.step("caffeinate: turning it on live holds the assertion, named for one agent, with a cup in every window", nil, {
            let n = others()
            return all([n == 1 ? nil : "\(n) panes are working, want 1 (cf-a)",
                        Caffeinate.shared.isHeld ? nil : "no assertion held",
                        held(expectedName(n)),
                        AppDelegate.shared.windowControllers.count == 2 ? nil : "want 2 windows, have \(AppDelegate.shared.windowControllers.count)"]
                       + cupsShown("\(n) agent working"))
        }) {
            second = nil
            let before = Set(AppDelegate.shared.windowControllers.map(ObjectIdentifier.init))
            AppDelegate.shared.newWindow(nil)
            second = AppDelegate.shared.windowControllers.first { !before.contains(ObjectIdentifier($0)) }
            settings("[power]\ncaffeinate = true\n")
        }

        t.step("caffeinate: the cup draws the symbol in Theme.text, on dark and light themes", nil, {
            var problems: [String] = []
            for (name, bg, fg) in [("dark", NSColor(hex: "#282c34")!, NSColor(hex: "#e7e9ee")!),
                                   ("light", NSColor(hex: "#fafafa")!, NSColor(hex: "#383a42")!)] {
                problems += PixelProbe.atEachScale { _ in
                    Theme.withBackground(bg, foreground: fg) {
                        let icon = CaffeineIconView(frame: CGRect(x: 0, y: 0, width: Theme.Metrics.caffeineIconWidth, height: 28))
                        icon.isHidden = false
                        let solid = PixelProbe.samples(icon, in: icon.bounds).filter { $0.alphaComponent > 0.99 }
                        let off = solid.filter { !PixelProbe.matches($0, Theme.text) }
                        return [solid.count >= 20 ? nil : "\(name): the cup has \(solid.count) solid pixels",
                                off.isEmpty ? nil : "\(name): \(off.count) solid pixels aren't Theme.text"].compactMap { $0 }
                    }
                }
            }
            return all(problems)
        }) {}

        t.step("caffeinate: a second working pane renames it to two agents; a waiting pane doesn't count", nil, {
            all([held(expectedName(1)), pane("cf-b")?.isWorking == false ? nil : "cf-b is waiting, not working"]
                + cupsShown("1 agent working"))
        }) {
            created(call("create", ["type": "tab", "focus": false], caller: "cf-a"), "cf-b")
            progress("cf-b", true)
            if let e = held(expectedName(2)) { lastError = "with two working panes: \(e)" }
            if let b = pane("cf-b") { self.setAttention(.waiting, on: b) }
            self.refreshChrome()
        }

        t.step("caffeinate: when the work ends, the assertion and cup stay through the grace, renamed", nil, {
            let c = Caffeinate.shared
            return all([c.isHeld && c.isInGrace ? nil : "should be held in its grace (held \(c.isHeld), grace \(c.isInGrace))",
                        held("Dealer: \(c.label)"),
                        c.label.hasPrefix("no agents working") ? nil : "label is \(c.label)"]
                       + cupsShown(c.label))
        }) {
            if let b = pane("cf-b") { self.clearAttention(b, cause: "caffeinate self-test") }
            progress("cf-b", false)
            progress("cf-a", false)
            graceStarted = Date()
        }

        t.step("caffeinate: after the grace the assertion is released and the cup hides; not before", nil, {
            var early: String?
            let released = SelfTest.waitUntil(timeout: grace + 5) { !Caffeinate.shared.isHeld }
            if let s = graceStarted, Date().timeIntervalSince(s) < grace - 0.1 { early = "released before the grace ran out" }
            return all([released ? nil : "still held \(grace + 5) s after the grace started", early,
                        nothingHeld(), cupsHidden()])
        }) {}

        t.step("caffeinate: work resuming during the grace keeps the same assertion going", nil, {
            all([held(expectedName(1)), Caffeinate.shared.isInGrace ? "the grace should be cancelled" : nil])
        }) {
            progress("cf-a", true)
            progress("cf-a", false)
            progress("cf-a", true)
        }

        t.step("caffeinate: the cup is clear of titlebar strips and pills, and a press on it reaches it", nil, {
            var problems: [String?] = []
            for (mode, text) in [("titlebar tabs", "[power]\ncaffeinate = true\n[window]\ntabs_in_titlebar = true\n"),
                                 ("top-bar pills", "[power]\ncaffeinate = true\n[workspaces]\nswitcher = \"top\"\n"),
                                 ("pills and titlebar tabs", "[power]\ncaffeinate = true\n[workspaces]\nswitcher = \"top\"\n[window]\ntabs_in_titlebar = true\n")] {
                settings(text)
                if mode.contains("tabs") && self.titlebarStripDecks.isEmpty { problems.append("\(mode): no strip went into the titlebar") }
                for d in self.titlebarStripDecks where d.view.strip.frame.maxX > self.titlebarTrailingX + 0.5 {
                    problems.append("\(mode): a strip ends at \(d.view.strip.frame.maxX), past the reserve at \(self.titlebarTrailingX)")
                }
                problems += cupClear(mode) + cupsShown("1 agent working")
            }
            problems.append(self.caffeineIcon.mouseDownCanMoveWindow ? nil : "the cup has no click action, so a press on it should move the window (#27)")
            return all(problems)
        }) {}

        t.step("caffeinate: a live reload turning it off releases at once, hides the cup and frees the space", nil, {
            let strip = self.titlebarStripDecks.first
            return all([Caffeinate.shared.isHeld ? "still held right after the reload" : nil,
                        nothingHeld(), cupsHidden(),
                        pane("cf-a")?.isWorking == true ? nil : "cf-a should still be working",
                        self.titlebarTrailingReserve == 0 ? nil : "space is still reserved",
                        strip.map { abs($0.view.strip.frame.maxX - $0.view.frame.maxX) < 0.5 ? nil : "the strip should reach its deck's end again" } ?? "no titlebar strip"])
        }) {
            settings("[window]\ntabs_in_titlebar = true\n")
        }

        t.step("caffeinate: a real OSC 9;4 progress report from a shell holds it; clearing it starts the grace", nil, {
            guard let a = pane("cf-a") else { return all(["setup failed"]) }
            guard a.surface.surface != nil else {
                print("      (skipped the live OSC 9;4 check: ghostty couldn't create terminal surfaces here)")
                return all([])
            }
            let on = SelfTest.waitUntil("the shell's OSC 9;4 to set progress") { a.isReportingProgress }
            let heldNow = held(expectedName(1))
            a.surface.typeText("printf '\\033]9;4;0\\007'\r")
            let off = SelfTest.waitUntil("the shell's OSC 9;4;0 to clear progress") { !a.isReportingProgress }
            return all([on, heldNow, off, Caffeinate.shared.isInGrace ? nil : "clearing progress should start the grace"])
        }) {
            progress("cf-a", false)
            settings("[power]\ncaffeinate = true\n")
            pane("cf-a")?.surface.typeText("printf '\\033]9;4;3\\007'\r")
        }

        t.step("caffeinate: cleanup leaves the setting off, nothing held and one window", nil, {
            all([nothingHeld(), cupsHidden(),
                 AppDelegate.shared.windowControllers.count == 1 ? nil : "\(AppDelegate.shared.windowControllers.count) windows left"])
        }) {
            progress("cf-a", false)
            if let ws = self.workspaces.first(where: { $0.name == "caffeine" }) { self.remove(workspace: ws) }
            second?.window?.close()
            second = nil
            settings("")
            Caffeinate.graceOverride = nil
            self.window?.makeKeyAndOrderFront(nil)
            self.layoutNow()
        }
    }
}
