import AppKit

/// Drags of pane bars and tabs. Where the drop lands decides what happens:
///
/// | Drop on                 | Pane / group               | Tab                         |
/// |-------------------------|----------------------------|-----------------------------|
/// | Edge of another pane    | re-split beside it         | rejoins as a split          |
/// | Centre of another pane  | swap the two panes         | (nearest edge)              |
/// | A tab strip             | becomes its own tab there  | reorder / move across decks |
/// | Window edge             | promote to a new deck      | becomes a new deck          |
///
/// Hovering a tab while dragging switches to it after a short delay. A dragged tab stops covering its
/// deck, which shows another tab, so the tab can be dropped beside that tab's panes (#27).
final class DragController {
    enum Source {
        case pane(Pane)
        case group(Node<Pane>)
        case tab(Tab)
    }

    enum Target {
        case paneEdge(Pane, Side)
        case paneCenter(Pane)
        case tabStrip(Deck, Int)
        case windowEdge(Side)
        /// A row in the workspace sidebar; `nil` is its "New Workspace" row.
        case workspace(Workspace?)
    }

    unowned let controller: TerminalWindowController
    private var view: WindowContentView { controller.contentView }

    static let edgeBand: CGFloat = 22
    static let hoverDelay: TimeInterval = 0.5

    init(controller: TerminalWindowController) {
        self.controller = controller
    }

    /// Runs a modal tracking loop until the mouse goes up. A click without movement does nothing.
    /// - Parameter behind: for a tab, the tab its deck showed before the press selected it; the deck
    ///   shows that one again while the tab is dragged.
    func begin(_ source: Source, event: NSEvent, behind: Tab? = nil) {
        guard let window = controller.window else { return }
        let start = event.locationInWindow
        var dragging = false
        var target: Target?
        var hover: (tab: Tab, since: Date)?
        var last = start

        while true {
            guard let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                            until: Date(timeIntervalSinceNow: 0.05),
                                            inMode: .eventTracking, dequeue: true) else {
                // Timed out with the mouse still: check for hover-to-switch.
                if dragging, let h = hover, Date().timeIntervalSince(h.since) >= Self.hoverDelay,
                   let deck = controller.deck(of: h.tab), deck.activeTab !== h.tab {
                    hover = nil
                    deck.activeIndex = deck.index(of: h.tab) ?? deck.activeIndex
                    controller.layoutNow()
                    target = update(source, at: last, hover: &hover)
                }
                continue
            }
            if ev.type == .leftMouseUp { break }
            last = ev.locationInWindow
            if !dragging {
                guard hypot(last.x - start.x, last.y - start.y) > 4 else { continue }
                dragging = true
                NSCursor.closedHand.push()
                uncover(source, showing: behind)
            }
            target = update(source, at: last, hover: &hover)
        }

        guard dragging else { return }
        NSCursor.pop()
        let previewed = !view.dropHighlight.isHidden
        clear(keepHighlight: previewed)
        if let target { perform(source, target) } else { recover(source) }
        // The preview settles onto where the content landed (#28), or just goes away.
        if previewed, target != nil, let r = landedRect(source) {
            view.dropHighlight.settle(to: r)
        } else {
            view.dropHighlight.hide()
        }
    }

    /// The moved content's frame after the drop, in content-view coordinates; nil when it isn't on
    /// screen (moved to another workspace, or a tab that went into a strip).
    private func landedRect(_ source: Source) -> CGRect? {
        guard let n = sourceNode(source), let ws = n.leaves.first.flatMap({ controller.workspace(of: $0) }),
              ws === controller.activeWorkspace else { return nil }
        return controller.frame(of: n)
    }

    /// The tab under a dragged tab: without this its deck would show only the dragged tab's own panes,
    /// which are no drop target, so a tab could never rejoin its own deck as a split (#27).
    private func uncover(_ source: Source, showing behind: Tab?) {
        guard case .tab(let tab) = source, let deck = controller.deck(of: tab), deck.activeTab === tab,
              deck.tabs.count > 1, let i = deck.index(of: tab) else { return }
        deck.activeIndex = behind.flatMap { $0 === tab ? nil : deck.index(of: $0) } ?? (i > 0 ? i - 1 : i + 1)
        controller.layoutNow()
    }

    /// A tab drag that went nowhere: the tab is selected again, as the press left it.
    private func recover(_ source: Source) {
        guard case .tab(let tab) = source, let deck = controller.deck(of: tab), let i = deck.index(of: tab),
              deck.activeIndex != i else { return }
        deck.activeIndex = i
        controller.layoutNow()
    }

    private func clear(keepHighlight: Bool = false) {
        if !keepHighlight { view.dropHighlight.hide() }
        view.ghost.isHidden = true
        controller.decks.forEach { $0.view.strip.showMarker(at: nil, color: .clear) }
    }

    private func label(_ source: Source) -> String {
        switch source {
        case .pane(let p): return p.title
        case .group(let n): return "\(n.leaves.count) panes"
        case .tab(let t): return t.title
        }
    }

    private func sourceNode(_ source: Source) -> Node<Pane>? {
        switch source {
        case .pane(let p): return controller.locate(p)?.node
        case .group(let n): return n
        case .tab(let t): return t.root
        }
    }

    // MARK: Hit testing

    private func update(_ source: Source, at windowPoint: CGPoint, hover: inout (tab: Tab, since: Date)?) -> Target? {
        let p = view.convert(windowPoint, from: nil)
        view.ghost.show(label(source), at: p)
        controller.decks.forEach { $0.view.strip.showMarker(at: nil, color: .clear) }

        let (target, hovered) = hitTest(source, at: p)
        if let hovered {
            if hover?.tab !== hovered { hover = (hovered, Date()) }
        } else {
            hover = nil
        }

        guard let target else {
            view.dropHighlight.hide()
            return nil
        }
        switch target {
        case let .tabStrip(deck, index):
            view.dropHighlight.hide()
            deck.view.strip.showMarker(at: index, color: deck.color)
        default:
            if let r = highlightRect(source, target) {
                view.dropHighlight.show(r, color: highlightColor(target))
            }
        }
        view.raiseOverlays()
        return target
    }

    private func hitTest(_ source: Source, at p: CGPoint) -> (Target?, Tab?) {
        let area = controller.deckArea
        let single = controller.decks.count == 1 && (controller.decks.first?.tabs.count ?? 0) == 1

        // Over the workspace sidebar or top-bar pills: move into that workspace (checked before the
        // edge bands, since both lie outside the deck area).
        if let sw = controller.visibleWorkspaceSwitchers.first(where: { $0.frame.contains(p) }) {
            guard let hit = sw.dropTarget(at: sw.convert(p, from: view)) else { return (nil, nil) }
            if let ws = hit.workspace, ws === sourceWorkspace(source) { return (nil, nil) }
            return (.workspace(hit.workspace), nil)
        }

        // A tab strip in the titlebar row (#16), before the top-edge band it sits in.
        for deck in controller.titlebarStripDecks {
            let s = deck.view.strip
            let sp = s.convert(p, from: view)
            if s.bounds.contains(sp) { return stripTarget(source, deck: deck, strip: s, at: sp) }
        }

        // Past the decks, at the window edge: promote.
        let edge: Side?
        if p.y < area.minY { edge = .top }
        else if p.x < area.minX + Self.edgeBand { edge = .left }
        else if p.x > area.maxX - Self.edgeBand { edge = .right }
        else if p.y > area.maxY - Self.edgeBand { edge = .bottom }
        else { edge = nil }
        if let edge {
            if case .tab = source, single { return (nil, nil) }
            if case .pane(let pane) = source, single, controller.locate(pane)?.tab.panes.count == 1 { return (nil, nil) }
            return (.windowEdge(edge), nil)
        }

        for deck in controller.decks where deck.view.superview != nil && !deck.view.isHidden {
            let dv = deck.view
            let local = dv.convert(p, from: view)
            guard dv.bounds.contains(local) else { continue }

            let sp = dv.strip.convert(p, from: view)
            if !dv.stripInTitlebar, dv.strip.bounds.contains(sp) { return stripTarget(source, deck: deck, strip: dv.strip, at: sp) }

            guard let tab = deck.activeTab else { return (nil, nil) }
            for pane in tab.panes where !pane.view.isHidden {
                let r = pane.view.convert(pane.view.bounds, to: view)
                guard r.contains(p) else { continue }
                return (target(source, over: pane, rect: r, at: p), nil)
            }
            return (nil, nil)
        }
        return (nil, nil)
    }

    /// Over a tab strip (in its deck or in the titlebar): insert there; hovering a tab switches to it.
    private func stripTarget(_ source: Source, deck: Deck, strip: TabStripView, at sp: CGPoint) -> (Target?, Tab?) {
        var hovered: Tab?
        if let i = strip.tabIndex(at: sp), i != deck.activeIndex {
            hovered = deck.tabs[i]
            if case .tab(let t) = source, t === hovered { hovered = nil }
        }
        return (.tabStrip(deck, strip.insertionIndex(atX: sp.x)), hovered)
    }

    private func target(_ source: Source, over pane: Pane, rect r: CGRect, at p: CGPoint) -> Target? {
        guard let targetNode = controller.locate(pane)?.node else { return nil }
        if let n = sourceNode(source), n.contains(targetNode) { return nil }

        let fx = (p.x - r.minX) / max(r.width, 1)
        let fy = (p.y - r.minY) / max(r.height, 1)
        let distances: [(Side, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        let nearest = distances.min { $0.1 < $1.1 }!

        if nearest.1 > 0.28, case .pane = source {
            return .paneCenter(pane)
        }
        return .paneEdge(pane, nearest.0)
    }

    private func highlightRect(_ source: Source, _ target: Target) -> CGRect? {
        switch target {
        case let .paneEdge(pane, side):
            let r = pane.view.convert(pane.view.bounds, to: view)
            return half(of: r, side: side)
        case let .paneCenter(pane):
            return pane.view.convert(pane.view.bounds, to: view).insetBy(dx: 6, dy: 6)
        case let .windowEdge(side):
            // The new deck's size: an even share with the decks along that axis (#31), not counting
            // a deck the move empties.
            let area = controller.deckArea
            var emptied: Deck?
            if let n = sourceNode(source), let loc = n.leaves.first.flatMap({ controller.locate($0) }),
               n === loc.tab.root, loc.deck.tabs.count == 1 { emptied = loc.deck }
            let f = controller.evenEdgeFraction(side: side, in: controller.root, excluding: emptied)
            let w = (area.width - TerminalWindowController.deckGap) * f
            let h = (area.height - TerminalWindowController.deckGap) * f
            switch side {
            case .left: return CGRect(x: area.minX, y: area.minY, width: w, height: area.height)
            case .right: return CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
            case .top: return CGRect(x: area.minX, y: area.minY, width: area.width, height: h)
            case .bottom: return CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h)
            }
        case let .workspace(ws):
            for sw in controller.visibleWorkspaceSwitchers {
                if let r = sw.rect(for: ws) { return sw.convert(r, to: view) }
            }
            return nil
        case .tabStrip:
            return nil
        }
    }

    private func half(of r: CGRect, side: Side) -> CGRect {
        switch side {
        case .left: return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right: return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .bottom: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
    }

    private func highlightColor(_ target: Target) -> NSColor {
        switch target {
        case let .paneEdge(p, _), let .paneCenter(p):
            return controller.locate(p)?.deck.color ?? Palette.neutral
        case let .tabStrip(d, _):
            return d.color
        case .workspace:
            return Theme.accentNeutral
        case .windowEdge:
            // The colour the new deck will get.
            let used = Set(controller.decks.map { $0.colorIndex % Palette.deckColors.count })
            return Palette.deckColors[Palette.deckColors.indices.first { !used.contains($0) } ?? 0]
        }
    }

    // MARK: Drop

    private func perform(_ source: Source, _ target: Target) {
        let c = controller
        switch (source, target) {
        case let (.pane(p), .paneCenter(t)):
            c.swap(p, t)
        case let (.tab(tab), .paneEdge(t, side)):
            c.merge(tab: tab, besidePane: t, side: side)
        case let (.tab(tab), .tabStrip(deck, index)):
            c.move(tab: tab, to: deck, index: index)
        case let (.tab(tab), .windowEdge(side)):
            c.promote(tab.root, side: side, allowWholeDeck: true, evenly: true)
        case (_, let .paneEdge(t, side)):
            if let n = sourceNode(source) { c.move(n, besidePane: t, side: side) }
        case (_, let .tabStrip(deck, index)):
            if let n = sourceNode(source) { c.moveToNewTab(n, deck: deck, index: index) }
        case (_, .windowEdge(let side)):
            if let n = sourceNode(source) { c.promote(n, side: side, allowWholeDeck: true, evenly: true) }
        case (_, let .workspace(ws)):
            if let n = sourceNode(source) { c.move(n, toWorkspace: ws, follow: ws == nil) }
        default:
            break
        }
    }

    private func sourceWorkspace(_ source: Source) -> Workspace? {
        switch source {
        case .pane(let p): return controller.workspace(of: p)
        case .group(let n): return n.leaves.first.flatMap { controller.workspace(of: $0) }
        case .tab(let t): return controller.deck(of: t).flatMap { controller.workspace(of: $0) }
        }
    }
}
