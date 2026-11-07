import AppKit

// MARK: - Self-test section: layout motion on structural changes (#94, LayoutAnimation.swift)

extension TerminalWindowController {
    /// The model and frames are final at once and only presentation moves; a new pane, deck and
    /// titlebar strip start collapsed at the far edge; closes leave ghosts that go away; a pane bar
    /// slides in and out while its terminal glides; drops, Reduce Motion and `[window] animate_layout
    /// = false` don't animate; split/close cycles free everything right away with the motion
    /// running (a completion block held closed panes once); translucent windows' card holes follow
    /// the moving cards. Motion is read from the animations themselves (their `fromValue`s), and the
    /// end is waited for with `waitUntil`, never a fixed delay. What it looks like is for eyes only.
    /// Self-contained (`DEALER_SELFTEST_ONLY=layout anim:`).
    func layoutAnimationSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func on() {
            LayoutAnimation.enabled = true
            AttentionFade.reduceMotionOverride = false
        }
        func writeSettings(_ body: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            layoutNow()
        }
        func animation(_ v: NSView, _ key: String) -> CABasicAnimation? {
            v.layer?.animation(forKey: "\(LayoutAnimation.keyPrefix).\(key)") as? CABasicAnimation
        }
        /// Where `v`'s motion starts, from its animations; nil when it isn't moving.
        func start(_ v: NSView) -> CGRect? {
            guard let layer = v.layer, let p = animation(v, "position")?.fromValue as? NSValue else { return nil }
            let size = (animation(v, "bounds")?.fromValue as? NSValue)?.sizeValue ?? v.frame.size
            let pos = p.pointValue
            return CGRect(x: pos.x - layer.anchorPoint.x * size.width, y: pos.y - layer.anchorPoint.y * size.height,
                          width: size.width, height: size.height)
        }
        func moving() -> Bool { LayoutAnimation.isAnimating(in: contentView) }
        func ghosts(in v: NSView) -> [LayoutGhostView] { v.subviews.compactMap { $0 as? LayoutGhostView } }
        func allGhosts(_ v: NSView) -> Int { (v is LayoutGhostView ? 1 : 0) + v.subviews.reduce(0) { $0 + allGhosts($1) } }
        func settled() -> String? {
            all(SelfTest.waitUntil("the layout motion to end") { !moving() },
                allGhosts(contentView) == 0 ? nil : "\(allGhosts(contentView)) ghost views left behind")
        }
        func near(_ a: CGRect?, _ b: CGRect) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        func show(_ r: CGRect?) -> String { r.map { NSStringFromRect($0) } ?? "nil" }

        var tab: Tab?
        func a() -> Pane { t.pane("laA") }
        func content() -> FlippedView? { tab.flatMap { self.deck(of: $0) }?.view.content }
        /// Every pane view of the test tab sits at its final frame.
        func finalFrames() -> String? {
            guard let tab, let c = content() else { return "test tab is gone" }
            let want = tab.root.frames(in: c.bounds, gap: Self.paneGap)
            let off = want.filter { $0.0.view.frame != $0.1 }
            return off.isEmpty ? nil : "not final at once: " + off.map { "\(t.name($0.0)) \(show($0.0.view.frame)) ≠ \(show($0.1))" }.joined(separator: ", ")
        }
        var deckPane: Pane?
        var passes = 0
        var oldB: CGRect = .zero

        t.step("layout anim: a split slides the new pane in from the far edge; frames are final at once", nil, {
            guard let c = content() else { return "test tab is gone" }
            let b = t.pane("laB"), bar = a().view.bar, s = a().surface
            return all(finalFrames(), moving() ? nil : "nothing is moving",
                       near(start(b.view), CGRect(x: c.bounds.maxX, y: 0, width: 0, height: c.bounds.height))
                           ? nil : "laB should start collapsed at the right edge, starts at \(show(start(b.view)))",
                       near(start(a().view), c.bounds) ? nil : "laA should start full width, starts at \(show(start(a().view)))",
                       // The bar comes in from above while the terminal glides down to make room.
                       bar.isHidden ? "laA's bar should show" : nil,
                       near(start(bar), bar.frame.offsetBy(dx: 0, dy: -bar.frame.height)) ? nil : "laA's bar should slide in from above, starts at \(show(start(bar)))",
                       start(s)?.minY == 0 && s.frame.minY == PaneView.barHeight ? nil : "laA's terminal should glide from y 0 to \(PaneView.barHeight), starts at \(show(start(s)))",
                       animation(s, "bounds") == nil ? nil : "a terminal's size must never animate")
        }) {
            on()
            passes = LayoutAnimation.passes
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "laA")
            tab = self.focusedDeck?.activeTab
            self.split(t.pane("laA"), side: .right)
            t.named(self.focusedPane, "laB")
        }
        t.step("layout anim: the motion ends, with nothing left clipped", nil, {
            all(settled(), LayoutAnimation.passes > passes ? nil : "no animated pass ran",
                [a(), t.pane("laB")].contains { $0.view.layer?.masksToBounds == true } ? "a pane is still clipped after the motion" : nil)
        }) {}

        t.step("layout anim: closing a pane leaves a ghost that collapses, and the bar slides out", nil, {
            guard let c = content() else { return "test tab is gone" }
            let g = ghosts(in: c), bar = ghosts(in: a().view)
            return all(finalFrames(), a().view.bar.isHidden ? nil : "laA's bar should be hidden at once",
                       g.count == 1 ? nil : "expected one pane ghost, found \(g.count)",
                       g.first.map { near(start($0), oldB) && near($0.frame, CGRect(x: c.bounds.maxX, y: 0, width: 0, height: c.bounds.height)) } == true
                           ? nil : "the ghost should collapse from laB's frame \(show(oldB)) to the right edge: \(show(g.first.flatMap(start))) → \(show(g.first?.frame))",
                       bar.count == 1 ? nil : "expected a picture of laA's bar sliding out, found \(bar.count)",
                       start(a().surface)?.minY == PaneView.barHeight && a().surface.frame.minY == 0 ? nil : "laA's terminal should glide up to the top")
        }) {
            oldB = t.pane("laB").view.frame
            self.remove(t.pane("laB"))
        }
        t.step("layout anim: the ghosts go away", nil, { settled() }) {}

        t.step("layout anim: a new deck slides in, its titlebar strip with it", nil, {
            guard let p = deckPane, let deck = self.locate(p)?.deck, let root = self.root else { return "no new deck" }
            let dv = deck.view, area = self.deckArea
            let want = root.frames(in: area, gap: Self.deckGap).first { $0.0 === deck }?.1
            return all(dv.frame == want ? nil : "deck not final at once: \(show(dv.frame)) ≠ \(show(want))",
                       near(start(dv), CGRect(x: area.maxX, y: area.minY, width: 0, height: area.height)) ? nil : "the deck should start collapsed at the right edge, starts at \(show(start(dv)))",
                       dv.stripInTitlebar ? nil : "the new deck's strip should be in the titlebar (default settings)",
                       start(dv.strip).map { $0.width == 0 } == true ? nil : "its titlebar strip should start zero wide, starts at \(show(start(dv.strip)))",
                       tab.flatMap { self.deck(of: $0) }.map { start($0.view) != nil } == true ? nil : "the old deck should move over")
        }) {
            guard let tab, let deck = self.deck(of: tab) else { return }
            deckPane = self.controlNewDeck(beside: deck, side: .right, fraction: 0.4, workingDirectory: nil, command: nil, title: nil, focus: true)
        }
        t.step("layout anim: the new deck settles", nil, { settled() }) {}
        t.step("layout anim: closing that deck leaves ghosts of the deck and its titlebar strip", nil, {
            let g = ghosts(in: self.contentView)
            let left = tab.flatMap { self.deck(of: $0) }?.view
            return all(g.count == 2 ? nil : "expected deck and strip ghosts, found \(g.count)",
                       left?.frame == self.deckArea ? nil : "the remaining deck should fill the area at once",
                       left.flatMap(start) == nil ? "the remaining deck should grow into the space" : nil)
        }) {
            if let p = deckPane { self.remove(p) }
            deckPane = nil
        }
        t.step("layout anim: the deck ghosts go away", nil, { settled() }) {}

        t.step("layout anim: a drop doesn't animate the layout (the preview's settle is its motion)", nil, {
            all(t.pane("laA").view.frame.minX > 0 ? nil : "laA and laC should have swapped",
                moving() ? "a drop's layout change must not animate" : nil,
                self.contentView.dropHighlight.isHidden ? "the drop preview should be settling" : nil)
        }) {
            LayoutAnimation.enabled = false
            self.split(t.pane("laA"), side: .right)
            t.named(self.focusedPane, "laC")
            on()
            let bar = t.pane("laA").view.bar
            let from = bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
            self.dragControllerForTest(.pane(t.pane("laA")), from: from, to: t.pane("laC").view)
        }
        t.step("layout anim: the drop preview goes away", nil, {
            SelfTest.waitUntil("the drop preview to fade out") { self.contentView.dropHighlight.isHidden }
        }) {}

        t.step("layout anim: Reduce Motion skips it", nil, {
            all(moving() ? "nothing should move under Reduce Motion" : nil, finalFrames())
        }) {
            AttentionFade.reduceMotionOverride = true
            self.split(t.pane("laA"), side: .bottom)
            if let p = self.focusedPane { self.remove(p) }
        }
        t.step("layout anim: [window] animate_layout = false skips it", nil, {
            all(Settings.animateLayout ? "the setting should read false" : nil,
                moving() ? "nothing should move with the setting off" : nil, finalFrames())
        }) {
            AttentionFade.reduceMotionOverride = false
            writeSettings("[window]\nanimate_layout = false\n")
            self.split(t.pane("laA"), side: .bottom)
            if let p = self.focusedPane { self.remove(p) }
        }

        // The completion block that unclips panes captured them strongly once, keeping closed panes'
        // surfaces and shells alive until the motion ended. Counted right after, motion running.
        var baseline: [LiveObjects.Kind: Int] = [:]
        t.step("layout anim: split/close cycles with the motion running free everything at once", nil, {
            let now = LiveObjects.snapshot
            let moved = LiveObjects.Kind.allCases.filter { now[$0] != baseline[$0] }
            return all(LayoutAnimation.passes >= passes + 9 ? nil : "expected animated passes, got \(LayoutAnimation.passes - passes)",
                       moved.isEmpty ? nil : "left behind: " + moved.map { "\($0.rawValue) \(baseline[$0] ?? 0)→\(now[$0] ?? 0)" }.joined(separator: ", "))
        }) {
            writeSettings("")
            passes = LayoutAnimation.passes
            baseline = LiveObjects.snapshot
            for _ in 0..<3 {
                autoreleasepool {
                    guard let c = tab.map({ $0.root.leaves.first }) ?? nil else { return }
                    self.split(c, side: .right)
                    guard let d = self.focusedPane else { return }
                    self.split(d, side: .bottom)
                    if let e = self.focusedPane { self.remove(e) }
                    self.remove(d)
                    guard let deck = tab.flatMap({ self.deck(of: $0) }) else { return }
                    let p = self.controlNewDeck(beside: deck, side: .right, fraction: 0.4, workingDirectory: nil, command: nil, title: nil, focus: false)
                    self.remove(p)
                }
            }
            self.layoutNow()
        }
        t.step("layout anim: the cycles' motion ends", nil, { settled() }) {}

        // Translucent (#67): the chrome is cut around the deck cards; while decks move, the holes
        // follow the cards on screen, then land on the final frames.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dealer-selftest-layoutanim-\(getpid())", isDirectory: true)
        func finalCards() -> [CGRect] {
            contentView.subviews.compactMap { $0 as? DeckView }.filter { !$0.isHidden }
                .map { $0.content.convert($0.content.bounds, to: contentView.backdrop) }
        }
        var ticks = 0
        t.step("layout anim: translucent: the card holes follow the moving cards", nil, {
            guard Theme.transparency.isTranslucent else { return "the window should be translucent" }
            let following = BackdropFollower.isFollowing(self.contentView)
            let ticked = SelfTest.waitUntil(timeout: 2) { BackdropFollower.ticks > ticks }
            let holes = self.contentView.backdrop.chrome.holes.map(\.card)
            return all(following ? nil : "the holes should follow while decks move",
                       ticked ? nil : "the follower never ticked",
                       holes != finalCards() ? nil : "mid-motion the holes should not be at the final card frames yet")
        }) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("config")
            try? "background = #303446\nforeground = #c6d0f5\nbackground-opacity = 0.85\n".write(to: file, atomically: true, encoding: .utf8)
            GhosttyRuntime.configFileOverride = file.path
            GhosttyRuntime.shared.reloadConfig()
            self.layoutNow()
            ticks = BackdropFollower.ticks
            guard let deck = tab.flatMap({ self.deck(of: $0) }) else { return }
            deckPane = self.controlNewDeck(beside: deck, side: .right, fraction: 0.4, workingDirectory: nil, command: nil, title: nil, focus: true)
        }
        t.step("layout anim: translucent: afterwards the holes are the final card frames", nil, {
            all(settled(), SelfTest.waitUntil("the follower to stop") { !BackdropFollower.isFollowing(self.contentView) },
                self.contentView.backdrop.chrome.holes.map(\.card) == finalCards() ? nil : "holes \(self.contentView.backdrop.chrome.holes.map(\.card)) ≠ cards \(finalCards())")
        }) {}

        t.step("layout anim: clean up", nil, {
            all(tab.flatMap { self.deck(of: $0) } == nil ? nil : "test tab should be closed",
                Settings.animateLayout ? nil : "animate_layout should be back to the default (on)")
        }) {
            LayoutAnimation.enabled = false
            if let p = deckPane, self.locate(p) != nil { self.remove(p) }
            deckPane = nil
            if let tab { self.close(tab: tab) }
            AttentionFade.reduceMotionOverride = nil
            writeSettings("")
            GhosttyRuntime.configFileOverride = nil
            try? fm.removeItem(at: dir)
            GhosttyRuntime.shared.reloadConfig()
            self.layoutNow()
        }
    }
}
