import AppKit

// MARK: - Self-test section: the drop preview settles onto the moved content (issue #28)

extension TerminalWindowController {
    func dragSettleSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        var tab: Tab?
        var surfaceFrames: [CGRect] = []
        func frames() -> [CGRect] { tab?.panes.map { $0.surface.frame } ?? [] }
        let hl = contentView.dropHighlight

        t.step("drop settle: a real pane drag onto another pane's centre swaps them and the preview settles", nil, {
            guard let a = t.pane("dsA").view.superview == nil ? nil : self.locate(t.pane("dsA"))?.node,
                  let landed = self.frame(of: a) else { return "dsA isn't on screen" }
            surfaceFrames = frames()
            return all(tab?.panes.first === t.pane("dsB") ? nil : "the panes should have swapped",
                       hl.isHidden ? "the preview should still be settling, not hidden at once" : nil,
                       hl.settleTarget == landed ? nil : "settle target \(String(describing: hl.settleTarget)) should be dsA's new frame \(landed)")
        }) {
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "dsA")
            tab = self.focusedDeck?.activeTab
            self.split(t.pane("dsA"), side: .right)
            t.named(self.focusedPane, "dsB")
            self.layoutNow()
            let bar = t.pane("dsA").view.bar
            let from = bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
            self.dragControllerForTest(.pane(t.pane("dsA")), from: from, to: t.pane("dsB").view)
        }
        t.step("drop settle: the preview is gone afterwards, and the terminals weren't resized while it ran", nil, {
            all(hl.isHidden ? nil : "the preview should have faded out",
                frames() == surfaceFrames ? nil : "surface frames changed after the drop: \(surfaceFrames) → \(frames())")
        }) {}
        t.step("drop settle: a drop with no target leaves no preview behind", nil, {
            hl.isHidden ? nil : "no preview should show"
        }) {
            // Release over the pane's own bar: a pane can't drop onto itself.
            let bar = t.pane("dsA").view.bar
            let p = bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
            self.dragControllerForTest(.pane(t.pane("dsA")), from: CGPoint(x: p.x - 30, y: p.y), to: bar)
        }
        t.step("drop settle: clean up", nil, { tab.flatMap { self.deck(of: $0) } == nil ? nil : "test tab should be closed" }) {
            if let tab { self.close(tab: tab) }
        }
    }
}
