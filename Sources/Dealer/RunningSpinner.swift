import AppKit

// MARK: - "An agent is working here"
//
// A continual animation on every tab button and workspace switcher entry (sidebar row or top-bar
// pill) that holds a pane whose `agentState` is `.running` — OSC 9;4 progress, which Claude Code
// reports while a turn runs (AgentStatus.swift, docs/claude-code-states.md). Attention outranks
// progress in `agentState`, so a pane waiting on a permission prompt (where Claude keeps progress
// set) shows its blue outline and no spinner, and the spinner never competes with an attention mark.
//
// It is the only *motion* in the chrome that isn't a fade, and it is deliberately colorless: it
// draws in the element's own title color, because colors and outlines mean attention (#7, #9).

/// The look: a six-spoke asterisk that turns while its spokes breathe. Claude Code animates its
/// own prompt by cycling `· ✢ ✳ ✶ ✻ ✽`, an asterisk whose spokes grow and shrink, so this draws
/// that cycle as vectors instead of swapping glyphs — per-frame glyph metrics differ, which would
/// make the chrome jitter, and the fallback font for those code points isn't ours to pick.
enum RunningSpinner {
    /// The slot a spinner takes in front of a title, and the asterisk's size inside it.
    static let slot: CGFloat = 14
    static let size: CGFloat = 9
    /// One full turn.
    static let period: TimeInterval = 2.4
    private static let spokes = 6
    /// How far a spoke's length swings around the middle, as a fraction of the radius.
    private static let breathe: CGFloat = 0.3
    /// Redraw rate while something spins. 30 Hz is plenty for a 2.4 s turn, and a tick costs one
    /// small `draw(_:)` per spinning element.
    static let tickInterval: TimeInterval = 1.0 / 30

    /// Off in self-test mode (like `AttentionFade.enabled`), so pixel checks see a fixed frame and
    /// no timer runs; on for the README demos, which run in self-test mode but should look like the
    /// app. `SelfTestSpinner.swift` turns it on for its own steps.
    static var animating = !SelfTest.enabled || Demo.name != nil

    /// Whether the asterisk moves at all. Reduce Motion keeps it, standing still: it says "an agent
    /// is working here", which a static mark still says.
    static var spins: Bool { animating && !AttentionFade.reduceMotion }

    /// The asterisk's box inside an element, given the slot's leading edge in the element's
    /// coordinates: `size` square, centred on the element's vertical middle.
    static func box(in bounds: CGRect, x: CGFloat) -> CGRect {
        CGRect(x: x + (slot - size) / 2, y: bounds.midY - size / 2, width: size, height: size)
    }

    /// Self-test only: renders a chosen frame, whatever the clock says.
    static var phaseOverride: CGFloat?

    /// 0…1 through the turn. One clock for every element, so all spinners turn together. Frozen at
    /// 0 when it doesn't spin, which leaves the asterisk standing in its mid-breath frame.
    static func phase(at now: Date = Date()) -> CGFloat {
        if let phaseOverride { return phaseOverride }
        guard spins else { return 0 }
        return CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }

    /// The one drawer. Every element calls this, so the look changes in one place.
    static func draw(in box: CGRect, color: NSColor, phase: CGFloat) {
        let c = CGPoint(x: box.midX, y: box.midY)
        let r = box.width / 2
        let turn = phase * 2 * .pi
        color.setStroke()
        for i in 0..<spokes {
            let a = turn + CGFloat(i) * 2 * .pi / CGFloat(spokes)
            // Each spoke breathes a sixth of a turn behind the one before it, so the asterisk
            // ripples the way Claude's `·✢✳✶✻✽` cycle grows and shrinks.
            let len = r * (1 - breathe + breathe * cos(turn * 2 - CGFloat(i) * .pi / 3))
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x + cos(a) * r * 0.2, y: c.y + sin(a) * r * 0.2))
            path.line(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}

/// Whether one chrome element (tab button, workspace row or pill) shows the spinner, and its
/// registration with the shared timer. Same shape as `AttentionFadeState`: feed it the model's
/// value on every refresh (`set(_:)`), draw while `isRunning`, redraw from `onChange`.
final class RunningSpinnerState {
    /// Called on every tick, and when the element starts or stops spinning; the element redraws.
    var onChange: (() -> Void)?
    private(set) var isRunning = false

    /// `slot` while the spinner shows, else 0: what the element must leave free in front of its title.
    var leading: CGFloat { isRunning ? RunningSpinner.slot : 0 }

    func set(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if running { SpinnerTicker.shared.add(self) } else { SpinnerTicker.shared.remove(self) }
        onChange?()
    }

    deinit { SpinnerTicker.shared.remove(self) }
}

/// One timer for every spinning element, running only while something spins. Like `AttentionFader`
/// it's scheduled in the common run-loop modes, so spinners keep turning during tracking loops and
/// the self-test's waits.
///
/// Its references are **weak**, unlike the fader's: a fade always ends and unregisters itself, but a
/// spin has no end of its own, so a strong reference to a closed pane's tab button would keep it,
/// its state and the timer alive forever (#43).
final class SpinnerTicker {
    static let shared = SpinnerTicker()
    private struct Weak { weak var state: RunningSpinnerState? }
    private var states: [Weak] = []
    private var timer: Timer?

    /// Elements registered right now, and whether the timer runs: self-test hooks. Both must fall
    /// back to 0/false once nothing is running, including when a spinning pane is closed.
    var count: Int { states.compactMap(\.state).count }
    var isTicking: Bool { timer != nil }

    func add(_ s: RunningSpinnerState) {
        guard RunningSpinner.spins else { return }
        if !states.contains(where: { $0.state === s }) { states.append(Weak(state: s)) }
        guard timer == nil else { return }
        let t = Timer(timeInterval: RunningSpinner.tickInterval, repeats: true) { [weak self] _ in self?.tickAll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func remove(_ s: RunningSpinnerState) {
        states.removeAll { $0.state === s || $0.state == nil }
        stopIfIdle()
    }

    private func tickAll() {
        states.removeAll { $0.state == nil }
        for s in states { s.state?.onChange?() }
        stopIfIdle()
    }

    private func stopIfIdle() {
        guard states.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}
