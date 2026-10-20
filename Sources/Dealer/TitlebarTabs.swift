import AppKit

// Tab strips in the titlebar (#16, `[window] tabs_in_titlebar`).
//
// With the setting on, a deck whose top edge touches the top of the deck area hands its tab strip
// to the window: the strip is reparented into the content view's titlebar row, aligned to the
// deck's x-range, and the deck's card starts right under the titlebar. Decks lower down keep their
// strips. Every layout pass recomputes this from the deck frames, so a strip follows its deck as
// it gains or loses the top edge (promote, fold, divider drags, zoom, workspace switches). Only the
// strip view moves; deck views and surfaces are never recreated.
//
// Clear zones: a strip starts after the traffic lights and the sidebar toggle, or in top-bar
// workspace mode after the pill segment (the pills keep a fixed left segment). The sidebar column
// isn't a concern because decks never extend over it. At the right end, `[power] caffeinate` (#69)
// reserves room for the coffee cup (`titlebarTrailingX`). A strip clipped below `minWidth` stays in
// its deck instead.

extension TerminalWindowController {
    /// Narrowest titlebar strip worth showing (about two tabs plus "+"); narrower stays in the deck.
    static let titlebarStripMinWidth: CGFloat = 140

    /// The x where titlebar strips may begin: after the traffic lights, the sidebar toggle, and
    /// (in top-bar mode) the workspace pills.
    var titlebarClearX: CGFloat {
        var x: CGFloat = 0
        if let zoom = window?.standardWindowButton(.zoomButton), zoom.superview != nil {
            x = max(x, zoom.convert(zoom.bounds, to: contentView).maxX)
        }
        if WorkspaceSwitcher.style == .top {
            workspaceBar.reload()
            x = max(x, WorkspaceBarView.leadingInset + workspaceBar.contentWidth)
        } else {
            x = max(x, sidebarToggle.frame.width > 0 ? sidebarToggle.frame.maxX : WorkspaceBarView.leadingInset + 28)
        }
        return x + 8
    }

    /// Moves each shown deck's strip into the titlebar row or back into its deck. Called from
    /// `layoutWindow` with this pass's deck frames, before the decks lay out.
    func placeTabStrips(_ frames: [(Deck, CGRect)]) {
        let area = deckArea
        var up = Set<ObjectIdentifier>()
        // By strip identity: an orphaned strip's `deck` is unowned and may already be freed (a deck
        // detached since the last pass), so reading `s.deck` here crashed.
        var upStrips = Set<ObjectIdentifier>()
        if Settings.tabsInTitlebar {
            let clear = titlebarClearX
            let end = titlebarTrailingX  // the cup's reserve (#69)
            for (deck, r) in frames where abs(r.minY - area.minY) < 0.5 {
                let x = max(r.minX, clear)
                let maxX = min(r.maxX, end)
                guard maxX - x >= Self.titlebarStripMinWidth else { continue }
                let strip = deck.view.strip
                if strip.superview !== contentView { contentView.addSubview(strip) }
                strip.frame = CGRect(x: x, y: 0, width: maxX - x, height: area.minY)
                deck.view.stripInTitlebar = true
                up.insert(ObjectIdentifier(deck))
                upStrips.insert(ObjectIdentifier(strip))
            }
        }
        // Strips left in the titlebar by decks that lost the top edge, were hidden, or were removed
        // (detach takes the deck view away but not a strip living outside it).
        if up.isEmpty, window?.isMovable == false { window?.isMovable = true }
        for case let s as TabStripView in contentView.subviews where !upStrips.contains(ObjectIdentifier(s)) {
            s.removeFromSuperview()
        }
        for deck in allDecks where !up.contains(ObjectIdentifier(deck)) {
            let dv = deck.view
            if dv.strip.superview !== dv { dv.addSubview(dv.strip, positioned: .below, relativeTo: dv.content) }
            dv.stripInTitlebar = false
        }
    }

    /// Decks whose strip is in the titlebar right now.
    var titlebarStripDecks: [Deck] { decks.filter { $0.view.stripInTitlebar && !$0.view.isHidden } }
}

extension TabStripView {
    /// True while this strip sits in the titlebar row.
    var isInTitlebar: Bool { (superview as? DeckView) == nil && superview != nil }

    /// Empty strip space in the titlebar behaves like the titlebar: it drags the window, and a
    /// double-click zooms or minimizes per System Settings › Desktop & Dock.
    override func mouseDown(with event: NSEvent) {
        guard isInTitlebar, let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(window)
        } else {
            window.performDrag(with: event)
        }
    }

    override var mouseDownCanMoveWindow: Bool { isInTitlebar }

    /// The system's titlebar double-click action (`AppleActionOnDoubleClick` in the global domain):
    /// "Minimize", "None", or zoom ("Maximize"/"Fill", the default).
    static func performTitlebarDoubleClick(_ window: NSWindow) {
        let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

// MARK: - Drag zones of a titlebar tab (#27)
//
// Matches macOS's native titlebar tabs (which Ghostty uses unchanged): a press-and-drag on the top
// half of a tab moves the window, on the bottom half it drags the tab; a click anywhere selects it.
//
// The window server, not the app, decides whether a titlebar press moves the window, and it decides
// before the app sees the press, so `mouseDownCanMoveWindow` (one answer per view) can't split a tab.
// Instead the tab turns the window's `isMovable` off while the pointer is over its bottom half and
// back on everywhere else. Top-half presses that reach the app are passed to `performDrag`.

extension TabButton {
    enum TitlebarZone { case window, tab }

    /// Which zone a window point falls in, or nil when this tab isn't in the titlebar.
    func titlebarZone(at windowPoint: CGPoint) -> TitlebarZone? {
        guard (superview as? TabStripView)?.isInTitlebar == true else { return nil }
        let p = convert(windowPoint, from: nil)
        guard bounds.contains(p) else { return nil }
        if closeRect.contains(p) { return .tab }   // the × must stay clickable
        return p.y < bounds.midY ? .window : .tab  // flipped: small y is the top
    }

    func updateTitlebarDragZone(_ event: NSEvent) {
        guard let window, (superview as? TabStripView)?.isInTitlebar == true else { return }
        let movable = titlebarZone(at: event.locationInWindow) != .tab
        if window.isMovable != movable { window.isMovable = movable }
    }

    func leaveTitlebarDragZone() {
        if let window, !window.isMovable { window.isMovable = true }
    }

    /// Waits for the press to become a drag (then moves the window) or a release (a plain click).
    func dragWindowIfDragged(_ event: NSEvent) {
        guard let window else { return }
        let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                    inMode: .eventTracking, dequeue: true)
        if next?.type == .leftMouseDragged { window.performDrag(with: event) }
    }
}
