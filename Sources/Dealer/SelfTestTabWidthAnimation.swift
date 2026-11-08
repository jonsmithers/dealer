import AppKit

// MARK: - Self-test section: tab widths glide (#103, TabWidthGlide in LayoutAnimation.swift)
//
// Self-contained (`DEALER_SELFTEST_ONLY=tab width:`). A strip re-laid out with the same tabs whose
// tabs want new widths (a retitle, focus moving within a tab, a working mark) glides the buttons'
// real frames there, the tabs after it moving along; the new title shows at once and truncates at
// the width on screen. A new target mid-glide continues from where the tab is. `[window]
// animate_layout = false`, Reduce Motion and structural changes put the tabs at their final frames
// at once. Titlebar and deck strips, connected and pill tabs. Waits on conditions only.

extension TerminalWindowController {
    func tabWidthAnimationSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func on() {
            LayoutAnimation.enabled = true
            AttentionFade.reduceMotionOverride = false
        }
        func writeSettings(_ body: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            layoutNow()
        }
        func text(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: Theme.Fonts.tabActive]).width) }

        var ws: Workspace?
        var lower: Pane?  // the lower deck's pane (deck strip)
        var focusPanes: [Pane] = []
        var topDeck: Deck? { ws?.root?.leaves.first }
        var lowerDeck: Deck? { lower.flatMap { self.locate($0)?.deck } }
        func strip(_ d: Deck?) -> TabStripView? { d?.view.strip }
        func widths(_ d: Deck?) -> [CGFloat] { strip(d)?.buttons.map(\.frame.width) ?? [] }
        func retitle(_ d: Deck?, _ i: Int, _ s: String) {
            guard let d, d.tabs.indices.contains(i) else { return }
            d.tabs[i].customTitle = s
            refreshChrome()
            strip(d)?.layoutSubtreeIfNeeded()
        }
        /// Buttons left to right with the strip spacing, "+" right after the last one, wherever the
        /// glide has them.
        func contiguous(_ d: Deck?) -> String? {
            guard let s = strip(d) else { return "no strip" }
            var x = s.buttons.first?.frame.minX ?? 0
            for (i, b) in s.buttons.enumerated() {
                if abs(b.frame.minX - x) > 0.01 { return "tab \(i + 1) starts at \(b.frame.minX), want \(x) (right after the one before)" }
                x = b.frame.maxX + Theme.Metrics.tabSpacing
            }
            return abs(s.addButton.frame.minX - x) < 0.01 ? nil : "\"+\" at \(s.addButton.frame.minX), want \(x)"
        }
        /// Every button at its final frame (the model's `tabFrame`).
        func final(_ d: Deck?) -> String? {
            guard let s = strip(d) else { return "no strip" }
            for (i, b) in s.buttons.enumerated() where b.frame != s.tabFrame(i) {
                return "tab \(i + 1) is at \(NSStringFromRect(b.frame)), want its final \(NSStringFromRect(s.tabFrame(i)))"
            }
            return contiguous(d)
        }
        func settled(_ d: Deck?) -> String? {
            all(SelfTest.waitUntil("the tab widths to settle") { strip(d)?.isGliding == false }, final(d))
        }
        /// Waits until tab `i` is clearly between `a` and `b`, checking the row stays contiguous
        /// on the way; returns the width it found there.
        func midway(_ d: Deck?, _ i: Int, _ a: CGFloat, _ b: CGFloat, problems: inout [String]) -> CGFloat? {
            var gap: String?
            let lo = min(a, b) + 3, hi = max(a, b) - 3
            let ok = SelfTest.waitUntil(timeout: 2) {
                if gap == nil { gap = contiguous(d) }
                let w = widths(d)
                return w.indices.contains(i) && w[i] > lo && w[i] < hi
            }
            if let gap { problems.append("mid-glide: \(gap)") }
            guard ok else {
                problems.append("tab \(i + 1) never showed a width between \(a) and \(b) (now \(widths(d)))")
                return nil
            }
            return widths(d)[i]
        }

        let long = "nvim Sources/Dealer/LayoutAnimation.swift"
        var before: [CGFloat] = []
        var problems: [String] = []

        t.step("tab width: a retitle glides the tab's width; the tabs after it move along (titlebar, connected)", nil, {
            guard let s = strip(topDeck), s.buttons.count == 3 else { return "the test deck should have three tabs" }
            let b = s.buttons[0], target = s.tabFrame(0).width
            return all(problems.isEmpty ? nil : problems.joined(separator: "; "),
                       s.isInTitlebar ? nil : "the strip should be in the titlebar (default settings)",
                       s.style == .connected ? nil : "tabs should be connected (default)",
                       target > before[0] + 40 ? nil : "the long title should want a much wider tab (\(before[0]) → \(target))",
                       settled(topDeck),
                       b.title == long ? nil : "the button should show the new title")
        }) {
            ws = self.newWorkspace(name: "tabwidth")
            guard let d = topDeck else { return }
            while d.tabs.count < 3 { self.newTab(in: d) }
            for (tab, s) in zip(d.tabs, ["one", "two", "three"]) { tab.customTitle = s }
            self.refreshChrome()
            self.layoutNow()
            on()
            problems = []
            before = widths(d)
            retitle(d, 0, long)
            guard let s = strip(d) else { return }
            // Right after the layout: the new title, at the old width, headed for the new one.
            let b = s.buttons[0], target = s.tabFrame(0).width
            if !s.isGliding { problems.append("the strip should be gliding") }
            if b.title != long { problems.append("the new title should show at once, shows \"\(b.title)\"") }
            if abs(b.frame.width - before[0]) > 0.5 { problems.append("the tab jumped to \(b.frame.width) at once (was \(before[0]), wants \(target))") }
            if s.glideTarget != (0..<s.buttons.count).map({ s.tabFrame($0).width }) { problems.append("the glide should head for the final widths: \(s.glideTarget)") }
            if midway(d, 0, before[0], target, problems: &problems) != nil {
                // The title truncates at the width on screen, not the final one: the button redraws
                // at the widths it passes through (not a picture stretched or pinned to the final one).
                if b.titleRect.width >= text(long) { problems.append("mid-glide the title should truncate at the moving width (\(b.titleRect.width) ≥ \(text(long)))") }
                let redrew = SelfTest.waitUntil(timeout: 1) { s.isGliding && b.drawnWidth > before[0] + 1 && b.drawnWidth < target - 1 }
                if !redrew { problems.append("the button should redraw mid-glide (last drew at \(b.drawnWidth), \(before[0]) → \(target))") }
                if s.buttons[1].frame.minX <= before[0] + s.buttons[0].frame.minX { problems.append("the tab after it should have moved right") }
            }
        }

        t.step("tab width: a new title mid-glide continues from where the tab is, never snapping back", nil, {
            all(problems.isEmpty ? nil : problems.joined(separator: "; "), settled(topDeck))
        }) {
            guard let d = topDeck, let s = strip(d) else { return }
            problems = []
            let wide = widths(d)[0]
            retitle(d, 0, "z")  // shrinking toward the minimum…
            let narrow = s.tabFrame(0).width
            guard let mid = midway(d, 0, wide, narrow, problems: &problems) else { return }
            retitle(d, 0, long)  // …and back before it gets there
            let now = widths(d)[0]
            if abs(now - mid) > 0.01 { problems.append("the retarget moved the tab from \(mid) to \(now) at once") }
            if s.glideTarget.first != wide { problems.append("the glide should head back to \(wide), heads for \(s.glideTarget)") }
            // From there it only grows, straight to the new target.
            var last = now
            _ = SelfTest.waitUntil(timeout: 2) {
                let w = widths(d)[0]
                if w < last - 0.01 { problems.append("the tab shrank from \(last) to \(w) after the retarget") }
                last = w
                return !s.isGliding
            }
        }

        t.step("tab width: focus moving within a tab glides to the other pane's title", nil, {
            all(problems.isEmpty ? nil : problems.joined(separator: "; "), settled(topDeck))
        }) {
            guard let d = topDeck, let tab = d.tabs.dropFirst().first, let p = tab.panes.first else { return }
            problems = []
            LayoutAnimation.enabled = false
            tab.customTitle = nil
            p.customTitle = "sh"
            self.split(p, side: .right)
            guard let q = self.focusedPane, q !== p else { problems.append("the split made no pane"); return }
            q.customTitle = "tail -f /var/log/system.log | grep dealer"
            focusPanes = [p, q]
            self.focus(p)
            self.refreshChrome()
            self.layoutNow()
            on()
            let w0 = widths(d)[1]
            self.focus(q)
            self.refreshChrome()
            strip(d)?.layoutSubtreeIfNeeded()
            guard let s = strip(d) else { return }
            if !s.isGliding { problems.append("focusing the long-titled pane should glide its tab") }
            if abs(s.buttons[1].frame.width - w0) > 0.5 { problems.append("the tab jumped from \(w0) to \(s.buttons[1].frame.width)") }
            _ = midway(d, 1, w0, s.tabFrame(1).width, problems: &problems)
        }

        t.step("tab width: a working mark widens its tab with a glide", nil, {
            all(problems.isEmpty ? nil : problems.joined(separator: "; "), settled(topDeck))
        }) {
            guard let d = topDeck, let p = d.tabs.last?.panes.first, let s = strip(d) else { return }
            problems = []
            let w0 = widths(d)[2]
            ProgressSource.foregroundOverride = { _ in false }
            _ = ProgressSource.note(p, active: true, percent: nil, foreground: 1)
            ProgressSource.foregroundOverride = nil
            self.refreshChrome()
            s.layoutSubtreeIfNeeded()
            let want = TabStripView.naturalWidth("three", working: 1)
            if s.tabFrame(2).width != want { problems.append("the working tab should want \(want), wants \(s.tabFrame(2).width)") }
            if !s.isGliding { problems.append("a working mark should glide its tab wider") }
            if abs(s.buttons[2].frame.width - w0) > 0.5 { problems.append("the tab jumped from \(w0) to \(s.buttons[2].frame.width)") }
            _ = midway(d, 2, w0, want, problems: &problems)
        }

        t.step("tab width: a deck strip with pill tabs glides too", nil, {
            guard let s = strip(lowerDeck) else { return "no lower deck" }
            return all(problems.isEmpty ? nil : problems.joined(separator: "; "),
                       s.isInTitlebar ? "the lower deck's strip should be in its deck" : nil,
                       s.style == .pill ? nil : "tabs should be pills",
                       settled(lowerDeck))
        }) {
            guard let d = topDeck else { return }
            problems = []
            LayoutAnimation.enabled = false
            if let p = d.tabs.last?.panes.first { _ = ProgressSource.note(p, active: false, percent: nil, foreground: 0) }
            writeSettings("[tabs]\nstyle = \"pill\"\n")
            lower = self.controlNewDeck(beside: d, side: .bottom, fraction: 0.4, workingDirectory: nil, command: nil, title: nil, focus: false)
            guard let ld = lowerDeck else { return }
            self.newTab(in: ld)
            for (tab, s) in zip(ld.tabs, ["a", "b"]) { tab.customTitle = s }
            self.refreshChrome()
            self.layoutNow()
            on()
            let w0 = widths(ld)[0]
            retitle(ld, 0, long)
            guard let s = strip(ld) else { return }
            if !s.isGliding { problems.append("the deck strip should glide") }
            _ = midway(ld, 0, w0, s.tabFrame(0).width, problems: &problems)
        }

        t.step("tab width: with animate_layout = false the widths change at once", nil, {
            all(strip(lowerDeck)?.isGliding == false ? nil : "the strip should not glide", final(lowerDeck),
                widths(lowerDeck).first == strip(lowerDeck)?.tabFrame(0).width ? nil : "the tab should be at its new width")
        }) {
            writeSettings("[tabs]\nstyle = \"pill\"\n[window]\nanimate_layout = false\n")
            retitle(lowerDeck, 0, "c")
        }

        t.step("tab width: under Reduce Motion the widths change at once", nil, {
            all(strip(topDeck)?.isGliding == false ? nil : "the strip should not glide", final(topDeck))
        }) {
            writeSettings("")
            AttentionFade.reduceMotionOverride = true
            retitle(topDeck, 0, "z")
        }

        t.step("tab width: a structural change mid-glide puts every tab at its final frame", nil, {
            all(problems.isEmpty ? nil : problems.joined(separator: "; "),
                strip(topDeck)?.isGliding == false ? nil : "a new tab should end the glide", final(topDeck),
                SelfTest.waitUntil("the layout motion to end") { !LayoutAnimation.isAnimating(in: self.contentView) })
        }) {
            on()
            problems = []
            retitle(topDeck, 0, long)
            if strip(topDeck)?.isGliding != true { problems.append("the retitle should glide") }
            if let d = topDeck { self.newTab(in: d) }
        }

        t.step("tab width: clean up", nil, {
            all(self.workspaces.contains { $0.name == "tabwidth" } ? "the test workspace should be gone" : nil,
                Settings.animateLayout ? nil : "animate_layout should be back to the default (on)")
        }) {
            LayoutAnimation.enabled = false
            AttentionFade.reduceMotionOverride = nil
            focusPanes = []
            lower = nil
            writeSettings("")
            if let ws { self.remove(workspace: ws) }
            ws = nil
            self.layoutNow()
        }
    }
}
