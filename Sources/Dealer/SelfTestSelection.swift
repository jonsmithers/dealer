import AppKit

// MARK: - Self-test section: the selected workspace stands out in both switchers (issue #52)

extension TerminalWindowController {
    func selectionSelfTestSteps(_ t: SelfTestKit) {
        let sb = workspaceSidebar
        let bar = workspaceBar
        func all(_ problems: [String?]) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func hex(_ c: NSColor?) -> String { c?.hexString ?? "nil" }
        func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let (l1, l2) = (a.luminance, b.luminance)
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        /// The selection's look on one switcher entry (`v`, a row or pill): its fill at a spot clear
        /// of text and dots, its bar (three points across it, so its width counts), and an empty
        /// margin where the attention outline would go, so selection never reads as an outline.
        func selected(_ v: NSView, bar r: CGRect, color: NSColor?, _ what: String) -> [String?] {
            let fill = PixelProbe.sample(v, at: CGPoint(x: v.bounds.maxX - 4, y: v.bounds.midY))
            let want = SelectionStyle.barColor(color)
            let barPx = [r.minX + 0.5, r.midX, r.maxX - 0.5].map { PixelProbe.sample(v, at: CGPoint(x: $0, y: r.midY)) }
            let out = outlineProblem(v)
            // A colored entry's tint lies over the fill; the bar carries its color.
            return [color != nil || PixelProbe.matches(fill, Theme.workspaceSelection) ? nil
                        : "\(what): fill is \(hex(fill)), want \(hex(Theme.workspaceSelection))",
                    barPx.allSatisfy { PixelProbe.matches($0, want) } ? nil
                        : "\(what): bar is \(barPx.map(hex)), want \(r.width)pt of \(hex(want))",
                    out.map { "\(what): \($0)" }]
        }
        /// The neutral selection outline (#52): `Theme.text`, `workspaceSelectionOutline` wide, on the
        /// top and left edges. At 2x the 1.5pt stroke covers three whole pixels; at 1x one whole pixel
        /// and half of the next. Just inside it there is no outline color.
        func outlineProblem(_ v: NSView) -> String? {
            let w = Theme.Metrics.workspaceSelectionOutline, s = PixelProbe.scale
            let solid = stride(from: 0.5 / s, to: floor(w * s) / s, by: 1 / s).map { $0 }
            var pts = solid.map { CGPoint(x: v.bounds.midX, y: $0) } + solid.map { CGPoint(x: $0, y: v.bounds.midY) }
            if w < 1.5 / s { pts = [CGPoint(x: v.bounds.midX, y: 0.5 / s)] }
            let px = pts.map { PixelProbe.sample(v, at: $0) }
            guard px.allSatisfy({ PixelProbe.matches($0, Theme.text) }) else {
                return "outline should be \(w)pt of \(hex(Theme.text)), reads \(px.map(hex)) at y/x \(solid)"
            }
            let inside = PixelProbe.sample(v, at: CGPoint(x: v.bounds.midX, y: ceil(w * s + 0.5) / s + 0.5 / s))
            if PixelProbe.matches(inside, Theme.text) { return "outline is wider than \(w)pt" }
            if s < 2 {
                // 1x: the stroke half covers the next pixel (the gap before the fill is transparent on
                // a detached view, so that pixel is the text color at partial alpha).
                let edge = PixelProbe.sample(v, at: CGPoint(x: v.bounds.midX, y: floor(w * s) / s + 0.5 / s))
                let a = edge?.alphaComponent ?? 0
                if !(0.2...0.8).contains(a) { return "@1x the stroke's last pixel should be partly covered, alpha \(a)" }
            }
            return nil
        }
        func unselected(_ v: NSView, bar r: CGRect, _ what: String) -> [String?] {
            let fill = PixelProbe.sample(v, at: CGPoint(x: v.bounds.maxX - 4, y: v.bounds.midY))
            let barPx = PixelProbe.sample(v, at: CGPoint(x: r.midX, y: r.midY))
            return [PixelProbe.matches(fill, Theme.workspaceSelection) ? "\(what): an unselected entry has the selection fill" : nil,
                    PixelProbe.matches(barPx, Theme.text) ? "\(what): an unselected, uncolored entry has a bar" : nil]
        }
        func heavy(_ f: NSFont, _ what: String) -> String? {
            let w = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            return w >= NSFont.Weight.semibold.rawValue - 0.01 ? nil : "\(what): selected title weight \(w), want semibold or heavier"
        }

        t.step("selection: the selected row and pill get a strong neutral fill, a wide bar and a heavier title, in dark and light themes, at 2x and 1x", nil, {
            var problems: [String] = []
            let teal = NSColor(hex: "#11a08f")!
            // Catppuccin Frappé and Latte backgrounds: the user's theme and its light sibling.
            let themes = [("dark", "#303446", "#c6d0f5"), ("light", "#eff1f5", "#4c4f69")]
            for (name, bg, fg) in themes.map({ ($0.0, NSColor(hex: $0.1)!, NSColor(hex: $0.2)!) }) {
                problems += PixelProbe.atEachScale { _ in Theme.withBackground(bg, foreground: fg) {
                    let row = WorkspaceRow(frame: CGRect(x: 0, y: 0, width: Theme.Metrics.sidebarWidth, height: Theme.Metrics.sidebarRowHeight))
                    row.number = "1"; row.title = "ws"
                    let pill = WorkspaceButton(frame: CGRect(x: 0, y: 0, width: 120, height: WorkspaceBarView.pillHeight))
                    pill.number = "1"; pill.title = "ws"
                    let rowBar = WorkspaceRow.chipRect(in: row.bounds, active: true)
                    var p: [String?] = []
                    p += unselected(row, bar: rowBar, "\(name) row")
                    p += unselected(pill, bar: pill.barRect, "\(name) pill")
                    row.isActive = true; pill.isActive = true
                    p += selected(row, bar: rowBar, color: nil, "\(name) row")
                    p += selected(pill, bar: pill.barRect, color: nil, "\(name) pill")
                    row.color = teal; pill.color = teal
                    p += selected(row, bar: rowBar, color: teal, "\(name) colored row")
                    p += selected(pill, bar: pill.barRect, color: teal, "\(name) colored pill")
                    p.append(rowBar.width >= 5 ? nil : "\(name): the row's bar should be at least 5pt wide, is \(rowBar.width)")
                    let c = contrast(Theme.workspaceSelection, Theme.chrome)
                    p.append(c >= 1.3 ? nil : "\(name): selection fill \(hex(Theme.workspaceSelection)) is only \(String(format: "%.2f", c)):1 on the chrome \(hex(Theme.chrome))")
                    p.append(heavy(row.titleFontForTest, "\(name) row"))
                    p.append(heavy(pill.titleFontForTest, "\(name) pill"))
                    // Attention still draws its outline around a selected entry.
                    // Attention's colored outline wins on a selected entry: exactly its color, on every edge
                    // (no neutral stroke stacked under it), and the neutral one is back once it clears.
                    for (state, color) in [(Attention.waiting, Theme.attentionWaiting), (.failed, Theme.attentionFailed)] {
                        for (v, kind) in [(row as NSView, "row"), (pill, "pill")] {
                            (v as? WorkspaceRow)?.attention = state; (v as? WorkspaceButton)?.attention = state
                            let edges = [PixelProbe.outlinePoint(in: v), CGPoint(x: 0.25, y: v.bounds.midY)].map { PixelProbe.sample(v, at: $0) }
                            p.append(edges.allSatisfy { PixelProbe.matches($0, color) } ? nil
                                     : "\(name): a selected \(state) \(kind)'s outline should be \(hex(color)), reads \(edges.map(hex))")
                        }
                    }
                    row.attention = .none; pill.attention = .none
                    p.append(outlineProblem(row).map { "\(name) row after attention: \($0)" })
                    return p.compactMap { $0 }
                } }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        // The same on the live switchers in the window: the sidebar, then the top-bar pills.
        func live(_ entry: (Int) -> NSView?, bar: (NSView) -> CGRect, _ what: String) -> String? {
            guard let a = entry(0), let b = entry(1) else { return "\(what): expected two entries" }
            return all(selected(a, bar: bar(a), color: nil, "\(what) 1") + unselected(b, bar: bar(b), "\(what) 2"))
        }
        let rowBar: (NSView) -> CGRect = { WorkspaceRow.chipRect(in: $0.bounds, active: true) }
        let pillBar: (NSView) -> CGRect = { ($0 as? WorkspaceButton)?.barRect ?? .zero }
        t.step("selection: the window's sidebar marks the active workspace's row", nil, {
            !sb.isHidden ? live({ sb.row(at: $0) }, bar: rowBar, "row") : "the sidebar should show"
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "sel2")
            self.activateWorkspace(index: 0)
            self.sidebarPreference = true
            self.layoutNow()
        }
        t.step("selection: …and in top-bar mode, the active workspace's pill", nil, {
            !bar.isHidden ? live({ bar.button(at: $0) }, bar: pillBar, "pill") : "the pills should show"
        }) {
            Settings.workspaceSwitcher = .top
            self.layoutNow()
        }
        t.step("selection: clean up", nil, {
            self.workspaces.count == 1 && Settings.workspaceSwitcher == .sidebar ? nil : "expected one workspace in sidebar mode"
        }) {
            Settings.workspaceSwitcher = .sidebar
            self.sidebarPreference = nil
            if let home = self.workspace(of: t.pane("srv")) {
                self.activate(home)
                self.workspaces.filter { $0 !== home }.forEach { self.remove(workspace: $0) }
            }
            self.layoutNow()
        }
    }
}
