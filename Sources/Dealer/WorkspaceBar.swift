import AppKit

/// The workspace switcher: a slim row of numbered pills in the titlebar row, right of the traffic
/// lights, plus a "+" button. Deliberately plain; the chrome restyle owns its look.
///
/// Click a pill to switch, double-click to rename, right-click for a menu, middle-click to close.
final class WorkspaceBarView: FlippedView {
    private var buttons: [WorkspaceButton] = []
    private let addButton = WorkspaceButton()

    static let leadingInset: CGFloat = 78
    static let pillHeight: CGFloat = 20
    static let maxPillWidth: CGFloat = 180

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.isAddButton = true
        addButton.title = "+"
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
        for (i, ws) in c.workspaces.enumerated() {
            let b = buttons[i]
            b.workspace = ws
            b.title = i < 9 ? "\(i + 1)  \(ws.displayName)" : ws.displayName
            b.isActive = ws === c.activeWorkspace
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let y = ((bounds.height - Self.pillHeight) / 2).rounded()
        for b in buttons + [addButton] {
            let w = min(b.idealWidth, Self.maxPillWidth)
            b.frame = CGRect(x: x, y: y, width: w, height: Self.pillHeight)
            x += w + 4
        }
    }
}

final class WorkspaceButton: FlippedView {
    weak var workspace: Workspace?
    var isAddButton = false
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var attrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .semibold : .regular),
            .foregroundColor: isActive ? Palette.text : Palette.muted,
            .paragraphStyle: para,
        ]
    }

    var idealWidth: CGFloat { isAddButton ? 22 : ceil((title as NSString).size(withAttributes: attrs).width) + 16 }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isActive {
            Palette.tabActive.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        } else if hovering {
            Palette.bar.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
        let h = (title as NSString).size(withAttributes: attrs).height
        let x: CGFloat = isAddButton ? (bounds.width - (title as NSString).size(withAttributes: attrs).width) / 2 : 8
        (title as NSString).draw(in: CGRect(x: x, y: (bounds.height - h) / 2, width: bounds.width - x - 4, height: h), withAttributes: attrs)
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
