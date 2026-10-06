import AppKit

// MARK: - Self-test section: hover-only close button on the pane bar (issue #24)

extension TerminalWindowController {
    func paneCloseSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func bar(_ n: String) -> PaneBarView { t.pane(n).view.bar }
        var tab: Tab?
        func tabShape() -> String {
            guard let tab else { return "<no tab>" }
            func d(_ n: Node<Pane>) -> String {
                if let p = n.leaf { return t.name(p) }
                return "\(n.axis == .row ? "Row" : "Col")(\(d(n.a!)), \(d(n.b!)))"
            }
            return d(tab.root)
        }

        t.step("pane close: a split tab shows bars, and their × is hidden until hover", nil, {
            all(bar("pcA").isHidden ? "pcA's bar should show" : nil,
                bar("pcB").closeButton.isHidden ? nil : "pcB's × should be hidden without hover",
                bar("pcA").closeButton.isHidden ? nil : "pcA's × should be hidden without hover")
        }) {
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "pcA")
            tab = self.focusedDeck?.activeTab
            self.split(t.pane("pcA"), side: .right)
            t.named(self.focusedPane, "pcB")
            self.layoutNow()
        }
        t.step("pane close: hovering a bar shows its × only; the status line makes room", nil, {
            let b = bar("pcB")
            let center = CGPoint(x: b.bounds.midX, y: b.bounds.midY)
            let cb = b.closeButton
            guard let sv = b.superview else { return "pcB's bar has no superview" }
            let hitBar = b.hitTest(b.convert(center, to: sv))
            let hitClose = b.hitTest(cb.convert(CGPoint(x: cb.bounds.midX, y: cb.bounds.midY), to: sv))
            return all(cb.isHidden ? "pcB's × should show on hover" : nil,
                       bar("pcA").closeButton.isHidden ? nil : "pcA's × should stay hidden",
                       cb.frame.maxX <= b.bounds.maxX && cb.frame.minY >= 0 && cb.frame.maxY <= b.bounds.maxY ? nil : "× \(cb.frame) outside bar \(b.bounds)",
                       b.statusTrailing >= b.bounds.maxX - cb.frame.minX ? nil : "status line would run under the ×",
                       hitBar === b ? nil : "the bar's middle should still be the drag handle",
                       hitClose === cb ? nil : "the × should take its own clicks")
        }) {
            bar("pcB").setHoveringForTest(true)
        }
        t.step("pane close: leaving the bar hides the × again", nil, {
            bar("pcB").closeButton.isHidden ? nil : "× should hide on mouse exit"
        }) {
            bar("pcB").setHoveringForTest(false)
        }
        t.step("pane close: clicking the × closes that pane (like ⌘W)", nil, {
            all(self.locate(t.pane("pcB")) == nil ? nil : "pcB should be gone",
                tabShape() == "pcA" ? nil : "tab should be just pcA, is \(tabShape())",
                self.focusedPane === t.pane("pcA") ? nil : "focus should move to pcA")
        }) {
            bar("pcB").setHoveringForTest(true)
            self.clickForTest(bar("pcB").closeButton)
        }
        t.step("pane close: split again for the middle-click (its shell gets a moment to start)", nil, {
            tabShape() == "Row(pcA, pcC)" ? nil : "expected Row(pcA, pcC), got \(tabShape())"
        }) {
            self.split(t.pane("pcA"), side: .right)
            t.named(self.focusedPane, "pcC")
            self.layoutNow()
        }
        t.step("pane close: middle-clicking a pane bar closes that pane, without starting a drag (#37)", nil, {
            all(self.locate(t.pane("pcC")) == nil ? nil : "pcC should be gone",
                tabShape() == "pcA" ? nil : "tab should be back to just pcA, is \(tabShape())",
                self.contentView.ghost.isHidden ? nil : "a middle-click must not start a pane drag")
        }) {
            guard let window = self.window else { return }
            let bar = t.pane("pcC").view.bar
            let p = bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
            // NSEvent.mouseEvent can't set a button number (it comes out 0), so build the middle-button
            // events with CGEvent. A window-less NSEvent reports its (flipped) CG location as
            // locationInWindow, so place it where that equals the bar's window point, then route it
            // through the window like any click.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let global = CGPoint(x: p.x, y: mainHeight - p.y)
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global, mouseButton: .center) else { continue }
                if let e = NSEvent(cgEvent: cg), e.buttonNumber == 2, abs(e.locationInWindow.x - p.x) < 1, abs(e.locationInWindow.y - p.y) < 1 {
                    window.sendEvent(e)
                }
            }
        }
        t.step("pane close: clean up the test tab", nil, {
            tab.flatMap { self.deck(of: $0) } == nil ? nil : "test tab should be closed"
        }) {
            if let tab { self.close(tab: tab) }
        }
    }
}
