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
// isn't a concern because decks never extend over it. A strip clipped below `minWidth` stays in its
// deck instead.

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
        if Settings.tabsInTitlebar {
            let clear = titlebarClearX
            for (deck, r) in frames where abs(r.minY - area.minY) < 0.5 {
                let x = max(r.minX, clear)
                guard r.maxX - x >= Self.titlebarStripMinWidth else { continue }
                let strip = deck.view.strip
                if strip.superview !== contentView { contentView.addSubview(strip) }
                strip.frame = CGRect(x: x, y: 0, width: r.maxX - x, height: area.minY)
                deck.view.stripInTitlebar = true
                up.insert(ObjectIdentifier(deck))
            }
        }
        // Strips left in the titlebar by decks that lost the top edge, were hidden, or were removed
        // (detach takes the deck view away but not a strip living outside it).
        for case let s as TabStripView in contentView.subviews where !up.contains(ObjectIdentifier(s.deck)) {
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

extension WorkspaceBarView {
    /// Width of the pills plus "+", i.e. the fixed left segment in top-bar mode.
    var contentWidth: CGFloat {
        subviews.compactMap { $0 as? WorkspaceButton }.filter { !$0.isHidden }
            .reduce(0) { $0 + min($1.idealWidth, Self.maxPillWidth) + Self.spacing }
    }
}
