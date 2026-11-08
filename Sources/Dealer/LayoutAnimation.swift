import AppKit

// Layout motion (#94): when a structural change re-lays out the window (a split created, a pane or
// deck closed, a promote, a fold, a move), the chrome glides from where it was to where it now is.
//
// - The model and every view frame are final at once: `finishChange` runs the normal layout pass.
//   Only Core Animation *presentation* moves. Each chrome view whose frame changed gets explicit
//   `position`/`bounds.size` animations from its old frame to its new one, so self-test frame checks
//   and `PixelProbe` (which renders the model layer tree) see the final state immediately.
// - Terminals are never animated. A `SurfaceView` gets its final size once, from the normal pass,
//   so libghostty gets one `ghostty_surface_set_size` and the program reflows once, at the start of
//   the motion (the user's call). While the motion runs a growing pane clips its already-larger
//   surface (`masksToBounds` on the PaneView) and a shrinking one shows its background past it.
//   When a pane's bar appears or goes, the surface's *position* glides (a layer move, no redraw).
// - A new pane or deck slides in from the far edge of its split: its start frames (and its new
//   divider's) are the same tree laid out with the new split's ratio pushed to 0 or 1
//   (`collapsedLayout`). A closed pane or deck leaves a ghost (`LayoutGhost`: its terminals' last
//   IOSurface frames and images of its bars and strip) that collapses the same way.
// - Old frames are read from the presentation layer while a motion is in flight, so quick
//   successive changes chain instead of jumping. A view that changed superview (a pane moved to
//   another deck, a strip moving into the titlebar) glides from where it was on screen.
// - Translucent windows (#67): the chrome fill's card holes follow the moving cards while decks
//   move (`BackdropFollower`); otherwise they'd be cut at the final frames for the whole motion.
// - Zoom (#97) is the same pass: the zoomed pane (and, for a window-level zoom, its deck) grows to
//   fill or shrinks back like any moved view, raised above its siblings (`zPosition`) while it
//   moves. Zooming in, the panes or decks it hides leave fading pictures under it
//   (`LayoutGhost.fades`); zooming out, the ones it reveals fade in at their final frames under it
//   (`Pass.fadesRevealed`).
//
// - Tab widths (#103): when a strip re-lays out with the same tabs at the same width but its tabs
//   want new widths (a retitle, focus moving within a tab, a mark stack), the buttons glide to them
//   (`TabWidthGlide`). Unlike the pass above this sets real intermediate frames each display frame:
//   a tab button is a small drawn view (no terminal), and its title must truncate at the width it
//   has on screen, which a stretched or pinned layer picture can't do.
//
// Which changes animate is one list, `LayoutChange.animates`. Off with `[window] animate_layout =
// false`, under Reduce Motion, during a live resize, and in self-test mode unless a step turns
// `LayoutAnimation.enabled` on (README demos animate, as they should look like the app).

/// The structural changes that re-lay out a window, one per path into `finishChange`.
enum LayoutChange: String, CaseIterable {
    /// ⌘D / ⌘⇧D, ghostty's `new_split`.
    case split
    /// ⌘T.
    case newTab
    /// `dealer create pane|tab|deck`.
    case cliCreate
    /// ⌘W on a pane, the pane bar's ×, a shell that exits, `dealer close` of a pane.
    case closePane
    /// A tab closed (⌘⇧W, the tab's ×, `dealer close tab:N`).
    case closeTab
    /// A workspace closed.
    case closeWorkspace
    /// A `dealer run` job pane closing after its linger.
    case jobClose
    /// Pane → deck (menu Promote).
    case promote
    /// Deck → pane (menu Fold).
    case fold
    /// Two panes trading places.
    case swap
    /// A pane or group re-split beside another pane.
    case movePane
    /// Menu Move to New Tab.
    case moveToNewTab
    /// A tab reordered or moved to another deck's strip.
    case moveTab
    /// A tab rejoining as a split.
    case mergeTab
    /// Menu or CLI moves into another workspace.
    case moveToWorkspace
    /// Anything done by a drag-and-drop. The drop preview already settles onto the result (#28).
    case drop
    /// Toggle Zoom (⌘⇧↩, ghostty's `toggle_split_zoom`), in or out, pane or window level (#97).
    case zoom
    /// Not a structural change and not a path into `finishChange` (#103): a strip re-laid out with
    /// the same tabs at the same width, whose tabs want new widths (a retitle, focus moving within
    /// a tab, a mark stack growing or shrinking). `TabWidthGlide` moves the tab buttons.
    case tabWidth

    /// Whether this change animates the layout. The user's call per path (#94).
    var animates: Bool {
        switch self {
        case .drop: return false  // no double motion with the settle glide
        case .split, .newTab, .cliCreate, .closePane, .closeTab, .closeWorkspace, .jobClose,
             .promote, .fold, .swap, .movePane, .moveToNewTab, .moveTab, .mergeTab, .moveToWorkspace, .zoom,
             .tabWidth:
            return true
        }
    }
}

enum LayoutAnimation {
    /// Off in self-test mode so existing checks never see motion; SelfTestLayoutAnimation turns it
    /// on. On for README demos (`DEALER_DEMO`), which should look like the app.
    static var enabled = !SelfTest.enabled || Demo.name != nil
    static var duration: TimeInterval { Theme.Motion.standard }
    static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)  // ease-out
    static let keyPrefix = "dealer.layout"
    /// Self-test hook: animated passes run so far.
    private(set) static var passes = 0

    static func allowed(_ change: LayoutChange, in window: NSWindow?) -> Bool {
        guard enabled, change.animates, Settings.animateLayout, !AttentionFade.reduceMotion, let window else { return false }
        return window.isVisible && !window.inLiveResize
    }

    // MARK: Snapshot of frames before the pass

    struct Snapshot {
        struct Entry {
            weak var superview: NSView?
            /// In the superview's coordinates, as presented.
            let frame: CGRect
            /// In the content view's coordinates, as presented (for views that change superview).
            let onScreen: CGRect
            let hidden: Bool
        }
        var entries: [ObjectIdentifier: Entry] = [:]
        weak var contentView: NSView?

        init(_ contentView: NSView) {
            self.contentView = contentView
            for v in contentView.subviews where Self.isChrome(v) { record(v, in: contentView) }
        }

        static func isChrome(_ v: NSView) -> Bool { v is DeckView || v is TabStripView || v is DividerView }

        private mutating func record(_ v: NSView, in contentView: NSView) {
            entries[ObjectIdentifier(v)] = Entry(superview: v.superview, frame: LayoutAnimation.presentedFrame(v),
                                                 onScreen: LayoutAnimation.presentedRect(v, in: contentView),
                                                 hidden: v.isHiddenOrHasHiddenAncestor)
            if v is SurfaceView { return }  // its own frame only; never inside a terminal
            for s in v.subviews { record(s, in: contentView) }
        }

        /// A view's old frame by identity, whatever its superview (pooled dividers).
        func frame(of id: ObjectIdentifier) -> CGRect? {
            guard let e = entries[id], !e.hidden else { return nil }
            return e.frame
        }

        /// Created since the snapshot (not merely hidden then, like a background tab or parked deck).
        func isNew(_ v: NSView) -> Bool { entries[ObjectIdentifier(v)] == nil }

        func wasVisible(_ v: NSView) -> Bool {
            guard let e = entries[ObjectIdentifier(v)] else { return false }
            return !e.hidden
        }

        /// Where `v` was, in its current superview's coordinates. A view that moved to another
        /// superview is placed where it was on screen (converted through the final frames).
        func oldFrame(_ v: NSView) -> CGRect? {
            guard let e = entries[ObjectIdentifier(v)], !e.hidden else { return nil }
            if e.superview === v.superview { return e.frame }
            guard let sv = v.superview, let cv = contentView else { return nil }
            return cv.convert(e.onScreen, to: sv)
        }
    }

    /// The frame on screen right now, mid-motion included (view frames are already final).
    static func presentedFrame(_ v: NSView) -> CGRect {
        guard let layer = v.layer, layer.animationKeys()?.contains(where: { $0.hasPrefix(keyPrefix) }) == true,
              let p = layer.presentation() else { return v.frame }
        let size = p.bounds.size
        return CGRect(x: p.position.x - layer.anchorPoint.x * size.width,
                      y: p.position.y - layer.anchorPoint.y * size.height,
                      width: size.width, height: size.height)
    }

    /// `v`'s presented frame in `ancestor`'s coordinates. Every view on the way is flipped with a
    /// zero bounds origin (FlippedView), so adding presented origins is the conversion.
    static func presentedRect(_ v: NSView, in ancestor: NSView) -> CGRect {
        var r = presentedFrame(v)
        var s = v.superview
        while let sv = s, sv !== ancestor {
            let f = presentedFrame(sv)
            r.origin.x += f.minX
            r.origin.y += f.minY
            s = sv.superview
        }
        return s == nil ? v.convert(v.bounds, to: ancestor) : r
    }

    /// Whether a layout motion runs anywhere in the window: an animated view or a ghost
    /// (self-test seam, and what a pass waits on before it clears masks).
    static func isAnimating(in root: NSView) -> Bool {
        if root is LayoutGhostView || Pass.clippedBy.object(forKey: root) != nil { return true }
        if (root as? TabStripView)?.isGliding == true { return true }  // #103
        if root.layer?.animationKeys()?.contains(where: { $0.hasPrefix(keyPrefix) }) == true { return true }
        return root.subviews.contains { isAnimating(in: $0) }
    }

    // MARK: The pass

    /// Collected while the animated pass runs, applied at its end.
    final class Pass {
        let snapshot: Snapshot
        /// Explicit start frames (new panes, new dividers, new decks and their titlebar strips), in
        /// the view's superview.
        var starts: [ObjectIdentifier: CGRect] = [:]
        /// Views handled by `starts` only (pooled dividers: their old frame belongs to another split).
        var explicitOnly = Set<ObjectIdentifier>()
        /// Gap rects of splits that are new this pass, collapsed at the far edge (keyed by Node).
        var collapsedDividers: [ObjectIdentifier: CGRect] = [:]
        /// Views clipped while they move (they hold content laid out at its final size).
        private var masked: [NSView] = []
        private var movedDecks = false
        /// Zoom (#97): the zoomed pane and its deck, drawn above their siblings while they move.
        var raised: [NSView] = []
        /// Zoom out (#97): panes, decks, strips and dividers shown again fade in under the
        /// shrinking pane instead of popping.
        var fadesRevealed = false

        init(snapshot: Snapshot) { self.snapshot = snapshot }

        func setStart(_ v: NSView, _ r: CGRect?) {
            explicitOnly.insert(ObjectIdentifier(v))
            if let r { starts[ObjectIdentifier(v)] = r }
        }

        func run(in contentView: WindowContentView, ghosts: [LayoutGhost]) {
            masked = []
            movedDecks = false
            LayoutAnimation.passes += 1
            CATransaction.begin()
            // Weak: a strong capture kept closed panes' views, and so their surfaces and shells,
            // alive until the motion ended (`layout anim:` memory step).
            let unmask = WeakList(), lower = WeakList()
            let id = NSNumber(value: LayoutAnimation.passes)
            CATransaction.setCompletionBlock {
                // A newer pass that clipped (or raised) the same view undoes it when its own motion ends.
                for v in unmask.views where Pass.clippedBy.object(forKey: v) == id {
                    v.layer?.masksToBounds = false
                    Pass.clippedBy.removeObject(forKey: v)
                }
                for v in lower.views where Pass.raisedBy.object(forKey: v) == id {
                    v.layer?.zPosition = 0
                    Pass.raisedBy.removeObject(forKey: v)
                }
            }
            for v in raised {
                v.layer?.zPosition = 1
                Pass.raisedBy.setObject(id, forKey: v)
            }
            lower.add(raised)
            for v in contentView.subviews where Snapshot.isChrome(v) { visit(v, fading: false) }
            unmask.add(masked)
            for g in ghosts {
                g.play(in: contentView)
                if g.isDeck { movedDecks = true }
            }
            CATransaction.commit()
            if movedDecks, Theme.transparency.isTranslucent { BackdropFollower.follow(contentView) }
        }

        /// Which pass clipped a view last (weak keys).
        static let clippedBy = NSMapTable<NSView, NSNumber>.weakToStrongObjects()
        /// Which pass raised a view last (weak keys).
        static let raisedBy = NSMapTable<NSView, NSNumber>.weakToStrongObjects()

        private func mask(_ v: NSView) {
            guard let layer = v.layer else { return }
            layer.masksToBounds = true
            Pass.clippedBy.setObject(NSNumber(value: LayoutAnimation.passes), forKey: v)
            masked.append(v)
        }

        private func visit(_ v: NSView, fading: Bool) {
            let id = ObjectIdentifier(v)
            var fading = fading
            // Zoom out: what the zoom hid comes back at its final frame, fading in (the outermost
            // view only; its contents fade with it).
            if fadesRevealed, !fading, v is PaneView || v is DeckView || v is TabStripView || v is DividerView,
               !v.isHiddenOrHasHiddenAncestor, !snapshot.wasVisible(v), let layer = v.layer {
                LayoutAnimation.fadeIn(layer)
                fading = true
            }
            if let s = v as? SurfaceView {
                // Never resized per frame: only a moved origin glides (its bar came or went).
                if let old = snapshot.oldFrame(s), !s.isHidden, old.origin != s.frame.origin {
                    LayoutAnimation.animate(s, from: CGRect(origin: old.origin, size: s.frame.size))
                    if let pv = s.superview { mask(pv) }
                }
                return
            }
            if let bar = v as? PaneBarView, let pv = bar.superview as? PaneView {
                if !fading { visitBar(bar, in: pv) }
                return
            }
            let from = starts[id] ?? (explicitOnly.contains(id) ? nil : snapshot.oldFrame(v))
            if let from, !v.isHidden, from != v.frame {
                LayoutAnimation.animate(v, from: from)
                if v is DeckView { movedDecks = true }
                // Content inside is laid out at its final size: a growing pane's surface, a new
                // deck's card, a new titlebar strip's tabs.
                if v is PaneView || starts[id] != nil && (v is DeckView || v is TabStripView) { mask(v) }
            }
            for s in v.subviews { visit(s, fading: fading) }
        }

        /// The pane bar shows only in a multi-pane tab, so it comes and goes with the first split and
        /// the last close. It slides in from above, or a picture of it slides out, while the
        /// terminal under it glides to its new top (#94: it used to pop, moving the terminal 22 pt).
        private func visitBar(_ bar: PaneBarView, in pv: PaneView) {
            let wasShown = snapshot.wasVisible(bar)
            let paneWasShown = snapshot.wasVisible(pv)
            if !bar.isHidden {
                if !wasShown, paneWasShown, starts[ObjectIdentifier(pv)] == nil {
                    LayoutAnimation.animate(bar, from: bar.frame.offsetBy(dx: 0, dy: -bar.frame.height))
                    mask(pv)
                } else if let from = snapshot.oldFrame(bar), from != bar.frame {
                    LayoutAnimation.animate(bar, from: from)
                }
                for s in bar.subviews { visit(s, fading: false) }
            } else if wasShown, paneWasShown, !pv.isHidden, let image = LayoutGhost.image(ofHidden: bar) {
                let ghost = LayoutGhostView(frame: bar.frame.offsetBy(dx: 0, dy: -bar.frame.height))
                let l = CALayer()  // a sublayer: AppKit owns the view's own layer contents
                l.frame = CGRect(origin: .zero, size: bar.frame.size)
                l.backgroundColor = bar.layer?.backgroundColor
                l.contents = image
                l.contentsGravity = .topLeft
                l.contentsScale = pv.window?.backingScaleFactor ?? 2
                ghost.layer?.addSublayer(l)
                pv.addSubview(ghost, positioned: .below, relativeTo: pv.veilView)
                LayoutAnimation.animate(ghost, from: bar.frame, completion: { [weak ghost] in ghost?.removeFromSuperview() })
                mask(pv)
            }
        }
    }

    /// Weak references for a completion block.
    final class WeakList {
        private var refs: [WeakRef<NSView>] = []
        func add(_ views: [NSView]) { refs += views.map { WeakRef($0) } }
        var views: [NSView] { refs.compactMap(\.value) }
    }

    static func animate(_ v: NSView, from old: CGRect, completion: (() -> Void)? = nil) {
        guard let layer = v.layer else { completion?(); return }
        let new = v.frame
        let ap = layer.anchorPoint
        func pos(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX + ap.x * r.width, y: r.minY + ap.y * r.height) }
        // Drawn contents (bar title, tab labels and marks) are redrawn at the final size; pin them
        // top-left rather than stretch them through the motion.
        if v is PaneBarView || v is TabButton, v.layerContentsPlacement != .topLeft { v.layerContentsPlacement = .topLeft }
        CATransaction.begin()
        if let completion { CATransaction.setCompletionBlock(completion) }
        if old.origin != new.origin || old.size != new.size {
            let p = CABasicAnimation(keyPath: "position")
            p.fromValue = NSValue(point: pos(old))
            p.toValue = NSValue(point: pos(new))
            add(p, to: layer, key: "position")
        }
        if old.size != new.size {
            let b = CABasicAnimation(keyPath: "bounds.size")
            b.fromValue = NSValue(size: old.size)
            b.toValue = NSValue(size: new.size)
            add(b, to: layer, key: "bounds")
        }
        CATransaction.commit()
    }

    /// An opacity fade over the motion's duration (zoom's siblings, #97). The model value is final.
    static func fadeIn(_ layer: CALayer) { fade(layer, from: 0, to: 1) }

    static func fade(_ layer: CALayer, from: Float, to: Float, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        if let completion { CATransaction.setCompletionBlock(completion) }
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = from
        o.toValue = to
        add(o, to: layer, key: "opacity")
        CATransaction.commit()
    }

    private static func add(_ a: CABasicAnimation, to layer: CALayer, key: String) {
        a.duration = duration
        a.timingFunction = timing
        layer.add(a, forKey: "\(keyPrefix).\(key)")
    }

    /// Start frames for a tree into which `node` was just inserted (or from which it's about to go):
    /// the same layout with its split's ratio pushed to the far edge, so `node` has zero width (or
    /// height) there.
    static func collapsedLayout<Leaf>(_ root: Node<Leaf>, collapsing node: Node<Leaf>, in rect: CGRect, gap: CGFloat)
        -> (frames: [(Leaf, CGRect)], dividers: [Node<Leaf>.Divider])? {
        guard let parent = node.parent else { return nil }
        let saved = parent.ratio
        parent.ratio = node.isFirstChild ? 0 : 1
        defer { parent.ratio = saved }
        var f: [(Leaf, CGRect)] = []
        var d: [Node<Leaf>.Divider] = []
        root.layout(in: rect, gap: gap, frames: &f, dividers: &d)
        return (f, d)
    }
}

// MARK: - Tab widths (#103)

/// A strip's tab widths gliding from where they are to where they're wanted, owned by the strip
/// (`TabStripView.layout`). The buttons get real frames each display frame (a run-loop timer in the
/// common modes, like `BackdropFollower`), so a title truncates at the width on screen; the title
/// text itself is already the new one. A new target mid-glide restarts the clock from the widths on
/// screen (`retarget`): nothing queues or stacks, so a program that retitles quickly (Claude's
/// spinner) only ever moves toward its latest width.
final class TabWidthGlide {
    private(set) var from: [CGFloat] = []
    private(set) var to: [CGFloat] = []
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?
    var isRunning: Bool { timer != nil }
    /// Self-test hook: glides started, retargets included.
    private(set) static var starts = 0

    /// Starts (or restarts) a glide from `from` to `to`; `tick` lays the buttons out each frame.
    func retarget(from: [CGFloat], to: [CGFloat], tick: @escaping () -> Void) {
        self.from = from
        self.to = to
        startTime = CACurrentMediaTime()
        Self.starts += 1
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.progress >= 1 { self.stop() }
                tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// 0…1 through the motion, before easing.
    private var progress: CGFloat {
        CGFloat(min(max((CACurrentMediaTime() - startTime) / LayoutAnimation.duration, 0), 1))
    }

    /// The widths to show now: the target once stopped.
    var widths: [CGFloat] {
        guard isRunning, from.count == to.count else { return to }
        let e = Self.ease(progress)
        return zip(from, to).map { $0 + ($1 - $0) * e }
    }

    /// `LayoutAnimation.timing` (a cubic Bézier) at `x`, solved for its curve parameter by bisection.
    static func ease(_ x: CGFloat) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var c1 = [Float](repeating: 0, count: 2), c2 = [Float](repeating: 0, count: 2)
        LayoutAnimation.timing.getControlPoint(at: 1, values: &c1)
        LayoutAnimation.timing.getControlPoint(at: 2, values: &c2)
        func bezier(_ t: CGFloat, _ a: Float, _ b: Float) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * CGFloat(a) + 3 * u * t * t * CGFloat(b) + t * t * t
        }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bezier(mid, c1[0], c2[0]) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, c1[1], c2[1])
    }
}

// MARK: - Ghosts of closed panes and decks

/// What a closed pane or deck looked like, kept for one collapse. It holds pictures only: the
/// surfaces' last IOSurface frames (the contents libghostty set on their layers) and images of the
/// bars and strip. The terminals themselves are freed as usual.
struct LayoutGhost {
    struct Part {
        var frame: CGRect
        var contents: Any?
        var background: CGColor?
        var scale: CGFloat
    }

    weak var container: NSView?
    let from: CGRect
    let to: CGRect
    var background: CGColor?
    var border: (color: CGColor?, width: CGFloat, radius: CGFloat, corners: CACornerMask)?
    var parts: [Part] = []
    let isDeck: Bool
    /// Zoom in (#97): stays where it is and fades out under the zoomed pane (or deck) as that grows,
    /// instead of collapsing.
    var fades = false

    /// A pane collapsing into its split's far edge (`to`, in its container's coordinates).
    init?(pane: Pane, collapsedTo to: CGRect) {
        let pv = pane.view
        guard let container = pv.superview, !pv.isHiddenOrHasHiddenAncestor else { return nil }
        self.container = container
        from = LayoutAnimation.presentedFrame(pv)
        self.to = to
        isDeck = false
        background = pv.layer?.backgroundColor
        parts = Self.parts(of: pv, offset: .zero)
    }

    /// A deck collapsing into its split's far edge. Its titlebar strip, if it has one there, is a
    /// ghost of its own (`stripTo`).
    init?(deck: Deck, collapsedTo to: CGRect, in contentView: NSView) {
        let dv = deck.view
        guard dv.superview === contentView, !dv.isHidden else { return nil }
        container = contentView
        from = LayoutAnimation.presentedFrame(dv)
        self.to = to
        isDeck = true
        let card = dv.content
        let cardFrame = card.frame
        parts.append(Part(frame: cardFrame, contents: nil, background: card.layer?.backgroundColor, scale: 1))
        border = (card.layer?.borderColor, card.layer?.borderWidth ?? 0, card.layer?.cornerRadius ?? 0,
                  card.layer?.maskedCorners ?? DeckView.allCorners)
        for pv in deck.activeTab?.panes.map(\.view) ?? [] where pv.superview === card && !pv.isHidden {
            let o = CGPoint(x: cardFrame.minX + pv.frame.minX, y: cardFrame.minY + pv.frame.minY)
            parts.append(Part(frame: CGRect(origin: o, size: pv.frame.size), contents: nil, background: pv.layer?.backgroundColor, scale: 1))
            parts += Self.parts(of: pv, offset: o)
        }
        if dv.strip.superview === dv, let img = Self.image(of: dv.strip) {
            parts.append(Part(frame: dv.strip.frame, contents: img, background: nil, scale: Self.scale(dv)))
        }
    }

    /// A titlebar strip collapsing with its deck.
    init?(strip: TabStripView, collapsedTo to: CGRect) {
        guard let container = strip.superview, !strip.isHidden, let img = Self.image(of: strip) else { return nil }
        self.container = container
        from = LayoutAnimation.presentedFrame(strip)
        self.to = to
        isDeck = true
        parts = [Part(frame: CGRect(origin: .zero, size: strip.frame.size), contents: img, background: nil, scale: Self.scale(strip))]
    }

    private static func scale(_ v: NSView) -> CGFloat { v.window?.backingScaleFactor ?? 2 }

    private static func parts(of pv: PaneView, offset o: CGPoint) -> [Part] {
        var parts: [Part] = []
        if let s = pv.pane?.surface {
            parts.append(Part(frame: s.frame.offsetBy(dx: o.x, dy: o.y), contents: s.layer?.contents, background: nil,
                              scale: s.layer?.contentsScale ?? scale(pv)))
        }
        if !pv.bar.isHidden {
            parts.append(Part(frame: pv.bar.frame.offsetBy(dx: o.x, dy: o.y), contents: image(of: pv.bar),
                              background: pv.bar.layer?.backgroundColor, scale: scale(pv)))
        }
        if let veil = Optional(pv.veilView), veil.alphaValue > 0 {
            parts.append(Part(frame: veil.frame.offsetBy(dx: o.x, dy: o.y), contents: nil,
                              background: veil.layer?.backgroundColor?.copy(alpha: veil.alphaValue), scale: 1))
        }
        return parts
    }

    /// A drawn view's picture. A layer-backed view's drawing can't be read from its layer.
    static func image(of v: NSView) -> CGImage? {
        guard v.bounds.width > 0, v.bounds.height > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    /// The same, for a view the pass just hid (a pane bar going away); nothing is displayed between.
    static func image(ofHidden v: NSView) -> CGImage? {
        v.isHidden = false
        defer { v.isHidden = true }
        return image(of: v)
    }

    func play(in contentView: NSView) {
        guard let container else { return }
        let ghost = LayoutGhostView(frame: to)
        ghost.fades = fades
        ghost.layer?.masksToBounds = true
        ghost.layer?.backgroundColor = background
        if let border {
            ghost.layer?.cornerRadius = border.radius
            ghost.layer?.maskedCorners = border.corners
        }
        for (i, p) in parts.enumerated() {
            let l = CALayer()
            l.frame = p.frame
            l.backgroundColor = p.background
            l.contents = p.contents
            l.contentsGravity = .topLeft
            l.contentsScale = p.scale
            if isDeck, i == 0, let border {  // the card
                l.borderColor = border.color
                l.borderWidth = border.width
                l.cornerRadius = border.radius
                l.maskedCorners = border.corners
                l.masksToBounds = true
            }
            ghost.layer?.addSublayer(l)
        }
        if isDeck {
            // Over the backdrop, under the decks that grow into its place.
            container.addSubview(ghost, positioned: .above, relativeTo: (container as? WindowContentView)?.backdrop)
        } else if let firstDivider = container.subviews.first(where: { $0 is DividerView }) {
            // Under the dividers (which stay on top for their grab areas), over the panes.
            container.addSubview(ghost, positioned: .below, relativeTo: firstDivider)
        } else {
            container.addSubview(ghost)
        }
        if fades, let layer = ghost.layer {
            ghost.alphaValue = 0  // the model is final; the animation holds it visible meanwhile
            LayoutAnimation.fade(layer, from: 1, to: 0, completion: { [weak ghost] in ghost?.removeFromSuperview() })
        } else {
            LayoutAnimation.animate(ghost, from: from, completion: { [weak ghost] in ghost?.removeFromSuperview() })
        }
    }
}

/// A picture of a closed pane, deck, strip or bar while it collapses (or, for zoom, fades). Never
/// takes events.
final class LayoutGhostView: PassthroughView {
    override var isFlipped: Bool { true }
    /// A zoom's fading picture (#97): no card hole is cut for it, as the deck it shows is going.
    var fades = false
}

// MARK: - Translucent windows

/// While decks move in a translucent window, the chrome fill's holes follow the cards' presented
/// frames each display frame; at the end the normal backdrop layout puts the final holes back.
enum BackdropFollower {
    private static var timers: [ObjectIdentifier: Timer] = [:]
    /// Self-test hook: ticks so far (each sets the holes from the presented frames).
    private(set) static var ticks = 0

    static func isFollowing(_ cv: WindowContentView) -> Bool { timers[ObjectIdentifier(cv)] != nil }

    static func follow(_ cv: WindowContentView) {
        let key = ObjectIdentifier(cv)
        timers[key]?.invalidate()
        let end = Date().addingTimeInterval(LayoutAnimation.duration + 0.05)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak cv] timer in
            MainActor.assumeIsolated {
                guard let cv, Date() < end, LayoutAnimation.isAnimating(in: cv) else {
                    timer.invalidate()
                    timers.removeValue(forKey: key)
                    cv?.layoutBackdrop()
                    return
                }
                ticks += 1
                cv.backdrop.layoutChrome(holes: presentedHoles(cv))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers[key] = t
        cv.backdrop.layoutChrome(holes: presentedHoles(cv))
    }

    /// The card holes where the cards are on screen now (`layoutBackdrop` uses the final frames).
    static func presentedHoles(_ cv: WindowContentView) -> [CardHole] {
        var holes: [CardHole] = []
        for v in cv.subviews where !v.isHidden {
            if let dv = v as? DeckView {
                let tab = dv.squareTop && TabStyle.connectedMatchesTerminal && dv.strip.buttons.indices.contains(dv.deck.activeIndex)
                    ? dv.strip.buttons[dv.deck.activeIndex] : nil
                holes.append(CardHole(card: LayoutAnimation.presentedRect(dv.content, in: cv), squareTop: dv.squareTop,
                                      tab: tab.map { LayoutAnimation.presentedRect($0, in: cv) }))
            } else if let g = v as? LayoutGhostView, !g.fades, let card = g.layer?.sublayers?.first, card.borderWidth > 0 {
                let f = LayoutAnimation.presentedFrame(g)
                holes.append(CardHole(card: card.frame.offsetBy(dx: f.minX, dy: f.minY).intersection(f),
                                      squareTop: card.maskedCorners == DeckView.bottomCorners, tab: nil))
            }
        }
        return holes
    }
}
