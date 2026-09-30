import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var controller: TerminalWindowController? { window?.windowController as? TerminalWindowController }
}

// MARK: - Pane

final class PaneView: FlippedView {
    weak var pane: Pane?
    let bar = PaneBarView()
    static let barHeight: CGFloat = 22

    var showsBar = false { didSet { if showsBar != oldValue { needsLayout = true } } }
    var isFocusedPane = false { didSet { if isFocusedPane != oldValue { updateChrome() } } }
    var accent: NSColor = Palette.neutral { didSet { if accent != oldValue { updateChrome() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.cgColor
        layer?.borderWidth = 1
        addSubview(bar)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateChrome() {
        let showRing = isFocusedPane && showsBar
        layer?.borderColor = (showRing ? accent.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.06)).cgColor
        bar.accent = accent
        bar.isFocusedPane = isFocusedPane
    }

    func refreshTitle() {
        bar.title = pane?.title ?? ""
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 1
        bar.isHidden = !showsBar
        var top = inset
        if showsBar {
            bar.frame = CGRect(x: inset, y: inset, width: bounds.width - inset * 2, height: Self.barHeight)
            top += Self.barHeight
        }
        pane?.surface.frame = CGRect(x: inset, y: top, width: max(bounds.width - inset * 2, 1), height: max(bounds.height - top - inset, 1))
        updateChrome()
    }
}

/// The drag handle on top of every pane in a multi-pane tab.
final class PaneBarView: FlippedView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var accent: NSColor = Palette.neutral { didSet { needsDisplay = true } }
    var isFocusedPane = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = Palette.bar.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dot = isFocusedPane ? accent : Palette.muted
        dot.setFill()
        for row in 0..<2 {
            for col in 0..<3 {
                NSBezierPath(ovalIn: CGRect(x: 10 + CGFloat(col) * 4, y: 8 + CGFloat(row) * 4, width: 2, height: 2)).fill()
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isFocusedPane ? Palette.text : Palette.muted,
            .paragraphStyle: para,
        ]
        (title as NSString).draw(in: CGRect(x: 28, y: 4, width: bounds.width - 36, height: 15), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard let pane = (superview as? PaneView)?.pane, let c = controller else { return }
        c.focus(pane)
        // ⌥-drag grabs the whole split the pane sits in.
        if event.modifierFlags.contains(.option), let node = c.locate(pane)?.node.parent {
            c.drag.begin(.group(node), event: event)
        } else {
            c.drag.begin(.pane(pane), event: event)
        }
    }
}

// MARK: - Deck

final class DeckView: FlippedView {
    unowned let deck: Deck
    let strip: TabStripView
    let content = FlippedView()
    private let topBorder = CALayer()
    static let stripHeight: CGFloat = 32

    init(deck: Deck) {
        self.deck = deck
        strip = TabStripView(deck: deck)
        super.init(frame: .zero)
        layer?.backgroundColor = Palette.deck.cgColor
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        addSubview(strip)
        addSubview(content)
        layer?.addSublayer(topBorder)
    }

    required init?(coder: NSCoder) { fatalError() }

    var showsColor = false { didSet { updateBorder() } }

    private func updateBorder() {
        topBorder.backgroundColor = (showsColor ? deck.color.withAlphaComponent(0.75) : NSColor.clear).cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topBorder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 2)
        topBorder.zPosition = 10
        CATransaction.commit()
        updateBorder()
        strip.frame = CGRect(x: 0, y: 2, width: bounds.width, height: Self.stripHeight)
        content.frame = CGRect(x: 4, y: Self.stripHeight + 2, width: max(bounds.width - 8, 1), height: max(bounds.height - Self.stripHeight - 6, 1))
    }
}

// MARK: - Tab strip

final class TabStripView: FlippedView {
    unowned let deck: Deck
    private(set) var buttons: [TabButton] = []
    private let addButton = NSButton()
    /// Insertion marker shown while dragging something over the strip.
    private let marker = CALayer()

    init(deck: Deck) {
        self.deck = deck
        super.init(frame: .zero)
        addButton.title = "+"
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 15, weight: .regular)
        addButton.contentTintColor = Palette.muted
        addButton.target = self
        addButton.action = #selector(addTab)
        addSubview(addButton)
        marker.cornerRadius = 1.5
        marker.isHidden = true
        marker.zPosition = 10
        layer?.addSublayer(marker)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func addTab() {
        controller?.newTab(in: deck)
    }

    func reload() {
        while buttons.count < deck.tabs.count {
            let b = TabButton()
            buttons.append(b)
            addSubview(b)
        }
        while buttons.count > deck.tabs.count {
            buttons.removeLast().removeFromSuperview()
        }
        for (i, tab) in deck.tabs.enumerated() {
            let b = buttons[i]
            b.tab = tab
            b.deck = deck
            b.title = tab.title
            b.isActive = i == deck.activeIndex
            b.accent = deck.color
        }
        needsLayout = true
    }

    private var tabWidth: CGFloat {
        let n = CGFloat(max(deck.tabs.count, 1))
        let avail = bounds.width - 12 - 30 - (n - 1) * 4
        return max(40, min(170, avail / n))
    }

    func tabFrame(_ i: Int) -> CGRect {
        CGRect(x: 6 + CGFloat(i) * (tabWidth + 4), y: 4, width: tabWidth, height: 25)
    }

    override func layout() {
        super.layout()
        for (i, b) in buttons.enumerated() { b.frame = tabFrame(i) }
        let end = buttons.isEmpty ? 6 : tabFrame(buttons.count - 1).maxX + 4
        addButton.frame = CGRect(x: end, y: 4, width: 24, height: 25)
    }

    /// Index a dropped tab would take at x (strip coordinates).
    func insertionIndex(atX x: CGFloat) -> Int {
        for i in 0..<deck.tabs.count where x < tabFrame(i).midX { return i }
        return deck.tabs.count
    }

    func tabIndex(at p: CGPoint) -> Int? {
        (0..<deck.tabs.count).first { tabFrame($0).contains(p) }
    }

    func showMarker(at index: Int?, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let index {
            let x = index < deck.tabs.count ? tabFrame(index).minX - 3 : (deck.tabs.isEmpty ? 6 : tabFrame(deck.tabs.count - 1).maxX + 1)
            marker.frame = CGRect(x: x, y: 3, width: 3, height: 27)
            marker.backgroundColor = color.cgColor
            marker.isHidden = false
        } else {
            marker.isHidden = true
        }
        CATransaction.commit()
    }
}

final class TabButton: FlippedView {
    weak var tab: Tab?
    weak var deck: Deck?
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var accent: NSColor = Palette.neutral { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var closeRect: CGRect { CGRect(x: bounds.width - 20, y: (bounds.height - 14) / 2, width: 14, height: 14) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isActive {
            Palette.tabActive.setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            accent.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: CGRect(x: 8, y: bounds.height - 2, width: bounds.width - 16, height: 2), xRadius: 1, yRadius: 1).fill()
        } else if hovering {
            Palette.bar.setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
            .foregroundColor: isActive ? Palette.text : Palette.muted,
            .paragraphStyle: para,
        ]
        (title as NSString).draw(in: CGRect(x: 10, y: 5, width: bounds.width - 32, height: 16), withAttributes: attrs)

        if hovering {
            let c = closeRect.insetBy(dx: 3.5, dy: 3.5)
            let path = NSBezierPath()
            path.move(to: c.origin)
            path.line(to: CGPoint(x: c.maxX, y: c.maxY))
            path.move(to: CGPoint(x: c.minX, y: c.maxY))
            path.line(to: CGPoint(x: c.maxX, y: c.minY))
            path.lineWidth = 1.3
            Palette.muted.setStroke()
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tab, let deck, let c = controller else { return }
        if hovering && closeRect.contains(convert(event.locationInWindow, from: nil)) {
            c.close(tab: tab)
            return
        }
        if event.clickCount == 2 {
            c.renameTab(tab)
            return
        }
        c.select(tab: tab, in: deck)
        c.drag.begin(.tab(tab), event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let tab, let c = controller else { return }
        c.close(tab: tab)
    }
}

// MARK: - Divider

final class DividerView: NSView {
    var onDrag: ((CGPoint) -> Void)?
    var axis: Axis = .row

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .row ? .resizeLeftRight : .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil))
    }
}

// MARK: - Overlays

/// Tinted rectangle showing where a drop will land, or which group is selected.
final class HighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 2
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rect: CGRect, color: NSColor, fill: CGFloat = 0.16) {
        layer?.backgroundColor = color.withAlphaComponent(fill).cgColor
        layer?.borderColor = color.withAlphaComponent(0.85).cgColor
        if isHidden {
            frame = rect
            isHidden = false
        } else if frame != rect {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().frame = rect
            }
        }
    }

    func hide() { isHidden = true }
}

/// The little label that follows the cursor while dragging a pane or tab.
final class GhostView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.tabActive.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, at p: CGPoint) {
        label.stringValue = "⠿  " + text
        label.sizeToFit()
        let w = min(label.frame.width + 20, 240)
        frame = CGRect(x: p.x + 14, y: p.y + 16, width: w, height: 24)
        label.frame = CGRect(x: 10, y: 4, width: w - 20, height: 16)
        isHidden = false
    }
}

/// Root view of a terminal window. Lays decks out according to the window's deck tree.
final class WindowContentView: FlippedView {
    let dropHighlight = HighlightView()
    let selectionHighlight = HighlightView()
    let ghost = GhostView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = Palette.window.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        controller?.layoutWindow()
    }

    /// Keeps overlays above deck views after the layout pass adds subviews.
    func raiseOverlays() {
        for v in [selectionHighlight, dropHighlight, ghost] where v.superview !== self || subviews.last !== ghost {
            addSubview(v, positioned: .above, relativeTo: nil)
        }
    }
}
