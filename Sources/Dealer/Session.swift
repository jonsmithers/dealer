import AppKit

/// Serialized window → deck → tab → pane tree, with sizes, so a restored session looks the same.
indirect enum TreeSnapshot<Leaf: Codable>: Codable {
    case leaf(Leaf)
    case split(axis: Axis, ratio: CGFloat, a: TreeSnapshot, b: TreeSnapshot)
}

struct PaneSnapshot: Codable {
    var pwd: String?
    var title: String?
    var focused: Bool
}

struct TabSnapshot: Codable {
    var customTitle: String?
    /// "#rrggbb" (#9); absent in older files.
    var color: String?
    var root: TreeSnapshot<PaneSnapshot>
}

struct DeckSnapshot: Codable {
    var tabs: [TabSnapshot]
    var activeIndex: Int
    var colorIndex: Int
}

struct WorkspaceSnapshot: Codable {
    var name: String?
    /// "#rrggbb" (#9); absent in older files.
    var color: String?
    var root: TreeSnapshot<DeckSnapshot>
    /// Index into `WindowSnapshot.groups` (#80); absent at the root and in older files. Older
    /// builds ignore it (and `groups`), so they load the same workspaces, ungrouped.
    var group: Int? = nil
}

/// A workspace group (#80). Its members are the workspaces whose `group` is its index.
struct GroupSnapshot: Codable {
    var name: String
    var collapsed: Bool
}

struct WindowSnapshot: Codable {
    var frame: CGRect
    var workspaces: [WorkspaceSnapshot]?
    var activeWorkspace: Int?
    /// Session files written before workspaces had one deck tree per window here.
    var root: TreeSnapshot<DeckSnapshot>?
    /// The user's explicit workspace-sidebar choice; absent (nil) means automatic. Optional so
    /// older files still decode.
    var sidebar: Bool?
    /// Workspace groups (#80); absent in older files and when there are none.
    var groups: [GroupSnapshot]?

    init(frame: CGRect, workspaces: [WorkspaceSnapshot], activeWorkspace: Int, sidebar: Bool? = nil, groups: [GroupSnapshot]? = nil) {
        self.frame = frame
        self.workspaces = workspaces
        self.activeWorkspace = activeWorkspace
        self.sidebar = sidebar
        self.groups = groups
    }

    /// The window's workspaces; an old single-tree file becomes one workspace.
    var allWorkspaces: [WorkspaceSnapshot] {
        workspaces ?? root.map { [WorkspaceSnapshot(name: nil, color: nil, root: $0)] } ?? []
    }
}

struct SessionSnapshot: Codable {
    var windows: [WindowSnapshot]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dealer", isDirectory: true)
        return dir.appendingPathComponent("session.json")
    }

    static func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.url, options: .atomic)
        } catch {
            NSLog("Dealer: failed to save session: \(error)")
        }
    }
}

extension TerminalWindowController {
    func snapshot() -> WindowSnapshot? {
        guard let window else { return nil }
        var focusedPane: Pane?
        func paneTree(_ n: Node<Pane>) -> TreeSnapshot<PaneSnapshot> {
            if let p = n.leaf {
                return .leaf(PaneSnapshot(pwd: p.pwd, title: p.shellTitle, focused: p === focusedPane))
            }
            return .split(axis: n.axis, ratio: n.ratio, a: paneTree(n.a!), b: paneTree(n.b!))
        }
        func deckTree(_ n: Node<Deck>) -> TreeSnapshot<DeckSnapshot> {
            if let d = n.leaf {
                let tabs = d.tabs.map { TabSnapshot(customTitle: $0.customTitle, color: $0.color?.hexString, root: paneTree($0.root)) }
                return .leaf(DeckSnapshot(tabs: tabs, activeIndex: d.activeIndex, colorIndex: d.colorIndex))
            }
            return .split(axis: n.axis, ratio: n.ratio, a: deckTree(n.a!), b: deckTree(n.b!))
        }
        let live = workspaces.filter { $0.root != nil }
        guard !live.isEmpty else { return nil }
        var groups: [WorkspaceGroup] = []
        let wss = live.map { ws -> WorkspaceSnapshot in
            focusedPane = ws.validFocusedPane
            var gi: Int?
            if let g = ws.group {
                if !groups.contains(where: { $0 === g }) { groups.append(g) }
                gi = groups.firstIndex { $0 === g }
            }
            return WorkspaceSnapshot(name: ws.name, color: ws.color?.hexString, root: deckTree(ws.root!), group: gi)
        }
        return WindowSnapshot(frame: window.frame, workspaces: wss,
                              activeWorkspace: live.firstIndex { $0 === activeWorkspace } ?? 0,
                              sidebar: sidebarPreference,
                              groups: groups.isEmpty ? nil : groups.map { GroupSnapshot(name: $0.name, collapsed: $0.isCollapsed) })
    }

    /// Rebuilds every workspace in a snapshot, including one migrated from a pre-workspace file.
    /// Groups (#80) are rebuilt from their indices; a bad index leaves the workspace at the root.
    /// Workspaces come back in file order; `restore` gathers a split group's members together.
    func restoreWorkspaces(_ snap: WindowSnapshot) -> [Workspace] {
        let groups = (snap.groups ?? []).map { gs -> WorkspaceGroup in
            let g = WorkspaceGroup(name: gs.name.isEmpty ? "Group" : gs.name)
            g.isCollapsed = gs.collapsed
            return g
        }
        return snap.allWorkspaces.map { wss in
            let (root, focus) = restoreTree(wss.root)
            let ws = Workspace(root: root, name: wss.name)
            ws.color = wss.color.flatMap { NSColor(hex: $0) }
            ws.group = wss.group.flatMap { groups.indices.contains($0) ? groups[$0] : nil }
            ws.focusedPane = focus
            return ws
        }
    }

    /// Rebuilds the tree from a snapshot. Returns the pane that had focus.
    func restoreTree(_ snap: TreeSnapshot<DeckSnapshot>) -> (root: Node<Deck>, focus: Pane?) {
        var focus: Pane?
        func paneTree(_ s: TreeSnapshot<PaneSnapshot>) -> Node<Pane> {
            switch s {
            case let .leaf(ps):
                let p = makePane(workingDirectory: ps.pwd)
                p.shellTitle = ps.title
                if ps.focused { focus = p }
                return Node(p)
            case let .split(axis, ratio, a, b):
                return Node(axis: axis, ratio: ratio, a: paneTree(a), b: paneTree(b))
            }
        }
        func deckTree(_ s: TreeSnapshot<DeckSnapshot>) -> Node<Deck> {
            switch s {
            case let .leaf(ds):
                let deck = Deck(colorIndex: ds.colorIndex)
                deck.tabs = ds.tabs.map { ts in
                    let tab = Tab(root: paneTree(ts.root))
                    tab.customTitle = ts.customTitle
                    tab.color = ts.color.flatMap { NSColor(hex: $0) }
                    return tab
                }
                deck.activeIndex = min(max(ds.activeIndex, 0), max(deck.tabs.count - 1, 0))
                return Node(deck)
            case let .split(axis, ratio, a, b):
                return Node(axis: axis, ratio: ratio, a: deckTree(a), b: deckTree(b))
            }
        }
        let root = deckTree(snap)
        // Remember the last-focused pane per tab so switching tabs lands where you left off.
        if let focus {
            for deck in root.leaves {
                for tab in deck.tabs where tab.root.node(for: focus) != nil {
                    tab.lastFocused = focus
                }
            }
        }
        return (root, focus)
    }
}
