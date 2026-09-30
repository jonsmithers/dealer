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
    var root: TreeSnapshot<PaneSnapshot>
}

struct DeckSnapshot: Codable {
    var tabs: [TabSnapshot]
    var activeIndex: Int
    var colorIndex: Int
}

struct WindowSnapshot: Codable {
    var frame: CGRect
    var root: TreeSnapshot<DeckSnapshot>
}

struct SessionSnapshot: Codable {
    var windows: [WindowSnapshot]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTerm", isDirectory: true)
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
            NSLog("MyTerm: failed to save session: \(error)")
        }
    }
}

extension TerminalWindowController {
    func snapshot() -> WindowSnapshot? {
        guard let root, let window else { return nil }
        func paneTree(_ n: Node<Pane>) -> TreeSnapshot<PaneSnapshot> {
            if let p = n.leaf {
                return .leaf(PaneSnapshot(pwd: p.pwd, title: p.shellTitle, focused: p === focusedPane))
            }
            return .split(axis: n.axis, ratio: n.ratio, a: paneTree(n.a!), b: paneTree(n.b!))
        }
        func deckTree(_ n: Node<Deck>) -> TreeSnapshot<DeckSnapshot> {
            if let d = n.leaf {
                let tabs = d.tabs.map { TabSnapshot(customTitle: $0.customTitle, root: paneTree($0.root)) }
                return .leaf(DeckSnapshot(tabs: tabs, activeIndex: d.activeIndex, colorIndex: d.colorIndex))
            }
            return .split(axis: n.axis, ratio: n.ratio, a: deckTree(n.a!), b: deckTree(n.b!))
        }
        return WindowSnapshot(frame: window.frame, root: deckTree(root))
    }

    /// Rebuilds the tree from a snapshot. Returns the pane that had focus.
    func restoreTree(_ snap: WindowSnapshot) -> (root: Node<Deck>, focus: Pane?) {
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
                    return tab
                }
                deck.activeIndex = min(max(ds.activeIndex, 0), max(deck.tabs.count - 1, 0))
                return Node(deck)
            case let .split(axis, ratio, a, b):
                return Node(axis: axis, ratio: ratio, a: deckTree(a), b: deckTree(b))
            }
        }
        let root = deckTree(snap.root)
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
