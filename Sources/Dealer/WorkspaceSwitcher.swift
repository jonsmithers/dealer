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

/// How both switchers mark the selected workspace (#52): a strong neutral fill, a bar at the left
/// edge (the workspace's color, or the text color without one), a heavier title, and a neutral
/// `Theme.text` outline (the user asked for it). The outline sits exactly where an attention
/// outline goes and gives way to it: a waiting/failed entry shows only its colored outline, and
/// the neutral one cross-fades back in as the attention fades (#34). The fill is inset like the
/// color tint, inside both outlines.
enum SelectionStyle {
    static var inset: CGFloat { AttentionStyle.outlineWidth + 0.5 }

    static func drawFill(in bounds: CGRect, cornerRadius: CGFloat) {
        let r = bounds.insetBy(dx: inset, dy: inset), radius = max(cornerRadius - inset, 0)
        Theme.workspaceSelection.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    /// The neutral selection outline at `bounds`' edge, at `alpha` (1 − the attention outline's
    /// alpha, so the two never stack). Same width and path as `AttentionStyle`'s outline.
    static func drawOutline(in bounds: CGRect, cornerRadius: CGFloat, attention: Attention, attentionAlpha: CGFloat) {
        let alpha = attention.outlined ? 1 - min(max(attentionAlpha, 0), 1) : 1
        guard alpha > 0 else { return }
        let w = Theme.Metrics.workspaceSelectionOutline
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2),
                                xRadius: max(cornerRadius - w / 2, 0), yRadius: max(cornerRadius - w / 2, 0))
        path.lineWidth = w
        Theme.text.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    static func barColor(_ workspaceColor: NSColor?) -> NSColor { workspaceColor ?? Theme.text }

    static func drawBar(_ workspaceColor: NSColor?, in rect: CGRect) {
        barColor(workspaceColor).setFill()
        let r = rect.width / 2
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
        // The attention look (#61) changes how unchanged marks draw: redraw every element.
        let keys = note.userInfo?["keys"] as? Set<String> ?? []
        if keys.contains("attention.done") || keys.contains("attention.unread") { applyTheme() }
    }
}
