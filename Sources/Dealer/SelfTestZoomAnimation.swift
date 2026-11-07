import AppKit

// MARK: - Self-test section: zoom glides like a structural change (#97, LayoutAnimation.swift)

extension TerminalWindowController {
    /// Toggle Zoom in and out, pane level and window level, with the layout motion on: the model and
    /// frames are final at once; the zoomed pane (or its deck) grows from its frame and shrinks back,
    /// raised above its siblings; the siblings it hides leave fading pictures and the ones it reveals
    /// fade in; each terminal is sized once, and a zoomed-away one not at all; a split or `dealer
    /// create --no-focus` still drops the zoom (#57); Reduce Motion and `animate_layout = false` skip
    /// it. Motion is read from the animations (`fromValue`s), and its end is waited for with
    /// `waitUntil`. Self-contained (`DEALER_SELFTEST_ONLY=zoom anim:`), in a workspace of its own.
    func zoomAnimationSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func on() {
            LayoutAnimation.enabled = true
            AttentionFade.reduceMotionOverride = false
        }
        func animation(_ v: NSView, _ key: String) -> CABasicAnimation? {
            v.layer?.animation(forKey: "\(LayoutAnimation.keyPrefix).\(key)") as? CABasicAnimation
        }
        func start(_ v: NSView) -> CGRect? {
            guard let layer = v.layer, let p = animation(v, "position")?.fromValue as? NSValue else { return nil }
            let size = (animation(v, "bounds")?.fromValue as? NSValue)?.sizeValue ?? v.frame.size
            return CGRect(x: p.pointValue.x - layer.anchorPoint.x * size.width, y: p.pointValue.y - layer.anchorPoint.y * size.height,
                          width: size.width, height: size.height)
        }
        func fadesIn(_ v: NSView) -> Bool {
            (animation(v, "opacity")?.fromValue as? NSNumber)?.floatValue == 0
        }
        func moving() -> Bool { LayoutAnimation.isAnimating(in: contentView) }
        func ghosts(in v: NSView) -> [LayoutGhostView] { v.subviews.compactMap { $0 as? LayoutGhostView } }
        func allGhosts(_ v: NSView) -> Int { (v is LayoutGhostView ? 1 : 0) + v.subviews.reduce(0) { $0 + allGhosts($1) } }
        func near(_ a: CGRect?, _ b: CGRect) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        func show(_ r: CGRect?) -> String { r.map { NSStringFromRect($0) } ?? "nil" }
        func raised(_ v: NSView) -> Bool { v.layer?.zPosition ?? 0 > 0 }

        var ws: Workspace?
        func a() -> Pane { t.pane("zmA") }
        func b() -> Pane { t.pane("zmB") }
        func d() -> Pane { t.pane("zmD") }
        func deckA() -> Deck? { locate(a())?.deck }
        func deckD() -> Deck? { locate(d())?.deck }
        /// Every pane of A's tab at its unzoomed frame, and the decks at theirs.
        func unzoomedFrames() -> String? {
            guard let deck = deckA(), let tab = deck.activeTab, let root else { return "test deck is gone" }
            let want = tab.root.frames(in: deck.view.content.bounds, gap: Self.paneGap)
            let decks = root.frames(in: deckArea, gap: Self.deckGap)
            let off = want.filter { $0.0.view.frame != $0.1 || $0.0.view.isHiddenOrHasHiddenAncestor }.map { t.name($0.0) }
                + decks.filter { $0.0.view.frame != $0.1 || $0.0.view.isHidden }.map { "deck of \($0.0.activeTab.flatMap { $0.panes.first }.map(t.name) ?? "?")" }
            return off.isEmpty ? nil : "not at the unzoomed frames at once: " + off.joined(separator: ", ")
        }
        func settled() -> String? {
            all(SelfTest.waitUntil("the zoom motion to end") { !moving() },
                allGhosts(contentView) == 0 ? nil : "\(allGhosts(contentView)) ghost views left behind",
                [a().view, deckA()?.view].compactMap { $0 }.contains(where: raised) ? "the zoomed pane or deck is still raised" : nil,
                a().view.layer?.masksToBounds == true ? "zmA is still clipped" : nil)
        }

        var oldA: CGRect = .zero, oldB: CGRect = .zero, oldDeck: CGRect = .zero
        var pushesA = 0, pushesB = 0, passes = 0
        func notePushes() {
            pushesA = a().surface.sizeChanges
            pushesB = b().surface.sizeChanges
        }
        /// zmA's terminal was resized exactly once since `notePushes`, and zmB's (zoomed away, or
        /// coming back to the size it had) not at all. zmD isn't checked: a deck hidden by a window
        /// zoom takes its strip back from the titlebar (#16), which resizes its terminal by a strip
        /// row with or without the motion.
        func sizedOnce() -> String? {
            all(a().surface.sizeChanges - pushesA == 1 ? nil : "zmA's terminal should be sized once, was \(a().surface.sizeChanges - pushesA) times",
                b().surface.sizeChanges == pushesB ? nil : "zmB's terminal should not be resized")
        }

        t.step("zoom anim: setup: zmA | zmB in one deck, zmD in another", nil, {
            all(deckA() != nil && deckA() !== deckD() ? nil : "expected two decks",
                self.locate(b())?.deck === deckA() ? nil : "zmB should be beside zmA", unzoomedFrames())
        }) {
            LayoutAnimation.enabled = false
            ws = self.newWorkspace(name: "zoom-anim")
            t.named(self.focusedPane, "zmA")
            self.split(t.pane("zmA"), side: .right)
            t.named(self.focusedPane, "zmB")
            guard let deck = self.locate(t.pane("zmA"))?.deck else { return }
            t.named(self.controlNewDeck(beside: deck, side: .right, fraction: 0.4, workingDirectory: nil, command: nil, title: nil, focus: false), "zmD")
            self.focus(t.pane("zmA"))
            self.layoutNow()
        }

        t.step("zoom anim: zooming in grows the pane from its frame; frames final at once; its neighbour fades under it", nil, {
            guard let c = deckA()?.view.content else { return "test deck is gone" }
            let g = ghosts(in: c)
            return all(a().view.frame == c.bounds ? nil : "zmA should fill its deck at once, is \(show(a().view.frame))",
                       b().view.isHidden ? nil : "zmB should be hidden at once",
                       near(start(a().view), oldA) ? nil : "zmA should grow from \(show(oldA)), starts at \(show(start(a().view)))",
                       animation(a().surface, "bounds") == nil && animation(a().surface, "position") == nil
                           ? nil : "the terminal itself must not animate",
                       raised(a().view) ? nil : "zmA should be drawn above its neighbour while it grows",
                       g.count == 1 ? nil : "expected one fading picture of zmB, found \(g.count)",
                       g.first.map { near($0.frame, oldB) && start($0) == nil && $0.fades
                           && (animation($0, "opacity")?.fromValue as? NSNumber)?.floatValue == 1 } == true
                           ? nil : "the picture should stay at zmB's frame \(show(oldB)) and fade out: \(show(g.first?.frame))")
        }) {
            on()
            passes = LayoutAnimation.passes
            oldA = t.pane("zmA").view.frame
            oldB = t.pane("zmB").view.frame
            notePushes()
            self.toggleZoom(nil)
        }
        t.step("zoom anim: the zoom-in settles; the terminal was sized once, the zoomed-away one not at all", nil, {
            all(settled(), LayoutAnimation.passes == passes + 1 ? nil : "expected one animated pass, got \(LayoutAnimation.passes - passes)",
                sizedOnce())
        }) {}

        t.step("zoom anim: zooming again grows the deck to the window; the other deck fades under it", nil, {
            guard let dv = deckA()?.view, let other = deckD()?.view else { return "test decks are gone" }
            let g = ghosts(in: self.contentView)
            return all(dv.frame == self.deckArea ? nil : "the deck should fill the window at once, is \(show(dv.frame))",
                       other.isHidden ? nil : "zmD's deck should be hidden at once",
                       near(start(dv), oldDeck) ? nil : "the deck should grow from \(show(oldDeck)), starts at \(show(start(dv)))",
                       raised(dv) ? nil : "the zoomed deck should be drawn above the others while it grows",
                       !g.isEmpty && g.allSatisfy(\.fades) ? nil : "expected fading pictures of zmD's deck (and strip), found \(g.count)",
                       animation(a().surface, "bounds") == nil ? nil : "the terminal itself must not animate")
        }) {
            oldDeck = deckA()?.view.frame ?? .zero
            notePushes()
            self.toggleZoom(nil)
        }
        t.step("zoom anim: the window zoom settles; only the zoomed terminal was resized, once", nil, { all(settled(), sizedOnce()) }) {}

        t.step("zoom anim: zooming out shrinks it back; everything is final at once and fades in under it", nil, {
            guard let dv = deckA()?.view, let other = deckD()?.view else { return "test decks are gone" }
            return all(unzoomedFrames(),
                       near(start(dv), self.deckArea) ? nil : "the deck should shrink from the whole area, starts at \(show(start(dv)))",
                       start(a().view).map { $0.width > a().view.frame.width } == true ? nil : "zmA should shrink from its deck's width, starts at \(show(start(a().view)))",
                       raised(dv) && raised(a().view) ? nil : "the zoomed deck and pane should stay above what they uncover",
                       fadesIn(b().view) ? nil : "zmB should fade in",
                       fadesIn(other) ? nil : "zmD's deck should fade in",
                       ghosts(in: self.contentView).isEmpty && ghosts(in: dv.content).isEmpty ? nil : "zooming out leaves no pictures",
                       animation(a().surface, "bounds") == nil ? nil : "the terminal itself must not animate")
        }) {
            notePushes()
            self.toggleZoom(nil)
        }
        t.step("zoom anim: the zoom-out settles; only the zoomed terminal was resized, once", nil, {
            all(settled(), sizedOnce(), [b().view, deckD()?.view].compactMap { $0 }.allSatisfy { ($0.layer?.opacity ?? 1) == 1 } ? nil : "a faded-in view isn't opaque")
        }) {}

        t.step("zoom anim: a split in a zoomed tab still drops the zoom and slides the new pane in", nil, {
            let e = t.pane("zmE")
            return all(unzoomedFrames(), e.view.isHiddenOrHasHiddenAncestor ? "zmE is hidden behind the zoom" : nil,
                       e.surface.frame.width > 0 && e.surface.frame.height > 0 ? nil : "zmE's terminal should be sized",
                       start(e.view) != nil ? nil : "zmE should slide in")
        }) {
            LayoutAnimation.enabled = false
            self.toggleZoom(nil)
            on()
            self.split(t.pane("zmA"), side: .bottom)
            t.named(self.focusedPane, "zmE")
        }
        t.step("zoom anim: the split settles", nil, { settled() }) {}

        t.step("zoom anim: create --no-focus in a zoomed tab still unzooms, with the motion on (#57)", nil, {
            let f = t.pane("zmF")
            return all(unzoomedFrames(), f.view.isHiddenOrHasHiddenAncestor ? "zmF is hidden behind the zoom" : nil,
                       f.surface.frame.width > 0 ? nil : "zmF's terminal should be sized",
                       self.focusedPane === a() ? nil : "focus should stay on zmA")
        }) {
            LayoutAnimation.enabled = false
            self.focus(t.pane("zmA"))
            self.toggleZoom(nil)
            on()
            let r = ControlHandler.handle(["cmd": "create", "args": ["target": "pane:\(t.pane("zmA").id)", "side": "right", "focus": false]])
            if let id = (r["result"] as? [String: Any])?["pane"] as? Int, let p = ControlHandler.pane(id: id) { t.named(p, "zmF") }
        }
        t.step("zoom anim: the create settles", nil, { settled() }) {}

        t.step("zoom anim: Reduce Motion skips it", nil, {
            all(moving() ? "nothing should move under Reduce Motion" : nil, unzoomedFrames(),
                LayoutAnimation.passes == passes ? nil : "no animated pass should run")
        }) {
            AttentionFade.reduceMotionOverride = true
            passes = LayoutAnimation.passes
            self.toggleZoom(nil)
            self.toggleZoom(nil)
            self.toggleZoom(nil)
        }
        t.step("zoom anim: [window] animate_layout = false skips it", nil, {
            all(Settings.animateLayout ? "the setting should read false" : nil,
                moving() ? "nothing should move with the setting off" : nil, unzoomedFrames(),
                LayoutAnimation.passes == passes ? nil : "no animated pass should run")
        }) {
            AttentionFade.reduceMotionOverride = false
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[window]\nanimate_layout = false\n".write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
            passes = LayoutAnimation.passes
            self.toggleZoom(nil)
            self.toggleZoom(nil)
            self.toggleZoom(nil)
        }

        t.step("zoom anim: clean up", nil, {
            all(ws.map { w in self.workspaces.contains { $0 === w } } == true ? "the test workspace should be closed" : nil,
                Settings.animateLayout ? nil : "animate_layout should be back to the default (on)")
        }) {
            LayoutAnimation.enabled = false
            AttentionFade.reduceMotionOverride = nil
            try? "".write(to: Settings.fileURL, atomically: true, encoding: .utf8)
            Settings.reload()
            if let ws { self.remove(workspace: ws) }
            self.layoutNow()
        }
    }
}
