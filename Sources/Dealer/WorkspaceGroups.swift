import AppKit

// MARK: - Workspace groups (#80)
//
// A group is a named, collapsible run of workspaces in the switcher. The window's `workspaces`
// stays one flat list (⌃1–9 count every workspace in order, collapsed or not); a group is just the
// `Workspace.group` its members share, and its members are always contiguous in that list. A group
// has no existence of its own: when its last workspace closes or leaves, it is gone.

extension Workspace {
    /// `order` with every group's members gathered at its first member's position, keeping their
    /// relative order. Every reorder and insert goes through it, so groups stay contiguous.
    static func contiguousGroups(_ order: [Workspace]) -> [Workspace] {
        var out: [Workspace] = []
        var seen: Set<ObjectIdentifier> = []
        for ws in order {
            guard let g = ws.group else { out.append(ws); continue }
            guard seen.insert(ObjectIdentifier(g)).inserted else { continue }
            out += order.filter { $0.group === g }
        }
        return out
    }
}

/// One entry of a switcher, in display order: a group's header, or a workspace's row/pill.
/// Members of a collapsed group have no entry.
enum SwitcherEntry {
    case header(WorkspaceGroup)
    case workspace(Workspace)

    var workspace: Workspace? { if case let .workspace(ws) = self { return ws }; return nil }
    var group: WorkspaceGroup? { if case let .header(g) = self { return g }; return nil }
    /// The group a workspace entry sits in (nil for headers and root workspaces).
    var memberOf: WorkspaceGroup? { workspace?.group }
}

/// Where a dragged switcher entry lands: before `anchor` (nil: at the end), in `group` (nil: root).
struct SwitcherDrop: Equatable {
    var anchor: Workspace?
    var group: WorkspaceGroup?
    /// The gap in the entry list (for the marker); `onHeader` instead when dropped on a header.
    var gap: Int
    var onHeader: WorkspaceGroup?

    static func == (a: SwitcherDrop, b: SwitcherDrop) -> Bool {
        a.anchor === b.anchor && a.group === b.group && a.gap == b.gap && a.onHeader === b.onHeader
    }
}

enum SwitcherLayout {
    /// The entries for `workspaces`, in order.
    static func entries(_ workspaces: [Workspace]) -> [SwitcherEntry] {
        var out: [SwitcherEntry] = []
        for (i, ws) in workspaces.enumerated() {
            if let g = ws.group {
                if i == 0 || workspaces[i - 1].group !== g { out.append(.header(g)) }
                if !g.isCollapsed { out.append(.workspace(ws)) }
            } else {
                out.append(.workspace(ws))
            }
        }
        return out
    }

    /// The first workspace an entry stands for (a header stands for its group's first member).
    static func firstWorkspace(of e: SwitcherEntry, in workspaces: [Workspace]) -> Workspace? {
        switch e {
        case let .workspace(ws): return ws
        case let .header(g): return workspaces.first { $0.group === g }
        }
    }

    /// The drop for a dragged workspace or group, given the entries' extents along the drag axis
    /// (`spans`, one `(min, max)` per entry) and the pointer position `p` on that axis.
    ///
    /// A workspace dropped on the middle of a header joins that group (at its end). Dropped in a
    /// gap, it joins the group of the entry below the gap when that entry is a shown member, and
    /// otherwise goes to the root: so "between members" (or between a header and its first
    /// member) means in the group, and the gap after a group's last member means out of it. A
    /// dragged group only lands in root gaps (never inside another group).
    static func drop(dragging: SwitcherEntry, entries: [SwitcherEntry], spans: [(CGFloat, CGFloat)],
                     at p: CGFloat, workspaces: [Workspace]) -> SwitcherDrop {
        if dragging.workspace != nil {
            for (i, e) in entries.enumerated() {
                guard let g = e.group else { continue }
                let (lo, hi) = spans[i], q = (hi - lo) / 4
                if p > lo + q && p < hi - q { return SwitcherDrop(anchor: nil, group: g, gap: i, onHeader: g) }
            }
        }
        var gap = spans.filter { ($0.0 + $0.1) / 2 < p }.count
        if dragging.group != nil {
            // Not inside another group: move past its members.
            while gap < entries.count, entries[gap].memberOf != nil { gap += 1 }
        }
        let below = gap < entries.count ? entries[gap] : nil
        let anchor = below.flatMap { firstWorkspace(of: $0, in: workspaces) }
        let group = dragging.workspace != nil ? below?.memberOf : nil
        return SwitcherDrop(anchor: anchor, group: group, gap: gap, onHeader: nil)
    }
}

extension TerminalWindowController {
    /// The window's groups, in switcher order.
    var groups: [WorkspaceGroup] {
        var out: [WorkspaceGroup] = []
        for ws in workspaces { if let g = ws.group, !out.contains(where: { $0 === g }) { out.append(g) } }
        return out
    }

    func members(of g: WorkspaceGroup) -> [Workspace] { workspaces.filter { $0.group === g } }

    /// The group a new workspace made next to `ws` joins: `ws`'s, unless it's collapsed (a new
    /// workspace should show up in the switcher).
    func joinableGroup(of ws: Workspace) -> WorkspaceGroup? {
        ws.group.flatMap { $0.isCollapsed ? nil : $0 }
    }

    /// A group's rolled-up attention: the strongest of its members' (failed > waiting > done > unread).
    func attention(of g: WorkspaceGroup) -> Attention { members(of: g).map(\.attention).max() ?? .none }

    /// "Group", or "Group 2", 3… when that name is taken in this window.
    private func defaultGroupName(excluding self_: WorkspaceGroup? = nil) -> String {
        let taken = Set(groups.filter { $0 !== self_ }.map(\.name))
        if !taken.contains("Group") { return "Group" }
        var n = 2
        while taken.contains("Group \(n)") { n += 1 }
        return "Group \(n)"
    }

    /// Moves `ws` into a new group. A root workspace stays where it is; a member of another group
    /// leaves it and the new group sits right after it.
    @discardableResult
    func moveToNewGroup(_ ws: Workspace, name: String? = nil) -> WorkspaceGroup {
        let g = WorkspaceGroup(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? defaultGroupName())
        if let old = ws.group {
            let after = members(of: old).filter { $0 !== ws }.last
            ws.group = g
            place(ws, after: after)
        } else {
            ws.group = g
            refreshChrome()
        }
        return g
    }

    /// Moves `ws` to the end of `g`; `nil` takes it out of its group, to just after the group.
    func move(_ ws: Workspace, toGroup g: WorkspaceGroup?) {
        guard ws.group !== g || g != nil else { return }
        if let g {
            let last = members(of: g).filter { $0 !== ws }.last
            ws.group = g
            place(ws, after: last)
        } else if let old = ws.group {
            let last = members(of: old).filter { $0 !== ws }.last
            ws.group = nil
            place(ws, after: last)
        }
    }

    /// Puts `ws` right after `other` (nil: leaves it where it is) and regathers the groups.
    private func place(_ ws: Workspace, after other: Workspace?) {
        var order = workspaces.filter { $0 !== ws }
        let i = other.flatMap { o in order.firstIndex { $0 === o } }.map { $0 + 1 }
            ?? workspaces.firstIndex { $0 === ws } ?? order.count
        order.insert(ws, at: min(i, order.count))
        setWorkspaceOrder(order)
    }

    /// The drag-and-drop move: `ws` goes before `anchor` (nil: the end), in `group` (nil: root).
    func move(workspace ws: Workspace, before anchor: Workspace?, group: WorkspaceGroup?) {
        var anchor = anchor
        if anchor === ws, let i = workspaces.firstIndex(where: { $0 === ws }) {
            anchor = i + 1 < workspaces.count ? workspaces[i + 1] : nil
        }
        var order = workspaces.filter { $0 !== ws }
        order.insert(ws, at: anchor.flatMap { a in order.firstIndex { $0 === a } } ?? order.count)
        ws.group = group
        setWorkspaceOrder(order)
    }

    /// Moves a whole group before `anchor` (nil: the end). An anchor inside the group is no move.
    func move(group g: WorkspaceGroup, before anchor: Workspace?) {
        guard anchor?.group !== g else { return }
        let block = members(of: g)
        var order = workspaces.filter { $0.group !== g }
        order.insert(contentsOf: block, at: anchor.flatMap { a in order.firstIndex { $0 === a } } ?? order.count)
        setWorkspaceOrder(order)
    }

    /// Applies a switcher drop (sidebar row or pill).
    func apply(_ drop: SwitcherDrop, dragging: SwitcherEntry) {
        switch dragging {
        case let .workspace(ws):
            if let g = drop.onHeader { return move(ws, toGroup: g) }
            move(workspace: ws, before: drop.anchor, group: drop.group)
        case let .header(g):
            move(group: g, before: drop.anchor)
        }
    }

    /// Dissolves a group; its workspaces stay where they are, at the root.
    func ungroup(_ g: WorkspaceGroup) {
        members(of: g).forEach { $0.group = nil }
        refreshChrome()
    }

    /// An empty name resets it to the default.
    func rename(group g: WorkspaceGroup, to name: String?) {
        let t = name?.trimmingCharacters(in: .whitespaces) ?? ""
        g.name = t.isEmpty ? defaultGroupName(excluding: g) : t
        refreshChrome()
    }

    /// Collapsing never changes the active workspace; a collapsed header stands in for it.
    func setCollapsed(_ g: WorkspaceGroup, _ collapsed: Bool) {
        guard g.isCollapsed != collapsed else { return }
        g.isCollapsed = collapsed
        layoutNow()
        refreshChrome()
    }

    func toggleCollapsed(_ g: WorkspaceGroup) { setCollapsed(g, !g.isCollapsed) }

    /// Move Workspace Left/Right with groups: a member steps within its group and leaves it past
    /// either end; a root workspace steps over a neighbouring workspace or a whole group (it
    /// never enters one this way; drag it or use Move to Group).
    func canStep(_ ws: Workspace, by d: Int) -> Bool {
        ws.group != nil || units().firstIndex(where: { $0.first === ws }).map { units().indices.contains($0 + d) } == true
    }

    func step(_ ws: Workspace, by d: Int) {
        guard canStep(ws, by: d) else { return NSSound.beep() }
        if let g = ws.group {
            let m = members(of: g)
            let k = m.firstIndex { $0 === ws }!
            var order = workspaces
            if m.indices.contains(k + d) {
                order.swapAt(order.firstIndex { $0 === ws }!, order.firstIndex { $0 === m[k + d] }!)
            } else {
                // Past the group's end: out of it, on that side.
                order.removeAll { $0 === ws }
                let edge = d < 0 ? order.firstIndex { $0.group === g } : order.lastIndex { $0.group === g }.map { $0 + 1 }
                order.insert(ws, at: edge ?? (d < 0 ? 0 : order.count))
                ws.group = nil
            }
            return setWorkspaceOrder(order)
        }
        var u = units()
        let i = u.firstIndex { $0.first === ws }!
        u.swapAt(i, i + d)
        setWorkspaceOrder(u.flatMap { $0 })
    }

    /// The root-level units of the switcher: single root workspaces and whole groups.
    private func units() -> [[Workspace]] {
        var units: [[Workspace]] = []
        for w in workspaces {
            if let g = w.group, let last = units.last?.last, last.group === g { units[units.count - 1].append(w) }
            else { units.append([w]) }
        }
        return units
    }

    // MARK: Interactive

    func renameGroupInteractively(_ g: WorkspaceGroup) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = g.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, weak g] resp in
            guard resp == .alertFirstButtonReturn, let g else { return }
            self?.rename(group: g, to: field.stringValue)
        }
    }

    /// Context-menu items for a workspace's row or pill: Move to New Group…, Move to Group ▸, and
    /// Remove from Group when it's in one.
    func groupMenuItems(for ws: Workspace) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.append(ClosureMenuItem("Move to New Group…") { [weak self, weak ws] in
            guard let self, let ws else { return }
            self.renameGroupInteractively(self.moveToNewGroup(ws))
        })
        let others = groups.filter { $0 !== ws.group }
        if !others.isEmpty {
            let sub = NSMenu()
            for g in others {
                sub.addItem(ClosureMenuItem(g.name) { [weak self, weak ws, weak g] in
                    guard let ws, let g else { return }
                    self?.move(ws, toGroup: g)
                })
            }
            let item = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            item.submenu = sub
            items.append(item)
        }
        if ws.group != nil {
            items.append(ClosureMenuItem("Remove from Group") { [weak self, weak ws] in
                guard let ws else { return }
                self?.move(ws, toGroup: nil)
            })
        }
        return items
    }

    /// The context menu of a group's header (sidebar) or label pill (top bar).
    func groupHeaderMenu(for g: WorkspaceGroup) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename Group…") { [weak self, weak g] in
            if let g { self?.renameGroupInteractively(g) }
        })
        menu.addItem(ClosureMenuItem(g.isCollapsed ? "Expand Group" : "Collapse Group") { [weak self, weak g] in
            if let g { self?.toggleCollapsed(g) }
        })
        menu.addItem(ClosureMenuItem("Ungroup") { [weak self, weak g] in
            if let g { self?.ungroup(g) }
        })
        return menu
    }
}

// MARK: - Dragging entries within a switcher

/// A switcher that lays out `SwitcherEntry`s along one axis and lets its rows, pills and group
/// headers be dragged to reorder them, into groups and out of them.
protocol SwitcherDragHost: FlippedView {
    /// The entries in display order, with the view showing each.
    var entryViews: [(SwitcherEntry, NSView)] { get }
    /// True for the sidebar (entries stacked), false for the pill bar.
    var isVertical: Bool { get }
    /// Shows where `drop` would land; nil hides the marker.
    func showDropMarker(_ drop: SwitcherDrop?)
}

extension SwitcherDragHost {
    /// Where `entry` would land with the pointer at `p` (window coordinates).
    func drop(for entry: SwitcherEntry, at p: CGPoint) -> SwitcherDrop? {
        guard let c = controller else { return nil }
        let views = entryViews
        let spans = views.map { isVertical ? ($0.1.frame.minY, $0.1.frame.maxY) : ($0.1.frame.minX, $0.1.frame.maxX) }
        let lp = convert(p, from: nil)
        return SwitcherLayout.drop(dragging: entry, entries: views.map(\.0), spans: spans,
                                   at: isVertical ? lp.y : lp.x, workspaces: c.workspaces)
    }

    /// The marker's rect for `d`: in the gap before entry `d.gap` (or after the last one), or at the
    /// end of the header's group for a drop on a header. `inset` indents it for a drop into a group.
    func markerRect(for d: SwitcherDrop, thickness: CGFloat, spacing: CGFloat, inset: CGFloat) -> CGRect {
        let views = entryViews
        var gap = d.gap
        if let g = d.onHeader, let last = views.lastIndex(where: { $0.0.group === g || $0.0.memberOf === g }) { gap = last + 1 }
        let edge: CGFloat
        if gap < views.count { edge = (isVertical ? views[gap].1.frame.minY : views[gap].1.frame.minX) - spacing / 2 }
        else { edge = (views.last.map { isVertical ? $0.1.frame.maxY : $0.1.frame.maxX } ?? 0) + spacing / 2 }
        let into = d.group != nil || d.onHeader != nil
        if isVertical {
            let x = 4 + (into ? inset : 0)
            return CGRect(x: x, y: edge - thickness / 2, width: bounds.width - 4 - x, height: thickness)
        }
        let h = WorkspaceBarView.pillHeight - (into ? 8 : 0)
        return CGRect(x: edge - thickness / 2, y: (bounds.height - h) / 2, width: thickness, height: h)
    }
}

/// Mouse handling shared by every draggable switcher entry: press, drag past a threshold to show
/// the drop marker, release to apply the drop.
struct SwitcherDragTracker {
    private var start: CGPoint?
    private(set) var dragging = false

    mutating func down(_ event: NSEvent) { start = event.locationInWindow; dragging = false }

    /// True once the press has moved far enough to be a drag.
    mutating func moved(_ event: NSEvent, entry: SwitcherEntry, host: SwitcherDragHost?) {
        guard let start, let host else { return }
        let p = event.locationInWindow
        if !dragging {
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            dragging = true
        }
        host.showDropMarker(host.drop(for: entry, at: p))
    }

    /// Applies the drop if this was a drag. Returns whether it was.
    mutating func up(_ event: NSEvent, entry: SwitcherEntry, host: SwitcherDragHost?) -> Bool {
        defer { start = nil; dragging = false }
        guard dragging, let host else { return false }
        host.showDropMarker(nil)
        if let d = host.drop(for: entry, at: event.locationInWindow) { host.controller?.apply(d, dragging: entry) }
        return true
    }
}

// MARK: - Group header (sidebar row or top-bar label pill)

/// A group's entry in a switcher (#80): a disclosure triangle and the group's name. Click to
/// collapse or expand, double-click to rename, drag to move the whole group, right-click for its
/// menu. While collapsed it stands in for its members: their rolled-up attention (outline or dot,
/// like a workspace entry: a large dot on the sidebar, #91), the working spinner, a member count
/// (sidebar), and the selection outline when the active workspace is inside. Groups have no color (#80), so it never draws one.
final class GroupHeaderView: FlippedView {
    enum Style { case row, pill }
    var style: Style = .row
    weak var group: WorkspaceGroup?
    var title = "" { didSet { if title != oldValue { needsDisplay = true; superview?.needsLayout = true } } }
    var isCollapsed = false { didSet { if isCollapsed != oldValue { needsDisplay = true; superview?.needsLayout = true } } }
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    /// Collapsed with the active workspace inside: the selection outline, as on a selected entry.
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var attention: Attention = .none {
        didSet {
            if attentionFade.onChange == nil { attentionFade.onChange = { [weak self] in self?.needsDisplay = true } }
            attentionFade.set(attention, subject: group)  // #34
            if attention != oldValue { needsDisplay = true; superview?.needsLayout = true }
        }
    }
    let attentionFade = AttentionFadeState()
    var working: WorkingMark? {
        didSet {
            guard working != oldValue else { return }
            if spinner.onChange == nil { spinner.onChange = { [weak self] in self?.needsDisplay = true } }
            spinner.set(working)
            if (working == nil) != (oldValue == nil) { superview?.needsLayout = true }
        }
    }
    var isRunning: Bool { working != nil }
    let spinner = RunningSpinnerState()
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracker = SwitcherDragTracker()
    private var skipToggle = false

    private var padding: CGFloat { style == .row ? 10 : 9 }
    private static let triangleColumn: CGFloat = 16
    private var dotSize: CGFloat { style == .row ? Theme.Metrics.sidebarDotSize : Theme.Metrics.switcherDotSize }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var titleAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return [.font: Theme.Fonts.groupHeader,
                .foregroundColor: hovering || isActive ? Theme.text : Theme.textMuted,
                .paragraphStyle: para]
    }

    private var countAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.textFaint]
    }

    /// Sidebar only: on a pill a bare number would read as a ⌃N workspace number.
    private var countText: String { style == .row && isCollapsed && count > 0 ? "\(count)" : "" }
    private var countWidth: CGFloat { countText.isEmpty ? 0 : ceil((countText as NSString).size(withAttributes: countAttrs).width) + 6 }
    private var dotWidth: CGFloat { attentionFade.shown > .none ? dotSize + 6 : 0 }

    /// A label pill's width (top bar).
    var idealWidth: CGFloat {
        padding * 2 + Self.triangleColumn + spinner.leading
            + ceil((title as NSString).size(withAttributes: titleAttrs).width) + countWidth + dotWidth
    }

    /// The attention dot at the right end (also read by the self-test).
    var attentionDotRect: CGRect {
        let d = dotSize
        return CGRect(x: bounds.width - padding - d, y: (bounds.height - d) / 2, width: d, height: d)
    }

    /// The disclosure triangle's box (self-test hook).
    var triangleRect: CGRect { CGRect(x: padding, y: (bounds.height - 10) / 2, width: 10, height: 10) }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Metrics.tabRadius
        if hovering {
            Theme.fill(Theme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let color = hovering || isActive ? Theme.text : Theme.textMuted
        // ▸ collapsed, ▾ expanded.
        let t = triangleRect, tri = NSBezierPath()
        if isCollapsed {
            tri.move(to: CGPoint(x: t.minX + 2.5, y: t.minY + 1.5))
            tri.line(to: CGPoint(x: t.maxX - 1.5, y: t.midY))
            tri.line(to: CGPoint(x: t.minX + 2.5, y: t.maxY - 1.5))
        } else {
            tri.move(to: CGPoint(x: t.minX + 1.5, y: t.minY + 2.5))
            tri.line(to: CGPoint(x: t.maxX - 1.5, y: t.minY + 2.5))
            tri.line(to: CGPoint(x: t.midX, y: t.maxY - 1.5))
        }
        tri.close()
        color.setFill()
        tri.fill()

        var x = padding + Self.triangleColumn
        if let mark = spinner.mark {
            RunningSpinner.draw(mark, in: RunningSpinner.box(in: bounds, x: x), phase: RunningSpinner.phase())
            x += RunningSpinner.slot
        }
        let font = Theme.Fonts.groupHeader
        let h = ceil(font.ascender - font.descender)
        let right = bounds.width - padding - dotWidth - countWidth
        (title as NSString).draw(in: CGRect(x: x, y: (bounds.height - h) / 2, width: max(right - x, 0), height: h), withAttributes: titleAttrs)
        if !countText.isEmpty {
            let cf = countAttrs[.font] as! NSFont
            let ch = ceil(cf.ascender - cf.descender)
            (countText as NSString).draw(at: CGPoint(x: right + 6, y: (bounds.height - ch) / 2), withAttributes: countAttrs)
        }
        // As on a workspace entry: on the sidebar a large dot and no attention outline, then the
        // selection outline on top (#91); on a pill the selection outline yields to attention's.
        if isActive && style == .pill {
            SelectionStyle.drawOutline(in: bounds, cornerRadius: radius, yieldingTo: attentionFade.shown, attentionAlpha: attentionFade.alpha)
        }
        if attentionFade.shown > .none {
            AttentionStyle.draw(attentionFade.shown, in: bounds, cornerRadius: radius, dotRect: attentionDotRect,
                                alpha: attentionFade.alpha, outline: style == .pill)
        }
        if isActive && style == .row { SelectionStyle.drawOutline(in: bounds, cornerRadius: radius) }
    }

    private var host: SwitcherDragHost? { superview as? SwitcherDragHost }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller, let g = group else { return }
        if event.clickCount == 2 {
            // The first click already toggled it: put it back, then rename.
            c.toggleCollapsed(g)
            skipToggle = true
            return c.renameGroupInteractively(g)
        }
        skipToggle = false
        tracker.down(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let g = group else { return }
        tracker.moved(event, entry: .header(g), host: host)
    }

    override func mouseUp(with event: NSEvent) {
        guard let g = group else { return }
        if tracker.up(event, entry: .header(g), host: host) || skipToggle { return }
        controller?.toggleCollapsed(g)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let g = group else { return nil }
        return controller?.groupHeaderMenu(for: g)
    }
}
