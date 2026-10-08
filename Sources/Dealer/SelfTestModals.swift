import AppKit
import GhosttyKit

// MARK: - Self-test section: no modal dialogs in self-test mode (issue #38)

extension TerminalWindowController {
    func modalsSelfTestSteps(_ t: SelfTestKit) {
        func wait(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !cond() && Date() < end {
                GhosttyRuntime.shared.tick()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return cond()
        }
        var ran = false
        var before = 0
        var busy = false
        var live = false

        t.step("modals: a close confirmation is accepted and logged, not shown", nil, {
            let problems = [ran ? nil : "the confirmed action should run at once",
                            SelfTest.openModal().map { "no sheet expected, found \($0)" },
                            Confirmation.autoAccepted.count == before + 1 ? nil : "should be logged as auto-accepted"]
                .compactMap { $0 }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {
            before = Confirmation.autoAccepted.count
            self.confirm("Close this test?", info: "Self-test.") { ran = true }
        }

        t.step("modals: the per-step guard finds a sheet, names it, and clears it", nil, {
            guard let window = self.window else { return "no window" }
            let alert = NSAlert()
            alert.messageText = "Guard probe"
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in }
            _ = wait(2) { window.attachedSheet != nil }
            let found = SelfTest.openModal()
            SelfTest.dismissModals()
            let gone = wait(2) { SelfTest.openModal() == nil }
            if !(found?.contains("Guard probe") ?? false) { return "guard should name the sheet, got \(found ?? "nil")" }
            return gone ? nil : "dismissModals should clear it, still \(SelfTest.openModal() ?? "?")"
        }) {}

        t.step("modals: a pane running a command reads as busy", nil, {
            guard live else {
                print("      (skipped: ghostty couldn't create terminal surfaces here)")
                return nil
            }
            // Busy *because `sleep` runs*: while the shell is still starting, ghostty also reads
            // it as busy, and between the first prompt and the typed command it briefly isn't, so
            // a close then wouldn't ask (that made the next step flaky).
            busy = wait(15) {
                guard let s = t.pane("mb").surface.surface, t.pane("mb").surface.needsConfirmQuit else { return false }
                let pid = Int32(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
                return pid > 0 && ProcessTree.arguments(of: pid)?.first.map { ($0 as NSString).lastPathComponent } == "sleep"
            }
            return busy ? nil : "`sleep 30` should make the pane busy"
        }) {
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "mb")
            live = t.pane("mb").surface.surface != nil
            t.pane("mb").surface.typeText("sleep 30\r")
        }

        t.step("modals: closing a busy pane closes it without a sheet (#38)", nil, {
            let problems = [self.locate(t.pane("mb")) == nil ? nil : "mb should be closed",
                            SelfTest.openModal().map { "no sheet expected, found \($0)" },
                            !busy || Confirmation.autoAccepted.last == "Close this pane?" ? nil
                                : "the busy close should be logged as auto-accepted"]
                .compactMap { $0 }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {
            self.close(pane: t.pane("mb"))
        }
    }
}
