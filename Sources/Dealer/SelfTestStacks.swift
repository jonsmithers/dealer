import AppKit

// MARK: - Self-test section: stacked working marks and attention dots (#95, MarkStack.swift)
//
// Self-contained (`DEALER_SELFTEST_ONLY=stacks:`). A tab, a sidebar row and a collapsed sidebar
// group header show one mark per pane: working marks on the left, strongest in front, attention
// dots on the right, most urgent in front, at most `MarkStack.cap` each. Top-bar pills keep the
// single strongest mark. Outlines stay the roll-up; each dot fades on its own (#34).

extension TerminalWindowController {
    func stacksSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
        let savedSwitcher = Settings.workspaceSwitcher

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
        func ws(_ name: String) -> Workspace? { workspaces.first { $0.name == name } }
        func tabButton(_ p: Pane?) -> TabButton? {
            guard let p, let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return nil }
            return loc.deck.view.strip.buttons[i]
        }
        func row(_ w: Workspace?) -> WorkspaceRow? {
            guard let w, let i = workspaces.firstIndex(where: { $0 === w }) else { return nil }
            return workspaceSidebar.row(at: i) as? WorkspaceRow
        }
        func pill(_ w: Workspace?) -> WorkspaceButton? {
            guard let w, let i = workspaces.firstIndex(where: { $0 === w }) else { return nil }
            return workspaceBar.button(at: i) as? WorkspaceButton
        }
        /// A progress report as ghostty delivers it, with who's in the foreground faked.
        func report(_ n: String, _ active: Bool, percent: Int? = nil, claude: Bool = false) {
            guard let p = pane(n) else { return }
            ProgressSource.foregroundOverride = { _ in claude }
            _ = ProgressSource.note(p, active: active, percent: percent, foreground: 1)
            ProgressSource.foregroundOverride = nil
        }
        func refresh() { refreshChrome(); layoutNow() }
        func want<T: Equatable>(_ what: String, _ got: T, _ expected: T) -> String? {
            got == expected ? nil : "\(what) is \(got), want \(expected)"
        }
        func states(_ s: AttentionStackState) -> [Attention] { s.shown.map(\.state) }
        func hex(_ c: NSColor?) -> String { c?.hexString ?? "nil" }

        // The model: order and cap, without any view.
        t.step("stacks: working marks order strongest first (Claude, arc, the least complete ring); dots by urgency; both cap at 3", nil, {
            let spin = RunningSpinnerState()
            spin.set([.ring(70), .arc, .ring(20), .claude])
            let dots = AttentionStackState()
            dots.set([PaneAttention(pane: 1, state: .unread), PaneAttention(pane: 2, state: .waiting),
                      PaneAttention(pane: 3, state: .failed), PaneAttention(pane: 4, state: .done)], subject: nil)
            let few = AttentionStackState()
            few.set([PaneAttention(pane: 7, state: .done), PaneAttention(pane: 8, state: .waiting)], subject: nil)
            return all([want("ordered [ring 70, arc, ring 20, claude]", WorkingMark.ordered([.ring(70), .arc, .ring(20), .claude]),
                             [.claude, .arc, .ring(20), .ring(70)]),
                        want("the strongest of them", WorkingMark.strongest([.ring(70), .arc, .ring(20), .claude]), .claude),
                        want("a stack of four working marks", spin.marks, [.claude, .arc, .ring(20)]),
                        want("a stack of four dots", states(dots), [.failed, .waiting, .done]),
                        want("a stack of two dots", states(few), [.waiting, .done]),
                        want("the stack's width for 3 marks", RunningSpinner.stackWidth(3),
                             RunningSpinner.slot + 2 * RunningSpinner.stackStep),
                        want("the stack's width for 5 marks (capped)", RunningSpinner.stackWidth(5), RunningSpinner.stackWidth(3)),
                        want("no marks take no room", RunningSpinner.stackWidth(0), 0)])
        }) {}

        // The drawing, on detached views in a dark and a light theme: each mark shows, the front one
        // where the single mark sat, the ones behind overlap it with a ring knocked out.
        t.step("stacks: tabs and sidebar rows draw every dot (front most urgent, outermost) and every working mark, overlapping, with a knock-out ring (dark and light, 2x and 1x)", nil, {
            var problems: [String] = []
            let themes = [("dark", "#303446", "#c6d0f5"), ("light", "#eff1f5", "#4c4f69")]
            for (theme, bg, fg) in themes.map({ ($0.0, NSColor(hex: $0.1)!, NSColor(hex: $0.2)!) }) {
                problems += PixelProbe.atEachScale { _ in Theme.withBackground(bg, foreground: fg) {
                    var p: [String] = []
                    let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 200, height: Theme.Metrics.tabHeight))
                    tab.title = "agents"; tab.isActive = true
                    let row = WorkspaceRow(frame: CGRect(x: 0, y: 0, width: Theme.Metrics.sidebarWidth, height: Theme.Metrics.sidebarRowDetailHeight))
                    row.title = "agents"; row.number = "1"; row.detail = "dealer · main"
                    let marks = [PaneAttention(pane: 1, state: .unread), PaneAttention(pane: 2, state: .waiting),
                                 PaneAttention(pane: 3, state: .failed), PaneAttention(pane: 4, state: .done)]
                    let views: [(String, NSView, () -> [CGRect], () -> CGRect)] = [
                        ("tab", tab, { tab.attentionDotRects }, { tab.attentionDotRect }),
                        ("row", row, { row.attentionDotRects }, { row.attentionDotRect })]
                    tab.attentionMarks = marks; row.attentionMarks = marks
                    for (name, v, rects, front) in views {
                        let what = "\(theme) \(name)"
                        let r = rects()
                        guard r.count == 3 else { p.append("\(what): \(r.count) dots, want 3 (capped)"); continue }
                        if r[0] != front() { p.append("\(what): the front dot moved from where the single dot sits") }
                        // Each dot's left part, clear of its glyph and of the dot in front of it.
                        for (i, (rect, color)) in zip(r, [Theme.attentionFailed, Theme.attentionWaiting, Theme.attentionWaiting]).enumerated() {
                            let px = PixelProbe.sample(v, at: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY + rect.height * 0.15))
                            if !PixelProbe.matches(px, color) { p.append("\(what): dot \(i + 1) is \(hex(px)), want \(hex(color))") }
                        }
                        if !(r[1].maxX > r[0].minX && r[1].minX < r[0].minX) { p.append("\(what): the dots don't overlap (\(r[0]), \(r[1]))") }
                        // Just left of the front dot, inside the dot behind it: knocked out.
                        let gap = PixelProbe.sample(v, at: CGPoint(x: r[0].minX - MarkStack.gap / 2, y: r[0].midY))
                        if PixelProbe.distance(gap, Theme.attentionWaiting) < 0.15 { p.append("\(what): no knock-out ring between the dots (\(hex(gap)))") }
                    }
                    if tab.titleRect.maxX > tab.attentionDotRects.map(\.minX).min()! { p.append("\(theme) tab: the title runs under the dots") }
                    // Working marks: three rings at 100% (a full circle each), without attention, whose
                    // tint lies over the whole element.
                    tab.attentionMarks = []; row.attentionMarks = []
                    tab.workingMarks = [.ring(100), .ring(100), .ring(100), .ring(100)]
                    row.workingMarks = [.ring(100), .ring(100), .ring(100)]
                    for (name, v, boxes, title) in [("tab", tab as NSView, tab.spinnerBoxes, tab.titleRect.minX),
                                                    ("row", row as NSView, row.spinnerBoxes, CGFloat.nan)] {
                        let what = "\(theme) \(name)"
                        guard boxes.count == 3 else { p.append("\(what): \(boxes.count) working marks, want 3 (capped)"); continue }
                        if !(boxes[1].minX < boxes[0].maxX) { p.append("\(what): the working marks don't overlap") }
                        // The far (right) side of each ring, which nothing covers: the ring's stroke.
                        for (i, b) in boxes.enumerated() {
                            let w = b.width * RunningSpinner.strokeFraction
                            let px = PixelProbe.samples(v, in: CGRect(x: b.maxX - w, y: b.midY - 0.5, width: w, height: 1))
                            if !px.contains(where: { PixelProbe.matches($0, Theme.text) }) { p.append("\(what): working mark \(i + 1) isn't drawn") }
                        }
                        if !title.isNaN && title < boxes[2].maxX { p.append("\(what): the title starts under the working marks") }
                    }
                    return p
                } }
            }
            return all(problems)
        }) {}

        t.step("stacks: hovering a tab: the × replaces the whole dot stack, the outline stays, the title doesn't move", nil, {
            let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 200, height: Theme.Metrics.tabHeight))
            tab.title = "agents"
            tab.attentionMarks = [PaneAttention(pane: 1, state: .waiting), PaneAttention(pane: 2, state: .failed)]
            let title = tab.titleRect
            guard tab.attentionDotRects.count == 2 else { return "\(tab.attentionDotRects.count) dots, want 2" }
            let behind = tab.attentionDotRects[1]
            let before = PixelProbe.sample(tab, at: CGPoint(x: behind.minX + behind.width * 0.25, y: behind.midY + behind.height * 0.15))
            tab.setHoveringForTest(true)
            let after = PixelProbe.sample(tab, at: CGPoint(x: behind.minX + behind.width * 0.25, y: behind.midY + behind.height * 0.15))
            let outlined = PixelProbe.isFailedOutlined(tab)
            let moved = tab.titleRect != title
            tab.setHoveringForTest(false)
            return all([PixelProbe.matches(before, Theme.attentionWaiting) ? nil : "the dot behind isn't drawn at rest (\(hex(before)))",
                        PixelProbe.distance(after, Theme.attentionWaiting) > 0.15 ? nil : "the dot behind still shows while hovering",
                        outlined ? nil : "the roll-up outline (failed) should stay while hovering",
                        moved ? "the title moved on hover" : nil])
        }) {}

        // Live: four panes in one tab, so the tab, its sidebar row, the pill and a collapsed header
        // roll up the same panes.
        t.step("stacks: live: a tab and its sidebar row show one working mark per working pane, Claude first, capped at 3; the pill keeps the strongest", nil, {
            guard let a = pane("st-a") else { return all(["setup failed"]) }
            let w = self.locate(a)?.workspace
            guard let tb = tabButton(a), let r = row(w) else { return all(["no tab button or row"]) }
            let natural = TabStripView.naturalWidth(tb.title, working: 3)
            return all([want("the tab's working marks", tb.spinner.marks, [.claude, .claude, .arc]),
                        want("the row's working marks", r.spinner.marks, [.claude, .claude, .arc]),
                        want("the tab's front mark", tb.working, .claude),
                        want("the pill's marks", pill(w)?.spinner.marks ?? [], [.claude]),
                        tb.frame.width + 0.5 >= natural ? nil : "the tab is \(tb.frame.width)pt, want room for 3 marks (\(natural)pt)",
                        tb.titleRect.minX >= (tb.spinnerBoxes.last?.maxX ?? 0) ? nil : "the title starts under the working marks"])
        }) {
            created(call("create", ["type": "workspace", "target": "focused", "name": "stacks"]), "st-home")
            created(call("create", ["type": "tab", "focus": false], caller: "st-home"), "st-a")
            created(call("create", ["type": "pane", "focus": false], caller: "st-a"), "st-b")
            created(call("create", ["type": "pane", "focus": false], caller: "st-b"), "st-c")
            created(call("create", ["type": "pane", "focus": false], caller: "st-c"), "st-d")
            report("st-a", true, claude: true)
            report("st-b", true, claude: true)
            report("st-c", true)
            report("st-d", true, percent: 40)
            refresh()
        }

        t.step("stacks: live: panes wanting attention move from the working stack to the dot stack, most urgent in front; the outline is the roll-up", nil, {
            guard let a = pane("st-a") else { return all(["setup failed"]) }
            let w = self.locate(a)?.workspace
            guard let tb = tabButton(a), let r = row(w) else { return all(["no tab button or row"]) }
            return all([want("the tab's dots", states(tb.dots), [.failed, .waiting, .unread]),
                        want("the row's dots", states(r.dots), [.failed, .waiting, .unread]),
                        // a is unread and still working (agentState stays running); b and c left.
                        want("the tab's working marks", tb.spinner.marks, [.claude, .ring(40)]),
                        want("the pill's dots (the roll-up only)", pill(w)?.attention, .failed),
                        PixelProbe.isFailedOutlined(tb) ? nil : "the tab's outline should be the roll-up's red",
                        PixelProbe.hasFailedDot(r) ? nil : "the row's front dot should be the large red one, with no outline"])
        }) {
            guard let a = pane("st-a"), let b = pane("st-b"), let c = pane("st-c") else { return }
            self.setAttention(.waiting, on: b, title: "t", body: "b")
            self.setAttention(.failed, on: c, title: "t", body: "b")
            self.setAttention(.unread, on: a, title: "t", body: "b")
            refresh()
        }

        t.step("stacks: live: a collapsed sidebar group header stacks its members' marks; the label pill keeps one of each", nil, {
            guard let g = self.groups.first(where: { $0.name == "Stacks" }), let h = self.workspaceSidebar.header(for: g)
            else { return all(["setup failed: no group header"]) }
            var p: [String?] = [want("the header's dots", states(h.dots), [.failed, .waiting, .unread]),
                                want("the header's working marks", h.spinner.marks, [.claude, .ring(40)])]
            Settings.workspaceSwitcher = .top
            refresh()
            let label = self.workspaceBar.label(for: g)
            p.append(want("the label pill's dots", label.map { states($0.dots) } ?? [], [.failed]))
            p.append(want("the label pill's working marks", label?.spinner.marks ?? [], [.claude]))
            Settings.workspaceSwitcher = savedSwitcher
            refresh()
            return all(p)
        }) {
            guard let s = ws("stacks") else { return }
            let g = self.moveToNewGroup(s, name: "Stacks")
            if let other = self.workspaces.first(where: { $0.group == nil }) { self.activate(other) }
            self.setCollapsed(g, true)
            refresh()
        }

        t.step("stacks: live: each dot fades on its own when its pane clears; the others stay solid (#34)", nil, {
            guard let b = pane("st-b"), let tb = tabButton(b) else { return all(["setup failed"]) }
            var p: [String?] = []
            AttentionFade.enabled = true
            defer { AttentionFade.enabled = false }
            // Wait out a reveal hold an earlier step may have started.
            _ = SelfTest.waitUntil(timeout: 2) { AttentionFade.timing().hold == 0 }
            self.clearAttention(b, cause: "self-test")
            refresh()
            let fading = tb.dots.shown
            p.append(want("the dots right after the clear", fading.map(\.state), [.failed, .waiting, .unread]))
            p.append(SelfTest.waitUntil("the waiting dot to fade part-way while the others stay solid", timeout: 3) {
                let s = tb.dots.shown
                return s.count == 3 && s[1].alpha < 0.9 && s[1].alpha > 0 && s[0].alpha == 1 && s[2].alpha == 1
            })
            p.append(SelfTest.waitUntil("the waiting dot to go", timeout: 3) { states(tb.dots) == [.failed, .unread] })
            return all(p)
        }) {}

        t.step("stacks: clean up", nil, {
            all([self.workspaces.contains { $0.name == "stacks" } ? "the test workspace should be gone" : nil,
                 ProgressSource.foregroundOverride == nil ? nil : "the foreground override should be cleared"])
        }) {
            Settings.workspaceSwitcher = savedSwitcher
            if let w = ws("stacks") { self.remove(workspace: w) }
            ProgressSource.foregroundOverride = nil
            self.layoutNow()
            lastError = nil
        }
    }
}
