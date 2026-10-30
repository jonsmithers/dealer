import AppKit

// MARK: - Self-test section: the selected workspace stands out in both switchers (#52, #90)

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
        /// Where an entry's selection bar must sit (#90): a sidebar row's or header's right edge, a
        /// pill's bottom edge, just inside the attention outline, at its full thickness.
        func barPlacement(_ v: NSView, _ r: CGRect, vertical: Bool, _ what: String) -> String? {
            let b = v.bounds, gap = SelectionStyle.inset
            if vertical {
                let w = Theme.Metrics.workspaceBarWidth
                return abs(r.maxX - (b.maxX - gap)) < 0.01 && r.width == w && r.height >= b.height / 2 ? nil
                    : "\(what): the bar should be \(w)pt wide at the right edge, is \(r) in \(b)"
            }
            let h = Theme.Metrics.workspacePillBarWidth
            return abs(r.maxY - (b.maxY - gap)) < 0.01 && r.height == h && r.width >= b.width / 2 ? nil
                : "\(what): the bar should be \(h)pt tall along the bottom edge, is \(r) in \(b)"
        }
        /// The bar's color across its thickness (three points, so the whole width counts).
        func barProblem(_ v: NSView, _ r: CGRect, vertical: Bool, want: NSColor, _ what: String) -> String? {
            let pts = vertical ? [r.minX + 0.5, r.midX, r.maxX - 0.5].map { CGPoint(x: $0, y: r.midY) }
                               : [r.minY + 0.5, r.midY, r.maxY - 0.5].map { CGPoint(x: r.midX, y: $0) }
            let px = pts.map { PixelProbe.sample(v, at: $0) }
            return px.allSatisfy { PixelProbe.matches($0, want) } ? nil : "\(what): bar is \(px.map(hex)), want \(hex(want))"
        }
        /// No selection outline (#90, replacing #52's): nothing at all is drawn on the outline's
        /// path, on any edge, so only attention draws outlines. The fill and tint are inset inside it.
        func outlineProblem(_ v: NSView, _ what: String) -> String? {
            let b = v.bounds, e = 0.5 / PixelProbe.scale
            let pts = [CGPoint(x: b.midX, y: e), CGPoint(x: e, y: b.midY), CGPoint(x: b.maxX - e, y: b.midY), CGPoint(x: b.midX, y: b.maxY - e)]
            let px = pts.map { PixelProbe.sample(v, at: $0) }
            return px.allSatisfy { ($0?.alphaComponent ?? 0) < 0.05 } ? nil
                : "\(what): something is drawn on the outline's path: \(px.map(hex)) (top, left, right, bottom)"
        }
        /// Where the color chip and #52's left bar used to sit: no color of their own may show there.
        func chipSpot(_ v: NSView) -> CGPoint { CGPoint(x: v is WorkspaceRow ? 5.5 : 12, y: v.bounds.midY) }
        /// A spot on the fill clear of text, dots and the bar.
        func fillSpot(_ v: NSView) -> CGPoint { CGPoint(x: v.bounds.maxX - (v is WorkspaceRow ? 14 : 4), y: v.bounds.midY) }
        func barRect(_ v: NSView) -> CGRect { (v as? WorkspaceRow)?.selectionBarRect ?? (v as? WorkspaceButton)?.selectionBarRect ?? .zero }

        func selected(_ v: NSView, color: NSColor?, _ what: String) -> [String?] {
            let vertical = v is WorkspaceRow, r = barRect(v), want = SelectionStyle.barColor(color)
            let fill = PixelProbe.sample(v, at: fillSpot(v))
            let left = PixelProbe.sample(v, at: chipSpot(v))
            // A colored entry's tint lies over the fill; the bar carries its color.
            return [color != nil || PixelProbe.matches(fill, Theme.workspaceSelection) ? nil
                        : "\(what): fill is \(hex(fill)), want \(hex(Theme.workspaceSelection))",
                    barPlacement(v, r, vertical: vertical, what),
                    barProblem(v, r, vertical: vertical, want: want, what),
                    PixelProbe.matches(left, want) ? "\(what): there is still a bar or chip at the left edge" : nil,
                    outlineProblem(v, what)]
        }
        func unselected(_ v: NSView, color: NSColor?, _ what: String) -> [String?] {
            let fill = PixelProbe.sample(v, at: fillSpot(v))
            let r = barRect(v)
            let barPx = PixelProbe.sample(v, at: CGPoint(x: r.midX, y: r.midY))
            let chip = PixelProbe.sample(v, at: chipSpot(v))
            return [PixelProbe.matches(fill, Theme.workspaceSelection) ? "\(what): an unselected entry has the selection fill" : nil,
                    PixelProbe.matches(barPx, SelectionStyle.barColor(color)) ? "\(what): an unselected entry has a selection bar" : nil,
                    color.flatMap { PixelProbe.matches(chip, $0) ? "\(what): an unselected colored entry still has a chip (#90: the tint alone)" : nil },
                    outlineProblem(v, what)]
        }
        func heavy(_ f: NSFont, _ what: String) -> String? {
            let w = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            return w >= NSFont.Weight.semibold.rawValue - 0.01 ? nil : "\(what): selected title weight \(w), want semibold or heavier"
        }

        t.step("selection: the selected row and pill get a neutral fill, a bar on the right edge (row) or bottom edge (pill) and a heavier title, and no outline; unselected entries have no chip; dark and light, 2x and 1x", nil, {
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
                    var p: [String?] = []
                    p += unselected(row, color: nil, "\(name) row")
                    p += unselected(pill, color: nil, "\(name) pill")
                    row.color = teal; pill.color = teal
                    p += unselected(row, color: teal, "\(name) colored row")
                    p += unselected(pill, color: teal, "\(name) colored pill")
                    row.color = nil; pill.color = nil
                    row.isActive = true; pill.isActive = true
                    p += selected(row, color: nil, "\(name) row")
                    p += selected(pill, color: nil, "\(name) pill")
                    row.color = teal; pill.color = teal
                    p += selected(row, color: teal, "\(name) colored row")
                    p += selected(pill, color: teal, "\(name) colored pill")
                    let c = contrast(Theme.workspaceSelection, Theme.chrome)
                    p.append(c >= 1.3 ? nil : "\(name): selection fill \(hex(Theme.workspaceSelection)) is only \(String(format: "%.2f", c)):1 on the chrome \(hex(Theme.chrome))")
                    p.append(heavy(row.titleFontForTest, "\(name) row"))
                    p.append(heavy(pill.titleFontForTest, "\(name) pill"))
                    // Attention still outlines a selected entry, in exactly its color on every edge, and
                    // the bar stays (under attention's tint); once it clears, the edges are empty again.
                    for (state, color) in [(Attention.waiting, Theme.attentionWaiting), (.failed, Theme.attentionFailed)] {
                        for (v, kind) in [(row as NSView, "row"), (pill, "pill")] {
                            (v as? WorkspaceRow)?.attention = state; (v as? WorkspaceButton)?.attention = state
                            let edges = [PixelProbe.outlinePoint(in: v), CGPoint(x: 0.25, y: v.bounds.midY)].map { PixelProbe.sample(v, at: $0) }
                            p.append(edges.allSatisfy { PixelProbe.matches($0, color) } ? nil
                                     : "\(name): a selected \(state) \(kind)'s outline should be \(hex(color)), reads \(edges.map(hex))")
                            let r = barRect(v)
                            let mid = PixelProbe.sample(v, at: CGPoint(x: r.midX, y: r.midY)), fill = PixelProbe.sample(v, at: fillSpot(v))
                            p.append(PixelProbe.matches(mid, fill, tolerance: 0.05) ? "\(name): a selected \(state) \(kind) lost its bar" : nil)
                        }
                    }
                    row.attention = .none; pill.attention = .none
                    p.append(outlineProblem(row, "\(name) row after attention"))
                    p.append(outlineProblem(pill, "\(name) pill after attention"))
                    return p.compactMap { $0 }
                } }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        t.step("selection: a collapsed group header holding the active workspace gets the bar in the text color (right edge in the sidebar, bottom edge on a pill) and no outline; its count keeps clear of the bar", nil, {
            let p = PixelProbe.atEachScale { _ in Theme.withBackground(NSColor(hex: "#303446")!, foreground: NSColor(hex: "#c6d0f5")!) {
                var p: [String?] = []
                for (style, size) in [(GroupHeaderView.Style.row, CGSize(width: Theme.Metrics.sidebarWidth, height: Theme.Metrics.groupHeaderHeight)),
                                      (.pill, CGSize(width: 140, height: WorkspaceBarView.pillHeight))] {
                    let h = GroupHeaderView(frame: CGRect(origin: .zero, size: size))
                    h.style = style; h.title = "group"; h.isCollapsed = true; h.count = 2
                    let what = style == .row ? "sidebar header" : "label pill", r = h.selectionBarRect
                    let off = PixelProbe.sample(h, at: CGPoint(x: r.midX, y: r.midY))
                    p.append(PixelProbe.matches(off, Theme.text) ? "\(what): an inactive header has a bar" : nil)
                    h.isActive = true
                    p.append(barPlacement(h, r, vertical: style == .row, what))
                    p.append(barProblem(h, r, vertical: style == .row, want: Theme.text, what))
                    p.append(outlineProblem(h, what))
                    if style == .row {
                        // The count ends a few points short of the bar, not against it.
                        let gap = PixelProbe.samples(h, in: CGRect(x: r.minX - 4, y: r.minY, width: 3.5, height: r.height))
                        p.append(gap.allSatisfy { $0.alphaComponent < 0.05 } ? nil : "\(what): the count runs into the bar")
                    }
                }
                return p.compactMap { $0 }
            } }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}

        // The same on the live switchers in the window: the sidebar, then the top-bar pills.
        func live(_ entry: (Int) -> NSView?, _ what: String) -> String? {
            guard let a = entry(0), let b = entry(1) else { return "\(what): expected two entries" }
            return all(selected(a, color: nil, "\(what) 1") + unselected(b, color: nil, "\(what) 2"))
        }
        t.step("selection: the window's sidebar marks the active workspace's row", nil, {
            !sb.isHidden ? live({ sb.row(at: $0) }, "row") : "the sidebar should show"
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "sel2")
            self.activateWorkspace(index: 0)
            self.sidebarPreference = true
            self.layoutNow()
        }
        t.step("selection: …and in top-bar mode, the active workspace's pill", nil, {
            !bar.isHidden ? live({ bar.button(at: $0) }, "pill") : "the pills should show"
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
