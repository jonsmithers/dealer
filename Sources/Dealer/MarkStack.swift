import AppKit

// MARK: - Stacked marks (#95)
//
// A roll-up (tab button, sidebar row, collapsed sidebar group header) shows one mark per pane
// instead of only the strongest, so you can count at a glance how many agents work and how many
// need you. Two stacks, on opposite sides as before: working marks (`WorkingMark`, drawn by
// `RunningSpinner`) on the left, attention dots (`AttentionStyle.drawDot`) on the right.
// - Strongest/most urgent first: the front mark sits where the single mark sat before #95 (the
//   outer end), each next one a `step` further in, behind it, like an avatar stack. A thin ring is
//   knocked out of the marks behind each one, so they read as separate on any background.
// - At most `cap` per stack; no `+N` counter (the lead's default, the user may ask for one).
// - Outlines and tints stay the element's roll-up (its highest state); only the marks stack.
// - Top-bar pills (and their group label pills) are fed a single mark: the user plans to rebuild
//   them.

enum MarkStack {
    /// The most marks a stack shows.
    static let cap = 3
    /// How far each mark behind sits from the one in front of it, as a fraction of the mark's size.
    static let stepFraction: CGFloat = 0.72
    /// The ring knocked out of the marks behind a mark, around its box.
    static let gap: CGFloat = 1

    /// The distance between neighbouring marks of `size`, in whole points.
    static func step(size: CGFloat) -> CGFloat { ceil(size * stepFraction) }

    /// What a stack of `count` marks of `size` adds beyond its front mark.
    static func extra(count: Int, size: CGFloat) -> CGFloat {
        CGFloat(max(min(count, cap) - 1, 0)) * step(size: size)
    }

    /// The boxes of `count` marks, front first: the front one is `front`, each next one `step`
    /// further along x in `direction` (+1 rightwards, −1 leftwards).
    static func boxes(count: Int, front: CGRect, direction: CGFloat) -> [CGRect] {
        let s = step(size: front.width)
        return (0..<min(max(count, 0), cap)).map { front.offsetBy(dx: direction * s * CGFloat($0), dy: 0) }
    }

    /// Draws the marks back to front: `mark(i, box)` draws mark i (0 = front) in its box, and before
    /// each mark a `gap` ring around its box is knocked out of the marks already drawn, scaled by
    /// `knockout(i)` (a fading mark gives its neighbours back their ink as it goes). One mark draws
    /// exactly as it did before #95, without a transparency layer.
    static func draw(_ boxes: [CGRect], knockout: (Int) -> CGFloat = { _ in 1 }, mark: (Int, CGRect) -> Void) {
        guard boxes.count > 1, let ctx = NSGraphicsContext.current?.cgContext else {
            if let b = boxes.first { mark(0, b) }
            return
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for i in boxes.indices.reversed() {
            if i < boxes.count - 1 {
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(CGColor(gray: 0, alpha: max(0, min(knockout(i), 1))))
                ctx.fillEllipse(in: boxes[i].insetBy(dx: -gap, dy: -gap))
                ctx.restoreGState()
            }
            mark(i, boxes[i])
        }
        ctx.endTransparencyLayer()
    }
}

/// One pane's attention, as a stack's input: the pane's id keys its dot, so each dot fades on its
/// own (#34) when that pane clears.
struct PaneAttention: Equatable {
    let pane: Int
    let state: Attention
    /// The id an element uses when it is given a plain state rather than its panes' (pills, and
    /// self-test steps that set `attention` directly).
    static let element = 0
}

extension Sequence where Element == Pane {
    /// The panes that want attention, in reading order: a roll-up's dot stack (#95).
    var attentionMarks: [PaneAttention] {
        compactMap { $0.attention > .none ? PaneAttention(pane: $0.id, state: $0.attention) : nil }
    }

    /// One working mark per working pane, strongest first: a roll-up's working stack (#95).
    var workingMarks: [WorkingMark] { WorkingMark.ordered(compactMap(\.workingMark)) }
}

/// What one element's dot stack shows: an `AttentionFadeState` per pane, so a pane that clears (or
/// leaves the element) fades out on its own while the others stay. Feed it the element's panes on
/// every refresh with `set(_:subject:)`, draw `shown`.
final class AttentionStackState {
    /// Called on every fade tick and when the stack changes; the element redraws.
    var onChange: (() -> Void)?

    private final class Entry {
        let pane: Int
        let fade = AttentionFadeState()
        var order: Int
        init(pane: Int, order: Int) { self.pane = pane; self.order = order }
    }
    private var entries: [Entry] = []
    private weak var subject: AnyObject?
    private var hasSubject = false

    /// `subject` is what the element represents (tab, workspace, group): a recycled view that now
    /// shows another one drops its dots instead of fading them.
    func set(_ marks: [PaneAttention], subject: AnyObject?) {
        if hasSubject && subject !== self.subject { entries.removeAll() }
        self.subject = subject
        hasSubject = true
        var seen = Set<Int>()
        for (i, m) in marks.enumerated() where seen.insert(m.pane).inserted {
            let e = entries.first { $0.pane == m.pane } ?? {
                let e = Entry(pane: m.pane, order: i)
                e.fade.onChange = { [weak self] in self?.onChange?() }
                entries.append(e)
                return e
            }()
            e.order = i
            e.fade.set(m.state, subject: e)
        }
        for e in entries where !seen.contains(e.pane) { e.fade.set(.none, subject: e) }
        entries.removeAll { $0.fade.shown == .none && !$0.fade.isFading }
    }

    /// The dots to draw, front (most urgent) first, at most `MarkStack.cap`: highest state first,
    /// a live dot before a fading one of the same state, then reading order.
    var shown: [(state: Attention, alpha: CGFloat)] {
        let live = entries.filter { $0.fade.shown > .none }
        let sorted = live.sorted {
            if $0.fade.shown != $1.fade.shown { return $0.fade.shown > $1.fade.shown }
            if $0.fade.isFading != $1.fade.isFading { return !$0.fade.isFading }
            return $0.order < $1.order
        }
        return sorted.prefix(MarkStack.cap).map { ($0.fade.shown, $0.fade.alpha) }
    }

    var count: Int { shown.count }
}
