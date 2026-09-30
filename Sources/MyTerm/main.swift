import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var controllers: [TerminalWindowController] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyRuntime.shared.start()
        NSApp.mainMenu = makeMenu()

        if SelfTest.enabled {
            let wc = TerminalWindowController()
            open(wc)
            wc.runSelfTest { ok in
                if SelfTest.quitWhenDone { exit(ok ? 0 : 1) }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot before windows start closing.
        if !SelfTest.enabled { SessionSnapshot(windows: controllers.compactMap { $0.snapshot() }).save() }
        terminating = true
        guard GhosttyRuntime.shared.needsConfirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit MyTerm?"
        alert.informativeText = "Processes are still running. Your layout will be restored next time."
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
        open(TerminalWindowController())
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

        submenu("MyTerm", [
            item("About MyTerm", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide MyTerm", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit MyTerm", #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu("Shell", [
            item("New Window", #selector(newWindow(_:)), "n"),
            item("New Tab", #selector(TerminalWindowController.newTab(_:)), "t"),
            .separator(),
            item("Split Right", #selector(TerminalWindowController.splitRight(_:)), "d"),
            item("Split Down", #selector(TerminalWindowController.splitDown(_:)), "d", [.command, .shift]),
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

        var tabItems = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Next Tab", #selector(TerminalWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(TerminalWindowController.previousTab(_:)), "[", [.command, .shift]),
            .separator(),
        ]
        for n in 1...9 {
            tabItems.append(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(TerminalWindowController.gotoTabFromMenu(_:)), "\(n)", tag: n))
        }
        submenu("Window", tabItems)
        NSApp.windowsMenu = main.items.last?.submenu

        return main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
