import AppKit

// `dealer <command>` / `Dealer <command>`: act as the control-socket client, don't launch the app.
if CLI.shouldRun(CommandLine.arguments) { exit(CLI.run(CommandLine.arguments)) }
// App mode: don't pass a parent terminal's or Claude Code session's identity on to the panes
// (InheritedEnvironment.swift).
InheritedEnvironment.scrub()

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var controllers: [TerminalWindowController] = []
    /// Open windows, for code that spans them (control socket, jump to next unread).
    var windowControllers: [TerminalWindowController] { controllers }
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.start()
        NotificationLog.start()
        Caffeinate.shared.start()
        // Before any pane exists, so every shell gets DEALER_SOCKET; and before ghostty_init,
        // because it setenvs DEALER_SOCKET and libghostty snapshots the environment at init.
        ControlServer.shared.start()
        GhosttyRuntime.shared.start()
        AttentionNotifier.shared.start()
        NSApp.mainMenu = makeMenu()

        if SelfTest.enabled {
            let wc = TerminalWindowController()
            open(wc)
            if let demo = Demo.name { return wc.runDemo(demo) }
            wc.runSelfTest { ok in
                if SelfTest.quitWhenDone {
                    ControlServer.shared.stop()
                    exit(ok ? 0 : 1)
                }
            }
            return
        }

        let session = SessionSnapshot.load()
        if let session, !session.windows.isEmpty {
            session.windows.forEach { open(TerminalWindowController(snapshot: $0)) }
        } else {
            newWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControlServer.shared.stop()
        Caffeinate.shared.release()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot before windows start closing.
        if !SelfTest.enabled { SessionSnapshot(windows: controllers.compactMap { $0.snapshot() }).save() }
        terminating = true
        guard GhosttyRuntime.shared.needsConfirmQuit else { return .terminateNow }
        let info = "Processes are still running. Your layout will be restored next time."
        if Confirmation.skip("Quit Dealer?", info) { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Dealer?"
        alert.informativeText = info
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateNow }
        terminating = false
        return .terminateCancel
    }

    private func open(_ wc: TerminalWindowController) {
        wc.onClose = { [weak self] wc in
            guard let self else { return }
            self.controllers.removeAll { $0 === wc }
            Caffeinate.shared.update()  // its working panes are gone (#69)
            // Closing the last window by hand ends the session; quitting keeps it.
            if self.controllers.isEmpty && !self.terminating && !SelfTest.enabled {
                SessionSnapshot(windows: []).save()
            }
        }
        controllers.append(wc)
        if let last = controllers.dropLast().last?.window {
            wc.window?.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        wc.showAndFocus()
    }

    @objc func newWindow(_ sender: Any?) {
        // Like Ghostty's window-inherit-working-directory: start where the front window's focus is (#32).
        let front = (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first)?.windowController as? TerminalWindowController
        open(TerminalWindowController(workingDirectory: WorkingDirectory.inherited(from: front?.focusedPane, for: .window)))
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func arrow(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }

        submenu("Dealer", [
            item("About Dealer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Open Settings File…", #selector(AppDelegate.openSettingsFile(_:)), ","),
            item("Reload Configuration", #selector(AppDelegate.reloadConfiguration(_:)), ",", [.command, .shift]),
            .separator(),
            item("Hide Dealer", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Dealer", #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu("Shell", [
            // ⇧⌘N (#44). Uppercase "N" carries the shift: AppKit matches "n" + a shift mask against
            // plain ⌘N (ahead of New Workspace), and never against a real ⇧⌘N event ("N").
            item("New Window", #selector(newWindow(_:)), "N"),
            item("New Tab", #selector(TerminalWindowController.newTab(_:)), "t"),
            .separator(),
            item("Split Right", #selector(TerminalWindowController.splitRight(_:)), "d"),
            item("Split Down", #selector(TerminalWindowController.splitDown(_:)), "d", [.command, .shift]),
            item("New Agent Pane", #selector(TerminalWindowController.newAgentPane(_:)), "a", [.command, .option]),
            item("New Agent Pane in Worktree", #selector(TerminalWindowController.newAgentPaneInWorktree(_:)), "a", [.command, .option, .shift]),
            // ⇧⌘A (#66): uppercase "A" carries the shift, as for ⇧⌘N, so plain ⌘A stays Select All.
            item("Go to Pane…", #selector(TerminalWindowController.openPanePicker(_:)), "A"),
            .separator(),
            item("Rename Tab…", #selector(TerminalWindowController.renameCurrentTab(_:))),
            item("Close Pane", #selector(TerminalWindowController.closePane(_:)), "w"),
            item("Close Tab", #selector(TerminalWindowController.closeTab(_:)), "w", [.command, .option]),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])

        submenu("Edit", [
            item("Copy", #selector(SurfaceView.copy(_:)), "c"),
            item("Paste", #selector(SurfaceView.paste(_:)), "v"),
            item("Select All", #selector(SurfaceView.selectAll(_:)), "a"),
            .separator(),
            // Find in the focused pane (#49, SearchBar.swift). ⇧⌘F is Fold Deck; esc hides the bar.
            item("Find…", #selector(PaneView.findInPane(_:)), "f"),
            item("Find Next", #selector(PaneView.findNext(_:)), "g"),
            item("Find Previous", #selector(PaneView.findPrevious(_:)), "G"),
            item("Use Selection for Find", #selector(PaneView.useSelectionForFind(_:)), "e"),
            item("Hide Find Bar", #selector(PaneView.hideFindBar(_:))),
        ])

        submenu("Layout", [
            item("Promote to Deck", #selector(TerminalWindowController.promoteToDeck(_:)), "p", [.command, .shift]),
            item("Fold Deck", #selector(TerminalWindowController.foldDeck(_:)), "f", [.command, .shift]),
            item("Select Parent Split", #selector(TerminalWindowController.selectParent(_:)), arrow(NSUpArrowFunctionKey), [.command, .shift]),
            .separator(),
            item("Zoom Pane", #selector(TerminalWindowController.toggleZoom(_:)), "\r", [.command, .shift]),
            item("Equalize Splits", #selector(TerminalWindowController.equalize(_:)), "=", [.command, .control]),
            .separator(),
            item("Focus Left", #selector(TerminalWindowController.focusLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
            item("Focus Right", #selector(TerminalWindowController.focusRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
            item("Focus Up", #selector(TerminalWindowController.focusUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            item("Focus Down", #selector(TerminalWindowController.focusDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
        ])

        // Workspace menu (issue #1). Item titles and visibility are filled in by
        // TerminalWindowController.validateWorkspaceMenuItem.
        func moveMenu(_ title: String, _ action: Selector) -> NSMenuItem {
            let menu = NSMenu(title: title)
            menu.addItem(item("New Workspace", action, tag: TerminalWindowController.newWorkspaceTag))
            menu.addItem(.separator())
            for n in 1...9 { menu.addItem(item("Workspace \(n)", action, tag: n)) }
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = menu
            return i
        }
        var workspaceItems = [
            item("Show Workspace Sidebar", #selector(TerminalWindowController.toggleWorkspaceSidebar(_:)), "b"),
            {
                // #8: where the switcher lives, for every window (the `workspaceSwitcher` default).
                let menu = NSMenu(title: "Workspace Switcher")
                menu.addItem(item("In Sidebar", #selector(TerminalWindowController.useSidebarSwitcher(_:))))
                menu.addItem(item("In Top Bar", #selector(TerminalWindowController.useTopBarSwitcher(_:))))
                let i = NSMenuItem(title: "Workspace Switcher", action: nil, keyEquivalent: "")
                i.submenu = menu
                return i
            }(),
            .separator(),
            item("New Workspace", #selector(TerminalWindowController.newWorkspace(_:)), "n"),  // ⌘N (#44)
            item("Rename Workspace…", #selector(TerminalWindowController.renameWorkspace(_:))),
            item("Close Workspace", #selector(TerminalWindowController.closeWorkspace(_:)), "w", [.command, .control]),
            .separator(),
            item("Next Workspace", #selector(TerminalWindowController.nextWorkspace(_:)), "]", [.command, .control]),
            item("Previous Workspace", #selector(TerminalWindowController.previousWorkspace(_:)), "[", [.command, .control]),
            item("Move Workspace Left", #selector(TerminalWindowController.moveWorkspaceLeft(_:))),
            item("Move Workspace Right", #selector(TerminalWindowController.moveWorkspaceRight(_:))),
            .separator(),
            moveMenu("Move Pane to Workspace", #selector(TerminalWindowController.movePaneToWorkspace(_:))),
            moveMenu("Move Tab to Workspace", #selector(TerminalWindowController.moveTabToWorkspace(_:))),
            moveMenu("Move Deck to Workspace", #selector(TerminalWindowController.moveDeckToWorkspace(_:))),
            .separator(),
        ]
        for n in 1...9 {
            workspaceItems.append(item("Workspace \(n)", #selector(TerminalWindowController.gotoWorkspaceFromMenu(_:)), "\(n)", .control, tag: n))
        }
        submenu("Workspace", workspaceItems)

        var tabItems = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Next Tab", #selector(TerminalWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(TerminalWindowController.previousTab(_:)), "[", [.command, .shift]),
            item("Jump to Next Unread", #selector(TerminalWindowController.jumpToNextUnread(_:)), "u", [.command, .shift]),
            .separator(),
        ]
        for n in 1...9 {
            tabItems.append(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(TerminalWindowController.gotoTabFromMenu(_:)), "\(n)", tag: n))
        }
        submenu("Window", tabItems)
        NSApp.windowsMenu = main.items.last?.submenu

        submenu("Help", [item("Capture Memory Diagnostics…", #selector(AppDelegate.captureDiagnostics(_:)))])
        NSApp.helpMenu = main.items.last?.submenu

        return main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
