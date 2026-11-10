import AppKit

/// Scripted mouse demos for the README recordings (#26, #28). `DEALER_SELFTEST=1 DEALER_DEMO=<name>`
/// runs one instead of the self-test, with the self-test's isolation (no session, temp settings).
/// Names: `tour` (#98) and `drag`. `scripts/record-demo.sh` records them.
///
/// The tour shows the niceties in a realistic flow without naming them (the user's call on #98):
/// captions say what the user is doing, never what feature is on screen.
///
/// Everything on screen is done with a pointer: `DemoMouse` posts real mouse events into the window,
/// so DragController's tracking loop, buttons and rows handle them exactly as they would a person's,
/// and draws a pointer sprite where they land (the real cursor is left out of the recording).
///
/// Every pane gets a neutral shell: `ZDOTDIR=$DEALER_DEMO_DIR` (default /tmp/demo, prepared by the
/// script) so the user's prompt, history and paths never show.
enum Demo {
    static var name: String? { SelfTest.enabled ? SelfTest.env("DEMO") : nil }
    /// The running demo's pointer driver.
    static var mouse: DemoMouse?
    /// A plain window behind the demo's: the capture is the window's bounding rectangle, so its
    /// rounded corners would otherwise show bits of the user's screen.
    static var backdrop: NSWindow?
    static var directory: String { SelfTest.env("DEMO_DIR") ?? "/tmp/demo" }
    /// Demos are recorded with top-edge tab strips in the titlebar row (`[window] tabs_in_titlebar`,
    /// #16), written to the demo's temp settings file. Flip this one switch to record in-deck strips.
    static let tabsInTitlebar = true
    /// Demos show colored workspaces (#79): `[colors] auto_assign = true`, written next to the
    /// above. As in normal use, a window's first workspace stays uncolored and each later one takes
    /// the next unused swatch. Flip this one switch to record without colors.
    static let autoAssignColors = true
    /// Demos are recorded with connected tabs, the app's default (`[tabs] style`, the user's call;
    /// they were pills before), written next to the above. Set it to `.pill` for the old look.
    static let tabStyle = TabStyle.connected
    /// A band under the decks that holds the demo's caption (0 outside demos). The titlebar row
    /// holds tabs, so the caption lives at the bottom, clear of every deck and drop target.
    static var captionBand: CGFloat { name == nil ? 0 : 34 }

    /// Pane hooks: where demo shells start and what they read.
    static var workingDirectory: String? { name == nil ? nil : project("api") }
    /// A project of the demo's (record-demo.sh makes api, web and docs).
    static func project(_ name: String) -> String { directory + "/" + name }
    static var environment: [String: String] {
        guard name != nil else { return [:] }
        return ["ZDOTDIR": directory, "HISTFILE": "/dev/null"]
    }

    /// Tells record-demo.sh's stand-in `claude` in `pane` what to do next (`ask`, `done`, `fail`), so its
    /// turns line up with the script's beats rather than with timers.
    static func signal(_ pane: Pane, _ action: String) {
        let dir = URL(fileURLWithPath: directory).appendingPathComponent(".signal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? action.write(to: dir.appendingPathComponent(String(pane.id)), atomically: true, encoding: .utf8)
    }
}

/// Custom shaders in self-test and demo runs (#77). Those runs load the user's real ghostty config
/// (theme and font are wanted in the recordings), but not its `custom-shader`s: one extra config
/// file, loaded last, empties the repeatable list (`custom-shader =`) and puts
/// `custom-shader-animation` back to its default. That file is also the one seam for a demo
/// shader: if `scripts/demo/shader.glsl` exists in the source tree, demos (not the self-test) use
/// it instead of none. One switch: `ignoresUserShaders`.
enum DemoShader {
    static var ignoresUserShaders: Bool { SelfTest.enabled }
    /// The repo's demo shader, for builds run in place (demos always are); nil when absent.
    static var demoShader: String? {
        guard Demo.name != nil else { return nil }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/demo/shader.glsl")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// The override's text: reset, then the demo shader if there is one.
    static func overrideText(shader: String?) -> String {
        var lines = ["# Written by Dealer for self-test and demo runs (DemoShader, #77).",
                     "custom-shader =", "custom-shader-animation = true"]
        if let shader { lines.append("custom-shader = \(shader)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file `GhosttyRuntime.loadConfig` loads after the user's files, or nil outside these runs.
    static func overrideFile() -> String? {
        guard ignoresUserShaders else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dealer-shader-override-\(getpid()).conf")
        guard (try? overrideText(shader: demoShader).write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }
}

/// A short caption centred in the band under the decks (`Demo.captionBand`), out of the way of
/// the titlebar tabs and every drop target.
final class DemoCaptionView: PassthroughView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12, weight: .medium)
        applyTheme()
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.foreground.withAlphaComponent(0.14).cgColor
        label.textColor = Theme.text
    }

    /// Shows `text` centred in `band` (content view coordinates).
    func show(_ text: String, centredIn band: CGRect) {
        label.stringValue = text
        label.sizeToFit()
        let w = label.frame.width + 24, h: CGFloat = 22
        frame = CGRect(x: (band.midX - w / 2).rounded(), y: (band.midY - h / 2).rounded(), width: w, height: h)
        label.frame = CGRect(x: 12, y: ((h - label.frame.height) / 2).rounded(), width: label.frame.width, height: label.frame.height)
        isHidden = text.isEmpty
    }
}

/// The keys just pressed, as a keycap at the right end of the caption band, like a screencast's
/// keystroke overlay: keyboard beats show what was pressed without a caption naming it.
final class DemoKeycapView: PassthroughView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        applyTheme()
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.foreground.withAlphaComponent(0.3).cgColor
        label.textColor = Theme.text
    }

    /// Shows `keys` at the right of `band` (content view coordinates) for `seconds`.
    func show(_ keys: String, in band: CGRect, for seconds: TimeInterval = 1.1) {
        label.stringValue = keys
        label.sizeToFit()
        let w = max(label.frame.width + 20, 34), h: CGFloat = 26
        frame = CGRect(x: (band.maxX - w - 12).rounded(), y: (band.midY - h / 2).rounded(), width: w, height: h)
        label.frame = CGRect(x: ((w - label.frame.width) / 2).rounded(), y: ((h - label.frame.height) / 2).rounded(),
                             width: label.frame.width, height: label.frame.height)
        isHidden = false
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.generation == g { self?.isHidden = true }
        }
    }
}

/// The pointer drawn into the recording: the system arrow, an open hand over pane bars, and a
/// closed hand while dragging.
final class DemoPointerView: PassthroughView {
    var cursor: NSCursor = .arrow { didSet { if cursor !== oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        cursor.image.draw(in: bounds)
    }

    /// Places the sprite so the cursor's hot spot sits on `p` (in the superview, which is flipped).
    func place(at p: CGPoint) {
        let size = cursor.image.size, hot = cursor.hotSpot
        frame = CGRect(x: p.x - hot.x, y: p.y - hot.y, width: size.width, height: size.height)
    }
}

/// Drives a pointer through a script of moves, presses and releases, posting real NSEvents.
///
/// - Presses, drags and releases go through `window.postEvent`, so the app's own event loop and
///   DragController's modal tracking loop (event-tracking mode) consume them in order. The ticker
///   runs in the common run-loop modes so it keeps going inside that loop.
/// - Hover can't come from posted events: AppKit drives tracking areas from the window server's
///   cursor, not from `mouseMoved` events in the queue. So while the button is up, the driver
///   hit-tests the pointer and sends `mouseEntered`/`mouseExited`/`mouseMoved` to the views under
///   it that own tracking areas, which is what AppKit would do for a real cursor.
final class DemoMouse {
    enum Step {
        case move(() -> CGPoint?, TimeInterval?)
        case press(Int), release
        case key(String, UInt16)
        case wait(TimeInterval)
        case run(() -> Void)
        /// Holds the script until the condition holds (checked every tick), at most the timeout.
        case until(() -> Bool, TimeInterval)
    }

    private unowned let controller: TerminalWindowController
    private let sprite = DemoPointerView()
    private var steps: [Step] = []
    private var timer: Timer?
    /// Pointer in window coordinates.
    private(set) var position: CGPoint
    private var pressed = false
    private var pressPoint: CGPoint = .zero
    private var hovered: [NSView] = []
    private var current: (step: Step, start: Date, from: CGPoint, to: CGPoint?, duration: TimeInterval)?
    var onFinish: (() -> Void)?

    init(controller: TerminalWindowController, start: CGPoint) {
        self.controller = controller
        position = start
    }

    // MARK: Script

    func move(to p: @escaping () -> CGPoint?, duration: TimeInterval? = nil) { steps.append(.move(p, duration)) }
    func press(clickCount: Int = 1) { steps.append(.press(clickCount)) }
    func release() { steps.append(.release) }
    func wait(_ t: TimeInterval) { steps.append(.wait(t)) }
    func run(_ f: @escaping () -> Void) { steps.append(.run(f)) }
    func until(timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) { steps.append(.until(condition, timeout)) }

    func click(_ p: @escaping () -> CGPoint?) {
        move(to: p)
        wait(0.15)
        press()
        wait(0.08)
        release()
        wait(0.25)
    }

    func doubleClick(_ p: @escaping () -> CGPoint?) {
        move(to: p)
        wait(0.15)
        press()
        wait(0.06)
        release()
        wait(0.1)
        press(clickCount: 2)
        wait(0.06)
        release()
        wait(0.3)
    }

    /// Types `text` a key at a time at a readable pace, as real key events (an open sheet, such as
    /// Rename Workspace, takes them before its window).
    func type(_ text: String, interval: TimeInterval = 0.11) {
        for ch in text {
            steps.append(.key(String(ch), 0))
            wait(interval)
        }
    }

    func pressReturn() {
        steps.append(.key("\r", 36))   // kVK_Return
        wait(0.4)
    }

    func drag(from: @escaping () -> CGPoint?, to: @escaping () -> CGPoint?, hold: TimeInterval = 0.25, duration: TimeInterval? = nil) {
        move(to: from)
        wait(0.2)
        press()
        wait(0.15)
        move(to: to, duration: duration)
        wait(hold)
        release()
        wait(0.6)
    }

    // MARK: Running

    func start() {
        guard let content = controller.window?.contentView else { return }
        content.addSubview(sprite)
        placeSprite()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        while true {
            if current == nil {
                guard !steps.isEmpty else {
                    timer?.invalidate()
                    onFinish?()
                    return
                }
                let step = steps.removeFirst()
                switch step {
                case .press(let count):
                    pressed = true
                    pressPoint = position
                    post(.leftMouseDown, clickCount: count)
                    continue
                case .key(let chars, let code):
                    postKey(chars, keyCode: code)
                    continue
                case .release:
                    pressed = false
                    post(.leftMouseUp)
                    sprite.cursor = .arrow
                    continue
                case .run(let f):
                    f()
                    continue
                case .wait(let t), .until(_, let t):
                    current = (step, Date(), position, nil, t)
                case .move(let target, let d):
                    let to = target() ?? position
                    let dist = hypot(to.x - position.x, to.y - position.y)
                    current = (step, Date(), position, to, d ?? min(max(0.35 + dist / 900, 0.4), 1.2))
                }
            }
            guard let c = current else { return }
            let t = min(Date().timeIntervalSince(c.start) / max(c.duration, 0.001), 1)
            if let to = c.to {
                let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease in-out cubic
                position = CGPoint(x: c.from.x + (to.x - c.from.x) * e, y: c.from.y + (to.y - c.from.y) * e)
                if pressed { post(.leftMouseDragged) }
            }
            if case .until(let condition, _) = c.step, condition() {
                current = nil
                continue
            }
            if t >= 1 {
                if case .until = c.step { print("DEMO TIMEOUT waiting for a condition"); fflush(stdout) }
                current = nil
            }
            break
        }
        if !pressed { updateHover() }
        if pressed, hypot(position.x - pressPoint.x, position.y - pressPoint.y) > 4 { sprite.cursor = .closedHand }
        placeSprite()
    }

    private func event(_ type: NSEvent.EventType, clickCount: Int = 1) -> NSEvent? {
        guard let window = controller.window else { return nil }
        return NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func post(_ type: NSEvent.EventType, clickCount: Int = 1) {
        if let e = event(type, clickCount: clickCount) { controller.window?.postEvent(e, atStart: false) }
    }

    /// A key down and up for the window's sheet if one is open, else the window. Sent straight to
    /// that window, key equivalents first, rather than queued: AppKit routes queued key events to
    /// the key window, and the demo app is usually not active (the recorder's terminal is).
    private func postKey(_ chars: String, keyCode: UInt16) {
        guard let window = controller.window else { return }
        let target = window.attachedSheet ?? window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: target.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) {
                // Key equivalents first, as NSApp.sendEvent does. Return is the sheet's default button,
                // but a button only takes its key equivalent in the key window, so press it directly.
                if type == .keyDown, target.performKeyEquivalent(with: e) { continue }
                if type == .keyDown, keyCode == 36, let button = target.defaultButtonCell {
                    button.performClick(nil)
                    continue
                }
                target.sendEvent(e)
            }
        }
    }

    /// Sends enter/exit/moved to the views under the pointer that own tracking areas.
    private func updateHover() {
        guard let window = controller.window, let content = window.contentView, let frame = content.superview else { return }
        var chain: [NSView] = []
        var v = content.hitTest(frame.convert(position, from: nil))
        while let view = v {
            if view !== sprite, !view.trackingAreas.isEmpty { chain.append(view) }
            v = view.superview
        }
        func enterExit(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.enterExitEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        for old in hovered where !chain.contains(where: { $0 === old }) {
            if let e = enterExit(.mouseExited) { old.mouseExited(with: e) }
        }
        for new in chain where !hovered.contains(where: { $0 === new }) {
            if let e = enterExit(.mouseEntered) { new.mouseEntered(with: e) }
        }
        hovered = chain
        if let moved = event(.mouseMoved) {
            for view in chain where view.trackingAreas.contains(where: { $0.options.contains(.mouseMoved) }) { view.mouseMoved(with: moved) }
        }
        sprite.cursor = chain.contains(where: { $0 is PaneBarView }) ? .openHand : .arrow
    }

    private func placeSprite() {
        guard let content = controller.window?.contentView else { return }
        sprite.place(at: content.convert(position, from: nil))
        if content.subviews.last !== sprite { content.addSubview(sprite, positioned: .above, relativeTo: nil) }
    }
}

extension TerminalWindowController {
    func runDemo(_ name: String) {
        // Self-test mode points Settings at a temp config home, so this never touches the user's file.
        if Demo.tabsInTitlebar { Settings.write("window.tabs_in_titlebar", .bool(true)) }
        if Demo.autoAssignColors { Settings.write("colors.auto_assign", .bool(true)) }
        Settings.write("tabs.style", .string(Demo.tabStyle.rawValue))
        window?.setContentSize(NSSize(width: 1000, height: 600))
        window?.center()
        // Recorded as a screen region (no real cursor, no capture badge), so nothing may cover it.
        window?.level = .floating
        window?.orderFrontRegardless()
        if let window {
            let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -24, dy: -24), styleMask: .borderless,
                                    backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            backdrop.backgroundColor = .black
            backdrop.ignoresMouseEvents = true
            backdrop.level = .floating
            backdrop.order(.below, relativeTo: window.windowNumber)
            Demo.backdrop = backdrop
        }
        layoutNow()
        // record-demo.sh crops the capture to this window, found by number (guessing by owner
        // and size once picked an off-screen window and recorded the user's screen instead), and
        // records only once its on-screen bounds have exactly this size (a take read them while
        // they were 2pt wider and showed a sliver of the screen behind).
        let frame = window?.frame ?? .zero
        print("DEMO WINDOW \(window?.windowNumber ?? 0) \(Int(frame.width))x\(Int(frame.height))"); fflush(stdout)

        let caption = DemoCaptionView()
        contentView.addSubview(caption)
        let keycap = DemoKeycapView()
        contentView.addSubview(keycap)
        let mouse = DemoMouse(controller: self, start: contentView.convert(CGPoint(x: 640, y: 420), to: nil))

        // MARK: Script helpers
        /// The script's names for panes, by pane id. The tour leaves titles to the shells and
        /// agents (as in real use), so panes are found by these names, not by `customTitle`.
        final class Names { var ids: [String: Int] = [:] }
        let names = Names()
        func named(_ p: Pane?, _ n: String) {
            guard let p else { return }
            names.ids[n] = p.id
            p.customTitle = n
        }
        /// Registers `p` as `n` without retitling it.
        func call(_ p: Pane?, _ n: String) { if let p { names.ids[n] = p.id } }
        func nameOf(_ p: Pane) -> String { names.ids.first { $0.value == p.id }?.key ?? p.customTitle ?? "?" }
        func type(_ p: Pane?, _ s: String) {
            // A new shell needs a moment before its prompt is up; typing earlier echoes the text twice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak p] in p?.surface.typeText(s) }
        }
        /// The caption band under the decks, in content view coordinates.
        func band() -> CGRect {
            let b = self.contentView.bounds, top = self.deckArea.maxY
            return CGRect(x: 0, y: top, width: b.width, height: b.height - top)
        }
        /// The Go to Pane picker (#66), for checking those beats in the log.
        func extras() -> String {
            let picker = PanePicker.shared
            let shown = picker.isOpen ? picker.entries.prefix(PanePicker.maxRows).map { nameOf($0.pane) } : []
            let focused = self.focusedPane.map(nameOf) ?? "?"
            return "focused=\(focused) picker=\(picker.isOpen ? "open query=\"\(picker.query)\" results=\(shown)" : "closed")"
                + " sidebar=\(self.isSidebarVisible) switcher=\(self.titlebarSwitcherMenu.isOpen ? "open" : self.titlebarSwitcher.isHiddenOrHasHiddenAncestor ? "hidden" : "shown") animating=\(LayoutAnimation.isAnimating(in: self.contentView))"
        }
        func say(_ text: String) {
            mouse.run { [weak self] in
                guard let self else { return }
                caption.show(text, centredIn: band())
                // The tree at each caption (the result of the beat before it), for checking a run in the log.
                // Panes ghostty would confirm closing: idle demo shells need shell integration for 0.
                let busy = self.allDecks.flatMap(\.tabs).flatMap(\.panes).filter { $0.surface.needsConfirmQuit }.count
                let strips = self.titlebarStripDecks.map { $0.tabs.map(\.title).joined(separator: ",") }
                // What's marked, per pane and as the stacks the active workspace's tabs and every
                // sidebar row draw (#95), so those beats can be checked too.
                let panes = self.workspaces.flatMap { $0.decks.flatMap(\.tabs).flatMap(\.panes) }
                let working = panes.compactMap { p in p.workingMark.map { "\(nameOf(p)):\($0)" } }
                let marked = panes.filter { $0.attention != .none }.map { "\(nameOf($0)):\($0.attention)" }
                let tabStacks = self.decks.flatMap(\.tabs).map { t in
                    "\(t.title)[\(t.panes.workingMarks.map { "\($0)" }.joined(separator: " "))|\(t.panes.attentionMarks.map { "\($0.state)" }.joined(separator: " "))]"
                }
                let rowStacks = self.workspaces.map { w in
                    "\(w.name ?? "?")[\(w.panes.workingMarks.map { "\($0)" }.joined(separator: " "))|\(w.panes.attentionMarks.map { "\($0.state)" }.joined(separator: " "))]"
                }
                let status = panes.compactMap { p in p.programStatus.summary.map { "\(nameOf(p)):\($0.state)\($0.progress.map { "@\($0)" } ?? "")" } }
                // Workspace names with their swatch (auto_assign), so the colors can be checked too.
                let swatches = Theme.swatches
                let ws = self.workspaces.map { w in
                    (w.name ?? "?") + ":" + (w.color.flatMap { c in swatches.first { $0.color.sameColor(as: c) }?.name } ?? "none")
                        + (w === self.activeWorkspace ? "*" : "")
                }
                print("DEMO BEAT \(self.describeWorkspaces(name: nameOf)) ws=\(ws) titlebar=\(strips) busy=\(busy) working=\(working) attention=\(marked) status=\(status) tabs=\(tabStacks) rows=\(rowStacks) \(extras()) next=\"\(text)\"")
                fflush(stdout)
            }
        }
        /// A point inside a view, by fraction of its bounds from the top-left, in window coordinates.
        func at(_ view: @escaping () -> NSView?, _ fx: CGFloat = 0.5, _ fy: CGFloat = 0.5) -> () -> CGPoint? {
            {
                guard let v = view(), v.window != nil, !v.isHiddenOrHasHiddenAncestor else { return nil }
                let b = v.bounds
                let y = v.isFlipped ? b.minY + b.height * fy : b.maxY - b.height * fy
                return v.convert(CGPoint(x: b.minX + b.width * fx, y: y), to: nil)
            }
        }
        /// Where to grab a tab to drag it: its bottom half, which in the titlebar is the tab-drag
        /// zone (#27; the top half drags the window), and away from the ×.
        func grip(_ tab: @escaping () -> NSView?) -> () -> CGPoint? { at(tab, 0.45, 0.75) }
        func pane(_ n: String) -> () -> Pane? {
            { [weak self] in
                let all = self?.allDecks.flatMap(\.tabs).flatMap(\.panes) ?? []
                if let id = names.ids[n] { return all.first { $0.id == id } }
                return all.first { $0.customTitle == n }
            }
        }
        func paneView(_ n: String) -> () -> NSView? { { pane(n)()?.view } }
        func bar(_ n: String) -> () -> NSView? { { pane(n)()?.view.bar } }
        func tab(_ n: String) -> () -> NSView? {
            { [weak self] in
                guard let self else { return nil }
                for deck in self.decks {
                    for (i, t) in deck.tabs.enumerated() where t.panes.contains(where: { $0 === pane(n)() }) && t.panes.count == 1 {
                        return deck.view.strip.buttons.indices.contains(i) ? deck.view.strip.buttons[i] : nil
                    }
                }
                return nil
            }
        }
        /// The tab button of the tab holding pane `n`, however many panes it has.
        func tabOf(_ n: String) -> () -> NSView? {
            { [weak self] in
                guard let self else { return nil }
                for deck in self.decks {
                    for (i, t) in deck.tabs.enumerated() where t.panes.contains(where: { $0 === pane(n)() }) {
                        return deck.view.strip.buttons.indices.contains(i) ? deck.view.strip.buttons[i] : nil
                    }
                }
                return nil
            }
        }
        func strip(of n: String) -> () -> TabStripView? { { [weak self] in pane(n)().flatMap { self?.locate($0)?.deck.view.strip } } }
        /// Just past the last tab of the strip holding pane `n`.
        func stripEnd(of n: String) -> () -> CGPoint? {
            {
                guard let s = strip(of: n)(), let last = s.buttons.last else { return nil }
                return s.convert(CGPoint(x: last.frame.maxX + 14, y: last.frame.midY), to: nil)
            }
        }
        func windowEdge(_ side: Side) -> () -> CGPoint? {
            { [weak self] in
                guard let self else { return nil }
                let a = self.deckArea
                let p: CGPoint
                switch side {
                case .right: p = CGPoint(x: a.maxX - 8, y: a.midY)
                case .left: p = CGPoint(x: a.minX + 8, y: a.midY)
                case .bottom: p = CGPoint(x: a.midX, y: a.maxY - 8)
                case .top: p = CGPoint(x: a.midX, y: a.minY + 40)
                }
                return self.contentView.convert(p, to: nil)
            }
        }
        /// The sidebar header of the group named `name` (#80).
        func header(_ name: String) -> () -> NSView? {
            { [weak self] in
                guard let self, let g = self.groups.first(where: { $0.name == name }) else { return nil }
                return self.workspaceSidebar.header(for: g)
            }
        }
        func row(_ name: String) -> () -> NSView? {
            { [weak self] in
                guard let self, let i = self.workspaces.firstIndex(where: { $0.name == name }) else { return nil }
                return self.workspaceSidebar.row(at: i)
            }
        }
        /// A drag whose drop point is resolved before the press. Pressing a tab selects it, which hides
        /// the pane it is to land beside (the drag uncovers it again only once it moves), so a target
        /// resolved after the press would be nil.
        func dragAimed(from: @escaping () -> CGPoint?, to: @escaping () -> CGPoint?, hold: TimeInterval = 0.4) {
            final class Aim { var point: CGPoint? }
            let aim = Aim()
            mouse.move(to: from)
            mouse.run { aim.point = to() }
            mouse.wait(0.2)
            mouse.press()
            mouse.wait(0.15)
            mouse.move(to: { aim.point })
            mouse.wait(hold)
            mouse.release()
            mouse.wait(0.6)
        }
        /// Adds a tab running `command` to `deck`, named `n`.
        @discardableResult
        func addTab(_ n: String, in deck: Deck?, _ command: String? = nil) -> Pane? {
            guard let deck else { return nil }
            newTab(in: deck)
            let p = deck.activeTab?.panes.first
            named(p, n)
            if let command { type(p, command + "\r") }
            return p
        }

        /// Presses a main-menu shortcut: shows `glyphs` (e.g. "⌘D") as a keycap and sends the item's
        /// action from the focused pane up the responder chain, as the menu would for a real press.
        /// Not as a key event: the recorder's terminal is the active app, so Dealer has no key window,
        /// and a posted ⇧⌘D then reached both the menu path and ghostty's own `new_split` keybind,
        /// splitting twice. The self-test covers the key path (`shortcuts:`).
        func menuKey(_ key: String, _ mods: NSEvent.ModifierFlags, _ glyphs: String) {
            mouse.run { [weak self] in
                guard let self, let window = self.window, let surface = self.focusedPane?.surface,
                      let item = Self.keyedMenuItems().first(where: { $0.keyEquivalent.lowercased() == key && Self.effectiveModifiers($0) == mods }),
                      let action = item.action
                else { print("DEMO KEY \(glyphs) missing"); fflush(stdout); return }
                keycap.show(glyphs, in: band())
                window.makeFirstResponder(surface)
                var r: NSResponder? = surface
                while let cur = r, !cur.responds(to: action) {
                    r = cur === window ? (window.delegate as? NSResponder) ?? cur.nextResponder : cur.nextResponder
                }
                let ok = NSApp.sendAction(action, to: r, from: item)
                print("DEMO KEY \(glyphs) handled=\(ok) \(extras())"); fflush(stdout)
            }
        }
        /// Types `chars` as key events to the first responder (the picker's field), at a readable pace.
        func typeKeys(_ chars: String, perSecond: Double = 7) {
            let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                              "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
                                              "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "\r": 36]
            for c in chars {
                mouse.run { [weak self] in
                    guard let self, let window = self.window else { return }
                    if c == "\r" { keycap.show("⏎", in: band()) }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, characters: String(c),
                                                       charactersIgnoringModifiers: String(c), isARepeat: false, keyCode: codes[c] ?? 0) else { continue }
                        window.sendEvent(e)
                    }
                    print("DEMO KEY \(c == "\r" ? "return" : String(c)) \(extras())"); fflush(stdout)
                }
                mouse.wait(1 / perSecond)
            }
        }
        /// Types `text` into pane `n`'s shell a character at a time, as a person would.
        func typeIn(_ n: String, _ text: String, interval: TimeInterval = 0.055) {
            for c in text {
                mouse.run { pane(n)()?.surface.typeText(String(c)) }
                mouse.wait(c == "\r" ? 0.3 : interval)
            }
        }
        /// Tells the stand-in agent in pane `n` what to do next (record-demo.sh's `claude`).
        func signal(_ n: String, _ action: String) {
            mouse.run {
                guard let p = pane(n)() else { print("DEMO MISSING pane \(n)"); fflush(stdout); return }
                Demo.signal(p, action)
            }
        }
        /// Closes pane `n` with its bar's ×: one move straight to where the × is laid out (its frame
        /// is set even while hidden), which shows as the pointer enters the bar (the hover driver
        /// sends `mouseEntered`), then a click.
        func closeByBar(_ n: String) {
            mouse.move(to: {
                guard let b = pane(n)()?.view.bar, b.window != nil, !b.isHiddenOrHasHiddenAncestor else { return nil }
                let f = b.closeButton.frame
                return b.convert(CGPoint(x: f.midX, y: f.midY), to: nil)
            })
            mouse.wait(0.2)
            mouse.press()
            mouse.wait(0.08)
            mouse.release()
            mouse.wait(0.25)
        }
        /// Waits out a layout motion (#94) before the next beat.
        func settle() {
            mouse.wait(0.05)
            mouse.until(timeout: 2) { [weak self] in self.map { !LayoutAnimation.isAnimating(in: $0.contentView) } ?? true }
        }

        let first = focusedPane
        switch name {
        case "tour":
            // One morning with agents (#98): the niceties come up as the work does, and captions
            // only say what the user does. Start: three workspaces, sidebar closed, one shell.
            if let ws = workspaces.first { rename(workspace: ws, to: "api") }
            call(first, "shell"); type(first, "git --no-pager log --oneline\r")
            // No workspace may wear an attention color (red failed, orange that reads as red, blue
            // waiting): a chip or tint matching a dot would muddy the marks. So these take
            // auto_assign's swatches with those skipped (demo only; auto_assign is unchanged).
            var calm = Theme.swatches.filter { !["red", "orange", "blue"].contains($0.name) }.map(\.color).makeIterator()
            for (ws, p, command) in [("web", "web", "ls src"), ("docs", "notes", "ls")] {
                let w = newWorkspace(name: ws, workingDirectory: Demo.project(ws))
                if Demo.autoAssignColors, let c = calm.next() { setColor(c, workspace: w) }
                call(w.panes.first, p); type(w.panes.first, command + "\r")
            }
            if let api = workspaces.first { activate(api) }
            if let first { focus(first) }
            sidebarPreference = false
            layoutNow()
            let shellBody = at(paneView("shell"), 0.6, 0.7)

            // Split/unsplit (#94): real splits through the menu keys, each one's glide waited out.
            say("Put an agent on the flaky test")
            mouse.move(to: shellBody)
            mouse.wait(0.5)
            menuKey("d", [.command], "⌘D")
            mouse.run { [weak self] in call(self?.focusedPane, "login") }
            settle()
            mouse.wait(0.5)
            typeIn("login", "claude \"fix the flaky login test\"\r")
            mouse.wait(1.0)
            say("Another one on pagination")
            menuKey("d", [.command, .shift], "⇧⌘D")
            mouse.run { [weak self] in call(self?.focusedPane, "pagination") }
            settle()
            mouse.wait(0.5)
            typeIn("pagination", "claude \"add pagination to /items\"\r")
            mouse.wait(1.0)
            // Program status (OSC 7501, #89): release.sh reports 0→100 % over about 12 s, then done.
            say("Cut a release from the shell")
            mouse.click(shellBody)
            typeIn("shell", "./release.sh\r")
            mouse.wait(1.6)
            // Stacks (#95): the agents' tab now carries two Claude marks and the release's ring.
            say("Open a tab for the server log")
            mouse.click(at({ [weak self] in self?.focusedDeck?.view.strip.addButton }))
            mouse.run { [weak self] in call(self?.focusedPane, "log") }
            settle()
            mouse.wait(0.4)
            typeIn("log", "cat server.log\r")
            // Near the agents' tab, not on it: hovering a tab swaps its dots for the ×.
            mouse.move(to: at(tabOf("login"), 0.5, 2.2))
            mouse.wait(1.8)
            signal("login", "ask")
            mouse.until(timeout: 5) { pane("login")()?.attention == .waiting }
            mouse.wait(1.8)
            // Workspace switching through the titlebar switcher (#96; the sidebar is closed): the
            // button opens its dropdown on mouseDown, a row picks on mouseUp.
            say("Switch to the web project")
            mouse.click(at({ [weak self] in self?.titlebarSwitcher }))
            mouse.until(timeout: 2) { [weak self] in self?.titlebarSwitcherMenu.isOpen ?? false }
            mouse.wait(0.5)
            mouse.click(at({ [weak self] in
                guard let self, let web = self.workspaces.first(where: { $0.name == "web" }) else { return nil }
                return self.titlebarSwitcherMenu.row(for: web)
            }, 0.4, 0.5))
            mouse.until(timeout: 2) { [weak self] in self?.activeWorkspace.name == "web" }
            mouse.wait(0.6)
            say("Run its tests in a split")
            menuKey("d", [.command], "⌘D")
            mouse.run { [weak self] in call(self?.focusedPane, "tests") }
            settle()
            mouse.wait(0.4)
            typeIn("tests", "make test\r")
            mouse.wait(1.0)
            say("Close it")
            closeByBar("tests")
            settle()
            mouse.wait(0.6)
            // The release has finished by now (done, a dot of its own); the agent still works.
            mouse.until(timeout: 15) { pane("shell")()?.programStatus.summary?.state == .done }
            say("Check on the other projects")
            mouse.click(at({ [weak self] in self?.sidebarToggle }))
            settle()
            mouse.move(to: at(row("api"), 0.6, 0.5))
            mouse.wait(1.8)
            // The pagination agent's turn ends in an API error: failed, beside waiting and done.
            signal("pagination", "fail")
            mouse.until(timeout: 5) { pane("pagination")()?.attention == .failed }
            mouse.wait(1.6)
            // Go to Pane (#66): to the agent that's asking, in its workspace.
            say("Jump to the agent that's asking")
            mouse.move(to: at(paneView("web"), 0.6, 0.6))
            menuKey("a", [.command, .shift], "⇧⌘A")
            mouse.wait(0.8)
            typeKeys("flaky")
            mouse.wait(0.6)
            typeKeys("\r")
            mouse.wait(1.0)
            say("Allow the edit")
            typeIn("login", "y\r")
            mouse.wait(1.4)
            say("Close the release shell")
            closeByBar("shell")
            settle()
            // Off the bar the pointer now rests on (its × and hand would linger): into the agent's
            // terminal, which the hover driver leaves with mouseExited.
            mouse.move(to: at(paneView("login"), 0.6, 0.62))
            mouse.wait(1.0)
            say("")
            mouse.wait(0.8)
        case "drag":
            // "Panes and Decks layout" (#79, the user's order): the README's first demo, so the core
            // ideas come first. Start: one deck, four tabs.
            named(first, "server"); type(first, "ls\r")
            addTab("logs", in: focusedDeck, "cat server.log")
            addTab("tests", in: focusedDeck, "make test")
            addTab("build", in: focusedDeck, "git --no-pager log --oneline")
            addTab("docs", in: focusedDeck, "cat README.md")
            if let d = focusedDeck, let t = d.tabs.first { select(tab: t, in: d) }

            say("One deck, five tabs")
            mouse.move(to: at(paneView("server"), 0.6, 0.5))
            mouse.wait(0.6)
            say("Drop a tab on a pane's side edge: they split side by side")
            dragAimed(from: grip(tab("logs")), to: at(paneView("server"), 0.9, 0.5))
            say("Drop one on a pane's bottom edge: they split stacked")
            dragAimed(from: grip(tab("tests")), to: at(paneView("server"), 0.5, 0.88))
            say("Drag a pane by its bar to the window edge: it becomes a new deck")
            mouse.drag(from: at(bar("logs"), 0.3), to: windowEdge(.right), hold: 0.4)
            say("Switch tabs in the first deck: the new deck stays as it is")
            mouse.click(grip(tab("build")))
            mouse.wait(0.8)
            mouse.click(grip(tab("docs")))
            mouse.wait(0.8)
            mouse.click(grip(tabOf("server")))
            mouse.wait(0.6)
            say("Drag a pane out of a split onto a tab strip: it becomes a tab there")
            mouse.drag(from: at(bar("tests"), 0.3), to: stripEnd(of: "logs"), hold: 0.4)
            // One drag shows both moving a tab across decks and placing it: it lands between the
            // other deck's two tabs, held long enough for the insertion marker to show.
            say("Drag a tab to another deck, in between two of its tabs")
            mouse.drag(from: grip(tab("build")), to: {
                guard let l = tab("logs")(), let t = tab("tests")(), let s = l.superview else { return nil }
                return s.convert(CGPoint(x: (l.frame.maxX + t.frame.minX) / 2, y: l.frame.midY), to: nil)
            }, hold: 0.7)
            mouse.move(to: at(paneView("logs"), 0.5, 0.5))
            say("")
            mouse.wait(0.8)


        default:
            say("unknown demo \(name)")
        }

        // Let the shells start (and the recorder attach) before the pointer moves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { mouse.start() }
        Demo.mouse = mouse  // the ticker holds it only weakly
        // The recorder stops on this line, *then* the app exits: a frame recorded after the window
        // closes would show whatever is behind it on the user's screen.
        mouse.onFinish = {
            print("DEMO DONE"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
    }
}
