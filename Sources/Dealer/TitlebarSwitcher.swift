import AppKit

// MARK: - Titlebar workspace switcher (#96)
//
// While the workspace sidebar is hidden (sidebar switcher mode only), a button in the titlebar row
// names the current workspace: at the row's right end, before the cup's reserve, or with `[workspaces]
// titlebar_switcher = "left"` right of the sidebar toggle (#104). Clicking it opens a dropdown listing
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
//
// Workspace › Go to Workspace… (⌘P, #105) opens the same dropdown: under the button when it shows,
// else at the top center of the window, where ⌘⇧A's panel sits. A search field at its top has the
// keys whenever it's open; typing filters the rows with Go to Pane's matching (`PanePickerMatch`),
// and ↑/↓ or ⌃P/⌃N (the system key bindings' `moveUp:`/`moveDown:`) move the highlight.

/// `[workspaces] titlebar_switcher` (#104): which end of the titlebar row the button sits at.
enum TitlebarSwitcherSide: String, CaseIterable {
    case right, left
}

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

    /// The button's frame when shown, always `TitlebarSwitcherButton.width` (#102), so the strips
    /// beside it don't move when the name or the dot changes: at the right end of the titlebar row,
    /// ending at the cup's reserve or the deck area's right edge (#104), or right of the toggle
    /// (`titlebar_switcher = "left"`). In a narrow window it keeps that width (never left of the
    /// toggle); `titlebarStripMinWidth` decides whether strips still fit beside it.
    var titlebarSwitcherFrame: CGRect {
        let t = sidebarToggleFrame
        let w = TitlebarSwitcherButton.width
        switch Settings.titlebarSwitcher {
        case .left:
            return CGRect(x: t.maxX + 4, y: t.minY, width: w, height: t.height)
        case .right:
            let end = min(titlebarCupX, contentView.bounds.width - Self.deckGap)
            return CGRect(x: max(end - w, t.maxX + 4), y: t.minY, width: w, height: t.height)
        }
    }

    /// Whether the shown button sits at the right end of the titlebar row (#104), where titlebar
    /// strips end before it instead of starting after it.
    var titlebarSwitcherOnRight: Bool { showsTitlebarSwitcher && Settings.titlebarSwitcher == .right }

    /// Places the button (called from `layoutWorkspaceSidebar`, after the toggle) and keeps an open
    /// dropdown on top of everything and under its button (or centered, when ⌘P opened it without one).
    func layoutTitlebarSwitcher() {
        let b = titlebarSwitcher
        if b.superview !== contentView { contentView.addSubview(b) }
        let shown = showsTitlebarSwitcher
        b.isHidden = !shown
        if shown {
            b.reload(from: self)
            b.frame = titlebarSwitcherFrame
        }
        let menu = titlebarSwitcherMenu
        guard menu.isOpen else { return }
        // A dropdown hanging from the button goes with it (the sidebar opened, top-bar mode).
        if !shown && menu.isAnchoredToButton { return menu.close(restoreFocus: false) }
        menu.place()
    }

    /// Workspace › Go to Workspace… (⌘P, #105): opens the switcher's dropdown with its search field
    /// focused, under the button when it shows, else at the top center of the window. ⌘P while it's
    /// open closes it, like a second click on the button. Not named after an AppKit selector.
    @objc func openWorkspaceSwitcher(_ sender: Any?) {
        let menu = titlebarSwitcherMenu
        if menu.isOpen { return menu.close(restoreFocus: true) }
        menu.open(in: self)
    }

    /// Keeps an open dropdown above everything in the window, the overlays included. Called from
    /// `layoutWindow` after `raiseOverlays`.
    func raiseTitlebarSwitcherMenu() {
        let menu = titlebarSwitcherMenu
        guard menu.isOpen, menu.superview === contentView, contentView.subviews.last !== menu else { return }
        contentView.addSubview(menu, positioned: .above, relativeTo: nil)
    }

    /// From `refreshChrome`: the name, color and other workspaces' attention change without a
    /// layout pass, and never the button's width (#102), so nothing after it moves.
    func refreshTitlebarSwitcher() {
        titlebarSwitcher.reload(from: self)
        if titlebarSwitcherMenu.isOpen { titlebarSwitcherMenu.reload() }
    }

    /// The strongest attention among the workspaces other than the active one.
    var otherWorkspacesAttention: Attention {
        workspaces.filter { $0 !== activeWorkspace }.map(\.attention).max() ?? .none
    }
}

/// The titlebar button: color chip, the current workspace's name, a dot when another workspace
/// needs attention, and a chevron at the right edge.
final class TitlebarSwitcherButton: FlippedView {
    /// One fixed width (#102, the user's call): long names truncate, short ones leave room.
    static let width: CGFloat = 200
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

    /// The color chip (self-test hook): 3pt at the left edge, like a sidebar row's.
    var chipRect: CGRect { CGRect(x: 4, y: 5, width: 3, height: bounds.height - 10) }
    /// The other workspaces' attention dot, just left of the chevron (self-test hook).
    var attentionDotRect: CGRect {
        let d = Self.dotSize
        return CGRect(x: chevronRect.minX - 6 - d, y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
    }
    /// The chevron, at the right edge whatever the name or dot (self-test hook).
    var chevronRect: CGRect {
        CGRect(x: bounds.width - Self.padding - Self.chevronWidth, y: bounds.midY - 2, width: Self.chevronWidth, height: 4)
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
        let right = chevronRect.minX - 6 - dotWidth
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

/// The dropdown under the titlebar button (or at the top center of the window, #105): a search
/// field, then the rows.
final class TitlebarSwitcherMenu: FlippedView, ThemeApplying, NSTextFieldDelegate {
    private(set) var rows: [TitlebarSwitcherRow] = []
    /// The row under the pointer or picked with ↑/↓ (⌃P/⌃N) or by typing.
    private(set) weak var highlighted: TitlebarSwitcherRow?
    /// The search field (#105): it has the keys while the dropdown is open.
    let field = NSTextField()
    private weak var owner: TerminalWindowController?
    /// The workspace that was current when it opened: a switch from anywhere else (⌃1–9, the CLI)
    /// closes it, since focus goes to the new workspace's terminal.
    private weak var openedOn: Workspace?
    /// Where focus goes back to on esc.
    private weak var previousResponder: NSResponder?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Whether it hangs from the button (shown when it opened), rather than the window's top center.
    private(set) var isAnchoredToButton = false
    /// The widest the rows have wanted since it opened, so filtering never narrows it mid-search.
    private var openWidth: CGFloat = 0

    static let inset: CGFloat = 5
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 340
    /// The search field's band at the top, above a hairline.
    static let fieldHeight: CGFloat = 32

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
        field.placeholderString = "Go to workspace"
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.font = Theme.Fonts.tab
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.chrome.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        field.backgroundColor = Theme.chrome
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(
            string: "Go to workspace", attributes: [.font: Theme.Fonts.tab, .foregroundColor: Theme.textFaint])
        rows.forEach { $0.needsDisplay = true }
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }

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

    /// Whether the search field has the keys (the field editor is first responder).
    var fieldHasFocus: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    // MARK: Open, close, pick

    func open(in c: TerminalWindowController) {
        guard let window = c.window else { return }
        owner = c
        openedOn = c.activeWorkspace
        previousResponder = window.firstResponder
        isAnchoredToButton = c.showsTitlebarSwitcher
        openWidth = 0
        field.stringValue = ""
        applyTheme()
        c.contentView.addSubview(self, positioned: .above, relativeTo: nil)
        if isAnchoredToButton { c.titlebarSwitcher.isOpen = true }
        highlighted = nil
        reload()
        // An empty query starts on the workspace shown before this one, so ⌘P then return toggles
        // back (as ⇧⌘A then return goes back to the previous pane); else on the current one.
        highlight(c.lastActiveWorkspace.flatMap(row(for:)) ?? row(for: c.activeWorkspace))
        window.makeFirstResponder(field)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, self.isOpen else { return e }
            let inMenu = e.window === self.window && self.bounds.contains(self.convert(e.locationInWindow, from: nil))
            // The button toggles the dropdown itself.
            let onButton = e.window === self.window && self.owner.map { b in
                !b.titlebarSwitcher.isHidden && b.titlebarSwitcher.bounds.contains(b.titlebarSwitcher.convert(e.locationInWindow, from: nil))
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
        let hadKeys = w.map { w in w.firstResponder === self || (w.firstResponder as? NSView)?.isDescendant(of: self) == true } ?? false
        if hadKeys { w?.makeFirstResponder(nil) }  // ends the field's editing before it leaves the window
        removeFromSuperview()
        owner?.titlebarSwitcher.isOpen = false
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        field.stringValue = ""
        if let w {
            if restoreFocus, let r = previousResponder, (r as? NSView)?.window === w || r === w { w.makeFirstResponder(r) }
            else if hadKeys, let p = owner?.focusedPane { w.makeFirstResponder(p.surface) }
        }
        previousResponder = nil
        owner = nil
        isAnchoredToButton = false
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

    // MARK: Search (#105)

    /// What's typed in the search field (self-test hook: setting it filters, as typing does).
    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; queryChanged() }
    }

    /// The window's workspaces the query keeps, in sidebar order, each with its rank
    /// (`PanePickerMatch.score` on the shown name, then the group's name and the shown name; 0 for all
    /// when the query is empty).
    private func matches(in c: TerminalWindowController) -> [(Workspace, Int)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return c.workspaces.map { ($0, 0) } }
        return c.workspaces.compactMap { ws in
            let around = [ws.group?.name, ws.displayName].compactMap { $0 }.joined(separator: " ")
            return PanePickerMatch.score(q, primary: ws.displayName, secondary: around).map { (ws, $0) }
        }
    }

    func controlTextDidChange(_ obj: Notification) { queryChanged() }

    /// After each keystroke the highlight moves to the first match: the best-ranked workspace,
    /// earliest in the list (a substring of its name before a scattered match, before its group's).
    private func queryChanged() {
        guard let c = owner else { return }
        reload()
        let best = matches(in: c).min { $0.1 < $1.1 }?.0  // `min` keeps the first of equals
        highlighted = nil
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            highlight(c.lastActiveWorkspace.flatMap(row(for:)) ?? row(for: c.activeWorkspace))
        } else {
            highlight(best.flatMap(row(for:)))
        }
        rows.forEach { $0.needsDisplay = true }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        // ↑/↓, and ⌃P/⌃N through the system key bindings.
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let h = highlighted { pick(h) }
            return true
        case #selector(NSResponder.cancelOperation(_:)): close(restoreFocus: true); return true
        default: return false
        }
    }

    /// Rebuilds the rows from the window's workspaces the query keeps, keeping the highlighted one.
    func reload() {
        guard let c = owner else { return }
        if c.activeWorkspace !== openedOn { return close(restoreFocus: false) }
        var kinds: [(TitlebarSwitcherRow.Kind, Workspace?, WorkspaceGroup?)] = []
        var lastGroup: WorkspaceGroup?
        // A group's header shows only when one of its members does.
        for (ws, _) in matches(in: c) {
            if let g = ws.group, g !== lastGroup { kinds.append((.header(g.name), nil, g)) }
            lastGroup = ws.group
            let i = c.workspaces.firstIndex { $0 === ws } ?? 9
            kinds.append((.workspace(number: i < 9 ? i + 1 : nil, indented: ws.group != nil), ws, nil))
        }
        if !kinds.isEmpty { kinds.append((.separator, nil, nil)) }
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

    /// Sizes the dropdown to its rows and puts it under the button: left-aligned to it on the left,
    /// right-aligned on the right (#104), so it stays in the window either way. Opened by ⌘P without
    /// the button (#105), it sits at the top center of the deck area, where ⌘⇧A's panel does.
    func place() {
        guard let c = owner else { return }
        openWidth = max(openWidth, rows.map(\.idealWidth).max() ?? 0)
        let bounds = c.contentView.bounds
        let w: CGFloat, x: CGFloat, top: CGFloat
        if isAnchoredToButton {
            let b = c.titlebarSwitcher.frame
            let onRight = Settings.titlebarSwitcher == .right
            let room = onRight ? b.maxX - 8 : bounds.width - b.minX - 8
            w = min(max(openWidth, Self.minWidth, b.width), Self.maxWidth, max(room, 120))
            x = onRight ? max(b.maxX - w, 8) : b.minX
            top = b.maxY + 4
        } else {
            let area = c.deckArea
            w = min(max(openWidth, Self.minWidth), Self.maxWidth, max(bounds.width - 16, 120))
            x = min(max(area.midX - w / 2, 8), max(bounds.width - 8 - w, 8))
            top = area.minY + 12
        }
        field.frame = CGRect(x: Self.inset + 8, y: Self.inset + 3, width: w - Self.inset * 2 - 16, height: 20)
        var y = Self.fieldHeight + Self.inset
        for r in rows {
            r.frame = CGRect(x: Self.inset, y: y, width: w - Self.inset * 2, height: r.height)
            y += r.height
        }
        let maxH = bounds.height - top - 12
        frame = CGRect(x: x, y: top, width: w, height: min(y + Self.inset, max(maxH, 60))).integral
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The hairline under the search field.
        Theme.hairline.setFill()
        NSRect(x: 0, y: Self.fieldHeight, width: bounds.width, height: 1).fill()
    }

    override func cancelOperation(_ sender: Any?) { close(restoreFocus: true) }

    /// ⌃[ closes it like esc (#105), while the search field has the keys: the system key bindings
    /// have nothing for it (`NSEvent.isControlBracketEscape`, PanePicker.swift).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isOpen, event.isControlBracketEscape, fieldHasFocus {
            close(restoreFocus: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
