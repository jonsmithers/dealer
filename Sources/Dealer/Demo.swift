import AppKit

/// Scripted mouse demos for the README recordings (#26, #28). `DEALER_SELFTEST=1 DEALER_DEMO=<name>`
/// runs one instead of the self-test, with the self-test's isolation (no session, temp settings).
/// Names: `drag`, `tabs`, `workspaces`, `attention`, `goto`. `scripts/record-demo.sh` records them.
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
    static var directory: String { SelfTest.env("DEMO_DIR") ?? "/tmp/demo" }
    /// Demos are recorded with top-edge tab strips in the titlebar row (`[window] tabs_in_titlebar`,
    /// #16), written to the demo's temp settings file. Flip this one switch to record in-deck strips.
    static let tabsInTitlebar = true
    /// A band under the decks that holds the demo's caption (0 outside demos). The titlebar row
    /// holds tabs, so the caption lives at the bottom, clear of every deck and drop target.
    static var captionBand: CGFloat { name == nil ? 0 : 34 }

    /// Pane hooks: where demo shells start and what they read.
    static var workingDirectory: String? { name == nil ? nil : directory }
    static var environment: [String: String] { name == nil ? [:] : ["ZDOTDIR": directory, "HISTFILE": "/dev/null"] }
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
        case press, release
        case wait(TimeInterval)
        case run(() -> Void)
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
    func press() { steps.append(.press) }
    func release() { steps.append(.release) }
    func wait(_ t: TimeInterval) { steps.append(.wait(t)) }
    func run(_ f: @escaping () -> Void) { steps.append(.run(f)) }

    func click(_ p: @escaping () -> CGPoint?) {
        move(to: p)
        wait(0.15)
        press()
        wait(0.08)
        release()
        wait(0.25)
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
                case .press:
                    pressed = true
                    pressPoint = position
                    post(.leftMouseDown)
                    continue
                case .release:
                    pressed = false
                    post(.leftMouseUp)
                    sprite.cursor = .arrow
                    continue
                case .run(let f):
                    f()
                    continue
                case .wait(let t):
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
            if t >= 1 { current = nil }
            break
        }
        if !pressed { updateHover() }
        if pressed, hypot(position.x - pressPoint.x, position.y - pressPoint.y) > 4 { sprite.cursor = .closedHand }
        placeSprite()
    }

    private func event(_ type: NSEvent.EventType) -> NSEvent? {
        guard let window = controller.window else { return nil }
        return NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func post(_ type: NSEvent.EventType) {
        if let e = event(type) { controller.window?.postEvent(e, atStart: false) }
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
        window?.setContentSize(NSSize(width: 1000, height: 600))
        window?.center()
        // Recorded as a screen region (no real cursor, no capture badge), so nothing may cover it.
        window?.level = .floating
        window?.orderFrontRegardless()
        layoutNow()

        let caption = DemoCaptionView()
        contentView.addSubview(caption)
        let mouse = DemoMouse(controller: self, start: contentView.convert(CGPoint(x: 640, y: 420), to: nil))

        // MARK: Script helpers
        func type(_ p: Pane?, _ s: String) {
            // A new shell needs a moment before its prompt is up; typing earlier echoes the text twice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak p] in p?.surface.typeText(s) }
        }
        func named(_ p: Pane?, _ n: String) { p?.customTitle = n }
        /// The Go to Pane picker (#66) and the caffeinate cup (#69), for checking those beats in the log.
        /// The tooltip check looks for AppKit's own tooltip window.
        func extras() -> String {
            let picker = PanePicker.shared
            let shown = picker.isOpen ? picker.entries.prefix(PanePicker.maxRows).map { $0.pane.customTitle ?? $0.pane.title } : []
            let tip = NSApp.windows.contains { $0.isVisible && String(describing: Swift.type(of: $0)).contains("ToolTip") }
            let focused = self.focusedPane?.customTitle ?? "?"
            return "focused=\(focused) picker=\(picker.isOpen ? "open query=\"\(picker.query)\" results=\(shown)" : "closed")"
                + " cup=\(Settings.caffeinate ? (Caffeinate.shared.isHeld ? "held" : "on") : "off")\(self.caffeineIcon.isHidden ? "" : "+shown") tooltip=\(tip)"
        }
        func say(_ text: String) {
            mouse.run { [weak self] in
                guard let self else { return }
                let b = self.contentView.bounds, top = self.deckArea.maxY
                caption.show(text, centredIn: CGRect(x: 0, y: top, width: b.width, height: b.height - top))
                // The tree at each caption (the result of the beat before it), for checking a run in the log.
                // Panes ghostty would confirm closing: idle demo shells need shell integration for 0.
                let busy = self.allDecks.flatMap(\.tabs).flatMap(\.panes).filter { $0.surface.needsConfirmQuit }.count
                let strips = self.titlebarStripDecks.map { $0.tabs.map(\.title).joined(separator: ",") }
                // What spins (the working spinner, #74) and what's marked, so those beats can be checked too.
                let panes = self.workspaces.flatMap { $0.decks.flatMap(\.tabs).flatMap(\.panes) }
                let working = panes.filter(\.isWorking).map { $0.customTitle ?? "?" } + self.workspaces.filter(\.isWorking).map { "ws:" + ($0.name ?? "?") }
                let marked = panes.filter { $0.attention != .none }.map { "\($0.customTitle ?? "?"):\($0.attention)" }
                print("DEMO BEAT \(self.describeWorkspaces { $0.customTitle ?? "?" }) titlebar=\(strips) movable=\(self.window?.isMovable ?? false) busy=\(busy) working=\(working) attention=\(marked) \(extras()) next=\"\(text)\"")
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
        func pane(_ n: String) -> () -> Pane? { { [weak self] in self?.allDecks.flatMap(\.tabs).flatMap(\.panes).first { $0.customTitle == n } } }
        func paneView(_ n: String) -> () -> NSView? { { pane(n)()?.view } }
        func bar(_ n: String) -> () -> NSView? { { pane(n)()?.view.bar } }
        func tab(_ n: String) -> () -> NSView? {
            { [weak self] in
                guard let self else { return nil }
                for deck in self.decks {
                    for (i, t) in deck.tabs.enumerated() where t.panes.contains(where: { $0.customTitle == n }) && t.panes.count == 1 {
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
                    for (i, t) in deck.tabs.enumerated() where t.panes.contains(where: { $0.customTitle == n }) {
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
        func row(_ name: String) -> () -> NSView? {
            { [weak self] in
                guard let self, let i = self.workspaces.firstIndex(where: { $0.name == name }) else { return nil }
                return self.workspaceSidebar.row(at: i)
            }
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

        /// Presses a main-menu shortcut as a key event, through the window and SurfaceView to the
        /// menu, as a person's press would go (works whether or not Dealer is the active app).
        func menuKey(_ key: String, _ mods: NSEvent.ModifierFlags, keyCode: Int, _ label: String) {
            mouse.run { [weak self] in
                guard let self, let surface = self.focusedPane?.surface else { return }
                let ok = self.pressMenuKeyForTest(key, mods, keyCode: keyCode, surface: surface)
                print("DEMO KEY \(label) handled=\(ok) \(extras())"); fflush(stdout)
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

        let first = focusedPane
        switch name {
        case "drag":
            // Start: one deck with three tabs.
            named(first, "server"); type(first, "ls\r")
            addTab("logs", in: focusedDeck, "cat server.log")
            addTab("build", in: focusedDeck, "git --no-pager log --oneline")
            if let d = focusedDeck, let t = d.tabs.first { select(tab: t, in: d) }

            say("Drag a tab to the window edge: it becomes a new deck")
            mouse.drag(from: grip(tab("logs")), to: windowEdge(.right), hold: 0.4)
            say("Drop a tab on a pane's edge: it joins as a split")
            mouse.drag(from: grip(tab("build")), to: at(paneView("logs"), 0.5, 0.88), hold: 0.4)
            say("Drag a pane by its bar to re-split it somewhere else")
            mouse.drag(from: at(bar("build"), 0.3), to: at(paneView("server"), 0.88, 0.55), hold: 0.4)
            say("Drop on a pane's centre to swap the two")
            mouse.drag(from: at(bar("server"), 0.3), to: at(paneView("build"), 0.5, 0.5), hold: 0.4)
            say("Drop a pane on a tab strip: it becomes a tab there")
            mouse.drag(from: at(bar("build"), 0.3), to: stripEnd(of: "logs"), hold: 0.4)
            say("Drop a tab on a pane's edge to split it back in")
            mouse.drag(from: grip(tab("logs")), to: at(paneView("server"), 0.5, 0.9), hold: 0.4)
            say("Hover a pane bar to close it with its ×")
            mouse.move(to: at(bar("logs"), 0.5))
            mouse.wait(0.5)
            mouse.click({ pane("logs")().map { p in p.view.bar.convert(CGPoint(x: p.view.bar.closeButton.frame.midX, y: p.view.bar.closeButton.frame.midY), to: nil) } ?? nil })
            mouse.move(to: at(paneView("server"), 0.5, 0.45))
            say("")
            mouse.wait(0.8)

        case "tabs":
            named(first, "server"); type(first, "ls\r")
            addTab("logs", in: focusedDeck, "cat server.log")
            addTab("tests", in: focusedDeck, "make test")
            if let docs = addTab("docs", in: focusedDeck), let n = locate(docs)?.tab.root {
                _ = promote(n, side: .right, allowWholeDeck: true)
            }
            let deckB = pane("docs")().flatMap { locate($0)?.deck }
            addTab("notes", in: deckB, "cat README.md")
            if let d = deckB, let t = d.tabs.first { select(tab: t, in: d) }
            if let d = pane("server")().flatMap({ locate($0)?.deck }), let t = d.tabs.first { select(tab: t, in: d) }

            say("Drag tabs to reorder them")
            mouse.drag(from: grip(tab("tests")), to: at(tab("server"), 0.3), hold: 0.3)
            say("Hover a tab mid-drag to switch to it, then drop it in that deck")
            mouse.drag(from: grip(tab("logs")), to: at(tab("notes"), 0.6), hold: 1.1)
            say("Drag a tab out to the window edge: a new deck")
            mouse.drag(from: grip(tab("server")), to: windowEdge(.bottom), hold: 0.4)
            say("…and into a pane to fold it back in as a split")
            mouse.drag(from: grip(tab("server")), to: at(paneView("tests"), 0.12, 0.5), hold: 0.4)
            mouse.move(to: at(paneView("docs"), 0.5, 0.5))
            say("")
            mouse.wait(0.8)

        case "workspaces":
            named(first, "server"); type(first, "ls\r")
            addTab("tests", in: focusedDeck, "make test")
            if let d = focusedDeck, let t = d.tabs.first { select(tab: t, in: d) }
            if let ws = workspaces.first { rename(workspace: ws, to: "api") }

            say("Open the workspace sidebar")
            mouse.click(at({ [weak self] in self?.sidebarToggle }))
            say("Add a workspace")
            mouse.click(at({ [weak self] in self?.workspaceSidebar.addRow }))
            mouse.run { [weak self] in
                guard let self else { return }
                self.rename(workspace: self.activeWorkspace, to: "web")
                named(self.focusedPane, "dev"); type(self.focusedPane, "ls src\r")
            }
            mouse.wait(0.8)
            say("Click to switch")
            mouse.click(at(row("api")))
            mouse.wait(0.5)
            say("Drag a tab onto a workspace to move it there")
            mouse.drag(from: grip(tab("tests")), to: at(row("web")), hold: 0.5)
            mouse.click(at(row("web")))
            mouse.wait(0.4)
            mouse.move(to: at(tab("tests")))
            mouse.wait(1.0)
            say("")
            mouse.wait(0.5)

        case "attention":
            if let ws = workspaces.first { rename(workspace: ws, to: "app") }
            named(first, "editor")
            split(first!, side: .right)
            let agent = focusedPane
            named(agent, "agent")
            let build = addTab("build", in: focusedDeck)
            if let d = focusedDeck, let t = d.tabs.first { select(tab: t, in: d) }
            let docs = newWorkspace(name: "docs", activate: false)
            named(docs.panes.first, "notes")
            if let first { focus(first) }

            // The agent reports progress the way Claude Code does (docs/claude-code-states.md):
            // OSC 9;4;3 while a turn runs, which spins its tab and its workspace's entry. When it
            // needs permission the waiting mark outranks the spinner; it then clears its progress.
            say("An agent (right) is working: its tab spins. A build runs in the second tab")
            mouse.run {
                type(agent, "printf '\\e]9;4;3\\a'; sleep 6; dealer notify --state waiting --title Agent --body 'Permission needed'; printf '\\e]9;4;0\\a'\r")
                type(build, "sleep 9; make deploy || dealer notify --state failed --title Build --body 'make deploy failed'\r")
            }
            mouse.move(to: at(paneView("agent"), 0.5, 0.6))
            mouse.wait(1.8)
            say("Switch to another workspace: the agent's spins in the sidebar")
            mouse.click(at(row("docs")))
            mouse.wait(3.6)
            say("It needs you: the spinner gives way to a blue outline")
            mouse.move(to: at(row("app"), 0.85, 0.5), duration: 0.9)
            mouse.wait(0.9)
            say("Then the build fails: red, since a failure outranks waiting")
            mouse.wait(1.4)
            mouse.move(to: at(row("app"), 0.5, 0.5), duration: 0.6)
            mouse.wait(0.8)
            say("Click it: the waiting pane is blue, the failed tab red")
            mouse.click(at(row("app")))
            mouse.wait(1.8)
            say("Clicking into the pane clears it, with a short fade")
            mouse.click(at(paneView("agent"), 0.5, 0.5))
            mouse.wait(1.8)
            say("Go to the failed tab: it fades out too")
            mouse.click(at(tabOf("build"), 0.5, 0.5))
            mouse.wait(2.4)
            say("")
            mouse.wait(0.4)

        case "goto":
            // Go to Pane (⌘⇧A, #66) and the caffeinate cup (#69). Keys go through the window as key
            // events, so the menu-shortcut path runs; each one is captioned (no key overlay).
            Settings.write("power.caffeinate", .bool(true))
            if let ws = workspaces.first { rename(workspace: ws, to: "api") }
            named(first, "server"); type(first, "ls\r")
            addTab("tests", in: focusedDeck, "make test")
            let web = newWorkspace(name: "web")
            named(web.panes.first, "dev"); type(web.panes.first, "ls src\r")
            if let dev = web.panes.first {
                split(dev, side: .right)
                let agent = focusedPane
                named(agent, "agent")
                // Reports progress the way Claude Code does while it works (docs/claude-code-states.md).
                type(agent, "printf '\\e]9;4;3\\a'; sleep 600\r")
            }
            addTab("storybook", in: focusedDeck, "cat README.md")
            let docs = newWorkspace(name: "docs")
            named(docs.panes.first, "notes"); type(docs.panes.first, "git --no-pager log --oneline\r")
            if let api = workspaces.first { activate(api) }
            if let d = focusedDeck, let t = d.tabs.first { select(tab: t, in: d) }
            if let first { focus(first) }

            say("An agent is working in web, so the cup shows: Dealer keeps the display awake")
            mouse.move(to: at({ [weak self] in self?.caffeineIcon }))
            mouse.wait(2.6)
            // AppKit's tooltips follow the window server's cursor, so a demo hover may not raise the
            // cup's tooltip; the log says whether one showed. The caption carries the meaning either way.
            mouse.run { print("DEMO HOVER cup \(extras())"); fflush(stdout) }
            mouse.move(to: at(paneView("server"), 0.6, 0.55))
            mouse.wait(0.3)
            say("⌘⇧A: Go to Pane lists every pane, most recent first")
            mouse.wait(0.6)
            menuKey("a", [.command, .shift], keyCode: 0, "cmd-shift-A")
            mouse.wait(1.6)
            say("Type “sto”: letters in order narrow the list")
            mouse.wait(0.5)
            typeKeys("sto")
            mouse.wait(1.2)
            say("⏎: jump to it, in its workspace")
            mouse.wait(0.6)
            typeKeys("\r")
            mouse.wait(1.6)
            say("⌘⇧A")
            mouse.wait(0.5)
            menuKey("a", [.command, .shift], keyCode: 0, "cmd-shift-A")
            mouse.wait(1.0)
            say("⏎ with no query: back to the previous pane")
            mouse.wait(0.6)
            typeKeys("\r")
            mouse.wait(1.6)
            say("")
            mouse.wait(0.4)

        default:
            say("unknown demo \(name)")
        }

        // Let the shells start (and the recorder attach) before the pointer moves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { mouse.start() }
        Demo.mouse = mouse  // the ticker holds it only weakly
        // The recorder stops when the app exits.
        // The recorder stops on this line, *then* the app exits: a frame recorded after the window
        // closes would show whatever is behind it on the user's screen.
        mouse.onFinish = {
            print("DEMO DONE"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
    }
}
