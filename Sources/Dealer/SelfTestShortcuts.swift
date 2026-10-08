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
    }
}
