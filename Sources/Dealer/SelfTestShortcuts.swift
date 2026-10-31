import AppKit
import Carbon.HIToolbox

// MARK: - Self-test section: menu key equivalents (#44: ⌘N is New Workspace, ⇧⌘N New Window)

extension TerminalWindowController {
    /// The modifiers an item really needs: an uppercase key equivalent implies shift.
    static func effectiveModifiers(_ i: NSMenuItem) -> NSEvent.ModifierFlags {
        let k = i.keyEquivalent
        return i.keyEquivalentModifierMask.union(k != k.lowercased() ? .shift : [])
    }

    /// Every main-menu item with a key equivalent, submenus included.
    static func keyedMenuItems(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { i in (i.keyEquivalent.isEmpty ? [] : [i]) + keyedMenuItems(i.submenu) }
    }

    /// A menu key press into a terminal pane, the way a real one travels (#13): SurfaceView is first
    /// responder and asks the main menu first (`SurfaceView.performKeyEquivalent`); the menu sends the
    /// matched item's nil-target action up the responder chain. Nothing is re-targeted.
    /// When this run is the active app, the event goes through `NSApp.sendEvent`. Otherwise there is
    /// no key window, AppKit has nowhere to route the action, and we can't take focus from the user
    /// mid-run; then the event still goes through the window and SurfaceView to the menu, and the
    /// item's action is resolved from SurfaceView up to the window's controller and validated the
    /// way AppKit does (past that, NSApp and the app delegate already got it from the menu).
    /// Returns whether the matched item was enabled for its target.
    /// Why the last `pressMenuKeyForTest` returned false, for step messages.
    static var menuKeyFailure = ""

    @discardableResult
    func pressMenuKeyForTest(_ key: String, _ mods: NSEvent.ModifierFlags, keyCode: Int, surface: SurfaceView) -> Bool {
        let chars = mods.contains(.shift) ? key.uppercased() : key
        guard let window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)),
              let item = Self.keyedMenuItems().first(where: { $0.keyEquivalent.lowercased() == key && Self.effectiveModifiers($0) == mods }),
              let action = item.action
        else { Self.menuKeyFailure = "no window, event or menu item"; return false }
        Self.menuKeyFailure = window.makeFirstResponder(surface) ? "" : "surface refused first responder"
        if NSApp.keyWindow === window {
            NSApp.sendEvent(e)
            return item.isEnabled
        }
        // The window hands it to SurfaceView, which must give it to the menu, not to ghostty.
        guard window.performKeyEquivalent(with: e) else {
            Self.menuKeyFailure += " window/SurfaceView didn't handle it (ghostty surface: \(surface.surface != nil))"
            return false
        }
        var r: NSResponder? = surface
        while let cur = r, !cur.responds(to: action) {
            r = cur === window ? (window.delegate as? NSResponder) ?? cur.nextResponder : cur.nextResponder
        }
        if let target = r {
            let enabled = (target as AnyObject).validateMenuItem?(item) ?? true  // informal, as AppKit asks it
            if enabled { NSApp.sendAction(action, to: target, from: item) }
            return enabled
        }
        // Past the window: NSApp, then the app delegate. AppKit's own dispatch reaches those without
        // a key window, so the menu has already sent the action; don't send it twice.
        if NSApp.responds(to: action) { return true }
        if let d = NSApp.delegate, d.responds(to: action) { return (d as AnyObject).validateMenuItem?(item) ?? true }
        Self.menuKeyFailure = "no responder for \(action)"
        return false
    }

    func shortcutsSelfTestSteps(_ t: SelfTestKit) {
        func ws() -> String { describeWorkspaces(name: t.name) }
        func surface() -> SurfaceView { (focusedPane ?? t.pane("srv")).surface }
        var problem: String?
        var windowsBefore = 0
        var treeBefore = ""
        var added: Workspace?
        var opened: [TerminalWindowController] = []

        t.step("shortcuts: ⌘N is New Workspace, ⇧⌘N New Window, nothing on ⌃⌘N (#44)", nil, {
            let items = Self.keyedMenuItems()
            func owner(_ mods: NSEvent.ModifierFlags) -> [String] {
                items.filter { $0.keyEquivalent.lowercased() == "n" && Self.effectiveModifiers($0) == mods }.map(\.title)
            }
            var p: [String] = []
            if owner(.command) != ["New Workspace"] { p.append("⌘N: \(owner(.command)), expected [New Workspace]") }
            if owner([.command, .shift]) != ["New Window"] { p.append("⇧⌘N: \(owner([.command, .shift])), expected [New Window]") }
            if !owner([.command, .control]).isEmpty { p.append("⌃⌘N should be unbound, has \(owner([.command, .control]))") }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}
        t.step("shortcuts: ⌘N in a pane adds a workspace to this window, no new window", nil, { problem }) {
            let before = ws(), count = self.workspaces.count
            treeBefore = before
            windowsBefore = AppDelegate.shared.windowControllers.count
            if !self.pressMenuKeyForTest("n", .command, keyCode: kVK_ANSI_N, surface: surface()) {
                problem = "⌘N matched no enabled item: \(Self.menuKeyFailure)"
            } else if self.workspaces.count != count + 1 || self.activeWorkspace !== self.workspaces.last {
                problem = "expected a new active workspace after \(before), got \(ws())"
            } else if AppDelegate.shared.windowControllers.count != windowsBefore {
                problem = "⌘N opened a window"
            } else {
                problem = nil
                added = self.activeWorkspace
            }
        }
        t.step("shortcuts: ⇧⌘N opens a window and leaves workspaces alone", nil, { problem }) {
            let count = self.workspaces.count
            let before = AppDelegate.shared.windowControllers
            if !self.pressMenuKeyForTest("n", [.command, .shift], keyCode: kVK_ANSI_N, surface: surface()) {
                problem = "⇧⌘N matched no enabled item: \(Self.menuKeyFailure)"
            } else if AppDelegate.shared.windowControllers.count != before.count + 1 {
                problem = "⇧⌘N should open one window (\(before.count) → \(AppDelegate.shared.windowControllers.count))"
            } else if self.workspaces.count != count {
                problem = "⇧⌘N changed the workspace count"
            } else {
                problem = nil
            }
            opened = AppDelegate.shared.windowControllers.filter { w in !before.contains { $0 === w } }
            self.window?.makeKeyAndOrderFront(nil)
        }
        t.step("shortcuts: closing the ⇧⌘N window and the ⌘N workspace restores the earlier state", nil, {
            ws() == treeBefore ? nil : "expected workspaces \(treeBefore)\n         got      \(ws())"
        }) {
            opened.forEach { $0.window?.close() }
            opened = []
            if let added, self.workspaces.contains(where: { $0 === added }) { self.remove(workspace: added) }
        }

        t.step("shortcuts: ⇧⌘R Rename Tab, ⌃⇧R Rename Workspace, ⇧⌘T Move to New Tab, ⌘T still New Tab", nil, {
            let items = Self.keyedMenuItems()
            func owner(_ key: String, _ mods: NSEvent.ModifierFlags) -> [String] {
                items.filter { $0.keyEquivalent.lowercased() == key && Self.effectiveModifiers($0) == mods }.map(\.title)
            }
            let want: [(String, NSEvent.ModifierFlags, String, String)] = [
                ("r", [.command, .shift], "⇧⌘R", "Rename Tab…"),
                ("r", [.control, .shift], "⌃⇧R", "Rename Workspace…"),
                ("t", [.command, .shift], "⇧⌘T", "Move to New Tab"),
                ("t", .command, "⌘T", "New Tab"),
            ]
            let p = want.compactMap { k, m, label, title in
                owner(k, m) == [title] ? nil : "\(label): \(owner(k, m)), expected [\(title)]"
            }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}
        var split: Pane?
        var original: Pane?
        t.step("shortcuts: ⇧⌘T moves the focused pane out of its split into a new tab right after", nil, { problem }) {
            guard let p = self.focusedPane else { problem = "no focused pane"; return }
            original = p
            self.split(p, side: .right)
            guard let new = self.focusedPane, new !== p, let deck = self.focusedDeck, let from = deck.activeTab,
                  let i = deck.index(of: from) else { problem = "split didn't focus a new pane"; return }
            split = new
            let tabsBefore = deck.tabs.count
            let rest = from.root.node(for: new)?.parent.flatMap { $0.a?.leaf === new ? $0.b : $0.a }
            if !self.pressMenuKeyForTest("t", [.command, .shift], keyCode: kVK_ANSI_T, surface: new.surface) {
                problem = "⇧⌘T matched no enabled item: \(Self.menuKeyFailure)"
            } else if deck.tabs.count != tabsBefore + 1 || deck.activeIndex != i + 1 {
                problem = "expected a new active tab at \(i + 1) of \(tabsBefore + 1), got \(deck.activeIndex) of \(deck.tabs.count)"
            } else if deck.tabs[i + 1].root.leaf !== new || (rest.map { from.root !== $0 } ?? true) {
                problem = "expected the new pane alone in the new tab and its old tab back to what it was"
            } else if self.focusedPane !== new {
                problem = "focus should follow the moved pane"
            } else {
                problem = nil
            }
        }
        t.step("shortcuts: ⇧⌘T on a tab's only pane does nothing (menu item disabled)", nil, { problem }) {
            guard let deck = self.focusedDeck else { problem = "no focused deck"; return }
            let before = deck.tabs.count
            if self.pressMenuKeyForTest("t", [.command, .shift], keyCode: kVK_ANSI_T, surface: split?.surface ?? surface()) {
                problem = "⇧⌘T should be disabled on a lone pane"
            } else if deck.tabs.count != before {
                problem = "⇧⌘T changed the tab count on a lone pane"
            } else {
                problem = nil
            }
            // Leave the tree as it was: removing the new tab would otherwise leave its right neighbour active.
            if let split { self.remove(split) }
            if let original { self.focus(original) }
        }
    }
}
