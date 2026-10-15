import AppKit

// MARK: - Live re-theming after a ghostty config reload (#33)

extension TerminalWindowController {
    /// Called from `init`: re-theme on `Theme.didChange`, and re-show the banner when the ghostty
    /// config's problems change.
    func observeTheme() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(themeDidChange(_:)), name: Theme.didChange, object: nil)
        nc.addObserver(self, selector: #selector(configProblemsDidChange(_:)), name: GhosttyRuntime.problemsDidChange, object: nil)
    }

    @objc private func themeDidChange(_ note: Notification) { applyTheme() }

    @objc private func configProblemsDidChange(_ note: Notification) {
        settingsBanner.undismiss()
        layoutNow()
    }

    /// Re-applies every chrome color from `Theme`. Covers views outside the window too: decks of
    /// workspaces that were never shown, and the switchers and banner while they're detached.
    /// Only colors change; surfaces and frames are untouched.
    func applyTheme() {
        window?.appearance = Theme.appearance
        applyTransparency()  // #67: opacity, blur and glass; sets the window's background
        contentView.applyThemeRecursively()
        // Anything not under the content view right now: decks of workspaces that were never
        // shown, panes never laid out, and the switchers or banner while detached.
        let others: [NSView] = [workspaceSidebar, workspaceBar, sidebarToggle, settingsBanner] + allDecks.map(\.view)
            + allDecks.flatMap(\.tabs).flatMap(\.panes).map(\.view)
        for v in others where !v.isDescendant(of: contentView) { v.applyThemeRecursively() }
        refreshChrome()          // attention rings, tab and row state
        layoutNow()              // accents are set during layout
        updateSelectionHighlight()
    }
}
