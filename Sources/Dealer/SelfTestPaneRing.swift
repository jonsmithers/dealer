import AppKit

// MARK: - Self-test section: the dashed pane attention ring (#99)
//
// Self-contained (`DEALER_SELFTEST_ONLY=pane ring:`). The ring around a pane that needs you is
// dashed like the tab and sidebar outlines (`AttentionStyle.dashedRing`, the tabs' dash scaled to
// its 2pt line), in its state's color, with a dash folded round every corner. Its path is built for
// the pane's final size and never animates, so the dashes hold still while the pane glides (#94)
// and while the ring fades (#34, opacity only).

extension TerminalWindowController {
    func paneRingSelfTestSteps(_ t: SelfTestKit) {
        var ids: [String: Int] = [:]
        var lastError: String?
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
        func hex(_ c: NSColor?) -> String { c?.hexString ?? "nil" }
        func setSettings(_ body: String?) {
            let fm = FileManager.default
            try? fm.createDirectory(at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let body { try? body.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: Settings.fileURL) }
            Settings.reload()
        }
        // Found by name, as before #99, so this section also builds (and fails) on the solid ring.
        func ringLayer(_ v: PaneView) -> CALayer? { v.layer?.sublayers?.first { $0.name == "dealer.attentionRing" } }

        /// Reads the ring off `v`'s render along its top and left edges, inside the 2pt line: the
        /// stroke must be `color` where drawn, with gaps of `gapColor`, a dash on every corner, and
        /// nothing else (every pixel the stroke, the gap or a blend of the two).
        func ringProblems(_ v: PaneView, _ color: NSColor, gapColor: NSColor) -> [String] {
            let w = v.bounds.width, h = v.bounds.height, s = PaneView.ringWidth / 2
            var p: [String] = []
            for (edge, rect) in [("top", CGRect(x: 0, y: s / 2, width: w, height: s)),
                                 ("left", CGRect(x: s / 2, y: 0, width: s, height: h))] {
                let px = PixelProbe.samples(v, in: rect)
                guard !px.isEmpty else { p.append("\(edge): nothing rendered"); continue }
                let on = px.filter { PixelProbe.matches($0, color) }.count
                let off = px.filter { PixelProbe.matches($0, gapColor) }.count
                let n = CGFloat(px.count), want = AttentionStyle.dashPattern[0] / (AttentionStyle.dashPattern[0] + AttentionStyle.dashPattern[1])
                if CGFloat(off) / n < 0.2 { p.append("\(edge) edge has no gaps (\(off) of \(px.count) pixels off the stroke)") }
                if abs(CGFloat(on) / n - want) > 0.15 {
                    p.append("\(edge) edge is \(Int(CGFloat(on) / n * 100))% \(hex(color)), want about \(Int(want * 100))% (dash \(AttentionStyle.dashPattern))")
                }
                if let odd = px.first(where: { PixelProbe.coverage(of: color, on: gapColor, in: $0) == nil }) {
                    p.append("\(edge) edge has a pixel \(hex(odd)) that is neither the stroke nor a blend of it")
                }
            }
            for c in [CGPoint(x: s, y: s), CGPoint(x: w - s, y: s), CGPoint(x: w - s, y: h - s), CGPoint(x: s, y: h - s)] {
                let px = PixelProbe.sample(v, at: c)
                if !PixelProbe.matches(px, color) { p.append("corner \(Int(c.x)),\(Int(c.y)) is \(hex(px)), want a dash in \(hex(color))") }
            }
            return p
        }

        t.step("pane ring: dashed like the tabs, in each outlined state's color, a dash on every corner (dark and light, 2x and 1x)", nil, {
            var problems: [String] = []
            for (theme, bg, fg) in [("dark", "#282c34", "#abb2bf"), ("light", "#fafafa", "#383a42")] {
                for (state, setting) in [(Attention.waiting, nil), (.failed, nil), (.done, nil),
                                         (.unread, "[attention]\nunread = \"outline\"\n")] as [(Attention, String?)] {
                    if let setting { setSettings(setting) }
                    defer { if setting != nil { setSettings(nil) } }
                    problems += PixelProbe.atEachScale { _ in Theme.withBackground(NSColor(hex: bg)!, foreground: NSColor(hex: fg)!) {
                        let v = PaneView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
                        v.attentionFade.set(state, subject: nil)
                        v.applyAttentionRing()
                        guard let color = state.color, ringLayer(v) != nil else { return ["\(theme) \(state.name): no ring"] }
                        var p = ringProblems(v, color, gapColor: Theme.background)
                        let mid = PixelProbe.sample(v, at: CGPoint(x: 160, y: 90))
                        if !PixelProbe.matches(mid, Theme.background) { p.append("the pane's inside is \(hex(mid)), want untouched \(hex(Theme.background))") }
                        return p.map { "\(theme) \(state.name): \($0)" }
                    } }
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        // A window-backed pane's offscreen render leaves out its sublayers (a detached one, above,
        // includes them), so the live ring is checked by its layer: the path the step above
        // rendered, at the pane's size, in the state's color.
        t.step("pane ring: a live waiting pane's ring is that dashed path, fitted to its frame", nil, {
            guard let a = pane("rg-a") else { return all(["no test pane"]) }
            let v = a.view
            let ring = ringLayer(v) as? CAShapeLayer
            let box = ring?.path?.boundingBox ?? .null
            return all([ring != nil ? nil : "no dashed (shape) ring on the pane",
                        ring?.frame == v.bounds ? nil : "ring frame \(ring.map { NSStringFromRect($0.frame) } ?? "nil") ≠ pane bounds \(NSStringFromRect(v.bounds))",
                        ring?.path == AttentionStyle.dashedRing(in: v.bounds, lineWidth: PaneView.ringWidth) ? nil : "the ring isn't the dashed path for the pane's size",
                        box.insetBy(dx: -PaneView.ringWidth / 2, dy: -PaneView.ringWidth / 2).equalTo(v.bounds) ? nil : "ring path \(NSStringFromRect(box)) doesn't fit the pane",
                        ring?.lineWidth == PaneView.ringWidth && ring?.fillColor == nil ? nil : "the ring should be a \(PaneView.ringWidth)pt stroke, unfilled",
                        PixelProbe.matches(v.attentionRingColor, Theme.attentionWaiting) ? nil : "ring is \(hex(v.attentionRingColor)), want \(hex(Theme.attentionWaiting))",
                        ring?.opacity == 1 ? nil : "ring opacity \(ring?.opacity ?? -1)"])
        }) {
            created(call("create", ["type": "workspace", "target": "focused", "name": "ring"]), "rg-home")
            created(call("create", ["type": "pane", "focus": false], caller: "rg-home"), "rg-a")
            if let ws = self.workspaces.first(where: { $0.name == "ring" }) { self.activate(ws) }
            if let a = pane("rg-a") { self.setAttention(.waiting, on: a) }
            self.layoutNow()
        }

        var before: CGPath?
        t.step("pane ring: a resize refits the dashes; during layout motion the ring holds still at its final path", nil, {
            guard let a = pane("rg-a"), let ring = ringLayer(a.view) as? CAShapeLayer, let path = ring.path else { return all(["no ring"]) }
            let want = AttentionStyle.dashedRing(in: a.view.bounds, lineWidth: PaneView.ringWidth)
            let moving = LayoutAnimation.isAnimating(in: self.contentView)
            let still = ring.animationKeys() ?? []
            return all([moving ? nil : "the split should be animating (so the check means something)",
                        path == want ? nil : "the ring's path isn't the one for the pane's final size \(NSStringFromSize(a.view.bounds.size))",
                        before.map { $0 != path } ?? true ? nil : "the path should have been rebuilt for the new size",
                        still.isEmpty ? nil : "the ring layer animates (\(still)); its dashes would crawl",
                        SelfTest.waitUntil("the layout motion to end") { !LayoutAnimation.isAnimating(in: self.contentView) },
                        ring.path === path ? nil : "the path changed during the motion"])
        }) {
            LayoutAnimation.enabled = true
            AttentionFade.reduceMotionOverride = false
            guard let a = pane("rg-a") else { return }
            before = (ringLayer(a.view) as? CAShapeLayer)?.path
            self.split(a, side: .bottom)
            t.named(self.focusedPane, "rg-b")
        }

        t.step("pane ring: fading out (#34) changes only its opacity; the dashes don't move", nil, {
            guard let a = pane("rg-a"), let ring = ringLayer(a.view) as? CAShapeLayer else { return all(["no ring at the start of the fade"]) }
            let path = ring.path
            SelfTest.waitUntil(timeout: AttentionFade.duration * 0.45) { false }  // mid-fade (real time, as SelfTestFade)
            let mid = ring.opacity
            let midPath = ring.path
            let gone = SelfTest.waitUntil("the ring to fade out", timeout: AttentionFade.duration * 1.5) { ringLayer(a.view) == nil }
            return all([mid > 0.05 && mid < 0.95 ? nil : "mid-fade opacity \(mid)",
                        midPath === path ? nil : "the path changed mid-fade",
                        gone])
        }) {
            LayoutAnimation.enabled = false
            AttentionFade.enabled = true
            SelfTest.waitUntil(timeout: 1) { AttentionFade.timing().hold == 0 }
            if let a = pane("rg-a") { self.setAttention(.none, on: a) }
        }

        t.step("pane ring: clean up", nil, {
            all([self.workspaces.contains { $0.name == "ring" } ? "the test workspace should be gone" : nil])
        }) {
            AttentionFade.enabled = false
            AttentionFade.reduceMotionOverride = nil
            LayoutAnimation.enabled = false
            if let w = self.workspaces.first(where: { $0.name == "ring" }) { self.remove(workspace: w) }
            self.layoutNow()
            lastError = nil
        }
    }
}
