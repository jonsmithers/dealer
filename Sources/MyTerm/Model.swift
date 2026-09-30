import AppKit

enum Axis: String, Codable {
    /// Children side by side.
    case row
    /// Children stacked.
    case col
}

enum Side: String, Codable {
    case left, right, top, bottom

    var axis: Axis { self == .left || self == .right ? .row : .col }
    /// True when the new node goes first (left/top) in its split.
    var isLeading: Bool { self == .left || self == .top }
}

/// A binary split tree. Used twice: panes inside a tab, and decks inside a window.
/// Nodes are reference types so that dividers, selections and fold origins can hold on to them.
final class Node<Leaf: AnyObject> {
    var leaf: Leaf?
    var axis: Axis = .row
    /// Fraction of the space given to `a`.
    var ratio: CGFloat = 0.5
    private(set) var a: Node?
    private(set) var b: Node?
    weak var parent: Node?

    init(_ leaf: Leaf) { self.leaf = leaf }

    init(axis: Axis, ratio: CGFloat, a: Node, b: Node) {
        self.axis = axis
        self.ratio = ratio
        self.a = a
        self.b = b
        a.parent = self
        b.parent = self
    }

    var isLeaf: Bool { leaf != nil }

    var leaves: [Leaf] {
        if let leaf { return [leaf] }
        return (a?.leaves ?? []) + (b?.leaves ?? [])
    }

    var root: Node {
        var n = self
        while let p = n.parent { n = p }
        return n
    }

    var sibling: Node? {
        guard let p = parent else { return nil }
        return p.a === self ? p.b : p.a
    }

    var isFirstChild: Bool { parent?.a === self }

    func node(for leaf: Leaf) -> Node? {
        if self.leaf === leaf { return self }
        return a?.node(for: leaf) ?? b?.node(for: leaf)
    }

    func contains(_ node: Node) -> Bool {
        var n: Node? = node
        while let x = n {
            if x === self { return true }
            n = x.parent
        }
        return false
    }

    private func replaceChild(_ old: Node, with new: Node) {
        if a === old { a = new } else if b === old { b = new } else { return }
        new.parent = self
    }

    /// Removes `node` from the tree rooted at `root`, collapsing its parent. Returns the new root.
    static func remove(_ node: Node, from root: Node) -> Node? {
        if node === root {
            node.parent = nil
            return nil
        }
        guard let parent = node.parent, let sibling = node.sibling else { return root }
        node.parent = nil
        if let gp = parent.parent {
            gp.replaceChild(parent, with: sibling)
            return root
        }
        sibling.parent = nil
        return sibling
    }

    /// Inserts `node` beside `target` on `side`. `fraction` is the share of the new split given to `node`.
    static func insert(_ node: Node, beside target: Node, side: Side, fraction: CGFloat = 0.5, root: Node) -> Node {
        let gp = target.parent
        let f = min(max(fraction, 0.1), 0.9)
        let split = side.isLeading
            ? Node(axis: side.axis, ratio: f, a: node, b: target)
            : Node(axis: side.axis, ratio: 1 - f, a: target, b: node)
        if let gp {
            gp.replaceChild(target, with: split)
            return root
        }
        return split
    }

    struct Divider {
        let node: Node
        let frame: CGRect
        /// The rect the split occupies, needed to turn a drag position into a ratio.
        let splitRect: CGRect
    }

    func layout(in rect: CGRect, gap: CGFloat, frames: inout [(Leaf, CGRect)], dividers: inout [Divider]) {
        if let leaf {
            frames.append((leaf, rect.integral))
            return
        }
        guard let a, let b else { return }
        let r0: CGRect, r1: CGRect, d: CGRect
        if axis == .row {
            let w = max(rect.width - gap, 0)
            let wa = (w * ratio).rounded()
            r0 = CGRect(x: rect.minX, y: rect.minY, width: wa, height: rect.height)
            d = CGRect(x: r0.maxX, y: rect.minY, width: gap, height: rect.height)
            r1 = CGRect(x: d.maxX, y: rect.minY, width: rect.maxX - d.maxX, height: rect.height)
        } else {
            let h = max(rect.height - gap, 0)
            let ha = (h * ratio).rounded()
            r0 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ha)
            d = CGRect(x: rect.minX, y: r0.maxY, width: rect.width, height: gap)
            r1 = CGRect(x: rect.minX, y: d.maxY, width: rect.width, height: rect.maxY - d.maxY)
        }
        dividers.append(Divider(node: self, frame: d, splitRect: rect))
        a.layout(in: r0, gap: gap, frames: &frames, dividers: &dividers)
        b.layout(in: r1, gap: gap, frames: &frames, dividers: &dividers)
    }

    func frames(in rect: CGRect, gap: CGFloat) -> [(Leaf, CGRect)] {
        var f: [(Leaf, CGRect)] = []
        var d: [Divider] = []
        layout(in: rect, gap: gap, frames: &f, dividers: &d)
        return f
    }

    /// The outermost split above this node decides which window edge it belongs to.
    var outermostSide: Side? {
        var n = self
        while let p = n.parent {
            if p.parent == nil {
                let first = p.a === n
                return p.axis == .row ? (first ? .left : .right) : (first ? .top : .bottom)
            }
            n = p
        }
        return nil
    }
}

// MARK: - Panes, tabs, decks

final class Pane {
    let surface: SurfaceView
    let view: PaneView
    var shellTitle: String?

    var title: String {
        if let t = shellTitle, !t.isEmpty { return t }
        if let pwd { return (pwd as NSString).lastPathComponent }
        return "shell"
    }

    init(workingDirectory: String?) {
        surface = SurfaceView(workingDirectory: workingDirectory)
        view = PaneView()
        surface.pane = self
        view.pane = self
        view.addSubview(surface)
    }

    var pwd: String? { surface.pwd }
}

final class Tab {
    var root: Node<Pane>
    /// The pane that had focus last time this tab was active.
    weak var lastFocused: Pane?
    /// A title the user typed; otherwise the focused pane's title is used.
    var customTitle: String?

    init(root: Node<Pane>) {
        self.root = root
    }

    var panes: [Pane] { root.leaves }

    var focusTarget: Pane? {
        if let p = lastFocused, root.node(for: p) != nil { return p }
        return panes.first
    }

    var title: String { customTitle ?? focusTarget?.title ?? "shell" }
}

/// Where a promoted deck came from, so fold can put it back.
enum FoldOrigin {
    /// A pane (or group of panes) promoted out of `tab`. `anchor` is the node it was split against.
    case panes(tab: WeakRef<Tab>, anchor: WeakRef<Node<Pane>>, side: Side, fraction: CGFloat)
    /// A whole tab promoted out of `deck`.
    case tab(deck: WeakRef<Deck>, index: Int)
}

final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

final class Deck {
    var tabs: [Tab] = []
    var activeIndex: Int = 0
    var colorIndex: Int
    var origin: FoldOrigin?
    lazy var view = DeckView(deck: self)

    init(colorIndex: Int) {
        self.colorIndex = colorIndex
    }

    var color: NSColor { Palette.deckColors[colorIndex % Palette.deckColors.count] }

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0 === tab } }
}

enum Palette {
    static let deckColors: [NSColor] = [
        NSColor(srgbRed: 0x7e / 255, green: 0xa6 / 255, blue: 0xf4 / 255, alpha: 1),
        NSColor(srgbRed: 0xe9 / 255, green: 0xa6 / 255, blue: 0x6c / 255, alpha: 1),
        NSColor(srgbRed: 0x8f / 255, green: 0xd1 / 255, blue: 0x9e / 255, alpha: 1),
        NSColor(srgbRed: 0xc7 / 255, green: 0x9c / 255, blue: 0xf2 / 255, alpha: 1),
        NSColor(srgbRed: 0xf2 / 255, green: 0x8f / 255, blue: 0xb0 / 255, alpha: 1),
        NSColor(srgbRed: 0x6f / 255, green: 0xd3 / 255, blue: 0xd6 / 255, alpha: 1),
    ]
    static let window = NSColor(srgbRed: 0x0c / 255, green: 0x0e / 255, blue: 0x12 / 255, alpha: 1)
    static let deck = NSColor(srgbRed: 0x16 / 255, green: 0x19 / 255, blue: 0x20 / 255, alpha: 1)
    static let bar = NSColor(srgbRed: 0x1f / 255, green: 0x23 / 255, blue: 0x2c / 255, alpha: 1)
    static let tabActive = NSColor(srgbRed: 0x2a / 255, green: 0x2f / 255, blue: 0x3a / 255, alpha: 1)
    static let text = NSColor(srgbRed: 0xe7 / 255, green: 0xe9 / 255, blue: 0xee / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 0x8a / 255, green: 0x93 / 255, blue: 0xa0 / 255, alpha: 1)
    static let neutral = NSColor(srgbRed: 0x9a / 255, green: 0xa2 / 255, blue: 0xae / 255, alpha: 1)
}
