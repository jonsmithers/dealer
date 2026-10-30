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

/// How both switchers mark the selected workspace (#90, replacing #52's outline): the
/// `Theme.workspaceSelection` fill inset like the color tint, a heavier title, and a bar in the
/// workspace's color (`Theme.text` without one) along one edge: a sidebar row's right edge (the one
/// facing the decks) and a pill's bottom edge. There is no selection outline: outlines mean
/// attention, and an attention outline is drawn around a selected entry as around any other. The
/// bar sits inside the outline's path, so the two never overlap.
enum SelectionStyle {
    static var inset: CGFloat { AttentionStyle.outlineWidth + 0.5 }

    static func drawFill(in bounds: CGRect, cornerRadius: CGFloat) {
        let r = bounds.insetBy(dx: inset, dy: inset), radius = max(cornerRadius - inset, 0)
        Theme.fill(Theme.workspaceSelection).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    static func barColor(_ workspaceColor: NSColor?) -> NSColor { workspaceColor ?? Theme.text }

    /// The bar on a sidebar row or a sidebar group header: at the right edge, inside the attention
    /// outline, `verticalInset` from the top and bottom.
    static func rowBarRect(in bounds: CGRect, verticalInset: CGFloat = 5) -> CGRect {
        let w = Theme.Metrics.workspaceBarWidth
        return CGRect(x: bounds.maxX - inset - w, y: bounds.minY + verticalInset, width: w, height: bounds.height - verticalInset * 2)
    }

    /// The bar on a pill or a top-bar group label: along the bottom edge (the views are flipped),
    /// inside the attention outline.
    static func pillBarRect(in bounds: CGRect) -> CGRect {
        let h = Theme.Metrics.workspacePillBarWidth, side: CGFloat = 7
        return CGRect(x: bounds.minX + side, y: bounds.maxY - inset - h, width: max(bounds.width - side * 2, 0), height: h)
    }

    static func drawBar(_ workspaceColor: NSColor?, in rect: CGRect) {
        barColor(workspaceColor).setFill()
        let r = min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }
}

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
        let full = max(titlebarTrailingX - x - Self.deckGap, 0)  // short of the cup (#69)
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
        // The attention look (#61) changes how unchanged marks draw: redraw every element.
        let keys = note.userInfo?["keys"] as? Set<String> ?? []
        // #87: the chrome contrast changes every chrome color, also those copied into layers.
        if keys.contains("attention.done") || keys.contains("attention.unread") || keys.contains("colors.chrome_contrast") { applyTheme() }
    }
}
