import AppKit

// MARK: - Titlebar workspace switcher (#96)
//
// While the workspace sidebar is hidden (sidebar switcher mode only), a button in the titlebar row,
// right of the sidebar toggle, names the current workspace. Clicking it opens a dropdown listing
// every workspace (groups as sections, collapsed ones included) plus "New Workspace"; picking a row
// switches through `activate(_:)`, the sidebar's own path.
//
// It's a switcher entry (CLAUDE.md, "Behavior decisions"): the current workspace's color shows on it
// as on its sidebar row (faint tint and chip), and one dot shows the strongest attention of the
// *other* workspaces (no outline: that would read as the current one needing you; no stacks).
//
// The dropdown is an overlay view in the window's content view, like ⌘⇧A's panel, not an NSMenu:
// an NSMenu runs its own tracking loop that posted window events can't drive (the README demo,
// #98, clicks it with `window.postEvent`) and lives in a window of its own. Not modal: esc, a click
// outside, the window resigning key, or a pick closes it.

extension TerminalWindowController {
    /// The sidebar toggle's place in the titlebar row (WorkspaceSidebar.swift). Known before the
    /// first layout pass, so the clear line can use it while strips are placed.
    var sidebarToggleFrame: CGRect {
        CGRect(x: WorkspaceBarView.leadingInset, y: ((deckArea.minY - 22) / 2).rounded(), width: 28, height: 22)
    }

    /// Whether the titlebar switcher shows: sidebar mode with the sidebar hidden, unless the window
    /// has nothing to switch to (a lone, unnamed, ungrouped workspace: the pill bar's quiet rule).
    var showsTitlebarSwitcher: Bool {
        guard WorkspaceSwitcher.style == .sidebar, !isSidebarVisible else { return false }
        return !(workspaces.count == 1 && workspaces[0].name == nil && workspaces[0].group == nil)
    }

    /// The button's frame when shown: right of the toggle, as wide as its content allows.
    var titlebarSwitcherFrame: CGRect {
        let t = sidebarToggleFrame
        let b = titlebarSwitcher
        b.reload(from: self)
        let room = max(titlebarTrailingX - t.maxX - 4 - Self.titlebarStripMinWidth, TitlebarSwitcherButton.minWidth)
        let w = min(b.idealWidth, TitlebarSwitcherButton.maxWidth, room)
        return CGRect(x: t.maxX + 4, y: t.minY, width: w, height: t.height)
    }

    /// Places the button (called from `layoutWorkspaceSidebar`, after the toggle) and keeps an open
    /// dropdown on top of everything and under its button.
    func layoutTitlebarSwitcher() {
        let b = titlebarSwitcher
        if b.superview !== contentView { contentView.addSubview(b) }
        let shown = showsTitlebarSwitcher
        b.isHidden = !shown
        if shown { b.frame = titlebarSwitcherFrame }
        let menu = titlebarSwitcherMenu
        guard menu.isOpen else { return }
        if !shown { return menu.close(restoreFocus: false) }
        menu.place()
    }

    /// Keeps an open dropdown above everything in the window, the overlays included. Called from
    /// `layoutWindow` after `raiseOverlays`.
    func raiseTitlebarSwitcherMenu() {
        let menu = titlebarSwitcherMenu
        guard menu.isOpen, menu.superview === contentView, contentView.subviews.last !== menu else { return }
        contentView.addSubview(menu, positioned: .above, relativeTo: nil)
    }

    /// From `refreshChrome`: the name, color and other workspaces' attention can change without a
    /// layout pass; a new width needs one (strips start after the button).
    func refreshTitlebarSwitcher() {
        let b = titlebarSwitcher
        let width = b.idealWidth
        b.reload(from: self)
        if !b.isHidden, b.idealWidth != width { contentView.needsLayout = true }
        if titlebarSwitcherMenu.isOpen { titlebarSwitcherMenu.reload() }
    }

    /// The strongest attention among the workspaces other than the active one.
    var otherWorkspacesAttention: Attention {
        workspaces.filter { $0 !== activeWorkspace }.map(\.attention).max() ?? .none
    }
}

/// The titlebar button: color chip, the current workspace's name, a chevron, and a dot when another
/// workspace needs attention.
final class TitlebarSwitcherButton: FlippedView {
    static let maxWidth: CGFloat = 220
    static let minWidth: CGFloat = 60
    private static let padding: CGFloat = 8
    /// Where the name starts: after the chip's column (kept with or without a color, so the name
    /// doesn't jump when one is set).
    private static let titleX: CGFloat = 12
    private static let chevronWidth: CGFloat = 8
    private static var dotSize: CGFloat { Theme.Metrics.switcherDotSize }

    /// The workspace shown (the window's active one). Weak: views can outlive their window (#43).
    private(set) weak var workspace: Workspace?
    private(set) var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    /// The current workspace's color (#9): the faint tint plus a chip, as on its sidebar row.
    private(set) var color: NSColor? { didSet { if color?.hexString != oldValue?.hexString { needsDisplay = true } } }
    /// The strongest attention of the *other* workspaces: one dot, fading out when cleared (#34).
    var otherAttention: Attention = .none {
        didSet {
            if attentionFade.onChange == nil { attentionFade.onChange = { [weak self] in self?.needsDisplay = true } }
            attentionFade.set(otherAttention, subject: subject)
            if otherAttention != oldValue { needsDisplay = true }
        }
    }
    let attentionFade = AttentionFadeState()
    /// The fade's subject: the window, so switching workspaces doesn't reset a fade.
    private weak var subject: AnyObject?
    /// Drawn pressed while its dropdown is open.
    var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }
    /// Set by a press; a drag onto a row and a release there picks it, like a popup button.
    private var pressMoved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Switch Workspace"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(from c: TerminalWindowController) {
        subject = c
        let ws = c.activeWorkspace
        workspace = ws
        title = ws.displayName
        color = ws.color
        otherAttention = c.otherWorkspacesAttention
    }

    private var titleAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return [.font: Theme.Fonts.tab, .foregroundColor: Theme.text, .paragraphStyle: para]
    }

    private var dotWidth: CGFloat { attentionFade.shown > .none ? Self.dotSize + 6 : 0 }

    /// Fits the name, the chevron and the dot.
    var idealWidth: CGFloat {
        Self.titleX + ceil((title as NSString).size(withAttributes: titleAttrs).width) + 6
            + Self.chevronWidth + dotWidth + Self.padding
    }

    /// The color chip (self-test hook): 3pt at the left edge, like a sidebar row's.
    var chipRect: CGRect { CGRect(x: 4, y: 5, width: 3, height: bounds.height - 10) }
    /// The other workspaces' attention dot, at the right end (self-test hook).
    var attentionDotRect: CGRect {
        let d = Self.dotSize
        return CGRect(x: bounds.width - Self.padding - d, y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
    }
    var chevronRect: CGRect {
        CGRect(x: bounds.width - Self.padding - dotWidth - Self.chevronWidth, y: bounds.midY - 2, width: Self.chevronWidth, height: 4)
    }
    /// A point inside the tint and clear of the text (self-test hook).
    var tintSamplePoint: CGPoint { CGPoint(x: Self.titleX - 3, y: bounds.height - 4) }

    // #27: a press here must never drag the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Metrics.tabRadius
        if hovering || isOpen {
            Theme.fill(Theme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        ColorStyle.drawTint(color, in: bounds, cornerRadius: radius)
        ColorStyle.drawChip(color, in: chipRect)

        let font = Theme.Fonts.tab
        let h = ceil(font.ascender - font.descender)
        let right = chevronRect.minX - 6
        (title as NSString).draw(in: CGRect(x: Self.titleX, y: (bounds.height - h) / 2, width: max(right - Self.titleX, 0), height: h),
                                 withAttributes: titleAttrs)

        let c = chevronRect
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: c.minX, y: c.minY))
        chevron.line(to: CGPoint(x: c.midX, y: c.maxY))
        chevron.line(to: CGPoint(x: c.maxX, y: c.minY))
        chevron.lineWidth = 1.3
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        (hovering || isOpen ? Theme.text : Theme.textMuted).setStroke()
        chevron.stroke()

        if attentionFade.shown > .none {
            AttentionStyle.drawDot(attentionFade.shown, in: attentionDotRect, alpha: attentionFade.alpha)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        pressMoved = false
        let menu = c.titlebarSwitcherMenu
        if menu.isOpen { return menu.close(restoreFocus: true) }
        menu.open(in: c)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let menu = controller?.titlebarSwitcherMenu, menu.isOpen else { return }
        pressMoved = true
        menu.highlight(menu.row(at: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressMoved, let menu = controller?.titlebarSwitcherMenu, menu.isOpen,
              let row = menu.row(at: event.locationInWindow) else { return }
        menu.pick(row)
    }
}

/// The dropdown under the titlebar button.
final class TitlebarSwitcherMenu: FlippedView, ThemeApplying {
    private(set) var rows: [TitlebarSwitcherRow] = []
    /// The row under the pointer or picked with ↑/↓.
    private(set) weak var highlighted: TitlebarSwitcherRow?
    private weak var owner: TerminalWindowController?
    /// The workspace that was current when it opened: a switch from anywhere else (⌃1–9, the CLI)
    /// closes it, since focus goes to the new workspace's terminal.
    private weak var openedOn: Workspace?
    /// Where focus goes back to on esc.
    private weak var previousResponder: NSResponder?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    static let inset: CGFloat = 5
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 340

    var isOpen: Bool { superview != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            return s
        }()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.chrome.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        rows.forEach { $0.needsDisplay = true }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// The row for workspace `ws` while open (self-test and demo hook).
    func row(for ws: Workspace) -> TitlebarSwitcherRow? { rows.first { $0.workspace === ws } }
    /// The "New Workspace" row while open.
    var newWorkspaceRow: TitlebarSwitcherRow? { rows.first { if case .newWorkspace = $0.kind { return true }; return false } }

    /// The pickable row at a window point, if any.
    func row(at windowPoint: CGPoint) -> TitlebarSwitcherRow? {
        guard isOpen else { return nil }
        let p = convert(windowPoint, from: nil)
        return rows.first { $0.isPickable && $0.frame.contains(p) }
    }

    // MARK: Open, close, pick

    func open(in c: TerminalWindowController) {
        guard let window = c.window, !c.titlebarSwitcher.isHidden else { return }
        owner = c
        openedOn = c.activeWorkspace
        previousResponder = window.firstResponder
        applyTheme()
        c.contentView.addSubview(self, positioned: .above, relativeTo: nil)
        c.titlebarSwitcher.isOpen = true
        highlighted = nil  // the check mark shows the current one; ↑/↓ start from it
        reload()
        window.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, self.isOpen else { return e }
            let inMenu = e.window === self.window && self.bounds.contains(self.convert(e.locationInWindow, from: nil))
            // The button toggles the dropdown itself.
            let onButton = e.window === self.window && self.owner.map { b in
                b.titlebarSwitcher.bounds.contains(b.titlebarSwitcher.convert(e.locationInWindow, from: nil))
            } == true
            if !inMenu && !onButton { self.close(restoreFocus: false) }
            return e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        }
    }

    func close(restoreFocus: Bool) {
        guard isOpen else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let w = window
        let wasFirstResponder = w?.firstResponder === self
        removeFromSuperview()
        owner?.titlebarSwitcher.isOpen = false
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        if let w {
            if restoreFocus, let r = previousResponder { w.makeFirstResponder(r) }
            else if wasFirstResponder, let p = owner?.focusedPane { w.makeFirstResponder(p.surface) }
        }
        previousResponder = nil
        owner = nil
    }

    /// Switches to the row's workspace (or makes a new one) through the sidebar's path.
    func pick(_ row: TitlebarSwitcherRow) {
        guard let c = owner else { return }
        let kind = row.kind, ws = row.workspace
        close(restoreFocus: false)
        switch kind {
        case .workspace: if let ws { c.activate(ws) }
        case .newWorkspace: c.newWorkspace(nil)
        case .header, .separator: break
        }
    }

    func highlight(_ row: TitlebarSwitcherRow?) {
        guard row?.isPickable != false else { return }
        let old = highlighted
        highlighted = row
        old?.needsDisplay = true
        row?.needsDisplay = true
    }

    /// Rebuilds the rows from the window's workspaces, keeping the highlighted one.
    func reload() {
        guard let c = owner else { return }
        if c.activeWorkspace !== openedOn { return close(restoreFocus: false) }
        var kinds: [(TitlebarSwitcherRow.Kind, Workspace?, WorkspaceGroup?)] = []
        var lastGroup: WorkspaceGroup?
        for (i, ws) in c.workspaces.enumerated() {
            if let g = ws.group, g !== lastGroup { kinds.append((.header(g.name), nil, g)) }
            lastGroup = ws.group
            kinds.append((.workspace(number: i < 9 ? i + 1 : nil, indented: ws.group != nil), ws, nil))
        }
        kinds.append((.separator, nil, nil))
        kinds.append((.newWorkspace, nil, nil))
        // Update rows in place, keyed by what they stand for. This runs on every chrome refresh (a
        // pane reporting progress refreshes it once or twice a second), and a row replaced between
        // a click's press and release would lose the click: AppKit sends the release to the view
        // that took the press. Only rows whose subject is gone are removed.
        var old = rows
        func reuse(_ match: (TitlebarSwitcherRow) -> Bool) -> TitlebarSwitcherRow? {
            guard let i = old.firstIndex(where: match) else { return nil }
            return old.remove(at: i)
        }
        let next: [TitlebarSwitcherRow] = kinds.map { k, ws, g in
            let found: TitlebarSwitcherRow?
            switch k {
            case .workspace: found = ws.flatMap { ws in reuse { $0.workspace === ws } }
            case .header: found = reuse { $0.group != nil && $0.group === g }
            case .separator: found = reuse { if case .separator = $0.kind { return true }; return false }
            case .newWorkspace: found = reuse { $0.isNewWorkspace }
            }
            let r = found ?? TitlebarSwitcherRow(kind: k, workspace: ws, group: g)
            r.kind = k
            r.isCurrent = ws != nil && ws === c.activeWorkspace
            if let ws {
                r.title = ws.displayName
                r.color = ws.color
                r.attention = ws.attention
            } else if case let .header(name) = k {
                r.title = name
            }
            if r.superview !== self { addSubview(r) }
            return r
        }
        old.forEach { $0.removeFromSuperview() }
        if let h = highlighted, !next.contains(where: { $0 === h }) { highlighted = nil }
        let moved = next.count != rows.count || zip(next, rows).contains { $0 !== $1 }
        let width = rows.map(\.idealWidth).max()
        rows = next
        // Frames only change when the rows or their widths do.
        if moved || rows.map(\.idealWidth).max() != width || frame.isEmpty { place() }
    }

    /// Sizes the dropdown to its rows and puts it under the button.
    func place() {
        guard let c = owner else { return }
        let b = c.titlebarSwitcher.frame
        let ideal = rows.map(\.idealWidth).max() ?? 0
        let room = c.contentView.bounds.width - b.minX - 8
        let w = min(max(ideal, Self.minWidth, b.width), Self.maxWidth, max(room, 120))
        var y = Self.inset
        for r in rows {
            r.frame = CGRect(x: Self.inset, y: y, width: w - Self.inset * 2, height: r.height)
            y += r.height
        }
        let maxH = c.contentView.bounds.height - b.maxY - 12
        frame = CGRect(x: b.minX, y: b.maxY + 4, width: w, height: min(y + Self.inset, max(maxH, 60))).integral
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)        // ↓
        case 126: move(-1)       // ↑
        case 36, 76:             // return, enter
            if let h = highlighted { pick(h) }
        case 53: close(restoreFocus: true)  // esc
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close(restoreFocus: true) }

    private func move(_ d: Int) {
        let pickable = rows.filter(\.isPickable)
        guard !pickable.isEmpty else { return }
        let i = (highlighted ?? rows.first { $0.isCurrent }).flatMap { h in pickable.firstIndex { $0 === h } } ?? (d > 0 ? -1 : pickable.count)
        highlight(pickable[min(max(i + d, 0), pickable.count - 1)])
    }
}

/// One dropdown row: a workspace (check mark when current, chip, name, attention dot, ⌃N), a group's
/// name, a separator, or "New Workspace".
final class TitlebarSwitcherRow: FlippedView {
    enum Kind {
        case workspace(number: Int?, indented: Bool)
        case header(String)
        case separator
        case newWorkspace
    }

    /// What the row shows; updated in place by `reload`, which keeps a row as long as its subject.
    var kind: Kind { didSet { needsDisplay = true } }
    /// A workspace row's workspace. Weak: the dropdown must never keep one alive (#43).
    private(set) weak var workspace: Workspace?
    /// A header row's group (weak, like the workspace).
    private(set) weak var group: WorkspaceGroup?
    var isCurrent = false { didSet { if isCurrent != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var color: NSColor? { didSet { if color?.hexString != oldValue?.hexString { needsDisplay = true } } }
    /// The workspace's strongest attention: one dot (the sidebar row stacks them; this is a list).
    var attention: Attention = .none { didSet { if attention != oldValue { needsDisplay = true } } }

    init(kind: Kind, workspace: Workspace? = nil, group: WorkspaceGroup? = nil) {
        self.kind = kind
        self.workspace = workspace
        self.group = group
        super.init(frame: .zero)
        if case .newWorkspace = kind { title = "New Workspace" }
        if case let .header(name) = kind { title = name }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    var isPickable: Bool {
        switch kind {
        case .workspace: return workspace != nil
        case .newWorkspace: return true
        case .header, .separator: return false
        }
    }
    var isNewWorkspace: Bool { if case .newWorkspace = kind { return true }; return false }

    var height: CGFloat {
        switch kind {
        case .workspace, .newWorkspace: return 26
        case .header: return 22
        case .separator: return 9
        }
    }

    private var dropdown: TitlebarSwitcherMenu? { superview as? TitlebarSwitcherMenu }
    var isHighlighted: Bool { dropdown?.highlighted === self }

    private static let checkX: CGFloat = 8
    private static let chipX: CGFloat = 24
    private static let titleX: CGFloat = 32
    private var indent: CGFloat { if case let .workspace(_, ind) = kind, ind { return Theme.Metrics.groupIndent }; return 0 }

    private var hint: String {
        switch kind {
        case let .workspace(n, _): return n.map { "⌃\($0)" } ?? ""
        case .newWorkspace: return "⌘N"
        default: return ""
        }
    }

    private var titleFont: NSFont {
        if case .header = kind { return Theme.Fonts.groupHeader }
        return isCurrent ? Theme.Fonts.workspaceActive : Theme.Fonts.tab
    }
    private var hintAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.textFaint]
    }

    var idealWidth: CGFloat {
        let t = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let h = hint.isEmpty ? 0 : ceil((hint as NSString).size(withAttributes: hintAttrs).width) + 14
        return TitlebarSwitcherMenu.inset * 2 + Self.titleX + indent + t + 8 + Theme.Metrics.switcherDotSize + 6 + h + 10
    }

    /// The chip (self-test hook).
    var chipRect: CGRect { CGRect(x: Self.chipX + indent, y: 6, width: 3, height: bounds.height - 12) }
    /// The check mark's box (self-test hook).
    var checkRect: CGRect { CGRect(x: Self.checkX, y: (bounds.height - 10) / 2, width: 10, height: 10) }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { if isPickable { dropdown?.highlight(self) } }
    override func mouseExited(with event: NSEvent) {
        if isHighlighted, let m = dropdown { m.highlight(nil) }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isPickable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        dropdown?.pick(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if case .separator = kind {
            Theme.hairline.setFill()
            NSRect(x: 6, y: (bounds.height / 2).rounded(), width: bounds.width - 12, height: 1).fill()
            return
        }
        // The highlighted row: an outline like ⌘⇧A's, since Theme.hover is too close to the chrome.
        if isHighlighted { SelectionStyle.drawOutline(in: bounds, cornerRadius: 5) }

        let isHeader: Bool = { if case .header = kind { return true }; return false }()
        if isCurrent {
            let r = checkRect
            let check = NSBezierPath()
            check.move(to: CGPoint(x: r.minX + 0.5, y: r.midY))
            check.line(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - 1))
            check.line(to: CGPoint(x: r.maxX - 0.5, y: r.minY + 1))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Theme.text.setStroke()
            check.stroke()
        }
        if isNewWorkspace {
            let c = CGPoint(x: checkRect.midX, y: bounds.midY)  // in the check mark's column
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: c.x - 4, y: c.y)); plus.line(to: CGPoint(x: c.x + 4, y: c.y))
            plus.move(to: CGPoint(x: c.x, y: c.y - 4)); plus.line(to: CGPoint(x: c.x, y: c.y + 4))
            plus.lineWidth = 1.3
            plus.lineCapStyle = .round
            Theme.textMuted.setStroke()
            plus.stroke()
        }
        ColorStyle.drawChip(color, in: chipRect)

        var right = bounds.width - 10
        if !hint.isEmpty {
            let s = (hint as NSString).size(withAttributes: hintAttrs)
            (hint as NSString).draw(at: CGPoint(x: right - s.width, y: (bounds.height - s.height) / 2), withAttributes: hintAttrs)
            right -= s.width + 14
        }
        if attention != .none {
            let d = Theme.Metrics.switcherDotSize
            AttentionStyle.drawDot(attention, in: CGRect(x: right - d, y: ((bounds.height - d) / 2).rounded(), width: d, height: d))
            right -= d + 8
        }
        let font = titleFont
        let h = ceil(font.ascender - font.descender)
        let x = isHeader ? Self.checkX : Self.titleX + indent
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let color = isHeader ? Theme.textMuted : (isNewWorkspace && !isHighlighted ? Theme.textMuted : Theme.text)
        (title as NSString).draw(in: CGRect(x: x, y: (bounds.height - h) / 2, width: max(right - x, 0), height: h),
                                 withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }
}
