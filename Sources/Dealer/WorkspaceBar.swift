import AppKit

/// The workspace switcher: a slim row of numbered pills in the titlebar row, right of the traffic
/// lights, plus a "+" button. Deliberately plain; the chrome restyle owns its look.
///
/// Click a pill to switch, double-click to rename, right-click for a menu, middle-click to close.
final class WorkspaceBarView: FlippedView {
    private var buttons: [WorkspaceButton] = []
    private let addButton = WorkspaceButton()

    static let leadingInset: CGFloat = 78
    static let pillHeight: CGFloat = 22
    static let maxPillWidth: CGFloat = 180
    static let spacing: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.isAddButton = true
        addButton.toolTip = "New Workspace"
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The pill for workspace `i`, for tests and drag targets.
    func button(at i: Int) -> NSView? { buttons.indices.contains(i) ? buttons[i] : nil }

    func reload() {
        guard let c = controller else { return }
        while buttons.count < c.workspaces.count {
            let b = WorkspaceButton()
            addSubview(b)
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
}

/// One workspace pill: a faint number, then the name. Styled like the deck tabs, one size down.
final class WorkspaceButton: FlippedView {
    weak var workspace: Workspace?
    var isAddButton = false
    var number = "" { didSet { if number != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var attention: Attention = .none { didSet { if attention != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }

    private static let padding: CGFloat = 9
    private static let dotSize: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var titleAttrs: [NSAttributedString.Key: Any] {
        [.font: isActive ? Theme.Fonts.tabActive : Theme.Fonts.tab,
         .foregroundColor: isActive || hovering ? Theme.text : Theme.textMuted]
    }

    private var numberAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
         .foregroundColor: Theme.textFaint]
    }

    private var numberWidth: CGFloat { number.isEmpty ? 0 : ceil((number as NSString).size(withAttributes: numberAttrs).width) + 6 }
    private var dotWidth: CGFloat { attention > .none ? Self.dotSize + 6 : 0 }

    var idealWidth: CGFloat {
        if isAddButton { return 24 }
        return Self.padding * 2 + numberWidth + ceil((title as NSString).size(withAttributes: titleAttrs).width) + dotWidth
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Metrics.tabRadius
        if isActive && !isAddButton {
            Theme.surface.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
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

        var x = Self.padding
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

        if let color = attention.color {
            color.setFill()
            let d = Self.dotSize
            NSBezierPath(ovalIn: CGRect(x: bounds.width - Self.padding - d, y: (bounds.height - d) / 2, width: d, height: d)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        if isAddButton { return c.newWorkspace(nil) }
        guard let ws = workspace else { return }
        if event.clickCount == 2 { return c.renameWorkspaceInteractively(ws) }
        c.activate(ws)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let ws = workspace, let c = controller else { return }
        c.close(workspace: ws)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard workspace != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Workspace…", action: #selector(renameIt), keyEquivalent: "").target = self
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

extension TerminalWindowController {
    /// Places the switcher in the titlebar row. Called from `layoutWindow`.
    func layoutWorkspaceBar() {
        let bar = workspaceBar
        if bar.superview !== contentView { contentView.addSubview(bar) }
        let h = deckArea.minY
        let x = WorkspaceBarView.leadingInset
        bar.frame = CGRect(x: x, y: 0, width: max(contentView.bounds.width - x - Self.deckGap, 0), height: h)
        bar.reload()
        bar.layoutSubtreeIfNeeded()
    }
}
