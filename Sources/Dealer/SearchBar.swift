import AppKit

// MARK: - Find in pane (#49)
//
// Ghostty does the searching: we send `search:<needle>`, `navigate_search:next|previous` and
// `end_search` binding actions, and it reports back with START_SEARCH / END_SEARCH /
// SEARCH_TOTAL / SEARCH_SELECTED (GhosttyRuntime). This is the find bar, a port of the behavior of
// Ghostty's `SurfaceSearchOverlay` (Surface View/SurfaceView.swift at the pin) in AppKit:
// return finds the next match, ⇧return the previous; esc returns to the terminal, or closes the bar
// when the field is empty. The needle is shared through the system find pasteboard, as in Ghostty.

final class PaneSearchBar: NSView, NSTextFieldDelegate {
    /// The pasteboard that carries the needle between find bars. The self-test swaps in a private one.
    static var findPasteboard = NSPasteboard(name: .find)

    weak var surface: SurfaceView?
    let field = NSTextField()
    let countLabel = NSTextField(labelWithString: "")
    private(set) var buttons: [NSButton] = []
    /// Search totals from ghostty; nil while unknown.
    var total: Int? { didSet { updateCount() } }
    var selected: Int? { didSet { updateCount() } }
    /// What we last sent ghostty, for the self-test.
    private(set) var sentNeedle: String?
    private var debounce: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        field.placeholderString = "Search"
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        addSubview(field)
        addSubview(countLabel)
        // Same order and glyphs as Ghostty's bar: chevron.up finds next, chevron.down previous.
        for (symbol, label, action) in [("chevron.up", "Next Match", #selector(next)),
                                        ("chevron.down", "Previous Match", #selector(previous)),
                                        ("xmark", "Close Find Bar", #selector(close))] {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.toolTip = label
            buttons.append(b)
            addSubview(b)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    static let size = NSSize(width: 300, height: 34)

    func applyTheme() {
        layer?.backgroundColor = Theme.chrome.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        layer?.borderWidth = 1
        field.backgroundColor = Theme.surface
        field.textColor = Theme.text
        countLabel.textColor = Theme.text.withAlphaComponent(0.6)
        buttons.forEach { $0.contentTintColor = Theme.text }
    }

    override func layout() {
        super.layout()
        let h = bounds.height, pad: CGFloat = 6, bw: CGFloat = 22
        var x = bounds.width - pad
        for b in buttons.reversed() {
            x -= bw
            b.frame = CGRect(x: x, y: (h - bw) / 2, width: bw, height: bw)
        }
        let fieldFrame = CGRect(x: pad, y: (h - 22) / 2, width: x - 2 * pad, height: 22)
        field.frame = fieldFrame
        countLabel.frame = CGRect(x: fieldFrame.maxX - 54, y: (h - 16) / 2, width: 50, height: 16)
    }

    // MARK: Needle

    var needle: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            needleChanged()
        }
    }

    /// Opens with `needle` when ghostty passes one (search_selection), else the shared find needle.
    func begin(needle given: String?) {
        if let given, !given.isEmpty {
            needle = given
        } else if let shared = Self.findPasteboard.string(forType: .string), shared != field.stringValue {
            field.stringValue = shared
            send(shared)
        } else if sentNeedle == nil {
            send(field.stringValue)
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ obj: Notification) { needleChanged() }

    private func needleChanged() {
        let n = field.stringValue
        Self.findPasteboard.clearContents()
        Self.findPasteboard.setString(n, forType: .string)
        debounce?.cancel()
        // Like Ghostty: short needles wait 300 ms so typing doesn't start expensive searches.
        if n.isEmpty || n.count >= 3 {
            send(n)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.send(n) }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func send(_ n: String) {
        guard n != sentNeedle else { return }
        sentNeedle = n
        surface?.perform("search:\(n)")
    }

    private func updateCount() {
        if let selected { countLabel.stringValue = "\(selected + 1)/\(total.map(String.init) ?? "?")" }
        else if let total { countLabel.stringValue = "-/\(total)" }
        else { countLabel.stringValue = "" }
    }

    // MARK: Commands

    @objc func next() { flushNeedle(); surface?.perform("navigate_search:next") }
    @objc func previous() { flushNeedle(); surface?.perform("navigate_search:previous") }
    /// Ghostty answers end_search with END_SEARCH, which hides the bar (PaneView.endSearch).
    @objc func close() { surface?.perform("end_search") }

    /// A pending short needle goes out before navigating, so return right after typing works.
    private func flushNeedle() {
        guard debounce != nil else { return }
        debounce?.cancel()
        debounce = nil
        send(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { close() } else if let surface { window?.makeFirstResponder(surface) }
            return true
        default:
            return false
        }
    }

    /// Forget what ghostty was told; the next begin resends the needle.
    func reset() {
        debounce?.cancel()
        debounce = nil
        sentNeedle = nil
        total = nil
        selected = nil
    }
}

extension PaneView {
    /// START_SEARCH from ghostty (⌘F, ⌘E or a `start_search` keybind).
    func startSearch(needle: String?) {
        let bar = searchBar ?? {
            let b = PaneSearchBar(frame: .zero)
            b.surface = pane?.surface
            searchBar = b
            return b
        }()
        if bar.superview == nil {
            addSubview(bar, positioned: .below, relativeTo: veilView)
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        bar.begin(needle: needle)
    }

    /// END_SEARCH from ghostty: hide the bar, and give the terminal focus back if the bar had it.
    func endSearch() {
        guard let bar = searchBar, bar.superview != nil else { return }
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: bar) == true
        bar.removeFromSuperview()
        bar.reset()
        if hadFocus, let surface = pane?.surface { window?.makeFirstResponder(surface) }
    }

    var isSearching: Bool { searchBar?.superview != nil }

    func layoutSearchBar(surfaceFrame: CGRect) {
        guard let bar = searchBar, bar.superview != nil else { return }
        let s = PaneSearchBar.size
        let w = min(s.width, surfaceFrame.width - 16)
        bar.frame = CGRect(x: surfaceFrame.maxX - w - 8, y: surfaceFrame.minY + 8, width: max(w, 1), height: s.height)
    }

    // Edit › Find. PaneView is in the responder chain from both the surface and the find bar, so
    // ⌘G works while typing in the bar too.
    @objc func findInPane(_ sender: Any?) { pane?.surface.perform("start_search") }
    @objc func findNext(_ sender: Any?) {
        if let bar = searchBar, isSearching { bar.next() } else { pane?.surface.perform("navigate_search:next") }
    }
    @objc func findPrevious(_ sender: Any?) {
        if let bar = searchBar, isSearching { bar.previous() } else { pane?.surface.perform("navigate_search:previous") }
    }
    @objc func useSelectionForFind(_ sender: Any?) { pane?.surface.perform("search_selection") }
    @objc func hideFindBar(_ sender: Any?) { pane?.surface.perform("end_search") }
}
