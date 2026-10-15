import AppKit

// MARK: - Self-test section: Go to Pane, ⇧⌘A (#66)
//
// Two windows with known pane titles. The panel opens through the ⇧⌘A key equivalent the way a
// key press travels (`pressMenuKeyForTest`), queries are typed into its field editor, and ↑/↓,
// return and esc go through the field's command dispatch. Real key presses aren't covered.

extension TerminalWindowController {
    func paneSearchSelfTestSteps(_ t: SelfTestKit) {
        let picker = PanePicker.shared
        weak var other: TerminalWindowController?
        var alpha: Workspace?
        var opened: String?
        var claude: [String] = [], db: [String] = [], byTab: [String] = [], byWorkspace: [String] = [], scattered: [String] = []
        var moved = -1

        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func titles(_ n: Int? = nil) -> [String] {
            let ps = picker.entries.map(\.pane.title).filter { $0.hasPrefix("ps-") }
            return n.map { Array(ps.prefix($0)) } ?? ps
        }
        func expect(_ got: [String], _ want: [String], _ what: String) -> String? {
            got == want ? nil : "\(what): expected \(want), got \(got)"
        }
        /// Types into the panel's field editor, replacing what's there.
        func type(_ s: String) {
            guard let editor = picker.field.currentEditor() as? NSTextView else { picker.query = s; return }
            editor.selectAll(nil)
            editor.insertText(s, replacementRange: editor.selectedRange())
        }
        func command(_ sel: Selector) {
            if let editor = picker.field.currentEditor() as? NSTextView { editor.doCommand(by: sel) }
        }
        func openWithKey() {
            let surface = (self.focusedPane ?? t.pane("ps-server")).surface
            opened = self.pressMenuKeyForTest("a", [.command, .shift], keyCode: 0, surface: surface)
                ? nil : "⇧⌘A should match an enabled Go to Pane… item (\(Self.menuKeyFailure))"
        }
        func frontmost(_ wc: TerminalWindowController?) -> Bool {
            guard let w = wc?.window else { return false }
            return NSApp.keyWindow === w || NSApp.orderedWindows.first === w
        }

        t.step("pane search: panes titled across two windows, workspaces and tabs", nil, {
            all(alpha == nil ? "no ps-alpha workspace" : nil, other == nil ? "no second window" : nil)
        }) {
            // This window: workspace ps-alpha = [ps-server | ps-claude-main], plus a tab "ps-api" holding ps-db.
            let ws = self.newWorkspace(name: "ps-alpha")
            alpha = ws
            t.named(self.focusedPane, "ps-server")
            self.focusedPane?.customTitle = "ps-server"
            if let p = self.focusedPane { self.split(p, side: .right) }
            t.named(self.focusedPane, "ps-claude-main")
            self.focusedPane?.customTitle = "ps-claude-main"
            if let deck = self.focusedDeck { self.newTab(in: deck) }
            t.named(self.focusedPane, "ps-db")
            self.focusedPane?.customTitle = "ps-db"
            self.focusedDeck?.activeTab?.customTitle = "ps-api"
            // A second window: its second workspace "ps-beta-db" holds ps-claude-other.
            AppDelegate.shared.newWindow(nil)
            guard let wc = AppDelegate.shared.windowControllers.last, wc !== self else { return }
            other = wc
            wc.window?.animationBehavior = .none
            let beta = wc.newWorkspace(name: "ps-beta-db")
            t.named(wc.focusedPane, "ps-claude-other")
            wc.focusedPane?.customTitle = "ps-claude-other"
            // Focus order, oldest first: db, claude-main, claude-other, then server (this window).
            self.focus(t.pane("ps-db"))
            self.focus(t.pane("ps-claude-main"))
            wc.focus(t.pane("ps-claude-other"))
            wc.activateWorkspace(index: 0)  // ps-beta goes to the background
            _ = beta
            self.window?.makeKeyAndOrderFront(nil)
            self.focus(t.pane("ps-server"))
        }

        t.step("pane search: ⇧⌘A opens the panel; the empty query lists most recently focused first, this pane last", nil, {
            let plainA = Self.keyedMenuItems().filter { $0.keyEquivalent.lowercased() == "a" && Self.effectiveModifiers($0) == .command }.map(\.title)
            return all(opened, plainA == ["Select All"] ? nil : "plain ⌘A should be only Select All, is \(plainA)",
                picker.isOpen && picker.window === self.window ? nil : "the panel should be open in this window",
                picker.field.currentEditor() != nil ? nil : "the field should have focus",
                expect(titles(3), ["ps-claude-other", "ps-claude-main", "ps-db"], "most recent first"),
                picker.entries.last?.pane === t.pane("ps-server") ? nil : "the focused pane should come last",
                picker.entries.first?.window == "Window 2" ? nil : "a pane in the other window should say so (\(picker.entries.first?.window ?? "nil"))")
        }) {
            openWithKey()
        }

        t.step("pane search: a query matches titles first, then tab and workspace names", nil, {
            all(expect(claude, ["ps-claude-other", "ps-claude-main"], "\"claude\""),
                expect(db, ["ps-db", "ps-claude-other"], "\"db\" (a title match before a more recent workspace match)"),
                expect(byTab, ["ps-db"], "\"psapi\" (the tab's name)"),
                expect(byWorkspace, ["ps-claude-other"], "\"psbeta\" (the workspace's name)"),
                expect(scattered, ["ps-claude-main", "ps-db", "ps-server"], "\"pslph\" (scattered over ps-alpha, this pane last)"))
        }) {
            type("claude"); claude = titles()
            type("db"); db = titles()
            type("psapi"); byTab = titles()
            type("psbeta"); byWorkspace = titles()
            type("pslph"); scattered = titles()
        }

        t.step("pane search: ↓/↑ move the selection and return focuses that pane in its window and workspace", nil, {
            guard let wc = other else { return "no second window" }
            return all(!picker.isOpen ? nil : "the panel should close on pick",
                       moved == 1 ? nil : "↓ should select the second row (\(moved))",
                       wc.focusedPane === t.pane("ps-claude-other") ? nil : "ps-claude-other should be focused",
                       wc.activeWorkspace.name == "ps-beta-db" ? nil : "ps-beta-db should be the selected workspace",
                       frontmost(wc) ? nil : "the second window should be raised")
        }) {
            type("claude")
            command(#selector(NSResponder.moveDown(_:)))
            moved = picker.selectedIndex
            command(#selector(NSResponder.moveUp(_:)))
            command(#selector(NSResponder.insertNewline(_:)))
        }

        t.step("pane search: picking a pane in a background tab selects that tab", nil, {
            guard let deck = alpha?.decks.first else { return "no ps-alpha deck" }
            return all(self.focusedPane === t.pane("ps-db") ? nil : "ps-db should be focused",
                       self.activeWorkspace === alpha ? nil : "ps-alpha should be selected",
                       deck.activeTab?.customTitle == "ps-api" ? nil : "the ps-api tab should be active",
                       frontmost(self) ? nil : "this window should be raised")
        }) {
            self.window?.makeKeyAndOrderFront(nil)
            self.focus(t.pane("ps-server"))
            openWithKey()
            type("ps-db")
            command(#selector(NSResponder.insertNewline(_:)))
        }

        t.step("pane search: esc dismisses the panel and gives focus back to the pane", nil, {
            all(opened, !picker.isOpen ? nil : "esc should close the panel",
                self.window?.firstResponder === t.pane("ps-db").surface ? nil : "focus should be back on ps-db")
        }) {
            openWithKey()
            type("zzz")
            command(#selector(NSResponder.cancelOperation(_:)))
        }

        t.step("pane search: clean up", nil, {
            all(other == nil || other?.window?.isVisible == false ? nil : "second window still open",
                self.workspaces.contains { $0.name == "ps-alpha" } ? "ps-alpha still there" : nil)
        }) {
            picker.close(restoreFocus: false)
            other?.window?.close()
            if let alpha { self.remove(workspace: alpha) }
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
}
