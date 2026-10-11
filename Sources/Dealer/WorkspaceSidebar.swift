import AppKit

/// The workspace switcher (#6): a collapsible column on the left of the window listing its
/// workspaces top to bottom, plus a "New Workspace" row. Collapsed means fully hidden; the
/// `SidebarToggleButton` in the titlebar row (and ⌘B) brings it back.
///
/// Click a row to switch, double-click to rename, right-click for a menu, middle-click to close,
/// drag to reorder. Panes and tabs dragged onto a row move to that workspace (DragController).
final class WorkspaceSidebarView: FlippedView, ThemeApplying {
    private var rows: [WorkspaceRow] = []
    let addRow = WorkspaceRow()
    /// Insertion marker shown while a row is dragged.
    private let marker = FlippedView()

    static let rowSpacing: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        addRow.isAddRow = true
        addRow.title = "New Workspace"
        addSubview(addRow)
        marker.layer?.cornerRadius = 1
        marker.isHidden = true
        addSubview(marker)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        marker.layer?.backgroundColor = Theme.accentNeutral.cgColor
    }

    /// The row for workspace `i`, for tests (clicked through `window.sendEvent`) and drop targets.
    func row(at i: Int) -> NSView? { rows.indices.contains(i) ? rows[i] : nil }

    func reload() {
        guard let c = controller else { return }
        while rows.count < c.workspaces.count {
            let r = WorkspaceRow()
            addSubview(r, positioned: .below, relativeTo: marker)
            rows.append(r)
        }
        while rows.count > c.workspaces.count { rows.removeLast().removeFromSuperview() }
        for (i, ws) in c.workspaces.enumerated() {
            let r = rows[i]
            r.workspace = ws
            r.number = i < 9 ? "\(i + 1)" : ""
            r.title = ws.displayName
            r.detail = (ws.validFocusedPane ?? ws.decks.first?.activeTab?.focusTarget)?.statusLine ?? ""
            r.isActive = ws === c.activeWorkspace
            r.attention = ws.attention
            r.color = ws.color
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows + [addRow] {
            let h = r.detail.isEmpty ? Theme.Metrics.sidebarRowHeight : Theme.Metrics.sidebarRowDetailHeight
            r.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + Self.rowSpacing
        }
    }

    // MARK: Reorder

    /// Where a dragged row would land: the number of rows whose middle is above `y`.
    func insertionIndex(atY y: CGFloat) -> Int {
        rows.filter { $0.frame.midY < y }.count
    }

    func showMarker(at index: Int?) {
        guard let index else { marker.isHidden = true; return }
        let y = index < rows.count ? rows[index].frame.minY - Self.rowSpacing / 2
                                   : (rows.last?.frame.maxY ?? 0) + Self.rowSpacing / 2
        marker.frame = CGRect(x: 4, y: y - 1, width: bounds.width - 8, height: 2)
        marker.isHidden = false
    }

    // MARK: Drop target (DragController)

    /// The row under `p` (sidebar coordinates): a workspace, or `nil` workspace for "New Workspace".
    func dropTarget(at p: CGPoint) -> (workspace: Workspace?, rect: CGRect)? {
        for r in rows where r.frame.contains(p) { return r.workspace.map { ($0, r.frame) } }
        return addRow.frame.contains(p) ? (nil, addRow.frame) : nil
    }

    func rect(for ws: Workspace?) -> CGRect? {
        guard let ws else { return addRow.frame }
        return rows.first { $0.workspace === ws }?.frame
    }
}

/// One sidebar row: a faint number, the name and attention dot, and a dim status line
/// (agent state · cwd · branch of the workspace's focused pane). Styled like the deck tabs.
final class WorkspaceRow: FlippedView {
    weak var workspace: Workspace?
    var isAddRow = false
    var number = "" { didSet { if number != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var detail = "" { didSet { if detail != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var attention: Attention = .none {
        didSet {
            if attentionFade.onChange == nil { attentionFade.onChange = { [weak self] in self?.needsDisplay = true } }
            attentionFade.set(attention, subject: workspace)  // #34: a cleared workspace fades out
            if attention != oldValue { needsDisplay = true }
        }
    }
    let attentionFade = AttentionFadeState()
    /// The workspace's color (#9): a chip at the left edge plus a faint tint.
    var color: NSColor? { didSet { if color?.hexString != oldValue?.hexString { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragStart: CGPoint?
    private var reordering = false

    private static let padding: CGFloat = 10

    /// Where the color chip sits (also sampled by the self-test). The selected row's bar (#52) is
    /// wider and taller, on the same center.
    static func chipRect(in bounds: CGRect, active: Bool = false) -> CGRect {
        guard active else { return CGRect(x: 4, y: 7, width: 3, height: bounds.height - 14) }
        let w = Theme.Metrics.workspaceBarWidth
        return CGRect(x: 5.5 - w / 2, y: 5, width: w, height: bounds.height - 10)
    }
    private static let dotSize: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var sidebar: WorkspaceSidebarView? { superview as? WorkspaceSidebarView }

    private var titleAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return [.font: isActive && !isAddRow ? Theme.Fonts.workspaceActive : Theme.Fonts.tab,
                .foregroundColor: isAddRow ? (hovering ? Theme.text : Theme.textFaint)
                    : (isActive || hovering ? Theme.text : Theme.textMuted),
                .paragraphStyle: para]
    }

    /// The title's font, for the self-test's weight check (#52).
    var titleFontForTest: NSFont { titleAttrs[.font] as! NSFont }

    private var numberAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: isActive && !isAddRow ? Theme.textMuted : Theme.textFaint]
    }

    private var detailAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        return [.font: Theme.Fonts.paneBar, .foregroundColor: isActive && !isAddRow ? Theme.textMuted : Theme.textFaint, .paragraphStyle: para]
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Metrics.tabRadius
        let selected = isActive && !isAddRow
        if selected {
            SelectionStyle.drawFill(in: bounds, cornerRadius: radius)
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if !isAddRow {
            ColorStyle.drawTint(color, in: bounds, cornerRadius: radius)
            if selected { SelectionStyle.drawBar(color, in: Self.chipRect(in: bounds, active: true)) }
            else { ColorStyle.drawChip(color, in: Self.chipRect(in: bounds)) }
        }

        let titleFont = titleAttrs[.font] as! NSFont
        let titleH = ceil(titleFont.ascender - titleFont.descender)
        let detailFont = Theme.Fonts.paneBar
        let detailH = ceil(detailFont.ascender - detailFont.descender)
        let hasDetail = !detail.isEmpty && !isAddRow
        let titleY = hasDetail ? (bounds.height - titleH - detailH - 1) / 2 : (bounds.height - titleH) / 2
        let numberColumn: CGFloat = 16
        var x = Self.padding

        if isAddRow {
            let c = CGPoint(x: x + 5, y: bounds.midY)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x - 4.5, y: c.y))
            path.line(to: CGPoint(x: c.x + 4.5, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - 4.5))
            path.line(to: CGPoint(x: c.x, y: c.y + 4.5))
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            (hovering ? Theme.text : Theme.textFaint).setStroke()
            path.stroke()
        } else if !number.isEmpty {
            let nf = numberAttrs[.font] as! NSFont
            let nh = ceil(nf.ascender - nf.descender)
            (number as NSString).draw(at: CGPoint(x: x, y: titleY + (titleH - nh) / 2), withAttributes: numberAttrs)
        }
        x += numberColumn

        let dot = attentionFade.shown > .none && !isAddRow
        let right = bounds.width - Self.padding - (dot ? Self.dotSize + 6 : 0)
        (title as NSString).draw(in: CGRect(x: x, y: titleY, width: max(right - x, 0), height: titleH), withAttributes: titleAttrs)
        if hasDetail {
            (detail as NSString).draw(in: CGRect(x: x, y: titleY + titleH + 1, width: max(bounds.width - Self.padding - x, 0), height: detailH),
                                      withAttributes: detailAttrs)
        }
        if isActive && !isAddRow {
            SelectionStyle.drawOutline(in: bounds, cornerRadius: Theme.Metrics.tabRadius,
                                       attention: attentionFade.shown, attentionAlpha: attentionFade.alpha)
        }
        if dot {
            // #7: waiting outlines the whole row; done/unread get a muted dot only (Attention.swift).
            let d = Self.dotSize
            AttentionStyle.draw(attentionFade.shown, in: bounds, cornerRadius: Theme.Metrics.tabRadius,
                                dotRect: CGRect(x: bounds.width - Self.padding - d, y: titleY + (titleH - d) / 2, width: d, height: d), alpha: attentionFade.alpha)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        if isAddRow { return c.newWorkspace(nil) }
        guard let ws = workspace else { return }
        if event.clickCount == 2 { return c.renameWorkspaceInteractively(ws) }
        c.activate(ws)
        dragStart = event.locationInWindow
        reordering = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let sidebar else { return }
        let p = event.locationInWindow
        if !reordering {
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            reordering = true
        }
        sidebar.showMarker(at: sidebar.insertionIndex(atY: sidebar.convert(p, from: nil).y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; reordering = false }
        guard reordering, let sidebar, let ws = workspace, let c = controller, let from = c.index(of: ws) else { return }
        sidebar.showMarker(at: nil)
        let i = sidebar.insertionIndex(atY: sidebar.convert(event.locationInWindow, from: nil).y)
        let to = i > from ? i - 1 : i
        if to != from { c.move(workspace: ws, to: to) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let ws = workspace, let c = controller else { return }
        c.close(workspace: ws)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard workspace != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Workspace…", action: #selector(renameIt), keyEquivalent: "").target = self
        if let ws = workspace {
            menu.addItem(ColorMenu.item("Workspace Color", current: ws.color) { [weak self, weak ws] c in
                guard let ws else { return }
                self?.controller?.setColor(c, workspace: ws)
            })
        }
        menu.addItem(withTitle: "Close Workspace", action: #selector(closeIt), keyEquivalent: "").target = self
        return menu
    }

    @objc private func renameIt() {
        if let ws = workspace { controller?.renameWorkspaceInteractively(ws) }
    }

    @objc private func closeIt() {
        if let ws = workspace { controller?.close(workspace: ws) }
    }
}

/// The titlebar-row button that shows and hides the sidebar: a small window glyph whose left
/// column fills in while the sidebar is showing.
final class SidebarToggleButton: FlippedView {
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Show or Hide Workspace Sidebar (⌘B)"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.Metrics.tabRadius, yRadius: Theme.Metrics.tabRadius).fill()
        }
        let color = hovering || isOn ? Theme.text : Theme.textMuted
        let glyph = CGRect(x: bounds.midX - 8, y: bounds.midY - 6.5, width: 16, height: 13)
        let outline = NSBezierPath(roundedRect: glyph.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.2
        color.setStroke()
        outline.stroke()
        let column = CGRect(x: glyph.minX + 0.5, y: glyph.minY + 0.5, width: 5.5, height: glyph.height - 1)
        if isOn {
            color.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: column, xRadius: 2.5, yRadius: 2.5).fill()
        }
        let line = NSBezierPath()
        line.move(to: CGPoint(x: column.maxX, y: glyph.minY + 1))
        line.line(to: CGPoint(x: column.maxX, y: glyph.maxY - 1))
        line.lineWidth = 1.2
        line.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        controller?.toggleWorkspaceSidebar(nil)
    }
}

extension TerminalWindowController {
    /// Shown when the user said so, otherwise automatically once the window has 2+ workspaces.
    /// Never in top-bar mode (#8), which leaves `sidebarPreference` alone for when it's switched back.
    var isSidebarVisible: Bool {
        WorkspaceSwitcher.style == .sidebar && (sidebarPreference ?? (workspaces.count > 1))
    }

    /// Not `toggleSidebar(_:)`: NSWindow implements that selector, and it sits ahead of this
    /// controller in the responder chain, so a nil-target menu item (⌘B) would never get here (#13).
    @objc func toggleWorkspaceSidebar(_ sender: Any?) {
        guard WorkspaceSwitcher.style == .sidebar else { return NSSound.beep() }
        sidebarPreference = !isSidebarVisible
        layoutNow()
        refreshChrome()
    }

    /// Places the toggle in the titlebar row and the sidebar left of the deck area.
    /// Called from `layoutWindow`, which uses `deckArea` (already narrowed for the sidebar).
    func layoutWorkspaceSidebar() {
        let area = deckArea
        let toggle = sidebarToggle
        if toggle.superview !== contentView { contentView.addSubview(toggle) }
        toggle.frame = CGRect(x: 78, y: ((area.minY - 22) / 2).rounded(), width: 28, height: 22)
        toggle.isOn = isSidebarVisible
        toggle.isHidden = WorkspaceSwitcher.style != .sidebar

        let sb = workspaceSidebar
        if sb.superview !== contentView { contentView.addSubview(sb) }
        sb.isHidden = !isSidebarVisible
        sb.frame = CGRect(x: Self.deckGap, y: area.minY, width: Theme.Metrics.sidebarWidth, height: area.height)
        sb.reload()
        // reload() runs inside the window's layout pass, where its needsLayout would be dropped.
        sb.layoutSubtreeIfNeeded()
        layoutWorkspaceBar()
        layoutSettingsBanner()
    }
}
