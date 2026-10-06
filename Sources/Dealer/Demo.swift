import AppKit

/// Scripted mouse demos for the README recordings (#26, #28). `DEALER_SELFTEST=1 DEALER_DEMO=<name>`
/// runs one instead of the self-test, with the self-test's isolation (no session, temp settings).
/// Names: `drag`, `tabs`, `workspaces`, `attention`. `scripts/record-demo.sh` records them.
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

    /// Pane hooks: where demo shells start and what they read.
    static var workingDirectory: String? { name == nil ? nil : directory }
    static var environment: [String: String] { name == nil ? [:] : ["ZDOTDIR": directory, "HISTFILE": "/dev/null"] }
}

/// A short caption centred in the titlebar row, out of the way of every drop target.
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

    func show(_ text: String, in parent: NSView, rowHeight: CGFloat) {
        label.stringValue = text
        label.sizeToFit()
        let w = label.frame.width + 24, h: CGFloat = 22
        frame = CGRect(x: ((parent.bounds.width - w) / 2).rounded(), y: ((rowHeight - h) / 2).rounded(), width: w, height: h)
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
        func say(_ text: String) {
            mouse.run { [weak self] in
                guard let self else { return }
                caption.show(text, in: self.contentView, rowHeight: self.deckArea.minY)
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

        let first = focusedPane
        switch name {
        case "drag":
            // Start: one deck with three tabs.
            named(first, "server"); type(first, "ls\r")
            addTab("logs", in: focusedDeck, "cat server.log")
            addTab("build", in: focusedDeck, "git --no-pager log --oneline")
            if let d = focusedDeck, let t = d.tabs.first { select(tab: t, in: d) }

            say("Drag a tab to the window edge: it becomes a new deck")
            mouse.drag(from: at(tab("logs")), to: windowEdge(.right), hold: 0.4)
            say("Drop a tab on a pane's edge: it joins as a split")
            mouse.drag(from: at(tab("build")), to: at(paneView("logs"), 0.5, 0.88), hold: 0.4)
            say("Drag a pane by its bar to re-split it somewhere else")
            mouse.drag(from: at(bar("build"), 0.3), to: at(paneView("server"), 0.88, 0.55), hold: 0.4)
            say("Drop on a pane's centre to swap the two")
            mouse.drag(from: at(bar("server"), 0.3), to: at(paneView("build"), 0.5, 0.5), hold: 0.4)
            say("Drop a pane on a tab strip: it becomes a tab there")
            mouse.drag(from: at(bar("build"), 0.3), to: stripEnd(of: "logs"), hold: 0.4)
            say("Drop a tab on a pane's edge to split it back in")
            mouse.drag(from: at(tab("logs")), to: at(paneView("server"), 0.5, 0.9), hold: 0.4)
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
            mouse.drag(from: at(tab("tests")), to: at(tab("server"), 0.3), hold: 0.3)
            say("Hover a tab mid-drag to switch to it, then drop it in that deck")
            mouse.drag(from: at(tab("logs")), to: at(tab("notes"), 0.6), hold: 1.1)
            say("Drag a tab out to the window edge: a new deck")
            mouse.drag(from: at(tab("server")), to: windowEdge(.bottom), hold: 0.4)
            say("…and into a pane to fold it back in as a split")
            mouse.drag(from: at(tab("server")), to: at(paneView("tests"), 0.12, 0.5), hold: 0.4)
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
            mouse.drag(from: at(tab("tests")), to: at(row("web")), hold: 0.5)
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
            let docs = newWorkspace(name: "docs", activate: false)
            named(docs.panes.first, "notes")
            if let first { focus(first) }

            say("An agent in the right pane is about to ask for permission")
            mouse.move(to: at(paneView("agent"), 0.5, 0.6))
            mouse.run { type(agent, "sleep 3; dealer notify --state waiting --title Agent --body 'Permission needed'\r") }
            mouse.wait(1.4)
            say("Meanwhile, you're in another workspace")
            mouse.click(at(row("docs")))
            mouse.wait(2.0)
            say("Waiting: its workspace gets a blue outline")
            mouse.move(to: at(row("app"), 0.5, 0.5), duration: 1.0)
            mouse.wait(0.6)
            say("Click it to go there: the pane and tab are outlined too")
            mouse.click(at(row("app")))
            mouse.wait(1.4)
            say("Clicking into the pane clears it")
            mouse.click(at(paneView("agent"), 0.5, 0.5))
            mouse.run { type(agent, "sleep 2; dealer notify --state done --title Agent --body Finished\r") }
            mouse.wait(0.4)
            mouse.click(at(paneView("editor"), 0.5, 0.5))
            mouse.wait(1.8)
            say("Done: a quiet dot")
            mouse.move(to: at(tab("editor"), 0.5, 0.5), duration: 0.9)
            mouse.wait(1.4)
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
