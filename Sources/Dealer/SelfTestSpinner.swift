import AppKit

// MARK: - Self-test section: the "an agent is working here" spinner (RunningSpinner.swift)

extension TerminalWindowController {
    /// A pane reporting OSC 9;4 progress spins its tab button and its workspace's switcher entry
    /// (sidebar row and top-bar pill): the model roll-up, the drawing (exact pixels in the leading
    /// slot, dark and light, 2x and 1x), the one shared timer, and the two cases that must *not*
    /// spin — a pane waiting on a dialog (Claude keeps progress set then), and Reduce Motion, which
    /// keeps a standing asterisk and no timer.
    func spinnerSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        let savedAnimating = RunningSpinner.animating

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
        func tabButton(_ p: Pane) -> TabButton? {
            guard let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return nil }
            return loc.deck.view.strip.buttons[i]
        }
        func row(_ p: Pane) -> WorkspaceRow? {
            guard let ws = locate(p)?.workspace, let i = workspaces.firstIndex(where: { $0 === ws }) else { return nil }
            return workspaceSidebar.row(at: i) as? WorkspaceRow
        }
        func pill(_ p: Pane) -> WorkspaceButton? {
            guard let ws = locate(p)?.workspace, let i = workspaces.firstIndex(where: { $0 === ws }) else { return nil }
            return workspaceBar.button(at: i) as? WorkspaceButton
        }
        /// Whether all three of a pane's elements say they spin.
        func spinning(_ p: Pane) -> [String: Bool] {
            ["tab": tabButton(p)?.isRunning ?? false, "row": row(p)?.isRunning ?? false,
             "pill": pill(p)?.isRunning ?? false]
        }
        func progress(_ p: Pane?, _ on: Bool) {
            p?.isReportingProgress = on
            refreshChrome()
            layoutNow()
        }
        /// The strongest coverage of `stroke` on `base` inside `box`: about 1 where the asterisk is
        /// drawn (its stroke is 1.2pt, so whole pixels are fully covered), 0 where nothing is.
        func inked(_ v: NSView, _ box: CGRect, stroke: NSColor, base: NSColor) -> CGFloat {
            PixelProbe.samples(v, in: box).compactMap { PixelProbe.coverage(of: stroke, on: base, in: $0) }.max() ?? 0
        }
        /// One of each element, detached, selected so the fill under the slot is a known colour.
        /// Labels are left empty: a title or number drawn in the slot would be ink of its own.
        func elements() -> [(view: NSView, kind: String, box: () -> CGRect, stroke: NSColor, base: NSColor,
                             run: (Bool) -> Void)] {
            let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
            tab.isActive = true  // an active tab fills its bounds, so the base colour is known
            let row = WorkspaceRow(frame: CGRect(x: 0, y: 0, width: Theme.Metrics.sidebarWidth,
                                                 height: Theme.Metrics.sidebarRowDetailHeight))
            row.detail = "running · ~/git/dealer · main"  // on its own line, below the slot
            row.isActive = true
            let pill = WorkspaceButton(frame: CGRect(x: 0, y: 0, width: 120, height: WorkspaceBarView.pillHeight))
            pill.isActive = true
            return [(tab, "tab", { tab.spinnerBox }, Theme.text, Theme.surface, { tab.isRunning = $0 }),
                    (row, "row", { row.spinnerBox }, Theme.text, Theme.workspaceSelection, { row.isRunning = $0 }),
                    (pill, "pill", { pill.spinnerBox }, Theme.text, Theme.workspaceSelection, { pill.isRunning = $0 })]
        }

        /// Each element detached, in a known background, at rest and then running.
        func drawingProblems(_ name: String) -> [String] {
            var problems: [String] = []
            for e in elements() {
                let atRest = inked(e.view, e.box(), stroke: e.stroke, base: e.base)
                if atRest > 0.2 { problems.append("\(name) \(e.kind): something is drawn in the slot at rest (\(atRest))") }
                e.run(true)
                let ink = inked(e.view, e.box(), stroke: e.stroke, base: e.base)
                if ink < 0.75 { problems.append("\(name) \(e.kind): the asterisk is faint or missing (\(ink))") }
            }
            return problems
        }

        t.step("spinner: a pane reporting progress spins its tab, its sidebar row and its pill; other workspaces don't", nil, {
            guard let b = pane("sp-b"), let a = pane("sp-a") else { return all(["setup failed"]) }
            let other = self.workspaces.first { $0 !== self.locate(b)?.workspace }
            return all([b.isWorking ? nil : "the pane should be working, is \(b.agentState.rawValue)",
                        self.locate(b)?.tab.isWorking == true ? nil : "its tab should roll up as working",
                        self.locate(b)?.workspace.isWorking == true ? nil : "its workspace should roll up as working",
                        spinning(b).allSatisfy { $0.value } ? nil : "elements spinning: \(spinning(b))",
                        // The pane that isn't working shares the workspace, so only its tab stays still.
                        tabButton(a)?.isRunning == false ? nil : "the resting pane's own tab should not spin",
                        other?.isWorking == false ? nil : "another workspace should not be working"])
        }) {
            created(call("create", ["type": "workspace", "target": "focused", "name": "spin"]), "sp-a")
            created(call("create", ["type": "tab", "focus": false], caller: "sp-a"), "sp-b")
            progress(pane("sp-b"), true)
        }

        t.step("spinner: the asterisk is drawn in the leading slot of a tab, row and pill, and nothing is there at rest (dark and light, 2x and 1x)", nil, {
            var problems: [String] = []
            for (name, bg) in [("dark", NSColor(hex: "#282c34")!), ("light", NSColor(hex: "#fafafa")!)] {
                problems += PixelProbe.atEachScale { _ in Theme.withBackground(bg) { drawingProblems(name) } }
            }
            // A frozen clock draws one frame; different phases must draw different pixels.
            let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
            tab.title = "agent"; tab.isActive = true; tab.isRunning = true
            RunningSpinner.phaseOverride = 0
            let first = PixelProbe.pixels(tab, rect: tab.spinnerBox)
            RunningSpinner.phaseOverride = 0.17
            let later = PixelProbe.pixels(tab, rect: tab.spinnerBox)
            RunningSpinner.phaseOverride = nil
            if first == nil || first == later { problems.append("the asterisk draws the same pixels at phase 0 and 0.17") }
            return all(problems.map { $0 })
        }) {}

        t.step("spinner: a spinning tab keeps its width and takes the slot from its title; a pill grows by the slot", nil, {
            let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
            tab.title = "agent"
            let rest = tab.titleRect
            tab.isRunning = true
            let running = tab.titleRect
            let pill = WorkspaceButton(frame: CGRect(x: 0, y: 0, width: 120, height: WorkspaceBarView.pillHeight))
            pill.number = "1"; pill.title = "ws"
            let pillRest = pill.idealWidth
            pill.isRunning = true
            let slot = RunningSpinner.slot
            return all([running.minX == rest.minX + slot ? nil : "the title should start \(slot)pt later, starts at \(running.minX) vs \(rest.minX)",
                        running.width == rest.width - slot ? nil : "the title should be \(slot)pt narrower, is \(running.width) vs \(rest.width)",
                        tab.spinnerBox.maxX <= running.minX ? nil : "the asterisk (\(tab.spinnerBox)) runs into the title (\(running))",
                        pill.idealWidth == pillRest + slot ? nil : "the pill should grow by \(slot)pt, \(pillRest) → \(pill.idealWidth)"])
        }) {}

        t.step("spinner: a waiting pane doesn't spin, although Claude keeps progress set while a dialog is open", nil, {
            guard let b = pane("sp-b") else { return all(["setup failed"]) }
            return all([b.attention == .waiting ? nil : "pane is \(b.attention.name), want waiting",
                        b.isReportingProgress ? nil : "progress should still be set",
                        b.isWorking ? "a waiting pane must not count as working" : nil,
                        spinning(b).contains { $0.value } ? "elements spinning: \(spinning(b))" : nil])
        }) {
            if let b = pane("sp-b") { self.setAttention(.waiting, on: b) }
            self.refreshChrome()
            self.layoutNow()
        }

        t.step("spinner: one shared timer runs while something spins, and stops when nothing does", nil, {
            guard let b = pane("sp-b") else { return all(["setup failed"]) }
            let spun = SpinnerTicker.shared.count
            let ticked = SpinnerTicker.shared.isTicking
            progress(b, false)
            return all([spun >= 3 ? nil : "the tab, row and pill should all be registered, \(spun) are",
                        ticked ? nil : "the timer should run while something spins",
                        SpinnerTicker.shared.count == 0 ? nil : "\(SpinnerTicker.shared.count) left registered after the progress cleared",
                        SpinnerTicker.shared.isTicking ? "the timer should stop when nothing spins" : nil])
        }) {
            // Registration happens when the value changes, so toggle it with the timer allowed.
            progress(pane("sp-b"), false)
            if let b = pane("sp-b") { self.clearAttention(b, cause: "spinner self-test") }
            RunningSpinner.animating = true
            progress(pane("sp-b"), true)
        }

        t.step("spinner: Reduce Motion keeps a standing asterisk and runs no timer", nil, {
            let problems = PixelProbe.atEachScale { _ in drawingProblems("reduce motion") }
            return all([RunningSpinner.spins ? "Reduce Motion should stop the spin" : nil,
                        RunningSpinner.phase() == 0 ? nil : "the phase should be frozen at 0",
                        SpinnerTicker.shared.count == 0 ? nil : "\(SpinnerTicker.shared.count) elements registered under Reduce Motion",
                        spinning(pane("sp-b")!).allSatisfy { $0.value } ? nil : "the elements should still show it: \(spinning(pane("sp-b")!))"]
                       + problems)
        }) {
            progress(pane("sp-b"), false)
            AttentionFade.reduceMotionOverride = true
            progress(pane("sp-b"), true)
        }

        t.step("spinner: a spinning workspace is closed", nil, {
            all([self.workspaces.contains { $0.name == "spin" } ? "the test workspace should be gone" : nil,
                 SpinnerTicker.shared.isTicking ? nil : "the timer should still have been running when it was closed"])
        }) {
            progress(pane("sp-b"), false)
            AttentionFade.reduceMotionOverride = nil
            progress(pane("sp-b"), true)
            if let ws = self.workspaces.first(where: { $0.name == "spin" }) { self.remove(workspace: ws) }
            self.layoutNow()
        }

        // AppKit releases the removed views after the closing step's own main-queue block returns
        // (SelfTestMemory.swift has the same rule), so the registrations can only be gone by now.
        t.step("spinner: the closed workspace's elements leave no registration and no timer (the ticker holds them weakly)", nil, {
            all([SelfTest.waitUntil("the closed workspace's elements to drop out of the ticker") {
                    SpinnerTicker.shared.count == 0 && !SpinnerTicker.shared.isTicking
                 }])
        }) {}

        t.step("spinner: clean up", nil, {
            all([RunningSpinner.phaseOverride == nil ? nil : "the phase override should be cleared",
                 AttentionFade.reduceMotionOverride == nil ? nil : "the Reduce Motion override should be cleared",
                 SpinnerTicker.shared.isTicking ? "the timer should be stopped" : nil])
        }) {
            RunningSpinner.animating = savedAnimating
            RunningSpinner.phaseOverride = nil
            AttentionFade.reduceMotionOverride = nil
            lastError = nil
        }
    }
}
