import AppKit
import Carbon.HIToolbox

// MARK: - Self-test section: find in pane (#49)

extension TerminalWindowController {
    func searchSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        // Never the user's system find pasteboard.
        PaneSearchBar.findPasteboard = NSPasteboard(name: NSPasteboard.Name("dealer-selftest-find-\(ProcessInfo.processInfo.processIdentifier)"))
        PaneSearchBar.findPasteboard.clearContents()

        var pane: Pane?
        var live: Bool { pane?.surface.surface != nil }
        var bar: PaneSearchBar? { pane?.view.searchBar }
        func skipped(_ what: String) -> String? {
            print("      (skipped \(what): ghostty couldn't create terminal surfaces here)")
            return nil
        }
        var problem: String?

        t.step("find: Edit has Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection ⌘E, each on one item", nil, {
            let items = Self.keyedMenuItems()
            func owner(_ key: String, _ mods: NSEvent.ModifierFlags) -> [String] {
                items.filter { $0.keyEquivalent.lowercased() == key && Self.effectiveModifiers($0) == mods }.map(\.title)
            }
            return all(owner("f", .command) == ["Find…"] ? nil : "⌘F: \(owner("f", .command))",
                       owner("g", .command) == ["Find Next"] ? nil : "⌘G: \(owner("g", .command))",
                       owner("g", [.command, .shift]) == ["Find Previous"] ? nil : "⇧⌘G: \(owner("g", [.command, .shift]))",
                       owner("e", .command) == ["Use Selection for Find"] ? nil : "⌘E: \(owner("e", .command))",
                       owner("f", [.command, .shift]) == ["Fold Deck"] ? nil : "⇧⌘F should stay Fold Deck: \(owner("f", [.command, .shift]))")
        }) {}

        t.step("find: ⌘F in a pane opens its find bar with the field focused", nil, {
            if let problem { return problem }
            guard live else { return skipped("the find bar (ghostty answers ⌘F with START_SEARCH)") }
            return SelfTest.waitUntil("the find bar to open with focus") {
                guard let bar, bar.superview != nil, let fr = self.window?.firstResponder as? NSView else { return false }
                return fr.isDescendant(of: bar.field) || fr === bar.field.currentEditor()
            }
        }) {
            guard let deck = self.focusedDeck else { problem = "no deck"; return }
            self.newTab(in: deck)
            pane = self.focusedPane
            t.named(pane, "find")
            guard let pane, live else { return }
            // Output with three matches; the typed line itself has none ("zq%s").
            pane.surface.perform("text:" + ControlHandler.escapeForBinding("printf 'zq%s\\n' 49x 49x 49x\r"))
            problem = self.pressMenuKeyForTest("f", .command, keyCode: kVK_ANSI_F, surface: pane.surface)
                ? nil : "⌘F matched no enabled item: \(Self.menuKeyFailure)"
        }

        t.step("find: typing a needle reports ghostty's match count", nil, {
            guard live, let bar else { return live ? "no find bar" : skipped("match counts") }
            // Resend until the shell has printed (the search covers what's on screen when it starts).
            return SelfTest.waitUntil("3 matches for zq49x, have \(bar.total.map(String.init) ?? "none")", timeout: 10) {
                if bar.total != 3 { bar.needle = ""; bar.needle = "zq49x" }
                return bar.total == 3 || SelfTest.waitUntil(timeout: 0.3) { bar.total == 3 }
            }
        }) {
            bar?.needle = "zq49x"
        }

        var firstSelected: Int?
        t.step("find: ⌘G and ⇧⌘G move between matches while typing in the bar", nil, {
            if let problem { return problem }
            guard live, let bar else { return live ? "no find bar" : skipped("navigation") }
            if let p = SelfTest.waitUntil("a selected match after ⌘G", { bar.selected != nil }) { return p }
            firstSelected = bar.selected
            if !self.pressMenuKey("g", .command, kVK_ANSI_G, from: bar) { return "⌘G: \(Self.menuKeyFailure)" }
            if let p = SelfTest.waitUntil("⌘G to move off match \(firstSelected ?? -1)", { bar.selected != firstSelected }) { return p }
            if !self.pressMenuKey("g", [.command, .shift], kVK_ANSI_G, from: bar) { return "⇧⌘G: \(Self.menuKeyFailure)" }
            return SelfTest.waitUntil("⇧⌘G to go back to match \(firstSelected ?? -1), at \(bar.selected ?? -1)") { bar.selected == firstSelected }
        }) {
            guard let bar, live else { return }
            problem = self.pressMenuKey("g", .command, kVK_ANSI_G, from: bar) ? nil : "⌘G: \(Self.menuKeyFailure)"
        }

        t.step("find: esc with a needle returns to the terminal and keeps the bar", nil, {
            guard live, let bar, let pane else { return live ? "no find bar" : skipped("esc") }
            return all(SelfTest.waitUntil("the terminal to take focus") { self.window?.firstResponder === pane.surface },
                       bar.superview != nil ? nil : "the bar closed")
        }) {
            guard let bar else { return }
            self.window?.makeFirstResponder(bar.field)
            if let editor = bar.field.currentEditor() as? NSTextView { editor.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        }

        t.step("find: the close button ends the search and hides the bar", nil, {
            guard live, let bar, let pane else { return live ? "no find bar" : skipped("closing") }
            return all(SelfTest.waitUntil("the bar to close") { bar.superview == nil },
                       pane.view.isSearching ? "pane still searching" : nil)
        }) {
            bar?.buttons.last?.performClick(nil)
        }

        t.step("find: ⌘F again reopens with the shared needle; esc on an empty field closes it", nil, {
            if let problem { return problem }
            guard live, let pane else { return skipped("reopening") }
            return all(SelfTest.waitUntil("the bar to close") { pane.view.searchBar?.superview == nil },
                       self.window?.firstResponder === pane.surface ? nil : "focus didn't return to the terminal")
        }) {
            guard let pane, live else { return }
            guard self.pressMenuKeyForTest("f", .command, keyCode: kVK_ANSI_F, surface: pane.surface),
                  SelfTest.waitUntil({ pane.view.isSearching }), let bar = pane.view.searchBar
            else { problem = "⌘F didn't reopen the bar: \(Self.menuKeyFailure)"; return }
            if bar.needle != "zq49x" { problem = "reopened with \(bar.needle.debugDescription), want the shared \"zq49x\""; return }
            bar.needle = ""
            self.window?.makeFirstResponder(bar.field)
            if let editor = bar.field.currentEditor() as? NSTextView { editor.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        }
    }

    /// A menu key's action sent while the find bar's field has focus, resolved up the responder chain
    /// from its field editor the way AppKit routes a nil-target menu action. It must reach PaneView.
    fileprivate func pressMenuKey(_ key: String, _ mods: NSEvent.ModifierFlags, _ keyCode: Int, from bar: PaneSearchBar) -> Bool {
        guard let item = Self.keyedMenuItems().first(where: { $0.keyEquivalent.lowercased() == key && Self.effectiveModifiers($0) == mods }),
              let action = item.action
        else { Self.menuKeyFailure = "no menu item"; return false }
        window?.makeFirstResponder(bar.field)
        var r: NSResponder? = bar.field.currentEditor() ?? bar.field
        while let cur = r, !cur.responds(to: action) { r = cur.nextResponder }
        guard let handler = r as? PaneView else {
            Self.menuKeyFailure = "\(action) from the bar reached \(r.map { "\(type(of: $0))" } ?? "nothing"), not PaneView"
            return false
        }
        handler.perform(action, with: item)
        return true
    }
}
