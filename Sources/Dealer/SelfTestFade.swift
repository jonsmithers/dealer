import AppKit

// MARK: - Self-test section: attention fades out instead of vanishing (issue #34)

extension TerminalWindowController {
    func fadeSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func spin(_ secs: TimeInterval) {
            let end = Date().addingTimeInterval(secs)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func ring(_ p: Pane) -> CALayer? { p.view.layer?.sublayers?.first { $0.name == "dealer.attentionRing" } }
        func tabButton(_ p: Pane) -> TabButton? {
            guard let loc = locate(p), let i = loc.deck.index(of: loc.tab),
                  loc.deck.view.strip.buttons.indices.contains(i) else { return nil }
            return loc.deck.view.strip.buttons[i]
        }
        func opacity(_ p: Pane) -> Float? { ring(p)?.opacity }
        var target: Pane?, home: Pane?

        t.step("fade: clearing changes the model at once; the ring and tab outline linger, fade, then go", nil, {
            guard let p = target, let btn = tabButton(p) else { return "no unfocused pane" }
            // Right after the clear (same step, no pause).
            let atOnce = all(p.attention == .none ? nil : "model should be none at once, is \(p.attention.name)",
                             self.locate(p)?.workspace.attention == Attention.none ? nil : "workspace roll-up should be none at once",
                             TerminalWindowController.nextUnread(after: self.focusedPane) == nil ? nil : "⌘⇧U should see nothing",
                             ring(p) != nil ? nil : "the ring should still be there",
                             btn.attentionFade.isFading && btn.attentionFade.shown == .failed ? nil : "the tab should be fading out failed",
                             {
                                 // The workspace's switcher entry, when the sidebar or pills are showing.
                                 let i = self.workspaces.firstIndex { $0 === self.activeWorkspace } ?? 0
                                 let entry = (self.workspaceSidebar.row(at: i) as? WorkspaceRow)?.attentionFade
                                     ?? (self.workspaceBar.button(at: i) as? WorkspaceButton)?.attentionFade
                                 guard let entry else { return nil }
                                 return entry.isFading && entry.shown == .failed ? nil : "the workspace entry should be fading out failed"
                             }())
            // Mid-fade.
            spin(AttentionFade.duration * 0.45)
            let o = opacity(p), a = btn.attentionFade.alpha
            let mid = all(o.map { $0 > 0.05 && $0 < 0.95 } == true ? nil : "mid-fade ring opacity \(o.map { String($0) } ?? "gone")",
                          a > 0.05 && a < 0.95 ? nil : "mid-fade tab alpha \(a)",
                          {
                              // An inactive tab has no fill, so a half-faded stroke keeps red RGB; its alpha drops.
                              let px = PixelProbe.sample(btn, at: PixelProbe.outlinePoint(in: btn))
                              let solid = PixelProbe.matches(px, Theme.attentionFailed) && (px?.alphaComponent ?? 0) > 0.98
                              return solid ? "a fading outline shouldn't be solid red (alpha \(px?.alphaComponent ?? -1))" : nil
                          }())
            // After.
            spin(AttentionFade.duration * 0.8)
            let after = all(ring(p) == nil ? nil : "ring should be gone after the fade",
                            !btn.attentionFade.isFading && btn.attentionFade.shown == .none ? nil : "tab should be done fading",
                            !PixelProbe.isFailedOutlined(btn) ? nil : "tab still red")
            return all(atOnce, mid, after)
        }) {
            AttentionFade.enabled = true
            AttentionFade.reduceMotionOverride = false
            home = self.focusedPane
            target = self.allPanes.first { $0 !== home && self.locate($0)?.workspace === self.activeWorkspace }
            guard let p = target else { return }
            self.setAttention(.failed, on: p)
            self.setAttention(.none, on: p)
        }

        t.step("fade: a re-raise mid-fade cancels it and shows the new state solidly", nil, {
            guard let p = target, let btn = tabButton(p) else { return "setup failed" }
            return all(opacity(p) == 1 ? nil : "ring opacity should be 1, is \(opacity(p).map { String($0) } ?? "gone")",
                       PixelProbe.matches(ring(p)?.borderColor.flatMap { NSColor(cgColor: $0) }, Theme.attentionWaiting) ? nil : "ring should be waiting blue",
                       !btn.attentionFade.isFading ? nil : "the fade should be cancelled",
                       PixelProbe.isWaitingOutlined(btn) ? nil : "tab outline should be solid blue")
        }) {
            guard let p = target else { return }
            self.setAttention(.failed, on: p)
            self.setAttention(.none, on: p)
            spin(AttentionFade.duration * 0.3)
            self.setAttention(.waiting, on: p)
        }

        t.step("fade: with Reduce Motion the state disappears at once", nil, {
            guard let p = target, let btn = tabButton(p) else { return "setup failed" }
            return all(ring(p) == nil ? nil : "ring should be gone at once",
                       !btn.attentionFade.isFading ? nil : "no fade with Reduce Motion",
                       !PixelProbe.isWaitingOutlined(btn) ? nil : "tab outline should be gone at once")
        }) {
            AttentionFade.reduceMotionOverride = true
            if let p = target { self.setAttention(.none, on: p) }
        }

        t.step("fade: arriving via ⌘⇧U holds the color solid first, then fades", nil, {
            guard let p = target else { return "setup failed" }
            spin(AttentionFade.revealHold * 0.6)
            let held = opacity(p)
            spin(AttentionFade.revealHold * 0.4 + AttentionFade.duration * 0.5)
            let fading = opacity(p)
            spin(AttentionFade.duration)
            return all(self.focusedPane === p ? nil : "⌘⇧U should have focused the pane",
                       p.attention == .none ? nil : "focus should clear the model at once",
                       held == 1 ? nil : "during the hold the ring should be solid, opacity \(held.map { String($0) } ?? "gone")",
                       fading.map { $0 > 0 && $0 < 1 } == true ? nil : "after the hold it should fade, opacity \(fading.map { String($0) } ?? "gone")",
                       ring(p) == nil ? nil : "and then be gone")
        }) {
            AttentionFade.reduceMotionOverride = false
            guard let p = target else { return }
            self.setAttention(.failed, on: p)
            self.jumpToNextUnread(nil)
        }

        t.step("fade: a recycled view that now shows something else doesn't fade", nil, {
            let s = AttentionFadeState()
            let a = NSObject(), b = NSObject()
            s.set(.failed, subject: a)
            s.set(.none, subject: b)
            let recycled = !s.isFading && s.shown == .none
            s.set(.waiting, subject: b)
            s.set(.none, subject: b)
            let same = s.isFading && s.shown == .waiting
            s.set(.done, subject: b)
            return all(recycled ? nil : "a new subject must jump, not fade",
                       same ? nil : "the same subject clearing must fade",
                       !s.isFading && s.shown == .done ? nil : "a raise must cancel the fade")
        }) {}

        t.step("fade: clean up", nil, {
            AttentionFade.enabled ? "fades should be off again in the self-test" : nil
        }) {
            AttentionFade.enabled = false
            AttentionFade.reduceMotionOverride = nil
            if let home { self.focus(home) }
        }
    }
}
