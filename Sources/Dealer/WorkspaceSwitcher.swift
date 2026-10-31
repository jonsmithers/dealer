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

/// How both switchers mark the selected workspace (#52; #90 tried an edge bar instead and was
/// reversed): a neutral `Theme.text` outline on the entry's outer edge (the attention outline's
/// width and path) and a heavier title; pills also get the `Theme.workspaceSelection` fill, sidebar
/// rows don't. On the sidebar attention draws no outline (#91, a large dot instead), so the
/// selection outline always shows there; draw it after `AttentionStyle.draw`, whose tint would
/// otherwise wash over it. On a pill it yields to an attention outline: a waiting/failed pill
/// shows only its colored outline, and the neutral one cross-fades back in as the attention fades
/// (#34); draw it just before `AttentionStyle.draw`.
enum SelectionStyle {
    static var inset: CGFloat { AttentionStyle.outlineWidth + 0.5 }

    /// Pills only: the fill, inset like the color tint, inside both outlines.
    static func drawFill(in bounds: CGRect, cornerRadius: CGFloat) {
        let r = bounds.insetBy(dx: inset, dy: inset), radius = max(cornerRadius - inset, 0)
        Theme.fill(Theme.workspaceSelection).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    /// The neutral selection outline at `bounds`' edge. With `yieldingTo` an outlined attention
    /// state (pills), it draws at 1 − the attention outline's alpha, so the two never stack.
    static func drawOutline(in bounds: CGRect, cornerRadius: CGFloat, yieldingTo attention: Attention = .none, attentionAlpha: CGFloat = 0) {
        let alpha = attention.outlined ? 1 - min(max(attentionAlpha, 0), 1) : 1
        guard alpha > 0 else { return }
        let w = Theme.Metrics.workspaceSelectionOutline
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2),
                                xRadius: max(cornerRadius - w / 2, 0), yRadius: max(cornerRadius - w / 2, 0))
        path.lineWidth = w
        Theme.text.withAlphaComponent(alpha).setStroke()
        path.stroke()
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
