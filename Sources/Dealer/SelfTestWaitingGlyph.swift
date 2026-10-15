import AppKit

// MARK: - Self-test section: the waiting dot's `?` (issue #65)

extension TerminalWindowController {
    /// *waiting* carries a knocked-out `?` on tabs, sidebar rows and pills; *done*, which since #61 has
    /// the same blue, stays a bare dot. Checked like #48 checks the `!`: the best pixel in each part
    /// of the glyph, as a share of chrome over the dot's blue, at 2x and 1x, in a dark and a light
    /// theme (Catppuccin Frappé and Latte).
    func waitingGlyphSelfTestSteps(_ t: SelfTestKit) {
        func entries() -> [(String, NSView, () -> CGRect, (Attention) -> Void)] {
            let tab = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
            tab.title = "tab"
            let row = WorkspaceRow(frame: CGRect(x: 0, y: 0, width: Theme.Metrics.sidebarWidth, height: Theme.Metrics.sidebarRowDetailHeight))
            row.title = "ws"; row.number = "1"; row.detail = "dealer · main"
            let pill = WorkspaceButton(frame: CGRect(x: 0, y: 0, width: 120, height: WorkspaceBarView.pillHeight))
            pill.title = "ws"; pill.number = "1"
            return [("tab", tab, { tab.attentionDotRect }, { tab.attention = $0 }),
                    ("row", row, { row.attentionDotRect }, { row.attention = $0 }),
                    ("pill", pill, { pill.attentionDotRect }, { pill.attention = $0 })]
        }
        func shares(_ v: NSView, in rect: CGRect) -> [CGFloat] {
            PixelProbe.samples(v, in: rect).compactMap { PixelProbe.coverage(of: Theme.chrome, on: Theme.attentionWaiting, in: $0) }
        }
        /// The largest share of chrome over `Theme.attentionWaiting` among the pixels in `rect`.
        func chrome(_ v: NSView, in rect: CGRect) -> CGFloat { shares(v, in: rect).max() ?? 0 }
        /// The chrome "ink" in `rect`, in pixels: the shares added up.
        func ink(_ v: NSView, in rect: CGRect) -> CGFloat { shares(v, in: rect).reduce(0, +) }

        t.step("waiting glyph: a `?` knocked out of the waiting dot on tabs, rows and pills; done stays a bare dot (Frappé and Latte, 2x and 1x)", nil, {
            var problems: [String] = []
            let themes = [("dark", "#303446", "#c6d0f5"), ("light", "#eff1f5", "#4c4f69")]
            for (theme, bg, fg) in themes.map({ ($0.0, NSColor(hex: $0.1)!, NSColor(hex: $0.2)!) }) {
                problems += PixelProbe.atEachScale { scale in Theme.withBackground(bg, foreground: fg) {
                    var p: [String] = []
                    for (name, v, dotRect, set) in entries() {
                        let what = "\(theme) \(name)"
                        let r = dotRect(), q = AttentionStyle.questionGeometry(in: r)
                        if r.width < 8 { p.append("\(what): dot is \(r.width)pt, want 8pt") }
                        // The bowl's left side, the point, and the open middle of the bowl.
                        let left = CGRect(x: q.center.x - q.radius - q.width / 2, y: q.center.y - q.width / 2, width: q.width, height: q.width)
                        let hole = CGRect(x: q.center.x - 0.25, y: q.center.y - 0.25, width: 0.5, height: 0.5)
                        set(.waiting)
                        // Around the point, but not up into the stem.
                        let around = CGRect(x: q.point.minX - 0.5, y: q.point.minY, width: q.point.width + 1, height: q.point.height + 0.5)
                        let gapY = (q.stemEnd.y + q.width / 2 + q.point.minY) / 2
                        let gap = chrome(v, in: CGRect(x: q.center.x - 0.25, y: gapY - 0.2, width: 0.5, height: 0.4))
                        if scale >= 2 && gap > 0.5 { p.append("\(what): the `?`'s stem runs into its point (\(String(format: "%.2f", gap)) chrome between)") }
                        let (l, pt, pInk, h) = (chrome(v, in: left), chrome(v, in: q.point), ink(v, in: around), chrome(v, in: hole))
                        print("      waiting glyph @\(Int(scale))x \(what): bowl \(String(format: "%.2f", l)), point \(String(format: "%.2f", pt)) (ink \(String(format: "%.2f", pInk)) px), hole \(String(format: "%.2f", h))")
                        // At 2x the 1.44pt strokes cover whole pixels; at 1x the bowl still covers most
                        // of one, while the 1.44pt point can straddle a pixel edge and split across two
                        // (about half each), so there it must add up to at least a pixel of chrome.
                        let solid: CGFloat = scale >= 2 ? 0.9 : 0.6
                        if l < solid { p.append("\(what): the `?`'s bowl is only \(String(format: "%.2f", l)) chrome, want ≥ \(solid)") }
                        if scale >= 2 ? pt < solid : pInk < 1 {
                            p.append("\(what): the `?`'s point is too faint (best \(String(format: "%.2f", pt)), ink \(String(format: "%.2f", pInk)) px)")
                        }
                        if scale >= 2 && h > 0.5 { p.append("\(what): the `?`'s bowl is filled in (\(String(format: "%.2f", h)) chrome), so it reads as a blob") }
                        if !PixelProbe.isWaitingOutlined(v) { p.append("\(what): waiting lost its outline") }
                        set(.done)
                        if Attention.done.outlined {
                            let d = chrome(v, in: left) + chrome(v, in: q.point)
                            if d > 0.1 { p.append("\(what): done should be a bare dot, has \(String(format: "%.2f", d)) chrome in it") }
                        }
                    }
                    return p
                } }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
    }
}
