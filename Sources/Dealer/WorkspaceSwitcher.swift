import AppKit

/// Where the workspace switcher lives (#8): the collapsible left sidebar (default) or pills in the
/// titlebar row. A user setting shared by every window; changing it re-lays out open windows live.
enum WorkspaceSwitcherStyle: String, CaseIterable {
    case sidebar, top
}

enum WorkspaceSwitcher {
    /// The current mode. Stored in `Settings.workspaceSwitcher`; set it there.
    static var style: WorkspaceSwitcherStyle { Settings.workspaceSwitcher }
}

/// A switcher view panes and tabs can be dropped on (DragController): the sidebar and the pill bar.
protocol WorkspaceDropTargets: NSView {
    /// The entry under `p` (own coordinates): a workspace, or a `nil` workspace for "new workspace".
    func dropTarget(at p: CGPoint) -> (workspace: Workspace?, rect: CGRect)?
    /// The entry's frame for a workspace (`nil`: the "new workspace" entry), in own coordinates.
    func rect(for ws: Workspace?) -> CGRect?
}

extension WorkspaceSidebarView: WorkspaceDropTargets {}

extension TerminalWindowController {
    /// The switcher views currently showing; DragController offers them as drop targets.
    var visibleWorkspaceSwitchers: [WorkspaceDropTargets] {
        ([workspaceSidebar, workspaceBar] as [WorkspaceDropTargets]).filter { $0.window != nil && !$0.isHidden }
    }

    /// Places the pill bar in the titlebar row (top mode only). Called from `layoutWorkspaceSidebar`.
    func layoutWorkspaceBar() {
        let bar = workspaceBar
        if bar.superview !== contentView { contentView.addSubview(bar) }
        bar.isHidden = WorkspaceSwitcher.style != .top
        let x = WorkspaceBarView.leadingInset
        bar.reload()
        // With tab strips in the titlebar (#16), the bar is only its pill segment so it never
        // sits over (and swallows clicks for) a strip.
        let full = max(contentView.bounds.width - x - Self.deckGap, 0)
        bar.frame = CGRect(x: x, y: 0, width: Settings.tabsInTitlebar ? min(full, bar.contentWidth) : full, height: deckArea.minY)
        // reload() runs inside the window's layout pass, where its needsLayout would be dropped.
        bar.layoutSubtreeIfNeeded()
    }

    @objc func useSidebarSwitcher(_ sender: Any?) { Settings.workspaceSwitcher = .sidebar }
    @objc func useTopBarSwitcher(_ sender: Any?) { Settings.workspaceSwitcher = .top }

    /// Called once from `init`: apply setting changes live.
    func observeSettings() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)), name: Settings.didChange, object: nil)
    }

    /// Only chrome and frames change: surfaces are resized, never recreated.
    @objc private func settingsDidChange(_ note: Notification) {
        layoutNow()
        refreshChrome()
    }
}
