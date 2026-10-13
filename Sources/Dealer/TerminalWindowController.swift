import AppKit

/// One terminal window: workspaces, each a tree of decks, each holding tabs, each holding a tree of panes.
///
///     Window
///     └─ Workspaces   one shown at a time; the others stay alive, hidden
///        └─ Decks   split side by side or stacked; each has its own tab strip
///           └─ Tabs   one active per deck
///              └─ Panes   split inside a single tab; hidden when the tab is
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    /// In switcher order. Never empty while the window is open.
    private(set) var workspaces: [Workspace]
    private(set) var activeWorkspace: Workspace

    /// The active workspace's deck tree.
    var root: Node<Deck>? { activeWorkspace.root }
    /// The active workspace's focused pane.
    var focusedPane: Pane? { activeWorkspace.validFocusedPane }
    /// A split selected with "Select Parent"; promote acts on it instead of the focused pane.
    var selection: Node<Pane>? { activeWorkspace.selection }
    /// Level 1 fills the deck, level 2 fills the window.
    private var zoom: (pane: WeakRef<Pane>, level: Int)?

    let contentView = WindowContentView()
    /// The sidebar workspace switcher, a left column below the titlebar row (WorkspaceSidebar.swift).
    let workspaceSidebar = WorkspaceSidebarView()
    /// The top-bar pill switcher, shown instead of the sidebar when `workspaceSwitcher = top` (#8).
    let workspaceBar = WorkspaceBarView()
    /// Shows settings.toml problems (SettingsBanner.swift).
    let settingsBanner = SettingsBannerView()
    /// The sidebar toggle in the titlebar row (WorkspaceSidebar.swift).
    let sidebarToggle = SidebarToggleButton()
    /// The user's explicit sidebar choice for this window; `nil` means automatic (shown with 2+
    /// workspaces). Persisted in the session.
    var sidebarPreference: Bool?
    lazy var drag = DragController(controller: self)
    /// Stable for the window's lifetime, for the control socket (`dealer`).
    let id = StableID.next(.window)
    var onClose: ((TerminalWindowController) -> Void)?

    private var windowDividers: [DividerView] = []
    private var paneDividers: [ObjectIdentifier: [DividerView]] = [:]

    static var deckGap: CGFloat { Theme.Metrics.deckGap }
    static var paneGap: CGFloat { Theme.Metrics.paneGap }

    /// `workingDirectory` is where a fresh window's first pane starts (ignored when restoring).
    init(snapshot: WindowSnapshot? = nil, workingDirectory: String? = nil) {
        let ws = Workspace(root: nil)
        workspaces = [ws]
        activeWorkspace = ws
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.window
        window.appearance = Theme.appearance
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 480, height: 320)
        window.contentView = contentView
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        LiveObjects.add(.window)
        observeSettings()
        observeTheme()

        if let snapshot {
            restore(snapshot)
        } else {
            ws.root = Node(makeDeck(workingDirectory: workingDirectory))
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { LiveObjects.remove(.window) }

    private func restore(_ snapshot: WindowSnapshot) {
        let restored = restoreWorkspaces(snapshot)
        if !restored.isEmpty {
            workspaces = restored
            activeWorkspace = restored[min(max(snapshot.activeWorkspace ?? 0, 0), restored.count - 1)]
        } else {
            activeWorkspace.root = Node(makeDeck(workingDirectory: nil))
        }
        sidebarPreference = snapshot.sidebar
        window?.setFrame(snapshot.frame, display: false)
    }

    /// A deck with one tab holding one fresh pane.
    func makeDeck(workingDirectory: String?, colorIndex: Int = 0) -> Deck {
        let deck = Deck(colorIndex: colorIndex)
        deck.tabs = [Tab(root: Node(makePane(workingDirectory: workingDirectory)))]
        return deck
    }

    func showAndFocus() {
        showWindow(nil)
        layoutNow()
        if let p = focusedPane ?? focusedDeck?.activeTab?.focusTarget { focus(p) }
    }

    // MARK: - Queries

    /// Decks of the active workspace.
    var decks: [Deck] { activeWorkspace.decks }
    /// Decks of every workspace in this window.
    var allDecks: [Deck] { workspaces.flatMap(\.decks) }

    var focusedDeck: Deck? {
        if let p = focusedPane, let loc = locate(p) { return loc.deck }
        return decks.first
    }

    /// Finds a pane in any workspace of this window.
    func locate(_ pane: Pane) -> (workspace: Workspace, deck: Deck, tab: Tab, node: Node<Pane>)? {
        for ws in workspaces {
            for deck in ws.decks {
                for tab in deck.tabs {
                    if let n = tab.root.node(for: pane) { return (ws, deck, tab, n) }
                }
            }
        }
        return nil
    }

    func deck(of tab: Tab) -> Deck? { allDecks.first { $0.index(of: tab) != nil } }
    func workspace(of deck: Deck) -> Workspace? { workspaces.first { $0.contains(deck) } }
    func workspace(of pane: Pane) -> Workspace? { locate(pane)?.workspace }

    /// The rect decks are laid out in: below the titlebar, inset from the window edge.
    var deckArea: CGRect {
        let b = contentView.bounds
        let titlebar = window.map { b.height - $0.contentLayoutRect.height } ?? 28
        let g = Self.deckGap
        // The workspace sidebar takes a column on the left; decks shrink rather than sit under it.
        let side = isSidebarVisible ? Theme.Metrics.sidebarWidth + g : 0
        return CGRect(x: g + side, y: max(titlebar, 28), width: b.width - g * 2 - side,
                      height: b.height - max(titlebar, 28) - g - Demo.captionBand)
    }

    /// Frames of every pane currently on screen, in content view coordinates.
    var visiblePaneFrames: [(Pane, CGRect)] {
        decks.flatMap { deck -> [(Pane, CGRect)] in
            guard deck.view.superview != nil, !deck.view.isHidden, let tab = deck.activeTab else { return [] }
            return tab.panes.compactMap { p in
                guard !p.view.isHidden, p.view.superview != nil else { return nil }
                return (p, p.view.convert(p.view.bounds, to: contentView))
            }
        }
    }

    func frame(of node: Node<Pane>) -> CGRect? {
        let rects = node.leaves.compactMap { p in visiblePaneFrames.first { $0.0 === p }?.1 }
        guard var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        return r
    }

    func nextColorIndex(in ws: Workspace? = nil) -> Int {
        let decks = (ws ?? activeWorkspace).decks
        let used = Set(decks.map { $0.colorIndex % Palette.deckColors.count })
        return Palette.deckColors.indices.first { !used.contains($0) } ?? decks.count
    }

    // MARK: - Pane lifecycle

    func makePane(workingDirectory: String?, command: String? = nil) -> Pane {
        let pane = Pane(workingDirectory: workingDirectory, command: command)
        pane.surface.onTitle = { [weak self, weak pane] title in
            guard let self, let pane else { return }
            pane.shellTitle = title
            self.refreshChrome()
        }
        pane.surface.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.remove(pane)
        }
        pane.surface.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.didFocus(pane)
        }
        return pane
    }

    func confirm(_ message: String, info: String, then action: @escaping () -> Void) {
        guard let window, !Confirmation.skip(message, info) else { return action() }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn { action() }
        }
    }

    func close(pane: Pane) {
        if pane.surface.needsConfirmQuit {
            confirm("Close this pane?", info: "A process is still running in it.") { [weak self] in self?.remove(pane) }
        } else {
            remove(pane)
        }
    }

    func close(tab: Tab) {
        let run = { [weak self] in
            guard let self, let deck = self.deck(of: tab) else { return }
            self.detach(tab: tab, from: deck)
            tab.panes.forEach { $0.view.removeFromSuperview() }
            self.finishChange(focus: nil)
        }
        if tab.panes.contains(where: { $0.surface.needsConfirmQuit }) {
            confirm("Close this tab?", info: "A process is still running in one of its panes.", then: run)
        } else {
            run()
        }
    }

    /// Removes a pane for good (its shell exited or the user closed it).
    func remove(_ pane: Pane) {
        pane.view.removeFromSuperview()
        guard let loc = locate(pane) else { return }
        let sibling = loc.node.sibling?.leaves.first
        detach(node: loc.node, from: loc.tab, in: loc.deck)
        finishChange(focus: focusedPane === pane ? sibling : focusedPane)
    }

    // MARK: - Structural helpers

    /// Takes a pane subtree out of its tab. Empty tabs and decks are cleaned up.
    func detach(node: Node<Pane>, from tab: Tab, in deck: Deck) {
        if let r = Node.remove(node, from: tab.root) {
            tab.root = r
        } else {
            detach(tab: tab, from: deck)
        }
    }

    /// Takes a tab out of its deck. An empty deck is removed and its neighbours expand.
    func detach(tab: Tab, from deck: Deck) {
        guard let i = deck.index(of: tab) else { return }
        deck.tabs.remove(at: i)
        if deck.activeIndex > i || deck.activeIndex >= deck.tabs.count {
            deck.activeIndex = max(0, deck.activeIndex - 1)
        }
        if deck.tabs.isEmpty { detach(deck: deck) }
    }

    /// Takes a deck out of its workspace's tree. An emptied workspace is closed by `finishChange`.
    func detach(deck: Deck) {
        guard let ws = workspace(of: deck), let root = ws.root, let node = root.node(for: deck) else { return }
        ws.root = Node.remove(node, from: root)
        deck.view.removeFromSuperview()
    }

    /// Common tail of every structural change: drop transient state, close emptied workspaces
    /// (and the window with the last one), lay out, restore focus.
    func finishChange(focus target: Pane?) {
        activeWorkspace.selection = nil
        if let z = zoom, z.pane.value.flatMap({ locate($0) })?.workspace !== activeWorkspace { zoom = nil }
        if let i = workspaces.firstIndex(where: { $0 === activeWorkspace }), activeWorkspace.root == nil {
            workspaces.removeAll { $0.root == nil }
            guard !workspaces.isEmpty else {
                window?.close()
                return
            }
            activeWorkspace = workspaces[min(i, workspaces.count - 1)]
        }
        workspaces.removeAll { $0.root == nil }
        layoutNow()
        if let p = target, locate(p) != nil {
            focus(p)
        } else if let p = focusedDeck?.activeTab?.focusTarget {
            focus(p)
        }
    }

    /// Shows `ws`, hiding (not removing) the other workspaces' decks, and focuses where it was left.
    func activate(_ ws: Workspace) {
        guard workspaces.contains(where: { $0 === ws }) else { return }
        if ws !== activeWorkspace {
            activeWorkspace.selection = nil
            zoom = nil
            activeWorkspace = ws
            layoutNow()
        }
        if let p = ws.validFocusedPane ?? ws.decks.first?.activeTab?.focusTarget { focus(p) }
        refreshChrome()
    }

    /// Adds `ws` to the window's list; used by workspace commands in Workspace.swift.
    func insert(workspace ws: Workspace, at index: Int) {
        autoAssignColor(ws)
        workspaces.insert(ws, at: min(max(index, 0), workspaces.count))
    }

    /// Reorders the switcher.
    func move(workspace ws: Workspace, to index: Int) {
        guard let i = workspaces.firstIndex(where: { $0 === ws }) else { return }
        workspaces.remove(at: i)
        workspaces.insert(ws, at: min(max(index, 0), workspaces.count))
        refreshChrome()
    }

    /// Drops a workspace and every terminal in it. The window closes with its last workspace.
    func remove(workspace ws: Workspace) {
        guard workspaces.contains(where: { $0 === ws }) else { return }
        ws.decks.forEach { $0.view.removeFromSuperview() }
        ws.root = nil
        finishChange(focus: nil)
    }

    /// Places a tab in `ws`: a new tab after the active one in its focused deck, or its first deck.
    func place(tab: Tab, in ws: Workspace) {
        let focusedDeck = ws.validFocusedPane.flatMap { locate($0)?.deck } ?? ws.decks.first
        if let deck = focusedDeck {
            let i = min(deck.activeIndex + 1, deck.tabs.count)
            deck.tabs.insert(tab, at: i)
            deck.activeIndex = i
        } else {
            let deck = Deck(colorIndex: 0)
            deck.tabs = [tab]
            ws.root = Node(deck)
        }
        if let p = tab.focusTarget { ws.focusedPane = p }
    }

    /// Adds a deck at the right edge of `ws`, sized like one more column.
    func place(deck: Deck, in ws: Workspace) {
        deck.origin = nil
        deck.colorIndex = nextColorIndex(in: ws)
        if let current = ws.root {
            let n = CGFloat(ws.decks.count)
            ws.root = Node.insert(Node(deck), beside: current, side: .right, fraction: 1 / (n + 1), root: current)
        } else {
            ws.root = Node(deck)
        }
        if let p = deck.activeTab?.focusTarget { ws.focusedPane = p }
    }

    // MARK: - Commands: panes and tabs

    func split(_ pane: Pane, side: Side) {
        guard let loc = locate(pane) else { return }
        let new = makePane(workingDirectory: WorkingDirectory.inherited(from: pane, for: .split))
        loc.tab.root = Node.insert(Node(new), beside: loc.node, side: side, root: loc.tab.root)
        zoom = nil
        finishChange(focus: new)
    }

    func newTab(in deck: Deck) {
        let tab = Tab(root: Node(makePane(workingDirectory: WorkingDirectory.inherited(from: focusedPane, for: .tab))))
        let i = min(deck.activeIndex + 1, deck.tabs.count)
        deck.tabs.insert(tab, at: i)
        deck.activeIndex = i
        finishChange(focus: tab.panes.first)
    }

    func select(tab: Tab, in deck: Deck) {
        guard let i = deck.index(of: tab) else { return }
        deck.activeIndex = i
        layoutNow()
        if let p = tab.focusTarget { focus(p) }
    }

    func gotoTab(index: Int) {
        guard let deck = focusedDeck, !deck.tabs.isEmpty else { return }
        let i = min(index, deck.tabs.count - 1)
        select(tab: deck.tabs[i], in: deck)
    }

    func renameTab(_ tab: Tab) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to follow the terminal title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customTitle ?? tab.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let t = field.stringValue.trimmingCharacters(in: .whitespaces)
            tab.customTitle = t.isEmpty ? nil : t
            self?.refreshChrome()
        }
    }

    /// Drag a pane (or group) onto another pane's edge: re-split beside it.
    func move(_ node: Node<Pane>, besidePane target: Pane, side: Side) {
        guard let src = node.leaves.first.flatMap({ locate($0) }),
              let dst = locate(target), !node.contains(dst.node) else { return }
        detach(node: node, from: src.tab, in: src.deck)
        guard let dstNow = locate(target) else { return }
        dstNow.tab.root = Node.insert(node, beside: dstNow.node, side: side, root: dstNow.tab.root)
        if let i = dstNow.deck.index(of: dstNow.tab) { dstNow.deck.activeIndex = i }
        finishChange(focus: node.leaves.first)
    }

    /// Drop a pane on the centre of another pane: they trade places.
    func swap(_ a: Pane, _ b: Pane) {
        guard a !== b, let la = locate(a), let lb = locate(b) else { return }
        la.node.leaf = b
        lb.node.leaf = a
        finishChange(focus: a)
    }

    /// Drop a pane (or group) on a tab strip: it becomes its own tab there.
    func moveToNewTab(_ node: Node<Pane>, deck: Deck, index: Int) {
        guard let src = node.leaves.first.flatMap({ locate($0) }) else { return }
        var index = index
        if src.tab.root === node {
            // The whole tab is moving; that's just a tab move.
            return move(tab: src.tab, to: deck, index: index)
        }
        detach(node: node, from: src.tab, in: src.deck)
        index = min(index, deck.tabs.count)
        let tab = Tab(root: node)
        deck.tabs.insert(tab, at: index)
        deck.activeIndex = index
        finishChange(focus: node.leaves.first)
    }

    /// Reorder a tab, or move it into another deck's strip.
    func move(tab: Tab, to deck: Deck, index: Int) {
        guard let from = self.deck(of: tab), let fi = from.index(of: tab) else { return }
        var index = index
        if from === deck {
            if index > fi { index -= 1 }
            deck.tabs.remove(at: fi)
        } else {
            detach(tab: tab, from: from)
        }
        index = min(index, deck.tabs.count)
        deck.tabs.insert(tab, at: index)
        deck.activeIndex = index
        finishChange(focus: tab.focusTarget)
    }

    /// Drop a tab onto a pane's edge: it rejoins as a split.
    func merge(tab: Tab, besidePane target: Pane, side: Side) {
        guard let from = deck(of: tab), tab.root.node(for: target) == nil else { return }
        let focus = tab.focusTarget
        detach(tab: tab, from: from)
        guard let dst = locate(target) else { return }
        dst.tab.root = Node.insert(tab.root, beside: dst.node, side: side, root: dst.tab.root)
        if let i = dst.deck.index(of: dst.tab) { dst.deck.activeIndex = i }
        finishChange(focus: focus)
    }

    // MARK: - Commands: decks

    /// Pane → deck. With no side, the pane hoists to the window edge its outermost split puts it on.
    ///
    /// Sizing (#31): a pane or group split out of a tab keeps its size (menu Promote, #2). A whole
    /// tab, or anything with `evenly` (window-edge drops), shares the space evenly with the decks
    /// along that edge's axis instead: a tab fills its deck, so "keep its size" would mean the
    /// whole window. `fraction` overrides both.
    /// - Parameter allowWholeDeck: moving a deck's only tab just relocates the deck; commands disallow it.
    @discardableResult
    func promote(_ node: Node<Pane>, side: Side? = nil, fraction: CGFloat? = nil, allowWholeDeck: Bool = false, evenly: Bool = false) -> Bool {
        guard let src = node.leaves.first.flatMap({ locate($0) }), let root = src.workspace.root else { return false }
        let ws = src.workspace
        let focus = focusedPane.flatMap { node.node(for: $0) != nil ? $0 : nil } ?? node.leaves.first
        let area = deckArea
        let deck = Deck(colorIndex: nextColorIndex(in: src.workspace))
        let edge: Side
        // Measure before detaching: a promoted pane keeps its width (or height, for a stacked split).
        let before = frame(of: node)
        let even = evenly || node === src.tab.root

        if node === src.tab.root {
            // Only pane in its tab: the whole tab moves out into a new deck.
            if src.deck.tabs.count == 1 && (!allowWholeDeck || ws.decks.count == 1) { return false }
            let i = src.deck.index(of: src.tab) ?? 0
            edge = side ?? root.node(for: src.deck)?.outermostSide ?? .right
            deck.origin = .tab(deck: WeakRef(src.deck), index: i)
            detach(tab: src.tab, from: src.deck)
            deck.tabs = [src.tab]
        } else {
            guard let parent = node.parent, let anchor = node.sibling else { return false }
            edge = side ?? node.outermostSide ?? .right
            let first = node.isFirstChild
            let relSide: Side = parent.axis == .row ? (first ? .left : .right) : (first ? .top : .bottom)
            let share = first ? parent.ratio : 1 - parent.ratio
            deck.origin = .panes(tab: WeakRef(src.tab), anchor: WeakRef(anchor), side: relSide, fraction: share)
            detach(node: node, from: src.tab, in: src.deck)
            deck.tabs = [Tab(root: node)]
        }

        var f = fraction ?? 0.5
        if fraction == nil, even {
            // After detaching: a deck emptied by the move is already gone from the count.
            f = evenEdgeFraction(side: edge, in: ws.root)
        } else if fraction == nil, let r = before {
            // Include the deck's own chrome so the terminal ends up the same size. The new deck gets
            // `f` of the area minus the gap in front of it (see `Node.layout`).
            f = edge.axis == .row
                ? (r.width + DeckView.chromeSize.width) / max(area.width - Self.deckGap, 1)
                : (r.height + DeckView.chromeSize.height) / max(area.height - Self.deckGap, 1)
            f = min(max(f, 0.1), 0.6)
        }

        guard let current = ws.root else {
            ws.root = Node(deck)
            finishChange(focus: focus)
            return true
        }
        ws.root = Node.insert(Node(deck), beside: current, side: edge, fraction: f, root: current)
        zoom = nil
        finishChange(focus: focus)
        return true
    }

    /// The share a new deck at the window's `side` edge needs for it and every deck along that
    /// edge's axis in `root` to come out the same size (#31). `excluding` leaves out a deck that the
    /// move will empty (for the drop preview, measured before the move).
    func evenEdgeFraction(side: Side, in root: Node<Deck>?, excluding: Deck? = nil) -> CGFloat {
        func span(_ n: Node<Deck>) -> Int {
            if let d = n.leaf { return d === excluding ? 0 : 1 }
            guard let a = n.a, let b = n.b else { return 0 }
            return n.axis == side.axis ? span(a) + span(b) : max(span(a), span(b))
        }
        let k = CGFloat(root.map(span) ?? 0)
        guard k > 0 else { return 0.5 }
        // k + 1 decks of size x with k gaps fill the area; the new deck gets f of (area - one gap).
        let a = side.axis == .row ? deckArea.width : deckArea.height
        let g = Self.deckGap
        let x = (a - k * g) / (k + 1)
        return min(max(x / max(a - g, 1), 0.1), 0.5)
    }

    /// Deck → pane. The reverse of promote.
    func fold(_ deck: Deck) -> Bool {
        guard let ws = workspace(of: deck), ws.decks.count > 1, let root = ws.root, let deckNode = root.node(for: deck) else { return false }
        let focus = focusedPane.flatMap { p in deck.tabs.contains { $0.root.node(for: p) != nil } ? p : nil }
            ?? deck.activeTab?.focusTarget

        var placed = false
        if deck.tabs.count == 1, let tab = deck.tabs.first {
            switch deck.origin {
            case let .panes(tabRef, anchorRef, side, fraction)?:
                // Back into the tab it came from, on its original side.
                if let home = tabRef.value, let homeDeck = self.deck(of: home), homeDeck !== deck, ws.contains(homeDeck) {
                    let target = anchorRef.value.flatMap { home.root.contains($0) ? $0 : nil } ?? home.root
                    home.root = Node.insert(tab.root, beside: target, side: side, fraction: fraction, root: home.root)
                    homeDeck.activeIndex = homeDeck.index(of: home) ?? homeDeck.activeIndex
                    placed = true
                }
            case let .tab(deckRef, index)?:
                if let home = deckRef.value, home !== deck, root.node(for: home) != nil {
                    let i = min(index, home.tabs.count)
                    home.tabs.insert(tab, at: i)
                    home.activeIndex = i
                    placed = true
                }
            case nil:
                break
            }
        }

        if !placed {
            // Its origin is gone: fall back to the neighbouring deck.
            guard let parent = deckNode.parent, let sib = deckNode.sibling else { return false }
            let first = deckNode.isFirstChild
            guard let neighbour = first ? sib.leaves.first : sib.leaves.last else { return false }
            if deck.tabs.count == 1, let tab = deck.tabs.first, let target = neighbour.activeTab {
                let side: Side = parent.axis == .row ? (first ? .left : .right) : (first ? .top : .bottom)
                target.root = Node.insert(tab.root, beside: target.root, side: side, root: target.root)
            } else {
                // Several tabs: merge them into the neighbour's tab strip.
                let active = deck.activeTab
                neighbour.tabs.append(contentsOf: deck.tabs)
                if let active, let i = neighbour.index(of: active) { neighbour.activeIndex = i }
            }
        }

        deck.tabs = []
        detach(deck: deck)
        zoom = nil
        finishChange(focus: focus)
        return true
    }

    // MARK: - Focus

    /// Focuses a pane anywhere in the window, switching workspace if it lives in another one.
    func focus(_ pane: Pane) {
        guard let loc = locate(pane) else { return }
        if loc.workspace !== activeWorkspace {
            activeWorkspace.selection = nil
            zoom = nil
            activeWorkspace = loc.workspace
            layoutNow()
        }
        if loc.deck.activeTab !== loc.tab, let i = loc.deck.index(of: loc.tab) {
            loc.deck.activeIndex = i
            layoutNow()
        }
        if let z = zoom, z.pane.value !== pane { zoom = nil; layoutNow() }
        if window?.firstResponder !== pane.surface {
            window?.makeFirstResponder(pane.surface)
        }
        didFocus(pane)
    }

    private func didFocus(_ pane: Pane) {
        guard let loc = locate(pane) else { return }
        let changed = loc.workspace.focusedPane !== pane
        loc.workspace.focusedPane = pane
        loc.tab.lastFocused = pane
        // Attention.swift: focusing a pane reads it. Re-focusing the pane that already has focus
        // (finishChange after a background change, e.g. a `dealer run` job closing) only counts
        // when the user is looking, so a mark set while they're away survives it.
        if changed || isLookingAt(pane) {
            if pane.attention != .none {
                NotificationLog.decision(pane: pane, event: NotificationLog.clearCause ?? "focus", outcome: "attention:cleared",
                                         reason: "\(pane.attention.name) → none (\(changed ? "focus moved to the pane" : "re-focused while you were looking"); \(NotificationLog.context(self)))")
            }
            pane.attention = .none
        } else if pane.attention != .none {
            NotificationLog.decision(pane: pane, event: "focus", outcome: "attention:kept",
                                     reason: "\(pane.attention.name) kept: re-focused while you weren't looking (\(NotificationLog.context(self)))")
        }
        if changed && loc.workspace.selection != nil {
            loc.workspace.selection = nil
            updateSelectionHighlight()
        }
        refreshChrome()
    }

    /// Directional focus crosses deck boundaries purely by geometry.
    func moveFocus(_ dir: Side) {
        let frames = visiblePaneFrames
        guard let cur = focusedPane, let from = frames.first(where: { $0.0 === cur })?.1 else { return }
        var best: (Pane, CGFloat)?
        for (p, r) in frames where p !== cur {
            let primary: CGFloat
            let overlap: Bool
            let perp: CGFloat
            switch dir {
            case .left:
                guard r.maxX <= from.minX + 1 else { continue }
                primary = from.minX - r.maxX
                overlap = r.minY < from.maxY && r.maxY > from.minY
                perp = abs(r.midY - from.midY)
            case .right:
                guard r.minX >= from.maxX - 1 else { continue }
                primary = r.minX - from.maxX
                overlap = r.minY < from.maxY && r.maxY > from.minY
                perp = abs(r.midY - from.midY)
            case .top:
                guard r.maxY <= from.minY + 1 else { continue }
                primary = from.minY - r.maxY
                overlap = r.minX < from.maxX && r.maxX > from.minX
                perp = abs(r.midX - from.midX)
            case .bottom:
                guard r.minY >= from.maxY - 1 else { continue }
                primary = r.minY - from.maxY
                overlap = r.minX < from.maxX && r.maxX > from.minX
                perp = abs(r.midX - from.midX)
            }
            // Crossing into another deck lands on the pane you left there, when it's in line.
            let remembered = overlap && locate(p).map { $0.tab.lastFocused === p && $0.deck !== locate(cur)?.deck } == true
            let score = primary + (overlap ? (remembered ? 0 : perp * 0.01 + 0.001) : 10_000 + perp)
            if best == nil || score < best!.1 { best = (p, score) }
        }
        if let p = best?.0 { focus(p) } else { NSSound.beep() }
    }

    // MARK: - Layout

    func layoutNow() {
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
    }

    /// Called from WindowContentView.layout().
    func layoutWindow() {
        let area = deckArea
        var frames: [(Deck, CGRect)] = []
        var dividers: [Node<Deck>.Divider] = []
        let zoomed = zoom.flatMap { z in z.pane.value.flatMap { locate($0) }.map { (z, $0) } }
            .flatMap { $0.1.workspace === activeWorkspace ? $0 : nil }
        if let (z, loc) = zoomed, z.level >= 2 {
            frames = [(loc.deck, area)]
        } else {
            root?.layout(in: area, gap: Self.deckGap, frames: &frames, dividers: &dividers)
        }

        let inTree = Set(allDecks.map { ObjectIdentifier($0) })
        for case let dv as DeckView in contentView.subviews where !inTree.contains(ObjectIdentifier(dv.deck)) {
            dv.removeFromSuperview()
        }
        // Decks hidden by a window-level zoom, or in another workspace, stay parked with their
        // terminals occluded.
        let shown = Set(frames.map { ObjectIdentifier($0.0) })
        for deck in allDecks where !shown.contains(ObjectIdentifier(deck)) && !deck.view.isHidden {
            deck.view.isHidden = true
            deck.activeTab?.panes.forEach { $0.surface.setVisible(false) }
        }
        placeTabStrips(frames)  // #16: titlebar or in-deck, before the decks lay out
        sizeParked(allDecks.filter { !shown.contains(ObjectIdentifier($0)) }, area: area)
        for (deck, r) in frames {
            let dv = deck.view
            if dv.superview !== contentView { contentView.addSubview(dv) }
            if dv.isHidden {
                dv.isHidden = false
                deck.activeTab?.panes.forEach { if !$0.view.isHidden { $0.surface.setVisible(true) } }
            }
            dv.frame = r
            dv.showsColor = decks.count > 1
            dv.layoutSubtreeIfNeeded()
            layout(deck: deck, zoomed: zoomed.flatMap { $0.1.deck === deck ? $0.1.node.leaf : nil })
        }

        // Capture the split rect, not `d`: the Divider struct holds its node strongly (#43).
        syncDividers(&windowDividers, in: contentView, specs: dividers.map { d in
            (d.frame, d.node.axis, { [weak self, weak node = d.node, rect = d.splitRect] p in
                guard let node else { return }
                node.ratio = Self.ratio(for: p, in: rect, axis: node.axis, gap: Self.deckGap)
                self?.layoutNow()
            })
        })
        // Divider pools of decks that are gone (closed, or in another window now).
        let liveDecks = Set(allDecks.map(ObjectIdentifier.init))
        for key in paneDividers.keys where !liveDecks.contains(key) {
            paneDividers.removeValue(forKey: key)?.forEach { $0.onDrag = nil; $0.removeFromSuperview() }
        }

        layoutWorkspaceSidebar()
        contentView.raiseOverlays()
        updateSelectionHighlight()
    }

    private func layout(deck: Deck, zoomed: Pane?) {
        let dv = deck.view
        dv.strip.reload()
        dv.strip.layoutSubtreeIfNeeded()
        let bounds = dv.content.bounds
        guard let active = deck.activeTab else { return }

        // Background tabs stay hidden (and occluded) but are sized like the active one (#45).
        for tab in deck.tabs where tab !== active {
            for p in tab.panes {
                if p.view.superview !== dv.content { dv.content.addSubview(p.view) }
                if !p.view.isHidden {
                    p.view.isHidden = true
                    p.surface.setVisible(false)
                }
            }
            sizeHidden(tab, in: bounds)
        }

        var frames: [(Pane, CGRect)] = []
        var dividers: [Node<Pane>.Divider] = []
        if let zoomed, active.root.node(for: zoomed) != nil {
            frames = [(zoomed, bounds)]
        } else {
            active.root.layout(in: bounds, gap: Self.paneGap, frames: &frames, dividers: &dividers)
        }
        let visible = Set(frames.map { ObjectIdentifier($0.0) })
        let multi = active.panes.count > 1
        for p in active.panes where !visible.contains(ObjectIdentifier(p)) {
            p.view.isHidden = true
            p.surface.setVisible(false)
        }
        for (p, r) in frames {
            if p.view.superview !== dv.content { dv.content.addSubview(p.view) }
            if p.view.isHidden {
                p.view.isHidden = false
                p.surface.setVisible(true)
            }
            p.view.frame = r
            p.view.showsBar = multi
            p.view.dimsWhenUnfocused = multi || decks.count > 1
            p.view.accent = decks.count > 1 ? deck.color : Palette.neutral
            p.view.isFocusedPane = p === focusedPane
            p.view.refreshTitle()
            p.view.layoutSubtreeIfNeeded()
        }

        // Pane views left behind by panes that moved to another deck are reparented
        // automatically; anything else in here that isn't ours any more goes away.
        let owned = Set(deck.tabs.flatMap(\.panes).map { ObjectIdentifier($0.view) })
        for case let pv as PaneView in dv.content.subviews where !owned.contains(ObjectIdentifier(pv)) {
            pv.removeFromSuperview()
        }

        var pool = paneDividers[ObjectIdentifier(deck)] ?? []
        syncDividers(&pool, in: dv.content, specs: dividers.map { d in
            (d.frame, d.node.axis, { [weak self, weak node = d.node, rect = d.splitRect] p in
                guard let node else { return }
                node.ratio = Self.ratio(for: p, in: rect, axis: node.axis, gap: Self.paneGap)
                self?.layoutNow()
            })
        })
        paneDividers[ObjectIdentifier(deck)] = pool
    }

    /// Gives a tab that isn't on screen the frames it would have in `bounds`, without showing it or
    /// touching occlusion (#45). A pane created out of view (a background tab, another workspace)
    /// otherwise has no frame, so its surface is 1×1 cells: the shell's output is written into that
    /// grid, and resizing it to the real size on first show leaves only the prompt.
    private func sizeHidden(_ tab: Tab, in bounds: CGRect) {
        var frames: [(Pane, CGRect)] = []
        var dividers: [Node<Pane>.Divider] = []
        tab.root.layout(in: bounds, gap: Self.paneGap, frames: &frames, dividers: &dividers)
        let multi = tab.panes.count > 1
        for (p, r) in frames {
            p.view.showsBar = multi
            if p.view.frame != r { p.view.frame = r }
            p.view.layoutSubtreeIfNeeded()
        }
    }

    /// Decks that aren't shown (another workspace, or hidden by a window-level zoom) are sized as
    /// their workspace's unzoomed layout would size them, so their surfaces have a real grid (#45).
    /// Only frames change: they stay parked and occluded.
    private func sizeParked(_ decks: [Deck], area: CGRect) {
        guard !decks.isEmpty else { return }
        let parked = Set(decks.map { ObjectIdentifier($0) })
        for ws in workspaces {
            guard ws.decks.contains(where: { parked.contains(ObjectIdentifier($0)) }) else { continue }
            var frames: [(Deck, CGRect)] = []
            var dividers: [Node<Deck>.Divider] = []
            ws.root?.layout(in: area, gap: Self.deckGap, frames: &frames, dividers: &dividers)
            for (deck, r) in frames where parked.contains(ObjectIdentifier(deck)) {
                let dv = deck.view
                if dv.superview !== contentView {
                    dv.isHidden = true
                    contentView.addSubview(dv)
                }
                if dv.frame != r { dv.frame = r }
                dv.layoutSubtreeIfNeeded()
                for tab in deck.tabs {
                    for p in tab.panes where p.view.superview !== dv.content {
                        p.view.isHidden = true
                        p.surface.setVisible(false)
                        dv.content.addSubview(p.view)
                    }
                    sizeHidden(tab, in: dv.content.bounds)
                }
            }
        }
    }

    private static func ratio(for p: CGPoint, in rect: CGRect, axis: Axis, gap: CGFloat) -> CGFloat {
        let r = axis == .row
            ? (p.x - rect.minX - gap / 2) / max(rect.width - gap, 1)
            : (p.y - rect.minY - gap / 2) / max(rect.height - gap, 1)
        return min(max(r, 0.08), 0.92)
    }

    /// Reuses divider views so one being dragged survives the relayout it triggers.
    private func syncDividers(_ pool: inout [DividerView], in parent: NSView, specs: [(CGRect, Axis, (CGPoint) -> Void)]) {
        while pool.count < specs.count { pool.append(DividerView()) }
        // Hit areas overlap the panes beside a thin gap, so dividers must stay above them.
        let firstDivider = parent.subviews.firstIndex { $0 is DividerView }
        let buried = firstDivider.map { parent.subviews[$0...].contains { $0 is PaneView || $0 is DeckView } } ?? false
        for (i, dv) in pool.enumerated() {
            if i < specs.count {
                let (gap, axis, onDrag) = specs[i]
                let frame = DividerView.hitFrame(for: gap, axis: axis)
                if dv.superview !== parent || buried { parent.addSubview(dv, positioned: .above, relativeTo: nil) }
                if dv.frame != frame || dv.axis != axis {
                    dv.frame = frame
                    dv.axis = axis
                    parent.window?.invalidateCursorRects(for: dv)
                }
                dv.onDrag = onDrag
            } else {
                dv.onDrag = nil  // a spare must not keep its last split alive
                dv.removeFromSuperview()
            }
        }
    }

    /// Titles and focus rings only; no frames change.
    func refreshChrome() {
        for deck in allDecks {
            deck.view.strip.reload()
            for tab in deck.tabs {
                for p in tab.panes {
                    p.view.isFocusedPane = p === focusedPane
                    p.view.refreshTitle()
                }
            }
        }
        window?.title = focusedPane?.title ?? "Dealer"
        workspaceSidebar.reload()
        workspaceBar.reload()
        // The automatic sidebar appears with a second workspace: that changes the deck area.
        if workspaceSidebar.isHidden == isSidebarVisible { contentView.needsLayout = true }
    }

    func updateSelectionHighlight() {
        if let sel = selection, let r = frame(of: sel) {
            contentView.selectionHighlight.show(r.insetBy(dx: -2, dy: -2), color: focusedDeck?.color ?? Palette.neutral, fill: 0.08)
        } else {
            contentView.selectionHighlight.hide()
        }
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) {
        if let deck = focusedDeck { newTab(in: deck) }
    }

    @objc func splitRight(_ sender: Any?) {
        if let p = focusedPane { split(p, side: .right) }
    }

    @objc func splitDown(_ sender: Any?) {
        if let p = focusedPane { split(p, side: .bottom) }
    }

    @objc func closePane(_ sender: Any?) {
        if let p = focusedPane { close(pane: p) }
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = focusedDeck?.activeTab { close(tab: tab) }
    }

    @objc func renameCurrentTab(_ sender: Any?) {
        if let tab = focusedDeck?.activeTab { renameTab(tab) }
    }

    @objc func promoteToDeck(_ sender: Any?) {
        let node = selection ?? focusedPane.flatMap { locate($0)?.node }
        guard let node, promote(node) else { return NSSound.beep() }
    }

    @objc func foldDeck(_ sender: Any?) {
        guard let deck = focusedDeck, fold(deck) else { return NSSound.beep() }
    }

    @objc func selectParent(_ sender: Any?) {
        guard let base = selection ?? focusedPane.flatMap({ locate($0)?.node }), let parent = base.parent else {
            return NSSound.beep()
        }
        activeWorkspace.selection = parent
        updateSelectionHighlight()
    }

    @objc func toggleZoom(_ sender: Any?) {
        guard let pane = focusedPane, let loc = locate(pane) else { return }
        let multiPane = loc.tab.panes.count > 1
        let multiDeck = decks.count > 1
        switch zoom?.level {
        case nil:
            if multiPane { zoom = (WeakRef(pane), 1) } else if multiDeck { zoom = (WeakRef(pane), 2) } else { return NSSound.beep() }
        case 1?:
            zoom = multiDeck ? (WeakRef(pane), 2) : nil
        default:
            zoom = nil
        }
        layoutNow()
        focus(pane)
    }

    @objc func equalize(_ sender: Any?) {
        func eq<L>(_ n: Node<L>?) {
            guard let n, !n.isLeaf else { return }
            n.ratio = 0.5
            eq(n.a)
            eq(n.b)
        }
        eq(root)
        decks.forEach { d in d.tabs.forEach { eq($0.root) } }
        layoutNow()
    }

    @objc func focusLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusUp(_ sender: Any?) { moveFocus(.top) }
    @objc func focusDown(_ sender: Any?) { moveFocus(.bottom) }

    @objc func nextTab(_ sender: Any?) {
        guard let deck = focusedDeck, !deck.tabs.isEmpty else { return }
        select(tab: deck.tabs[(deck.activeIndex + 1) % deck.tabs.count], in: deck)
    }

    @objc func previousTab(_ sender: Any?) {
        guard let deck = focusedDeck, !deck.tabs.isEmpty else { return }
        select(tab: deck.tabs[(deck.activeIndex - 1 + deck.tabs.count) % deck.tabs.count], in: deck)
    }

    @objc func gotoTabFromMenu(_ sender: NSMenuItem) {
        gotoTab(index: sender.tag == 9 ? Int.max : sender.tag - 1)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(foldDeck(_:)): return decks.count > 1
        case #selector(promoteToDeck(_:)):
            guard let node = selection ?? focusedPane.flatMap({ locate($0)?.node }), let loc = node.leaves.first.flatMap({ locate($0) }) else { return false }
            return node !== loc.tab.root || loc.deck.tabs.count > 1
        default: return validateWorkspaceMenuItem(item) ?? true
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = allDecks.flatMap(\.tabs).flatMap(\.panes).contains { $0.surface.needsConfirmQuit }
        guard busy else { return true }
        confirm("Close this window?", info: "Processes are still running in it.") { [weak self] in
            guard let self else { return }
            self.workspaces.forEach { $0.root = nil }
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        releaseViews()
        onClose?(self)
    }

    /// A closed NSWindow can outlive its controller for a while (AppKit holds it past the close),
    /// and it would keep every deck, pane and SurfaceView in it alive: shells still running, tens
    /// of MB of renderer memory each, and a later layout pass reading freed decks through the
    /// strips' `unowned` reference (#43). Take them out of the window now; the model goes with the
    /// controller.
    private func releaseViews() {
        for deck in allDecks {
            deck.tabs.flatMap(\.panes).forEach { $0.view.removeFromSuperview() }
            deck.view.strip.removeFromSuperview()  // may sit in the titlebar row (#16)
            deck.view.removeFromSuperview()
        }
        for dv in windowDividers + paneDividers.values.flatMap({ $0 }) {
            dv.onDrag = nil
            dv.removeFromSuperview()
        }
        windowDividers = []
        paneDividers = [:]
    }

    func windowDidResize(_ notification: Notification) {
        updateSelectionHighlight()
    }
}
