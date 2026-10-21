import AppKit

/// The top-bar workspace switcher (`workspaceSwitcher = top`, #8): numbered pills in the titlebar
/// row, right of the traffic lights, plus a "+" button. The sidebar (WorkspaceSidebar.swift) is
/// the default; `WorkspaceSwitcher.swift` picks between them.
///
/// Click a pill to switch, double-click to rename, right-click for a menu, middle-click to close,
/// drag to reorder. Panes and tabs dragged onto a pill move to that workspace (DragController).
/// A group (#80) is a run of pills led by its label pill; collapsed, the label alone stands for it,
/// and clicking the label expands or collapses it.
final class WorkspaceBarView: FlippedView, WorkspaceDropTargets, ThemeApplying, SwitcherDragHost {
    /// One pill per workspace, in `workspaces` order (members of a collapsed group are hidden).
    private var buttons: [WorkspaceButton] = []
    /// One label pill per group (#80): it leads the group's run of pills, or alone stands for the
    /// collapsed group.
    private var labels: [GroupHeaderView] = []
    /// The lone, unnamed, ungrouped workspace shows no pill.
    private var quiet = false
    let addButton = WorkspaceButton()
    /// Insertion marker shown while a pill is dragged.
    private let marker = FlippedView()

    static let leadingInset: CGFloat = 78
    static let pillHeight: CGFloat = 22
    static let maxPillWidth: CGFloat = 180
    static let spacing: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.isAddButton = true
        addButton.toolTip = "New Workspace"
        addSubview(addButton)
        marker.layer?.cornerRadius = 1
        marker.isHidden = true
        addSubview(marker)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        marker.layer?.backgroundColor = Theme.accentNeutral.cgColor
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The pill for workspace `i`, for tests and drag targets.
    func button(at i: Int) -> NSView? { buttons.indices.contains(i) ? buttons[i] : nil }

    /// The label pill of group `g` (#80), for tests.
    func label(for g: WorkspaceGroup) -> GroupHeaderView? { labels.first { $0.group === g } }

    func reload() {
        guard let c = controller else { return }
        while buttons.count < c.workspaces.count {
            let b = WorkspaceButton()
            addSubview(b, positioned: .below, relativeTo: marker)
            buttons.append(b)
        }
        while buttons.count > c.workspaces.count { buttons.removeLast().removeFromSuperview() }
        // A lone, unnamed, ungrouped workspace needs no switcher: keep the titlebar quiet until there's a choice.
        quiet = c.workspaces.count == 1 && c.workspaces[0].name == nil && c.workspaces[0].group == nil
        for (i, ws) in c.workspaces.enumerated() {
            let b = buttons[i]
            b.workspace = ws
            b.number = i < 9 ? "\(i + 1)" : ""
            b.title = ws.displayName
            b.isActive = ws === c.activeWorkspace
            b.attention = ws.attention
            b.isRunning = ws.isWorking  // AgentStatus.swift
            b.color = ws.color
            b.isHidden = quiet || ws.group?.isCollapsed == true
        }
        let groups = c.groups
        while labels.count < groups.count {
            let l = GroupHeaderView()
            l.style = .pill
            addSubview(l, positioned: .below, relativeTo: marker)
            labels.append(l)
        }
        while labels.count > groups.count { labels.removeLast().removeFromSuperview() }
        for (l, g) in zip(labels, groups) {
            l.group = g
            l.title = g.name
            l.isCollapsed = g.isCollapsed
            l.count = c.members(of: g).count
            l.isActive = g.isCollapsed && c.activeWorkspace.group === g
            l.attention = g.isCollapsed ? c.attention(of: g) : .none
            l.isRunning = g.isCollapsed && c.members(of: g).contains(where: \.isWorking)
        }
        needsLayout = true
    }

    /// Computed, never stored: AppKit can keep a closed window's views, and they must not hold
    /// its workspaces (#43).
    var entryViews: [(SwitcherEntry, NSView)] {
        (quiet ? [] : SwitcherLayout.entries(controller?.workspaces ?? [])).compactMap { e in
            switch e {
            case let .workspace(ws): return buttons.first { $0.workspace === ws }.map { (e, $0) }
            case let .header(g): return label(for: g).map { (e, $0) }
            }
        }
    }

    var isVertical: Bool { false }

    /// The frames `layout` gives each entry view and the "+" button, in order.
    private func plannedFrames() -> [(NSView, CGRect)] {
        var out: [(NSView, CGRect)] = []
        var x: CGFloat = 0
        let y = ((bounds.height - Self.pillHeight) / 2).rounded()
        var prev: SwitcherEntry?
        func inGroup(_ e: SwitcherEntry) -> Bool { e.group != nil || e.memberOf != nil }
        for (e, v) in entryViews {
            // A group's run of pills is set apart from its neighbours.
            if let p = prev, e.group != nil || (inGroup(p) && !inGroup(e)) { x += Theme.Metrics.groupPillGap }
            let ideal = (v as? WorkspaceButton)?.idealWidth ?? (v as? GroupHeaderView)?.idealWidth ?? 0
            let w = min(ideal, Self.maxPillWidth)
            out.append((v, CGRect(x: x, y: y, width: w, height: Self.pillHeight)))
            x += w + Self.spacing
            prev = e
        }
        if let p = prev, inGroup(p) { x += Theme.Metrics.groupPillGap }
        out.append((addButton, CGRect(x: x, y: y, width: addButton.idealWidth, height: Self.pillHeight)))
        return out
    }

    /// Width of the pills, group labels and "+", i.e. the fixed left segment in top-bar mode.
    var contentWidth: CGFloat { (plannedFrames().last?.1.maxX ?? 0) + Self.spacing }

    override func layout() {
        super.layout()
        for b in buttons where b.isHidden { b.frame = .zero }
        for (v, f) in plannedFrames() { v.frame = f }
    }

    // MARK: Reorder

    func showDropMarker(_ drop: SwitcherDrop?) {
        guard let drop else { marker.isHidden = true; return }
        marker.frame = markerRect(for: drop, thickness: 2, spacing: Self.spacing, inset: 0)
        marker.isHidden = false
    }

    // MARK: Drop target (DragController)

    /// A group's label pill is no target.
    func dropTarget(at p: CGPoint) -> (workspace: Workspace?, rect: CGRect)? {
        for b in buttons where !b.isHidden && b.frame.contains(p) { return b.workspace.map { ($0, b.frame) } }
        return addButton.frame.contains(p) ? (nil, addButton.frame) : nil
    }

    func rect(for ws: Workspace?) -> CGRect? {
        guard let ws else { return addButton.frame }
        return buttons.first { $0.workspace === ws && !$0.isHidden }?.frame
    }
}

/// One workspace pill: a faint number, then the name. Styled like the deck tabs, one size down.
final class WorkspaceButton: FlippedView {
    weak var workspace: Workspace?
    var isAddButton = false
    var number = "" { didSet { if number != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var attention: Attention = .none {
        didSet {
            if attentionFade.onChange == nil { attentionFade.onChange = { [weak self] in self?.needsDisplay = true } }
            attentionFade.set(attention, subject: workspace)  // #34: a cleared workspace fades out
            if attention != oldValue { needsDisplay = true }
        }
    }
    let attentionFade = AttentionFadeState()
    /// True while an agent in this workspace is working (#64, RunningSpinner.swift): Claude's working mark
    /// in front of the number. Unlike a tab, a pill is sized to its content, so it widens by the
    /// spinner's slot, the way it already does for the attention dot.
    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if spinner.onChange == nil { spinner.onChange = { [weak self] in self?.needsDisplay = true } }
            spinner.set(isRunning)
            superview?.needsLayout = true
        }
    }
    let spinner = RunningSpinnerState()
    /// The workspace's color (#9): a dot before the number plus a faint tint.
    var color: NSColor? { didSet { if color?.hexString != oldValue?.hexString { needsDisplay = true; superview?.needsLayout = true } } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracker = SwitcherDragTracker()

    private static let padding: CGFloat = 9
    private static var dotSize: CGFloat { Theme.Metrics.switcherDotSize }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var titleAttrs: [NSAttributedString.Key: Any] {
        [.font: isActive && !isAddButton ? Theme.Fonts.workspaceActive : Theme.Fonts.tab,
         .foregroundColor: isActive || hovering ? Theme.text : Theme.textMuted]
    }

    /// The title's font, for the self-test's weight check (#52).
    var titleFontForTest: NSFont { titleAttrs[.font] as! NSFont }

    private var numberAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
         .foregroundColor: isActive && !isAddButton ? Theme.textMuted : Theme.textFaint]
    }

    private var numberWidth: CGFloat { number.isEmpty ? 0 : ceil((number as NSString).size(withAttributes: numberAttrs).width) + 6 }
    private var dotWidth: CGFloat { attentionFade.shown > .none ? Self.dotSize + 6 : 0 }

    private var chipWidth: CGFloat { color == nil || isAddButton ? 0 : 10 }
    /// Where the color dot sits (also sampled by the self-test).
    var chipRect: CGRect { CGRect(x: Self.padding, y: (bounds.height - 6) / 2, width: 6, height: 6) }
    /// The selected pill's bar (#52), in the left padding: the sidebar's bar, narrower, since a
    /// pill has no room for a wider one without shifting its text.
    var barRect: CGRect {
        let w = Theme.Metrics.workspacePillBarWidth
        return CGRect(x: 3, y: 6, width: w, height: bounds.height - 12)
    }

    var idealWidth: CGFloat {
        if isAddButton { return 24 }
        return Self.padding * 2 + chipWidth + spinner.leading + numberWidth
            + ceil((title as NSString).size(withAttributes: titleAttrs).width) + dotWidth
    }

    /// The attention dot, at the pill's right end (also read by the self-test).
    var attentionDotRect: CGRect {
        let d = Self.dotSize
        return CGRect(x: bounds.width - Self.padding - d, y: (bounds.height - d) / 2, width: d, height: d)
    }
    /// The spinner's box, after the colour chip (self-test hook).
    var spinnerBox: CGRect { RunningSpinner.box(in: bounds, x: Self.padding + chipWidth) }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Metrics.tabRadius
        let selected = isActive && !isAddButton
        if selected {
            SelectionStyle.drawFill(in: bounds, cornerRadius: radius)
        } else if hovering {
            Theme.fill(Theme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if !isAddButton {
            ColorStyle.drawTint(color, in: bounds, cornerRadius: radius)
            ColorStyle.drawChip(color, in: chipRect)
            if selected { SelectionStyle.drawBar(color, in: barRect) }
        }

        if isAddButton {
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x - 4.5, y: c.y))
            path.line(to: CGPoint(x: c.x + 4.5, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - 4.5))
            path.line(to: CGPoint(x: c.x, y: c.y + 4.5))
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            (hovering ? Theme.text : Theme.textFaint).setStroke()
            path.stroke()
            return
        }

        var x = Self.padding + chipWidth
        if spinner.isRunning {
            RunningSpinner.draw(in: spinnerBox, phase: RunningSpinner.phase())
            x += RunningSpinner.slot
        }
        if !number.isEmpty {
            let font = numberAttrs[.font] as! NSFont
            let h = ceil(font.ascender - font.descender)
            (number as NSString).draw(at: CGPoint(x: x, y: (bounds.height - h) / 2), withAttributes: numberAttrs)
            x += numberWidth
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var attrs = titleAttrs
        attrs[.paragraphStyle] = para
        let font = attrs[.font] as! NSFont
        let h = ceil(font.ascender - font.descender)
        let w = bounds.width - x - Self.padding - dotWidth
        (title as NSString).draw(in: CGRect(x: x, y: (bounds.height - h) / 2, width: max(w, 0), height: h), withAttributes: attrs)

        if isActive {
            SelectionStyle.drawOutline(in: bounds, cornerRadius: Theme.Metrics.tabRadius,
                                       attention: attentionFade.shown, attentionAlpha: attentionFade.alpha)
        }
        if attentionFade.shown > .none {
            // #7 owns the look: waiting outlines the pill, done/unread get a muted dot (Attention.swift).
            AttentionStyle.draw(attentionFade.shown, in: bounds, cornerRadius: Theme.Metrics.tabRadius,
                                dotRect: attentionDotRect, alpha: attentionFade.alpha)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        if isAddButton { return c.newWorkspace(nil) }
        guard let ws = workspace else { return }
        if event.clickCount == 2 { return c.renameWorkspaceInteractively(ws) }
        c.activate(ws)
        tracker.down(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ws = workspace else { return }
        tracker.moved(event, entry: .workspace(ws), host: superview as? WorkspaceBarView)
    }

    override func mouseUp(with event: NSEvent) {
        guard let ws = workspace else { return }
        _ = tracker.up(event, entry: .workspace(ws), host: superview as? WorkspaceBarView)
    }

    /// Middle-click closes the workspace (#37); other extra buttons (back/forward) do nothing (#57).
    private var middleClick = MiddleClick()
    override func otherMouseDown(with event: NSEvent) {
        middleClick.down(event) { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        guard middleClick.up(event, in: self, passOn: { super.otherMouseUp(with: event) }),
              let ws = workspace, let c = controller else { return }
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
            if let c = controller {
                menu.addItem(.separator())
                c.groupMenuItems(for: ws).forEach(menu.addItem)  // #80
                menu.addItem(.separator())
            }
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
