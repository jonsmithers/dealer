import AppKit
import Carbon.HIToolbox

// MARK: - Self-test section: Go to Workspace, ⌘P (#105, TitlebarSwitcher.swift)
//
// Self-contained (`DEALER_SELFTEST_ONLY=switcher search:`). ⌘P opens the titlebar switcher's dropdown
// with a search field: under the button when it shows, else at the top center of the window. Keys
// travel the way real ones do as far as an inactive run allows: ⌘P through the window (SurfaceView
// asks the main menu first) or, from the search field, to the main menu, with the action resolved up
// the responder chain (`pressMenuKey`); typing, ⌃N/⌃P, arrows, return and esc as key events the
// window hands to the field editor, after the window and the main menu have declined them as key
// equivalents (`sendKey`). Real key presses aren't covered.

extension TerminalWindowController {
    func switcherSearchSelfTestSteps(_ t: SelfTestKit) {
        let menu = titlebarSwitcherMenu
        let button = titlebarSwitcher
        var alpha: Workspace?, bluetail: Workspace?, beta: Workspace?, api: Workspace?, gamma: Workspace?
        var savedPreference: Bool??
        var problem: String?
        weak var lone: TerminalWindowController?

        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func want<T: Equatable>(_ what: String, _ got: T, _ expected: T) -> String? {
            got == expected ? nil : "\(what) is \(got), want \(expected)"
        }
        func active(_ ws: Workspace?, _ c: TerminalWindowController? = nil) -> String? {
            let c = c ?? self
            return c.activeWorkspace === ws ? nil : "\(ws?.displayName ?? "nil") should be the active workspace, is \(c.activeWorkspace.displayName)"
        }
        /// This section's workspace rows, in the dropdown's order, by name.
        func shown(_ m: TitlebarSwitcherMenu = menu) -> [String] {
            m.rows.compactMap { $0.workspace?.displayName }.filter { $0.hasPrefix("zq-") }
        }
        func headers(_ m: TitlebarSwitcherMenu = menu) -> [String] {
            m.rows.compactMap { if case let .header(n) = $0.kind { return n }; return nil }
        }
        func highlightedName(_ m: TitlebarSwitcherMenu = menu) -> String {
            guard let h = m.highlighted else { return "nothing" }
            return h.isNewWorkspace ? "New Workspace" : h.workspace?.displayName ?? "?"
        }
        func newWorkspaceLast(_ m: TitlebarSwitcherMenu = menu) -> String? {
            m.rows.last?.isNewWorkspace == true ? nil : "New Workspace should be the last row"
        }
        func focusedOnPane(_ c: TerminalWindowController? = nil) -> String? {
            let c = c ?? self
            return c.window?.firstResponder === c.focusedPane?.surface ? nil
                : "focus should be on the active workspace's pane, is \(c.window?.firstResponder.map { "\(type(of: $0))" } ?? "nil")"
        }

        /// A key event to `c`'s window as AppKit routes one: the key window gets it through
        /// `NSApp.sendEvent`; otherwise the window, then the main menu, may take a ⌘ or ⌃ press as a
        /// key equivalent, and only then does the first responder (the field editor) get the keyDown.
        func sendKey(_ chars: String, ignoring: String? = nil, _ mods: NSEvent.ModifierFlags = [], keyCode: Int,
                     in c: TerminalWindowController? = nil) {
            guard let w = (c ?? self).window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: UInt16(keyCode))
                else { continue }
                if NSApp.keyWindow === w { NSApp.sendEvent(e); continue }
                // Only a press with ⌘ or ⌃ is offered as a key equivalent: AppKit's auto-added Emoji &
                // Symbols item ("e" + fn) would otherwise take a synthetic plain "e".
                if type == .keyDown, !mods.isDisjoint(with: [.command, .control]),
                   w.performKeyEquivalent(with: e) || NSApp.mainMenu?.performKeyEquivalent(with: e) == true { continue }
                w.sendEvent(e)
            }
        }
        let codes: [Character: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "e": kVK_ANSI_E, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
                                       "i": kVK_ANSI_I, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
                                       "q": kVK_ANSI_Q, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "z": kVK_ANSI_Z,
                                       "-": kVK_ANSI_Minus]
        /// Types `s` into whatever has the keys, a character at a time.
        func typeText(_ s: String, in c: TerminalWindowController? = nil) {
            for ch in s { sendKey(String(ch), keyCode: codes[ch] ?? kVK_ANSI_X, in: c) }
        }
        /// Backspaces the search field empty.
        func clear() {
            for _ in 0..<menu.query.count { sendKey("\u{7F}", keyCode: kVK_Delete) }
        }
        func ctrlN() { sendKey("\u{0E}", ignoring: "n", .control, keyCode: kVK_ANSI_N) }
        func ctrlP() { sendKey("\u{10}", ignoring: "p", .control, keyCode: kVK_ANSI_P) }
        func down() { sendKey("\u{F701}", [.function, .numericPad], keyCode: kVK_DownArrow) }
        func up() { sendKey("\u{F700}", [.function, .numericPad], keyCode: kVK_UpArrow) }
        func ret() { sendKey("\r", keyCode: kVK_Return) }
        func esc(in c: TerminalWindowController? = nil) { sendKey("\u{1B}", keyCode: kVK_Escape, in: c) }

        /// A menu key press from whatever has the keys in `c`'s window (a pane, or the search field),
        /// like `pressMenuKeyForTest` but without moving focus: the window (SurfaceView asks the main
        /// menu first) or else the main menu must take it, and the matched item's nil-target action is
        /// resolved from the first responder up to the window's controller, as AppKit does.
        func pressMenuKey(_ key: String, _ mods: NSEvent.ModifierFlags, keyCode: Int, in c: TerminalWindowController? = nil) -> String? {
            let c = c ?? self
            let chars = mods.contains(.shift) ? key.uppercased() : key
            guard let w = c.window,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                           keyCode: UInt16(keyCode)),
                  let item = Self.keyedMenuItems().first(where: { $0.keyEquivalent.lowercased() == key && Self.effectiveModifiers($0) == mods }),
                  let action = item.action
            else { return "no window, event or menu item for \(key)" }
            if NSApp.keyWindow === w {
                NSApp.sendEvent(e)
                return nil
            }
            guard w.performKeyEquivalent(with: e) || NSApp.mainMenu?.performKeyEquivalent(with: e) == true else {
                return "neither the window nor the main menu took the key"
            }
            var r: NSResponder? = w.firstResponder
            while let cur = r, !cur.responds(to: action) {
                r = cur === w ? (w.delegate as? NSResponder) ?? cur.nextResponder : cur.nextResponder
            }
            guard let target = r else { return "no responder for \(action)" }
            guard (target as AnyObject).validateMenuItem?(item) ?? true else { return "\(item.title) is disabled" }
            NSApp.sendAction(action, to: target, from: item)
            return nil
        }
        /// ⌘P from the focused pane.
        func cmdPFromPane(_ c: TerminalWindowController? = nil) -> String? {
            let c = c ?? self
            guard let p = c.focusedPane else { return "no focused pane" }
            c.window?.makeFirstResponder(p.surface)
            return pressMenuKey("p", .command, keyCode: kVK_ANSI_P, in: c).map { "⌘P: \($0)" }
        }
        let everything = ["zq-alpha", "zq-bluetail", "zq-beta", "zq-api-server", "zq-gamma"]

        t.step("switcher search: five workspaces, one in a group; the sidebar hidden, so the titlebar button shows", nil, {
            let order = self.workspaces.filter { $0.name?.hasPrefix("zq-") == true }.map(\.displayName)
            return all(want("order", order, everything),
                       [alpha, bluetail, beta, api].contains { $0?.group != nil } ? "only zq-gamma should be in a group" : nil,
                       gamma?.group?.name == "zq-tools" ? nil : "zq-gamma should be in zq-tools",
                       self.showsTitlebarSwitcher && !button.isHiddenOrHasHiddenAncestor ? nil : "the titlebar switcher should show",
                       active(alpha),
                       self.lastActiveWorkspace === beta ? nil
                           : "the window should record zq-beta as the previously active workspace, has \(self.lastActiveWorkspace?.displayName ?? "none")")
        }) {
            savedPreference = .some(self.sidebarPreference)
            alpha = self.newWorkspace(name: "zq-alpha"); t.named(self.focusedPane, "zqa")
            bluetail = self.newWorkspace(name: "zq-bluetail"); t.named(self.focusedPane, "zqbt")
            beta = self.newWorkspace(name: "zq-beta"); t.named(self.focusedPane, "zqb")
            api = self.newWorkspace(name: "zq-api-server"); t.named(self.focusedPane, "zqapi")
            gamma = self.newWorkspace(name: "zq-gamma"); t.named(self.focusedPane, "zqg")
            if let g = gamma { self.moveToNewGroup(g, name: "zq-tools") }
            beta.map(self.activate)
            alpha.map(self.activate)
            self.sidebarPreference = false
            self.layoutNow()
        }

        // AppKit's own matching, not the tests' (`effectiveModifiers`): Promote was declared "p" + ⇧,
        // which AppKit also matched against a plain ⌘P. Each keyed item points at a probe for the
        // duration, so nothing runs and the probe records which item the menu would send.
        t.step("switcher search: AppKit sends ⌘P to Go to Workspace… and ⇧⌘P to Promote to Deck; no item takes ⌃N or ⌃P", nil, { problem }) {
            final class Probe: NSObject {
                var got: [String] = []
                @objc func probe(_ sender: NSMenuItem) { got.append(sender.title) }
            }
            guard let w = self.window, let main = NSApp.mainMenu else { problem = "no window or menu"; return }
            let probe = Probe()
            let items = Self.keyedMenuItems()
            let saved = items.map { ($0, $0.action, $0.target) }
            items.forEach { $0.action = #selector(Probe.probe(_:)); $0.target = probe }
            defer { saved.forEach { $0.0.action = $0.1; $0.0.target = $0.2 } }
            func sends(_ mods: NSEvent.ModifierFlags, _ chars: String, _ ignoring: String) -> [String] {
                probe.got = []
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false,
                                            keyCode: UInt16(kVK_ANSI_P)) { _ = main.performKeyEquivalent(with: e) }
                return probe.got
            }
            let ctrl = items.filter { ["n", "p"].contains($0.keyEquivalent.lowercased()) && Self.effectiveModifiers($0).contains(.control) }
            problem = all(want("⌘P sends", sends(.command, "p", "p"), ["Go to Workspace…"]),
                          want("⇧⌘P sends", sends([.command, .shift], "P", "P"), ["Promote to Deck"]),
                          want("⌃N sends", sends(.control, "\u{0E}", "n"), []),
                          want("⌃P sends", sends(.control, "\u{10}", "p"), []),
                          ctrl.isEmpty ? nil : "⌃N/⌃P belong to the search field, but \(ctrl.map(\.title)) take them")
        }

        t.step("switcher search: ⌘P in a pane opens the dropdown under the button, its search field focused, on the previously active workspace", nil, {
            all(problem,
                menu.isOpen ? nil : "the dropdown should be open",
                menu.isAnchoredToButton ? nil : "it should hang from the button",
                button.isOpen ? nil : "the button should draw open",
                menu.frame.minY >= button.frame.maxY && abs(menu.frame.maxX - button.frame.maxX) < 1
                    ? nil : "the dropdown \(menu.frame) should open under the button \(button.frame), right-aligned",
                menu.fieldHasFocus ? nil : "the search field should have the keys",
                want("query", menu.query, ""),
                want("the highlight", highlightedName(), "zq-beta"),
                want("rows", shown(), everything),
                newWorkspaceLast())
        }) {
            problem = cmdPFromPane()
        }
        t.step("switcher search: return switches to it, so ⌘P then return toggles between the last two workspaces", nil, { problem }) {
            ret()
            let first = all(active(beta), menu.isOpen ? "the dropdown should close" : nil, focusedOnPane())
            problem = cmdPFromPane()
            let highlight = highlightedName()
            ret()
            problem = all(problem, first.map { "after the first return: \($0)" },
                          want("the second time, the highlight", highlight, "zq-alpha"),
                          active(alpha), menu.isOpen ? "the dropdown should close" : nil, focusedOnPane())
        }

        var typed: [String: ([String], [String], String)] = [:]
        t.step("switcher search: typing filters by name or group (subsequence) in sidebar order, a header only with a member; the highlight goes to the first match, substrings first; New Workspace stays last", nil, {
            func check(_ q: String, rows: [String], headers h: [String], highlight: String) -> String? {
                guard let got = typed[q] else { return "\"\(q)\" wasn't typed" }
                return all(want("\"\(q)\" rows", got.0, rows), want("\"\(q)\" headers", got.1, h), want("\"\(q)\" highlight", got.2, highlight))
            }
            return all(problem,
                       check("zqapi", rows: ["zq-api-server"], headers: [], highlight: "zq-api-server"),
                       // zq-bluetail matches scattered and comes first; zq-beta's substring wins the highlight.
                       check("beta", rows: ["zq-bluetail", "zq-beta"], headers: [], highlight: "zq-beta"),
                       // The group's name finds its (collapsed) member, under its header.
                       check("zqtools", rows: ["zq-gamma"], headers: ["zq-tools"], highlight: "zq-gamma"),
                       check("gamma", rows: ["zq-gamma"], headers: ["zq-tools"], highlight: "zq-gamma"),
                       check("zqalpha", rows: ["zq-alpha"], headers: [], highlight: "zq-alpha"),
                       check("zqqqzz", rows: [], headers: [], highlight: "nothing"),
                       check("", rows: everything, headers: ["zq-tools"], highlight: "zq-beta"))
        }) {
            gamma?.group?.isCollapsed = true
            self.refreshChrome()
            problem = cmdPFromPane()
            var p: [String] = []
            for q in ["zqapi", "beta", "zqtools", "gamma", "zqalpha", "zqqqzz", ""] {
                clear()
                typeText(q)
                typed[q] = (shown(), headers(), highlightedName())
                if newWorkspaceLast() != nil { p.append("\"\(q)\": New Workspace should be the last row") }
                if menu.query != q { p.append("typing \"\(q)\" left \"\(menu.query)\" in the field") }
            }
            if !menu.isOpen { p.append("the dropdown should still be open") }
            problem = all(problem, p.isEmpty ? nil : p.joined(separator: "; "))
        }
        t.step("switcher search: return picks the first match", nil, {
            all(problem, active(api), menu.isOpen ? "the dropdown should close" : nil, focusedOnPane())
        }) {
            typeText("zq-api")
            ret()
        }

        var moves: [String] = []
        t.step("switcher search: ⌃N/⌃P and ↓/↑ move the highlight over pickable rows (headers skipped), as far as New Workspace", nil, {
            all(problem,
                want("highlights", moves, ["zq-alpha", "zq-bluetail", "zq-beta", "zq-api-server", "zq-gamma", "New Workspace", "New Workspace",
                                           "zq-gamma", "zq-api-server", "zq-gamma", "zq-api-server"]),
                active(bluetail), menu.isOpen ? "the dropdown should close on return" : nil)
        }) {
            moves = []
            problem = cmdPFromPane()
            typeText("zq")  // the first match: zq-alpha
            moves.append(highlightedName())
            for _ in 0..<6 { ctrlN(); moves.append(highlightedName()) }  // over the zq-tools header; stays on the last row
            ctrlP(); moves.append(highlightedName())
            ctrlP(); moves.append(highlightedName())
            down(); moves.append(highlightedName())
            up(); moves.append(highlightedName())
            for _ in 0..<2 { ctrlP() }
            ret()  // zq-bluetail
        }
        var reopened = "not reopened"
        t.step("switcher search: esc closes it and gives the keys back to the pane; nothing switches, and it reopens empty", nil, {
            all(problem, menu.isOpen ? "esc should close the dropdown" : nil, active(bluetail), focusedOnPane(),
                want("the query after reopening", reopened, ""))
        }) {
            problem = cmdPFromPane()
            typeText("beta")
            esc()
            problem = all(problem, menu.isOpen ? "the first esc should close it" : nil, focusedOnPane(), cmdPFromPane())
            reopened = menu.query
            esc()
        }
        t.step("switcher search: ⌘P while it's open closes it, from the search field, like a second click on the button", nil, {
            all(problem, menu.isOpen ? "a second ⌘P should close the dropdown" : nil, button.isOpen ? "the button should no longer draw open" : nil,
                active(bluetail), focusedOnPane())
        }) {
            problem = cmdPFromPane()
            let focused = menu.fieldHasFocus
            problem = all(problem, focused ? nil : "the field should have the keys before the second ⌘P",
                          pressMenuKey("p", .command, keyCode: kVK_ANSI_P).map { "second ⌘P: \($0)" })
        }
        t.step("switcher search: a click on the button opens it with the search field focused too", nil, {
            all(problem, active(gamma), menu.isOpen ? "the dropdown should close" : nil)
        }) {
            self.clickForTest(button)
            problem = all(menu.isOpen ? nil : "a click should open the dropdown",
                          menu.fieldHasFocus ? nil : "the search field should have the keys after a click",
                          want("the highlight", highlightedName(), "zq-api-server"))
            typeText("gamma")
            ret()
        }

        t.step("switcher search: with the sidebar shown, ⌘P opens it at the top center of the window, and it stays there through a layout", nil, {
            let area = self.deckArea
            return all(problem,
                       self.isSidebarVisible ? nil : "the sidebar should show",
                       menu.isOpen ? nil : "⌘P should open the dropdown without the button",
                       menu.isAnchoredToButton ? "it shouldn't hang from the hidden button" : nil,
                       abs(menu.frame.midX - area.midX) <= 1 ? nil : "it should be centered over the deck area (\(menu.frame.midX) vs \(area.midX))",
                       want("its top", menu.frame.minY, area.minY + 12),
                       self.contentView.bounds.contains(menu.frame) ? nil : "it should stay inside the window",
                       self.contentView.subviews.last === menu ? nil : "it should be above everything in the window",
                       menu.fieldHasFocus ? nil : "the search field should have the keys",
                       want("the highlight", highlightedName(), "zq-bluetail"))
        }) {
            self.sidebarPreference = true
            self.layoutNow()
            problem = cmdPFromPane()
            self.refreshChrome()
            self.layoutNow()
        }
        t.step("switcher search: …and typing and return switch from there", nil, {
            all(problem, active(beta), menu.isOpen ? "the dropdown should close" : nil, focusedOnPane())
        }) {
            typeText("zq-beta")
            ret()
        }
        t.step("switcher search: in top-bar mode ⌘P opens it at the top center too", nil, {
            all(problem, menu.isOpen ? "return should close it" : nil, active(alpha))
        }) {
            Settings.workspaceSwitcher = .top
            self.layoutNow()
            problem = cmdPFromPane()
            let area = self.deckArea
            problem = all(problem, menu.isOpen ? nil : "⌘P should open the dropdown in top-bar mode",
                          menu.isAnchoredToButton ? "it shouldn't hang from the hidden button" : nil,
                          abs(menu.frame.midX - area.midX) <= 1 ? nil : "it should be centered over the deck area",
                          want("its top", menu.frame.minY, area.minY + 12),
                          menu.fieldHasFocus ? nil : "the search field should have the keys")
            typeText("zq-alpha")
            ret()
            Settings.workspaceSwitcher = .sidebar
            self.layoutNow()
        }
        t.step("switcher search: in a new window's lone unnamed workspace (no button, no history) ⌘P opens it on the current workspace", nil, { problem }) {
            AppDelegate.shared.newWindow(nil)
            guard let wc = AppDelegate.shared.windowControllers.last, wc !== self else { problem = "no new window"; return }
            lone = wc
            wc.window?.animationBehavior = .none
            wc.layoutNow()
            let m = wc.titlebarSwitcherMenu
            problem = all(wc.showsTitlebarSwitcher ? "a lone unnamed workspace has no titlebar switcher" : nil,
                          cmdPFromPane(wc))
            let area = wc.deckArea
            let current = m.highlighted?.workspace === wc.activeWorkspace
            problem = all(problem, m.isOpen ? nil : "⌘P should open the dropdown",
                          abs(m.frame.midX - area.midX) <= 1 && m.frame.minY == area.minY + 12 ? nil : "it should sit at the window's top center",
                          want("its workspace rows", m.rows.filter { $0.workspace != nil }.count, 1),
                          current ? nil : "with no history it should start on the current workspace, is on \(highlightedName(m))",
                          newWorkspaceLast(m))
            esc(in: wc)
            problem = all(problem, m.isOpen ? "esc should close it" : nil, focusedOnPane(wc))
            wc.window?.close()
            self.window?.makeKeyAndOrderFront(nil)
        }

        // Go to Pane (#66) gets ⌃N/⌃P the same way, through its field editor's `moveDown:`/`moveUp:`.
        t.step("switcher search: ⌃N/⌃P move Go to Pane's selection too", nil, { problem }) {
            let picker = PanePicker.shared
            guard let p = self.focusedPane else { problem = "no focused pane"; return }
            problem = self.pressMenuKeyForTest("a", [.command, .shift], keyCode: kVK_ANSI_A, surface: p.surface)
                ? nil : "⇧⌘A should open Go to Pane (\(Self.menuKeyFailure))"
            let opened = picker.isOpen && picker.entries.count > 2
            ctrlN(); ctrlN()
            let afterN = picker.selectedIndex
            ctrlP()
            let afterP = picker.selectedIndex
            esc()
            problem = all(problem, opened ? nil : "Go to Pane should be open with a few panes",
                          want("the selection after ⌃N ⌃N", afterN, 2), want("the selection after ⌃P", afterP, 1),
                          picker.isOpen ? "esc should close Go to Pane" : nil)
            picker.close(restoreFocus: false)
        }

        t.step("switcher search: cleanup", nil, {
            all(self.workspaces.contains { $0.name?.hasPrefix("zq-") == true } ? "test workspaces should be gone" : nil,
                menu.isOpen ? "the dropdown should be closed" : nil, menu.rows.isEmpty ? nil : "a closed dropdown holds no rows",
                lone?.window?.isVisible == true ? "the second window should be closed" : nil)
        }) {
            menu.close(restoreFocus: false)
            Settings.workspaceSwitcher = .sidebar
            lone?.window?.close()
            for ws in [alpha, bluetail, beta, api, gamma].compactMap({ $0 }) { self.close(workspace: ws) }
            alpha = nil; bluetail = nil; beta = nil; api = nil; gamma = nil
            if let saved = savedPreference { self.sidebarPreference = saved }
            self.layoutNow()
        }
    }
}
