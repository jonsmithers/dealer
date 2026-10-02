import AppKit
import GhosttyKit

// MARK: - Self-test section: workspace switcher mode, sidebar vs top-bar pills (issue #8)

extension TerminalWindowController {
    func switcherSelfTestSteps(_ t: SelfTestKit) {
        let sb = workspaceSidebar
        let bar = workspaceBar
        let g = Self.deckGap
        let w = Theme.Metrics.sidebarWidth
        func tree() -> String { describeWorkspaces(name: t.name) }
        func expect(_ e: String) -> String? { tree() == e ? nil : "expected workspaces \(e)\n         got      \(tree())" }
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ what: String) -> String? { abs(a - b) < 0.5 ? nil : "\(what): \(a), expected \(b)" }
        /// #7's check: the waiting outline in exactly Theme.attentionWaiting (SelfTestPixels.swift).
        func outlined(_ v: NSView?) -> Bool { PixelProbe.isWaitingOutlined(v) }
        func toggleEnabled() -> Bool {
            validateWorkspaceMenuItem(NSMenuItem(title: "", action: #selector(toggleWorkspaceSidebar(_:)), keyEquivalent: "")) ?? true
        }
        /// #13: a ⌘B keystroke into a terminal pane, the way a real one travels: SurfaceView is first
        /// responder and asks the main menu first (`SurfaceView.performKeyEquivalent`); the menu sends
        /// the matched item's nil-target action up the responder chain. Nothing is re-targeted: a
        /// chain member that also answers the selector (NSWindow has its own `toggleSidebar:`) wins.
        /// When this run is the active app, the event goes through `NSApp.sendEvent`. Otherwise there
        /// is no key window, AppKit has nowhere to route the action, and we can't take focus from the
        /// user mid-run; then the event still goes through the window and SurfaceView to the menu,
        /// and the item's action is resolved and validated from SurfaceView the same way AppKit does.
        /// Returns whether the item ⌘B matched was enabled for its resolved target.
        @discardableResult func pressCmdB() -> Bool {
            guard let window = self.window, let menu = NSApp.mainMenu,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)
            else { return false }
            let surface = (self.focusedPane ?? t.pane("srv")).surface
            window.makeFirstResponder(surface)
            func find(_ m: NSMenu) -> NSMenuItem? {
                for i in m.items {
                    if i.keyEquivalent == "b" && i.keyEquivalentModifierMask == .command { return i }
                    if let sub = i.submenu, let hit = find(sub) { return hit }
                }
                return nil
            }
            guard let item = find(menu), let action = item.action else { return false }
            if NSApp.keyWindow === window {
                NSApp.sendEvent(e)
                return item.isEnabled
            }
            // The window hands it to SurfaceView, which must give it to the menu, not to ghostty.
            guard window.performKeyEquivalent(with: e) else { return false }
            var r: NSResponder? = surface
            while let cur = r, !cur.responds(to: action) {
                r = cur === window ? (window.delegate as? NSResponder) ?? cur.nextResponder : cur.nextResponder
            }
            guard let target = r else { return false }
            let enabled = (target as AnyObject).validateMenuItem?(item) ?? true  // informal, as AppKit asks it
            if enabled { NSApp.sendAction(action, to: target, from: item) }
            return enabled
        }

        var before = ""
        var problem: String?
        var srvWidth: CGFloat = 0
        var srvSurface: ghostty_surface_t?

        t.step("switcher: sidebar mode by default, sidebar shown and pinned open", nil, {
            all(Settings.workspaceSwitcher == .sidebar ? nil : "default should be sidebar",
                !sb.isHidden && bar.isHidden && !self.sidebarToggle.isHidden ? nil : "sidebar + toggle should show, pills not",
                near(self.deckArea.minX, g + w + g, "deck area minX"))
        }) {
            self.newWorkspace(nil)
            t.named(self.focusedPane, "t2")
            self.activateWorkspace(index: 0)
            self.sidebarPreference = true
            self.layoutNow()
        }
        t.step("switcher: ⌘B (main menu key equivalent) hides the sidebar", nil, {
            all(problem, sb.isHidden && self.sidebarPreference == false ? nil : "⌘B should hide the sidebar",
                near(self.deckArea.minX, g, "deck area minX"))
        }) {
            problem = pressCmdB() ? nil : "⌘B should match an enabled Show/Hide Workspace Sidebar item"
        }
        t.step("switcher: ⌘B shows it again", nil, {
            all(!sb.isHidden && self.sidebarPreference == true ? nil : "⌘B should show the sidebar",
                near(self.deckArea.minX, g + w + g, "deck area minX"))
        }) {
            pressCmdB()
        }
        t.step("switcher: going to top bar is live; tree and surfaces untouched, decks widen", nil, {
            all(expect(before),
                sb.isHidden && self.sidebarToggle.isHidden && !bar.isHidden ? nil : "pills should show, sidebar and toggle not",
                bar.button(at: 1) != nil ? nil : "two pills expected",
                near(self.deckArea.minX, g, "deck area minX"),
                near(t.pane("srv").view.frame.width - srvWidth, w + g, "srv widened by"),
                t.pane("srv").surface.surface == srvSurface ? nil : "srv's surface was replaced",
                self.sidebarPreference == true ? nil : "the window's sidebar choice should be kept")
        }) {
            before = tree()
            srvWidth = t.pane("srv").view.frame.width
            srvSurface = t.pane("srv").surface.surface
            Settings.workspaceSwitcher = .top
        }
        t.step("switcher: ⌘B is disabled in top-bar mode and does nothing", nil, {
            all(problem, toggleEnabled() ? "⌘B should be disabled" : nil,
                self.sidebarPreference == true && sb.isHidden && !bar.isHidden ? nil : "⌘B must not change anything",
                near(self.deckArea.minX, g, "deck area minX"))
        }) {
            problem = pressCmdB() ? "the ⌘B item should be disabled" : nil
        }
        t.step("switcher: clicking a pill switches workspace", nil, { expect("1:Deck0[*srv, Row(srv2, edit)] | *2:Deck0[*t2]") }) {
            if let b = bar.button(at: 1) { self.clickForTest(b) }
        }
        t.step("switcher: drag a pill past the next one to reorder", nil, { expect("1:Deck0[*t2] | *2:Deck0[*srv, Row(srv2, edit)]") }) {
            guard let b0 = bar.button(at: 0), let b1 = bar.button(at: 1) else { return }
            self.dragForTest(b0, to: b1.convert(CGPoint(x: b1.bounds.maxX - 2, y: b1.bounds.midY), to: nil))
        }
        t.step("switcher: drop a tab on a pill (DragController) moves it to that workspace", nil, {
            expect("1:Deck0[t2, *Row(srv2, edit)] | *2:Deck0[*srv]")
        }) {
            self.activateWorkspace(index: 1)
            guard let tab = self.locate(t.pane("srv2"))?.tab, let pill = bar.button(at: 0) else { return }
            let from = t.pane("srv").view.convert(CGPoint(x: 40, y: 40), to: nil)
            self.dragControllerForTest(.tab(tab), from: from, to: pill)
        }
        t.step("switcher: waiting attention outlines the pill", nil, {
            all(outlined(bar.button(at: 0)) ? nil : "workspace 1's pill should have the waiting outline",
                outlined(bar.button(at: 1)) ? "workspace 2's pill should not" : nil)
        }) {
            self.setAttention(.waiting, on: t.pane("t2"))
        }
        t.step("switcher: back to sidebar is live; the kept choice reopens it; the row shows attention", nil, {
            all(expect("1:Deck0[t2, *Row(srv2, edit)] | *2:Deck0[*srv]"),
                !sb.isHidden && !self.sidebarToggle.isHidden && bar.isHidden ? nil : "sidebar + toggle should show, pills not",
                near(self.deckArea.minX, g + w + g, "deck area minX"),
                t.pane("srv").surface.surface == srvSurface ? nil : "srv's surface was replaced",
                outlined(sb.row(at: 0)) ? nil : "workspace 1's row should have the waiting outline",
                toggleEnabled() ? nil : "⌘B should be enabled again")
        }) {
            Settings.workspaceSwitcher = .sidebar
        }
        t.step("switcher: clicking a row switches workspace", nil, { expect("*1:Deck0[t2, *Row(srv2, edit)] | 2:Deck0[*srv]") }) {
            if let r = sb.row(at: 0) { self.clickForTest(r) }
        }
        t.step("switcher: back to one workspace, automatic sidebar", nil, {
            all(expect("*1:Deck0[*srv]"), sb.isHidden ? nil : "automatic sidebar should hide with one workspace")
        }) {
            self.setAttention(.none, on: t.pane("t2"))
            self.sidebarPreference = nil
            if let home = self.workspace(of: t.pane("srv")) {
                self.activate(home)
                self.workspaces.filter { $0 !== home }.forEach { self.remove(workspace: $0) }
            }
        }
    }
}
