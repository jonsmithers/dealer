import AppKit

// MARK: - Go to Pane (⌘⇧A, #66)
//
// A panel over the window: type part of a pane's title (or its tab's or workspace's name), pick a
// result, and Dealer focuses that pane in whatever window holds it, through `reveal`, the same path
// as Jump to Next Unread. An empty query lists every pane, most recently focused first, with the
// focused pane last, so ⌘⇧A + return goes back to the previous pane. Not modal: esc or a click
// outside dismisses it.

extension TerminalWindowController {
    /// Shell › Go to Pane… (⌘⇧A). Not named after an AppKit selector (Sources/Dealer/CLAUDE.md).
    @objc func openPanePicker(_ sender: Any?) {
        PanePicker.shared.open(in: self)
    }
}

/// One candidate: a pane and where it lives.
struct PanePickerEntry {
    let pane: Pane
    let controller: TerminalWindowController
    let workspace: String
    let tab: String
    /// "Window 2" when there's more than one window, else nil.
    let window: String?

    var location: String { [workspace, tab].joined(separator: " · ") }
    var cwd: String? { pane.pwd.map(Pane.abbreviate) }
}

enum PanePickerMatch {
    /// Case-insensitive subsequence match: every character of `query` appears in `text`, in order.
    static func isSubsequence(_ query: String, of text: String) -> Bool {
        var it = text.lowercased().makeIterator()
        for q in query.lowercased() where !q.isWhitespace {
            var found = false
            while let c = it.next() { if c == q { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// Every pane of every window, ranked for `query`. Empty query: most recently focused first,
    /// `current` last. Otherwise title matches first, then tab or workspace matches; within each,
    /// a contiguous match before a scattered one, then most recently focused.
    static func ranked(_ query: String, current: Pane?) -> [PanePickerEntry] {
        let controllers = AppDelegate.shared.windowControllers
        var entries: [PanePickerEntry] = []
        for (i, wc) in controllers.enumerated() {
            for ws in wc.workspaces {
                for pane in ws.panes {
                    guard let loc = wc.locate(pane) else { continue }
                    entries.append(PanePickerEntry(pane: pane, controller: wc, workspace: ws.displayName, tab: loc.tab.title,
                                                   window: controllers.count > 1 ? "Window \(i + 1)" : nil))
                }
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        func recency(_ e: PanePickerEntry) -> Int { e.pane === current ? -1 : e.pane.focusSequence }
        guard !q.isEmpty else { return entries.sorted { recency($0) > recency($1) } }
        let lower = q.lowercased()
        func score(_ e: PanePickerEntry) -> Int? {
            let title = e.pane.title
            if isSubsequence(q, of: title) { return title.lowercased().contains(lower) ? 0 : 1 }
            let around = e.tab + " " + e.workspace
            if isSubsequence(q, of: around) { return around.lowercased().contains(lower) ? 2 : 3 }
            return nil
        }
        return entries.compactMap { e in score(e).map { (e, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : recency($0.0) > recency($1.0) }
            .map(\.0)
    }
}

final class PanePicker: NSView, NSTextFieldDelegate {
    static let shared = PanePicker(frame: .zero)

    let field = NSTextField()
    private(set) var entries: [PanePickerEntry] = []
    private(set) var selectedIndex = 0
    private var rows: [PanePickerRow] = []
    private weak var controller: TerminalWindowController?
    /// Where focus goes back to on esc.
    private weak var previousResponder: NSResponder?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    static let width: CGFloat = 520
    static let maxRows = 10
    static let fieldHeight: CGFloat = 40
    static let rowHeight: CGFloat = 44

    override var isFlipped: Bool { true }
    var isOpen: Bool { superview != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        field.placeholderString = "Go to pane"
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Open, close, pick

    func open(in wc: TerminalWindowController) {
        if isOpen { close(restoreFocus: false) }
        guard let window = wc.window else { return }
        controller = wc
        previousResponder = window.firstResponder
        applyTheme()
        field.stringValue = ""
        wc.contentView.addSubview(self, positioned: .above, relativeTo: nil)
        update()
        window.makeFirstResponder(field)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, self.isOpen else { return e }
            let inside = e.window === self.window && self.bounds.contains(self.convert(e.locationInWindow, from: nil))
            if !inside { self.close(restoreFocus: false) }
            return e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        }
    }

    /// Dismisses the panel; esc puts focus back where it was.
    func close(restoreFocus: Bool) {
        guard isOpen else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let w = window
        removeFromSuperview()
        // The panel is shared and outlives windows: hold no panes or controllers while closed.
        entries = []
        rows.forEach { $0.entry = nil; $0.removeFromSuperview() }
        controller = nil
        if restoreFocus, let r = previousResponder, let w { w.makeFirstResponder(r) }
        previousResponder = nil
    }

    /// Focuses the chosen pane in its window (raising it), the way ⌘⇧U does.
    func pick(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let e = entries[index]
        close(restoreFocus: false)
        e.controller.reveal(e.pane, cause: "pane-picker")
    }

    // MARK: Query

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; update() }
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(selectedIndex + 1); return true
        case #selector(NSResponder.moveUp(_:)): select(selectedIndex - 1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(selectedIndex); return true
        case #selector(NSResponder.cancelOperation(_:)): close(restoreFocus: true); return true
        default: return false
        }
    }

    func select(_ i: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = min(max(i, 0), min(entries.count, Self.maxRows) - 1)
        for (j, r) in rows.enumerated() { r.isSelected = j == selectedIndex }
    }

    private func update() {
        entries = PanePickerMatch.ranked(field.stringValue, current: controller?.focusedPane)
        let shown = Array(entries.prefix(Self.maxRows))
        while rows.count < shown.count {
            let r = PanePickerRow(frame: .zero)
            r.onClick = { [weak self, weak r] in
                guard let self, let r, let i = self.rows.firstIndex(where: { $0 === r }) else { return }
                self.pick(i)
            }
            rows.append(r)
        }
        for (i, r) in rows.enumerated() {
            if i < shown.count {
                r.entry = shown[i]
                if r.superview == nil { addSubview(r) }
            } else {
                r.spinner.set(nil)
                r.removeFromSuperview()
            }
        }
        selectedIndex = 0
        select(0)
        layoutPanel()
    }

    // MARK: Look

    func applyTheme() {
        layer?.backgroundColor = Theme.chrome.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        field.backgroundColor = Theme.chrome
        field.textColor = Theme.text
        rows.forEach { $0.needsDisplay = true }
    }

    private func layoutPanel() {
        guard let wc = controller else { return }
        let n = min(entries.count, Self.maxRows)
        let h = Self.fieldHeight + CGFloat(n) * Self.rowHeight + (n > 0 ? 8 : 0)
        let area = wc.deckArea
        let w = min(Self.width, max(area.width - 32, 240))
        frame = CGRect(x: area.midX - w / 2, y: area.minY + 12, width: w, height: h).integral
        field.frame = CGRect(x: 14, y: 10, width: w - 28, height: 22)
        for (i, r) in rows.prefix(n).enumerated() {
            r.frame = CGRect(x: 4, y: Self.fieldHeight + CGFloat(i) * Self.rowHeight, width: w - 8, height: Self.rowHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty else { return }
        Theme.hairline.setFill()
        NSRect(x: 0, y: Self.fieldHeight - 1, width: bounds.width, height: 1).fill()
    }
}

/// One result: attention dot or working spinner, title (and window), `workspace · tab`, cwd.
final class PanePickerRow: NSView {
    var entry: PanePickerEntry? {
        didSet {
            spinner.set(entry?.pane.workingMark)
            needsDisplay = true
        }
    }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    let spinner = RunningSpinnerState()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.onChange = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let e = entry else { return }
        if isSelected {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let lead: CGFloat = 12
        let slot = RunningSpinner.slot
        let top = CGRect(x: 0, y: 4, width: bounds.width, height: 20)
        if let mark = spinner.mark {
            RunningSpinner.draw(mark, in: RunningSpinner.box(in: top, x: lead), phase: RunningSpinner.phase())
        } else if e.pane.attention != .none {
            let d: CGFloat = 8
            AttentionStyle.draw(e.pane.attention, in: .zero, cornerRadius: 0,
                                dotRect: CGRect(x: lead + (slot - d) / 2, y: top.midY - d / 2, width: d, height: d))
        }
        let x = lead + slot + 6
        let right = bounds.width - 12
        var titleRight = right
        if let w = e.window {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textFaint]
            let s = NSAttributedString(string: w, attributes: a)
            titleRight = right - s.size().width - 8
            s.draw(at: CGPoint(x: right - s.size().width, y: top.minY + 3))
        }
        draw(e.pane.title, font: .systemFont(ofSize: 13, weight: .medium), color: Theme.text,
             in: CGRect(x: x, y: top.minY, width: titleRight - x, height: 18))
        let second = CGRect(x: x, y: 24, width: right - x, height: 16)
        let small = NSFont.systemFont(ofSize: 11)
        let locWidth = min(NSAttributedString(string: e.location, attributes: [.font: small]).size().width + 1, second.width * 0.55)
        draw(e.location, font: small, color: Theme.textMuted, in: CGRect(x: x, y: second.minY, width: locWidth, height: 16))
        if let cwd = e.cwd {
            let cx = x + locWidth + 12
            draw(cwd, font: small, color: Theme.textFaint, in: CGRect(x: cx, y: second.minY, width: right - cx, height: 16))
        }
    }

    private func draw(_ s: String, font: NSFont, color: NSColor, in rect: CGRect) {
        guard rect.width > 4 else { return }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]).draw(in: rect)
    }
}
