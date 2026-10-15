import AppKit

/// The top-bar workspace switcher (`workspaceSwitcher = top`, #8): numbered pills in the titlebar
/// row, right of the traffic lights, plus a "+" button. The sidebar (WorkspaceSidebar.swift) is
/// the default; `WorkspaceSwitcher.swift` picks between them.
///
/// Click a pill to switch, double-click to rename, right-click for a menu, middle-click to close,
/// drag to reorder. Panes and tabs dragged onto a pill move to that workspace (DragController).
final class WorkspaceBarView: FlippedView, WorkspaceDropTargets, ThemeApplying {
    private var buttons: [WorkspaceButton] = []
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

    func reload() {
        guard let c = controller else { return }
        while buttons.count < c.workspaces.count {
            let b = WorkspaceButton()
            addSubview(b, positioned: .below, relativeTo: marker)
            buttons.append(b)
        }
        while buttons.count > c.workspaces.count { buttons.removeLast().removeFromSuperview() }
        // A lone, unnamed workspace needs no switcher: keep the titlebar quiet until there's a choice.
        let quiet = c.workspaces.count == 1 && c.workspaces[0].name == nil
        for (i, ws) in c.workspaces.enumerated() {
            let b = buttons[i]
            b.workspace = ws
            b.number = i < 9 ? "\(i + 1)" : ""
            b.title = ws.displayName
            b.isActive = ws === c.activeWorkspace
            b.attention = ws.attention
            b.isRunning = ws.isWorking  // AgentStatus.swift
            b.color = ws.color
            b.isHidden = quiet
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let y = ((bounds.height - Self.pillHeight) / 2).rounded()
        for b in buttons + [addButton] where !b.isHidden {
            let w = min(b.idealWidth, Self.maxPillWidth)
            b.frame = CGRect(x: x, y: y, width: w, height: Self.pillHeight)
            x += w + Self.spacing
        }
    }

    // MARK: Reorder

    /// Where a dragged pill would land: the number of shown pills whose middle is left of `x`.
    func insertionIndex(atX x: CGFloat) -> Int {
        buttons.filter { !$0.isHidden && $0.frame.midX < x }.count
    }

    func showMarker(at index: Int?) {
        guard let index else { marker.isHidden = true; return }
        let shown = buttons.filter { !$0.isHidden }
        let x = index < shown.count ? shown[index].frame.minX - Self.spacing / 2
                                    : (shown.last?.frame.maxX ?? 0) + Self.spacing / 2
        marker.frame = CGRect(x: x - 1, y: (bounds.height - Self.pillHeight) / 2, width: 2, height: Self.pillHeight)
        marker.isHidden = false
    }

    // MARK: Drop target (DragController)

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
    /// True while an agent in this workspace is working (#64, RunningSpinner.swift): a turning asterisk
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
    private var dragStart: CGPoint?
    private var reordering = false

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
            Theme.hover.setFill()
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
            // In the name's own colour: colours and outlines on chrome mean attention.
            RunningSpinner.draw(in: spinnerBox, color: titleAttrs[.foregroundColor] as! NSColor,
                                phase: RunningSpinner.phase())
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
        dragStart = event.locationInWindow
        reordering = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let bar = superview as? WorkspaceBarView else { return }
        let p = event.locationInWindow
        if !reordering {
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            reordering = true
        }
        bar.showMarker(at: bar.insertionIndex(atX: bar.convert(p, from: nil).x))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; reordering = false }
        guard reordering, let bar = superview as? WorkspaceBarView, let ws = workspace, let c = controller,
              let from = c.index(of: ws) else { return }
        bar.showMarker(at: nil)
        let i = bar.insertionIndex(atX: bar.convert(event.locationInWindow, from: nil).x)
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
