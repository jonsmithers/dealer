import AppKit

/// Middle-click close (#37) for pane bars, tabs, rows and pills. Only button 2 counts: mice send
/// back/forward as buttons 3 and 4, and those closed tabs and workspaces (#57). The click needs a
/// press on the view and a release inside it; AppKit sends the release to the view that got the
/// press, wherever the pointer is by then. Other buttons go to `passOn` (the view's `super`).
struct MiddleClick {
    private var pressed = false

    mutating func down(_ event: NSEvent, passOn: () -> Void) {
        if event.buttonNumber == 2 { pressed = true } else { passOn() }
    }

    /// True when this release completes a middle click on `view`.
    mutating func up(_ event: NSEvent, in view: NSView, passOn: () -> Void) -> Bool {
        guard event.buttonNumber == 2 else { passOn(); return false }
        defer { pressed = false }
        return pressed && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
}

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

final class PaneView: FlippedView, ThemeApplying {
    /// The ring's state, including a cleared one fading out (#34, Attention.swift).
    let attentionFade = AttentionFadeState()
    weak var pane: Pane?
    let bar = PaneBarView()
    static var barHeight: CGFloat { Theme.Metrics.paneBarHeight }

    var showsBar = false { didSet { if showsBar != oldValue { needsLayout = true } } }
    var isFocusedPane = false { didSet { if isFocusedPane != oldValue { updateChrome() } } }
    /// Veil unfocused panes, the way Ghostty does (`unfocused-split-opacity`/`-fill`).
    /// The controller turns it on when more than one pane is on screen.
    var dimsWhenUnfocused = false { didSet { if dimsWhenUnfocused != oldValue { updateChrome() } } }
    var accent: NSColor = Theme.accentNeutral { didSet { if accent != oldValue { updateChrome() } } }
    /// Sits above the surface; never takes mouse events.
    private let veil = PassthroughView()
    var veilView: NSView { veil }
    /// The find bar (#49, SearchBar.swift), created on first ⌘F.
    var searchBar: PaneSearchBar?

    override init(frame: NSRect) {
        super.init(frame: frame)
        LiveObjects.add(.paneView)
        addSubview(bar)
        veil.alphaValue = 0
        addSubview(veil)
        applyTheme()
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { LiveObjects.remove(.paneView) }

    func applyTheme() {
        // Translucent (#67): the terminal paints its own background at `background-opacity` (or
        // none, over glass); an opaque one here would show through it.
        layer?.backgroundColor = Theme.transparency.isTranslucent ? nil : Theme.background.cgColor
        veil.layer?.backgroundColor = Theme.unfocusedFill.cgColor
        // The veil's strength comes from the config too (`unfocused-split-opacity`).
        veil.alphaValue = dimsWhenUnfocused && !isFocusedPane ? Theme.unfocusedAlpha : 0
        applyAttentionRing()  // its border color is a Theme color (Attention.swift)
        searchBar?.applyTheme()
    }

    /// Self-test hook (#33): the veil's color and current alpha.
    var veilForTest: NSView { veil }

    private func updateChrome() {
        bar.accent = accent
        bar.isFocusedPane = isFocusedPane
        let target = dimsWhenUnfocused && !isFocusedPane ? Theme.unfocusedAlpha : 0
        if veil.alphaValue != target {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.quick
                veil.animator().alphaValue = target
            }
        }
    }

    func refreshTitle() {
        bar.title = pane?.title ?? ""
        bar.status = pane?.statusLine ?? ""  // AgentStatus.swift
        updateAttentionRing()  // Attention.swift
    }

    override func layout() {
        super.layout()
        bar.isHidden = !showsBar
        var top: CGFloat = 0
        if showsBar {
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
            top = Self.barHeight
        }
        pane?.surface.frame = CGRect(x: 0, y: top, width: max(bounds.width, 1), height: max(bounds.height - top, 1))
        layoutSearchBar(surfaceFrame: pane?.surface.frame ?? bounds)
        veil.frame = bounds
        if subviews.last !== veil { addSubview(veil, positioned: .above, relativeTo: nil) }
        updateChrome()
    }
}

/// A layer-backed view that never takes mouse events: veils, rings, badges.
class PassthroughView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The drag handle on top of every pane in a multi-pane tab.
final class PaneBarView: FlippedView, ThemeApplying {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var accent: NSColor = Theme.accentNeutral { didSet { needsDisplay = true } }
    var isFocusedPane = false { didSet { if isFocusedPane != oldValue { needsDisplay = true } } }
    /// Right-aligned agent state, cwd and branch (AgentStatus.swift).
    var status = "" { didSet { if status != oldValue { needsDisplay = true } } }
    /// Close ×, shown only while the pointer is over the bar (#24). Closing goes through
    /// `close(pane:)`, the same path as ⌘W, busy-process confirmation included.
    let closeButton = PaneCloseButton()
    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            closeButton.isHidden = !hovering
            needsDisplay = true
        }
    }
    /// Where the status line ends: it slides left to make room for the × while hovering.
    var statusTrailing: CGFloat { hovering ? Self.closeSlot + 6 : 10 }
    private static let closeSlot: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        applyTheme()
        closeButton.isHidden = true
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.fill(Theme.paneBar).cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Self-test hook: tracking areas need a real pointer.
    func setHoveringForTest(_ on: Bool) { hovering = on }

    override func layout() {
        super.layout()
        let s = Theme.Metrics.paneBarCloseSize
        closeButton.frame = CGRect(x: bounds.width - Self.closeSlot + (Self.closeSlot - s) / 2 - 2,
                                   y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Grip: two rows of three dots, lit in the deck's accent when focused.
        (isFocusedPane ? accent : Theme.textFaint).setFill()
        let gy = (bounds.height - 6) / 2
        for row in 0..<2 {
            for col in 0..<3 {
                NSBezierPath(ovalIn: CGRect(x: 9 + CGFloat(col) * 3.5, y: gy + CGFloat(row) * 3.5, width: 2, height: 2)).fill()
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let font = Theme.Fonts.paneBar
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isFocusedPane ? Theme.text : Theme.textMuted,
            .paragraphStyle: para,
        ]
        let h = ceil(font.ascender - font.descender)
        let statusWidth = drawStatus(font: font, height: h)
        (title as NSString).draw(in: CGRect(x: 26, y: (bounds.height - h) / 2, width: bounds.width - 34 - max(statusWidth, hovering ? Self.closeSlot : 0), height: h), withAttributes: attrs)
    }

    /// Middle-click closes the pane (#37), like tabs, pills and rows, through `close(pane:)` (⌘W's
    /// path, busy confirmation included). The press is consumed so nothing starts a drag.
    private var middleClick = MiddleClick()
    override func otherMouseDown(with event: NSEvent) {
        middleClick.down(event) { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        guard middleClick.up(event, in: self, passOn: { super.otherMouseUp(with: event) }),
              let pane = (superview as? PaneView)?.pane, let c = controller else { return }
        c.close(pane: pane)
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

/// The × on a pane bar. A subview, so its click never starts the bar's drag.
final class PaneCloseButton: FlippedView {
    private var pressed = false
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Close Pane"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.foreground.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        Theme.drawCross(in: bounds.insetBy(dx: 4.5, dy: 4.5), color: hovering ? Theme.text : Theme.textMuted)
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)),
              let pane = (superview?.superview as? PaneView)?.pane, let c = controller else { return }
        c.close(pane: pane)
    }
}

// MARK: - Deck

/// A deck: a tab strip sitting directly on the window chrome, over a rounded card
/// holding the active tab's panes. Pane gaps show the card's divider color as hairlines.
final class DeckView: FlippedView, ThemeApplying {
    unowned let deck: Deck
    let strip: TabStripView
    let content = FlippedView()
    static var stripHeight: CGFloat { Theme.Metrics.stripHeight }
    /// Chrome around the content card: extra width and height a deck needs beyond its panes.
    static var chromeSize: CGSize { CGSize(width: 0, height: stripHeight) }

    init(deck: Deck) {
        self.deck = deck
        strip = TabStripView(deck: deck)
        super.init(frame: .zero)
        LiveObjects.add(.deckView)
        content.layer?.cornerRadius = Theme.Metrics.deckRadius
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        applyTheme()
        addSubview(strip)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { LiveObjects.remove(.deckView) }

    func applyTheme() {
        // Opaque, the card's background is the pane gaps' color showing between the panes. Translucent
        // (#67), it would sit under every terminal too, so the card is clear and each pane divider
        // paints its own gap (`DividerView.paintsGap`).
        content.layer?.backgroundColor = Theme.transparency.isTranslucent ? nil : Theme.divider.cgColor
        content.layer?.borderColor = Theme.hairline.cgColor
    }

    /// A deck that appears (new tab strip, promote, fold back) fades in rather than popping.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil, window != nil else { return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.standard
            animator().alphaValue = 1
        }
    }

    /// True when the window has several decks and each shows its identity color.
    /// Passed on to the strip, which keeps its own copy: in the titlebar row (#16) the strip's
    /// superview isn't this deck view (#59).
    var showsColor = false { didSet { if showsColor != oldValue { strip.showsDeckColor = showsColor } } }

    /// True while `strip` lives in the window's titlebar row (#16, TitlebarTabs.swift); the content
    /// card then fills the whole deck. Set by the controller, which also reparents the strip.
    var stripInTitlebar = false { didSet { if stripInTitlebar != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        if stripInTitlebar {
            content.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: max(bounds.height, 1))
            return
        }
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.stripHeight)
        content.frame = CGRect(x: 0, y: Self.stripHeight, width: max(bounds.width, 1), height: max(bounds.height - Self.stripHeight, 1))
    }
}

// MARK: - Tab strip

final class TabStripView: FlippedView {
    unowned let deck: Deck
    /// Whether tabs underline in the deck's color (several decks), set by the `DeckView`.
    var showsDeckColor = false { didSet { if showsDeckColor != oldValue { reload() } } }
    private(set) var buttons: [TabButton] = []
    /// The strip's "+" (internal for the demo pointer and tests).
    let addButton = HoverButton()
    /// Insertion marker shown while dragging something over the strip.
    private let marker = CALayer()

    private static let inset: CGFloat = 2
    private static let addWidth: CGFloat = 26

    init(deck: Deck) {
        self.deck = deck
        super.init(frame: .zero)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        addButton.toolTip = "New Tab"
        addButton.target = self
        addButton.action = #selector(addTab)
        addSubview(addButton)
        marker.cornerRadius = 1
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
            b.accent = showsDeckColor ? deck.color : nil
            b.attention = tab.attention
            b.working = tab.workingMark  // AgentStatus.swift
            b.color = tab.color
            b.toolTip = tab.focusTarget?.statusLine  // AgentStatus.swift
        }
        needsLayout = true
    }

    // MARK: Fitted widths (#46)
    //
    // Each tab is as wide as its title plus fixed padding (`TabButton.chromeWidth`), within
    // tabMinWidth…tabMaxWidth. When the fitted tabs don't fit the strip, the
    // widest shrink first: every tab wider than a common level L is cut to L, chosen so the row
    // just fits, so short titles stay whole. Below tabMinWidth the row overflows (clipped), as
    // the old equal-width strip did. Titles are measured in the active (medium) font, so
    // selecting a tab doesn't resize it. No animation: titles change often (shells set them per
    // command), and a width that glides on every prompt would be distracting.

    /// The width a tab wants for `title`, before any shrinking. A tab whose agent is working (#73)
    /// also wants the spinner's slot, so the mark doesn't eat a short title; the strip reflows when
    /// an agent starts or stops, as it does whenever a shell retitles a tab.
    static func naturalWidth(_ title: String, running: Bool = false) -> CGFloat {
        let text = title.isEmpty ? 0 : ceil((title as NSString).size(withAttributes: [.font: Theme.Fonts.tabActive]).width)
        let chrome = TabButton.chromeWidth + (running ? RunningSpinner.slot : 0)
        return min(max(text + chrome, Theme.Metrics.tabMinWidth), Theme.Metrics.tabMaxWidth)
    }

    /// Shrinks the widest of `natural` first until they sum to at most `available`, never below
    /// tabMinWidth. Whole points, so tabs land on pixel boundaries.
    static func fit(_ natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > available else { return natural }
        let minW = Theme.Metrics.tabMinWidth
        // Water level: walk the widths from widest down until the remaining budget fits.
        let sorted = natural.sorted(by: >)
        var level = minW
        var rest = natural.reduce(0, +)  // sum of the tabs narrower than the candidate level
        for (k, w) in sorted.enumerated() {
            rest -= w
            let candidate = (available - rest) / CGFloat(k + 1)
            let next = k + 1 < sorted.count ? sorted[k + 1] : 0
            if candidate >= next { level = candidate; break }
        }
        level = max(floor(level), minW)
        return natural.map { min($0, level) }
    }

    private var fitCache: (titles: [String], running: [Bool], width: CGFloat, widths: [CGFloat])?

    /// Current tab widths, from the model's titles and working states (the buttons may lag a reload
    /// behind).
    var tabWidths: [CGFloat] {
        let titles = deck.tabs.map(\.title), running = deck.tabs.map(\.isWorking)
        if let c = fitCache, c.titles == titles, c.running == running, c.width == bounds.width { return c.widths }
        let n = CGFloat(titles.count)
        let avail = bounds.width - Self.inset * 2 - Self.addWidth - n * Theme.Metrics.tabSpacing
        let widths = Self.fit(zip(titles, running).map { Self.naturalWidth($0, running: $1) }, available: avail)
        fitCache = (titles, running, bounds.width, widths)
        return widths
    }

    private var tabY: CGFloat { (bounds.height - Theme.Metrics.tabHeight) / 2 }

    func tabFrame(_ i: Int) -> CGRect {
        let widths = tabWidths
        let x = Self.inset + widths.prefix(i).reduce(0) { $0 + $1 + Theme.Metrics.tabSpacing }
        return CGRect(x: x, y: tabY, width: i < widths.count ? widths[i] : Theme.Metrics.tabMinWidth,
                      height: Theme.Metrics.tabHeight)
    }

    override func layout() {
        super.layout()
        for (i, b) in buttons.enumerated() { b.frame = tabFrame(i) }
        let end = buttons.isEmpty ? Self.inset : tabFrame(buttons.count - 1).maxX + Theme.Metrics.tabSpacing
        addButton.frame = CGRect(x: end, y: tabY, width: Self.addWidth, height: Theme.Metrics.tabHeight)
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
            let s = Theme.Metrics.tabSpacing
            let x = index < deck.tabs.count ? tabFrame(index).minX - s / 2 - 1
                : (deck.tabs.isEmpty ? Self.inset : tabFrame(deck.tabs.count - 1).maxX + s / 2 - 1)
            marker.frame = CGRect(x: x, y: tabY + 2, width: 2, height: Theme.Metrics.tabHeight - 4)
            marker.backgroundColor = color.cgColor
            marker.isHidden = false
        } else {
            marker.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Borderless icon button with a soft hover fill, matching the tab buttons.
final class HoverButton: NSButton, ThemeApplying {
    private var hovering = false { didSet { updateLook() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Theme.Metrics.tabRadius
        imagePosition = .imageOnly
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    func applyTheme() { updateLook() }

    private func updateLook() {
        contentTintColor = hovering ? Theme.text : Theme.textFaint
        layer?.backgroundColor = (hovering ? Theme.fill(Theme.hover) : .clear).cgColor
    }
}

final class TabButton: FlippedView {
    weak var tab: Tab?
    weak var deck: Deck?
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    /// Deck identity color, or nil in a single-deck window.
    var accent: NSColor? { didSet { if accent != oldValue { needsDisplay = true } } }
    /// The tab's own color (#9): its underline (instead of the deck accent) and a faint tint.
    var color: NSColor? { didSet { if color?.hexString != oldValue?.hexString { needsDisplay = true } } }
    /// Badge for the most urgent pane in this tab (#4); drawn by `drawAttentionDot` in Attention.swift.
    var attention: Attention = .none {
        didSet {
            if attentionFade.onChange == nil { attentionFade.onChange = { [weak self] in self?.needsDisplay = true } }
            attentionFade.set(attention, subject: tab)  // #34: a cleared tab fades out
            if attention != oldValue { needsDisplay = true }
        }
    }
    let attentionFade = AttentionFadeState()
    /// Set while something in this tab is working (#64, #81, RunningSpinner.swift): its working mark in
    /// front of the title, in a slot the strip adds to the tab's width (`TabStripView.naturalWidth`).
    /// A tab already at its maximum, or shrunk to fit, gives the slot from its title instead.
    var working: WorkingMark? {
        didSet {
            if spinner.onChange == nil { spinner.onChange = { [weak self] in self?.needsDisplay = true } }
            spinner.set(working)
        }
    }
    var isRunning: Bool { working != nil }
    let spinner = RunningSpinnerState()
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoveringClose = false { didSet { if hoveringClose != oldValue { needsDisplay = true } } }
    /// The × sits in the trailing slot (`Theme.Metrics.tabTrailingSlot`), 3pt from the edge.
    var closeRect: CGRect { CGRect(x: bounds.width - 19, y: (bounds.height - 16) / 2, width: 16, height: 16) }
    /// Everything but the title (#46): leading pad plus the trailing ×/dot slot.
    static var chromeWidth: CGFloat { Theme.Metrics.tabLeadingPad + Theme.Metrics.tabTrailingSlot }
    /// Where the title is drawn (also read by the self-test). While an agent works, it starts after
    /// the spinner's slot and is that much narrower.
    var titleRect: CGRect {
        let font = Theme.Fonts.tabActive
        let h = ceil(font.ascender - font.descender)
        let lead = Theme.Metrics.tabLeadingPad + spinner.leading
        return CGRect(x: lead, y: (bounds.height - h) / 2,
                      width: max(bounds.width - Self.chromeWidth - spinner.leading, 0), height: h)
    }
    /// The spinner's box, in the leading pad (also read by the self-test).
    var spinnerBox: CGRect { RunningSpinner.box(in: bounds, x: Theme.Metrics.tabLeadingPad) }
    private var showsClose: Bool { hovering }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A press on a tab must reach the tab, also when its strip sits in the titlebar (#27). The
    /// window server drags the window instead wherever the view under the pointer says yes, and
    /// NSView says yes by default for any non-opaque view (Ghostty's NonDraggableHostingView pattern).
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateTitlebarDragZone(event) }
    override func mouseExited(with event: NSEvent) { hovering = false; hoveringClose = false; leaveTitlebarDragZone() }
    /// A hovered tab removed from the window (its tab closed or dragged away, its deck closed) gets
    /// no mouseExited, so it hands back the window drag it may have turned off (#27).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, hovering { hovering = false; hoveringClose = false; leaveTitlebarDragZone() }
    }
    override func mouseMoved(with event: NSEvent) {
        hoveringClose = closeRect.contains(convert(event.locationInWindow, from: nil))
        updateTitlebarDragZone(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = Theme.Metrics.tabRadius
        // Tabs stay fully opaque on a translucent window (#67, the user's call: translucent tabs
        // were hard to tell apart). Inactive tabs then get a solid pill in the strip's own chrome
        // color, so each reads as a shape; opaque windows draw exactly as before (no pill).
        let fill: NSColor? = isActive ? Theme.surface : hovering ? Theme.hover
            : Theme.transparency.isTranslucent ? Theme.chrome : nil
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        // #9: a tab color tints the button and replaces the deck accent in the underline, which
        // then shows on inactive tabs too (fainter), so colored tabs are findable in the strip.
        ColorStyle.drawTint(color, in: r, cornerRadius: radius)
        if let underline = color.map({ isActive ? $0 : $0.withAlphaComponent(0.55) }) ?? (isActive ? accent : nil) {
            underline.setFill()
            NSBezierPath(roundedRect: underlineRect, xRadius: 1, yRadius: 1).fill()
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let font = isActive ? Theme.Fonts.tabActive : Theme.Fonts.tab
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isActive ? Theme.text : (hovering ? Theme.text.mixed(with: Theme.textMuted, 0.4) : Theme.textMuted),
            .paragraphStyle: para,
        ]
        // The trailing slot is always reserved, so the title stays put when the × appears (#46).
        (title as NSString).draw(in: titleRect, withAttributes: attrs)
        if let mark = spinner.mark {
            RunningSpinner.draw(mark, in: spinnerBox, phase: RunningSpinner.phase())
        }

        if showsClose {
            if hoveringClose {
                Theme.foreground.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: closeRect, xRadius: 4, yRadius: 4).fill()
            }
            Theme.drawCross(in: closeRect.insetBy(dx: 4.5, dy: 4.5), color: hoveringClose ? Theme.text : Theme.textMuted)
        }
        drawAttentionDot(hidden: hovering)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tab, let deck, let c = controller else { return }
        if showsClose && closeRect.contains(convert(event.locationInWindow, from: nil)) {
            c.close(tab: tab)
            return
        }
        if event.clickCount == 2 {
            c.renameTab(tab)
            return
        }
        let shown = deck.activeTab
        c.select(tab: tab, in: deck)
        // Top half of a titlebar tab: a drag moves the window, like Ghostty's native tabs (#27).
        if titlebarZone(at: event.locationInWindow) == .window { return dragWindowIfDragged(event) }
        c.drag.begin(.tab(tab), event: event, behind: shown)
    }

    /// Middle-click closes the tab (#37); other extra buttons (back/forward) do nothing (#57).
    private var middleClick = MiddleClick()
    override func otherMouseDown(with event: NSEvent) {
        middleClick.down(event) { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        guard middleClick.up(event, in: self, passOn: { super.otherMouseUp(with: event) }),
              let tab, let c = controller else { return }
        c.close(tab: tab)
    }

    /// Where the underline sits (also sampled by the self-test).
    var underlineRect: CGRect { CGRect(x: 10, y: bounds.height - 2, width: bounds.width - 20, height: 2) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename Tab…") { [weak self, weak tab] in
            if let tab { self?.controller?.renameTab(tab) }
        })
        menu.addItem(ColorMenu.item("Tab Color", current: tab.color) { [weak self, weak tab] c in
            if let tab { self?.controller?.setColor(c, tab: tab) }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self, weak tab] in
            if let tab { self?.controller?.close(tab: tab) }
        })
        return menu
    }
}

// MARK: - Divider

/// Invisible grab handle over the gap between two panes or decks. The gap itself is the
/// visible line; the controller makes this view a little wider than the gap so a 1pt
/// hairline is still easy to grab.
final class DividerView: NSView, ThemeApplying {
    var onDrag: ((CGPoint) -> Void)?
    var axis: Axis = .row { didSet { if axis != oldValue { needsLayout = true } } }
    /// A pane divider paints its gap while the window is translucent (#67), since the deck card
    /// behind the panes is clear then. Deck dividers never do: their gap is the window's chrome.
    var paintsGap = false { didSet { if paintsGap != oldValue { applyTheme() } } }
    private var gapLayer: CALayer?

    func applyTheme() {
        let show = paintsGap && Theme.transparency.isTranslucent
        if show, gapLayer == nil {
            wantsLayer = true
            let l = CALayer()
            l.name = "dealer.gapFill"
            l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
            gapLayer = l
        }
        gapLayer?.isHidden = !show
        gapLayer?.backgroundColor = Theme.fill(Theme.divider).cgColor
        needsLayout = true
    }

    /// The visible gap inside the hit frame (`hitFrame` widened it by `dividerSlop`).
    var gapRect: CGRect {
        let slop = Theme.Metrics.dividerSlop
        return axis == .row ? bounds.insetBy(dx: slop, dy: 0) : bounds.insetBy(dx: 0, dy: slop)
    }

    override func layout() {
        super.layout()
        gapLayer?.frame = gapRect
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Frame for a divider covering `gap`, widened to a comfortable grab size.
    static func hitFrame(for gap: CGRect, axis: Axis) -> CGRect {
        let slop = Theme.Metrics.dividerSlop
        return axis == .row ? gap.insetBy(dx: -slop, dy: 0) : gap.insetBy(dx: 0, dy: -slop)
    }

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
        layer?.cornerRadius = Theme.Metrics.overlayRadius
        layer?.borderWidth = Theme.Metrics.overlayStroke
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Bumped by every show/hide, so a settle's delayed completion can't hide a newer preview.
    private var generation = 0
    /// Where the last `settle` glided to (self-test hook).
    private(set) var settleTarget: CGRect?

    func show(_ rect: CGRect, color: NSColor, fill: CGFloat = 0.16) {
        generation += 1
        alphaValue = isHidden ? alphaValue : 1
        layer?.backgroundColor = color.withAlphaComponent(fill).cgColor
        layer?.borderColor = color.withAlphaComponent(0.9).cgColor
        if isHidden {
            frame = rect
            alphaValue = 0
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.quick
                animator().alphaValue = 1
            }
        } else if frame != rect {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.quick
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().frame = rect
            }
        }
    }

    func hide() {
        generation += 1
        isHidden = true
        alphaValue = 1
    }

    /// After a drop (#28): the preview glides to where the content landed, then fades. Chrome only;
    /// the terminals underneath were laid out once, so no surface is resized per frame.
    func settle(to rect: CGRect) {
        guard !isHidden else { return }
        generation += 1
        let g = generation
        settleTarget = rect
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Motion.standard
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().frame = rect
        }, completionHandler: { [weak self] in
            guard let self, self.generation == g else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.Motion.standard
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == g else { return }
                self.hide()
            })
        })
    }
}

/// The little label that follows the cursor while dragging a pane or tab.
final class GhostView: NSView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.Metrics.overlayRadius
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        label.font = Theme.Fonts.overlay
        label.lineBreakMode = .byTruncatingTail
        applyTheme()
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.foreground.withAlphaComponent(0.16).cgColor
        label.textColor = Theme.text
    }

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
final class WindowContentView: FlippedView, ThemeApplying {
    let dropHighlight = HighlightView()
    let selectionHighlight = HighlightView()
    let ghost = GhostView()
    /// Behind everything (#67): the translucent chrome fill and the glass (WindowTransparency.swift).
    let backdrop = WindowBackdropView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(backdrop)
        applyTheme()
    }

    func applyTheme() {
        // Translucent (#67), the chrome is drawn by `backdrop` instead, around the deck cards.
        layer?.backgroundColor = Theme.transparency.isTranslucent ? nil : Theme.chrome.cgColor
        backdrop.applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        controller?.layoutWindow()
        layoutBackdrop()
    }

    /// Keeps overlays above deck views after the layout pass adds subviews.
    func raiseOverlays() {
        for v in [selectionHighlight, dropHighlight, ghost] where v.superview !== self || subviews.last !== ghost {
            addSubview(v, positioned: .above, relativeTo: nil)
        }
    }
}
