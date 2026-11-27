import AppKit

// MARK: - Self-test section: close questions hang from what they close

extension TerminalWindowController {
    func confirmPopoverSelfTestSteps(_ t: SelfTestKit) {
        var tab: Tab?
        var ran = false
        var cancelled = false

        /// Asks about closing `tab` for real (not auto-accepted), anchored to its button.
        func ask(_ anchor: ConfirmAnchor?) {
            ran = false
            cancelled = false
            Confirmation.asksForTest = true
            defer { Confirmation.asksForTest = false }
            confirm("Close this tab?", info: "Self-test.", accept: "Close Tab", anchor: anchor,
                    then: { ran = true }, otherwise: { cancelled = true })
        }
        func shownProblem(from view: NSView?) -> String? {
            guard let p = confirmPopover else { return "no popover (sheet: \(window?.attachedSheet != nil))" }
            if let view, p.anchorView !== view {
                return "it should hang from \(type(of: view)), not \(p.anchorView.map { "\(type(of: $0))" } ?? "nil")"
            }
            return p.popover.isShown ? nil : "the popover should be shown"
        }

        t.step("close popover: a pane, a tab and a workspace each have an anchor", nil, {
            guard let tab, let deck = self.deck(of: tab) else { return "no tab" }
            let a = t.pane("cpa"), b = t.pane("cpb")
            let button = deck.view.strip.buttons.first { $0.tab === tab }
            let problems = [
                self.confirmAnchor(pane: a)?.view === a.view.bar ? nil : "a pane with a bar hangs from it",
                self.confirmAnchor(tab: tab)?.view === button ? nil : "a tab hangs from its button",
                self.confirmAnchor(workspace: self.activeWorkspace) != nil || !self.isSidebarVisible && !self.showsTitlebarSwitcher
                    ? nil : "the active workspace's switcher entry should be an anchor",
            ]
            // A lone pane (no bar) hangs from its own top edge.
            self.remove(b)
            self.layoutNow()
            let lone = self.confirmAnchor(pane: a)?.view === a.view ? nil : "a pane without a bar hangs from itself"
            let all = (problems + [lone]).compactMap { $0 }
            return all.isEmpty ? nil : all.joined(separator: "; ")
        }) {
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "cpa")
            tab = deck.activeTab
            self.split(t.pane("cpa"), side: .right)
            t.named(self.focusedPane, "cpb")
            self.layoutNow()
        }

        t.step("close popover: a tab's question hangs from its button; Cancel keeps the tab", nil, {
            guard let tab else { return "no tab" }
            let button = self.deck(of: tab)?.view.strip.buttons.first { $0.tab === tab }
            if let p = shownProblem(from: button) { return p }
            if !(SelfTest.openModal()?.contains("Close this tab?") ?? false) { return "the per-step guard should see it" }
            self.confirmPopover?.cancelButton.performClick(nil)
            let gone = SelfTest.waitUntil(timeout: 2) { self.confirmPopover == nil }
            let problems = [cancelled && !ran ? nil : "Cancel should run only `otherwise` (ran \(ran), cancelled \(cancelled))",
                            gone ? nil : "the popover should close",
                            self.deck(of: tab) != nil ? nil : "the tab should stay"]
            return problems.compactMap { $0 }.joined(separator: "; ").nilIfEmpty
        }) {
            ask(tab.flatMap { self.confirmAnchor(tab: $0) })
        }

        /// A key press as AppKit delivers it, addressed to the terminal's window: the popover
        /// doesn't always take the keys, and return still has to answer it.
        func press(_ chars: String, keyCode: UInt16, _ mods: NSEvent.ModifierFlags = []) -> Bool {
            guard let w = self.window,
                  let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                             windowNumber: w.windowNumber, context: nil, characters: chars,
                                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { return false }
            NSApp.sendEvent(key)
            return true
        }

        t.step("close popover: return accepts, running the close", nil, {
            if let p = shownProblem(from: nil) { return p }
            if !press("\r", keyCode: 36) { return "no window" }
            let gone = SelfTest.waitUntil(timeout: 2) { self.confirmPopover == nil }
            return ran && !cancelled && gone ? nil : "return should run the action and close (ran \(ran), closed \(gone))"
        }) {
            ask(tab.flatMap { self.confirmAnchor(tab: $0) })
        }

        t.step("close popover: esc and ⌃[ cancel", nil, {
            var problems: [String] = []
            for (name, chars, code, mods) in [("esc", "\u{1b}", UInt16(53), NSEvent.ModifierFlags()),
                                              ("⌃[", "\u{1b}", UInt16(33), NSEvent.ModifierFlags.control)] {
                ask(tab.flatMap { self.confirmAnchor(tab: $0) })
                if let p = shownProblem(from: nil) { problems.append("\(name): \(p)"); continue }
                _ = press(chars, keyCode: code, mods)
                let gone = SelfTest.waitUntil(timeout: 2) { self.confirmPopover == nil }
                if !(cancelled && !ran && gone) { problems.append("\(name) should cancel (ran \(ran), cancelled \(cancelled), closed \(gone))") }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            tab = deck.activeTab
            self.layoutNow()
        }

        t.step("close popover: it cancels itself when what it asks about goes away", nil, {
            let gone = SelfTest.waitUntil(timeout: 2) { self.confirmPopover == nil }
            return cancelled && !ran && gone ? nil : "closing the tab elsewhere should cancel the question (cancelled \(cancelled), closed \(gone))"
        }) {
            ask(tab.flatMap { self.confirmAnchor(tab: $0) })
            if let tab { self.remove(tab: tab) }
        }

        t.step("close popover: no anchor falls back to a sheet", nil, {
            let sheet = self.window?.attachedSheet != nil && self.confirmPopover == nil
            SelfTest.dismissModals()
            return sheet ? nil : "with no anchor the question should be a sheet"
        }) {
            ask(nil)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
