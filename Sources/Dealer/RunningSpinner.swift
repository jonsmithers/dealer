import AppKit

// MARK: - "An agent is working here" (#64, #73)
//
// A continual animation on every tab button and workspace switcher entry (sidebar row or top-bar
// pill) that holds a pane whose `agentState` is `.running` — OSC 9;4 progress, which Claude Code
// reports while a turn runs (AgentStatus.swift, docs/claude-code-states.md). Attention outranks
// progress in `agentState`, so a pane waiting on a permission prompt (where Claude keeps progress
// set) shows its blue outline and no spinner, and the spinner never competes with an attention mark.
//
// It is the only *motion* in the chrome that isn't a fade. It has no hue, because colors and
// outlines mean attention (#7, #9); it stands out by shape and contrast instead: a filled mark in
// the full foreground color (`Theme.text`) whatever its element's title color, pulsing brighter
// and dimmer.

/// An agent's working animation: still frames shown in turn, each a filled shape in a
/// `side`×`side` box (y down, like the SVG it came from). A value, so another kind of agent can get
/// its own; Dealer only knows "a pane reports progress" today, so `RunningSpinner.animation` is
/// Claude's.
struct SpinnerAnimation {
    let frames: [NSBezierPath]
    let side: CGFloat
    /// How long each frame shows. Frames step; they are never tweened.
    let frameDuration: TimeInterval

    /// The mark claude.ai shows while Claude works (#73), its exact frames (ClaudeSpinnerSprite.swift):
    /// a sprite sheet of eight 100×100 frames stacked down a 100×800 viewBox, one subpath each.
    /// The page's frame rate isn't in the file; 0.12 s matches it by eye.
    static let claude: SpinnerAnimation = {
        let frames = SVGPath.subpaths(claudeSpritePath).enumerated().map { i, path -> NSBezierPath in
            path.transform(using: AffineTransform(translationByX: 0, byY: -100 * CGFloat(i)))
            return path
        }
        return SpinnerAnimation(frames: frames, side: 100, frameDuration: 0.12)
    }()
}

enum RunningSpinner {
    /// The slot a spinner takes in front of a title, and the mark's size inside it.
    static let slot: CGFloat = 18
    static let size: CGFloat = 13
    /// One pulse, bright → dim → bright. The frames run on the same clock (16 of them per pulse).
    static let period: TimeInterval = 1.92
    /// The pulse's dimmest opacity; the brightest is 1.
    static let dimmest: CGFloat = 0.5
    /// Redraw rate while something spins: frames step at ~8 Hz, but the pulse fades smoothly. A tick
    /// costs one small `draw(_:)` per spinning element.
    static let tickInterval: TimeInterval = 1.0 / 30

    /// Which animation spinners show (see `SpinnerAnimation`).
    static var animation = SpinnerAnimation.claude

    /// Off in self-test mode (like `AttentionFade.enabled`), so pixel checks see a fixed frame and
    /// no timer runs; on for the README demos, which run in self-test mode but should look like the
    /// app. `SelfTestSpinner.swift` turns it on for its own steps.
    static var animating = !SelfTest.enabled || Demo.name != nil

    /// Whether the mark moves at all. Reduce Motion keeps it, standing still at full brightness: it
    /// says "an agent is working here", which a static mark still says.
    static var spins: Bool { animating && !AttentionFade.reduceMotion }

    /// The mark's box inside an element, given the slot's leading edge in the element's
    /// coordinates: `size` square, centred on the element's vertical middle.
    static func box(in bounds: CGRect, x: CGFloat) -> CGRect {
        CGRect(x: x + (slot - size) / 2, y: bounds.midY - size / 2, width: size, height: size)
    }

    /// Self-test only: renders a chosen frame, whatever the clock says.
    static var phaseOverride: CGFloat?

    /// 0…1 through the pulse. One clock for every element, so all spinners show the same frame. Frozen
    /// at 0 when it doesn't spin, which leaves the first frame standing at full brightness.
    static func phase(at now: Date = Date()) -> CGFloat {
        if let phaseOverride { return phaseOverride }
        guard spins else { return 0 }
        return CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }

    /// The frame shown at `phase`.
    static func frame(at phase: CGFloat, of a: SpinnerAnimation = animation) -> Int {
        guard !a.frames.isEmpty else { return 0 }
        return Int((Double(phase) * period / a.frameDuration).rounded(.down)) % a.frames.count
    }

    /// The mark's opacity at `phase`: 1 at 0, `dimmest` halfway.
    static func opacity(at phase: CGFloat) -> CGFloat {
        dimmest + (1 - dimmest) * (0.5 + 0.5 * cos(phase * 2 * .pi))
    }

    /// The one drawer. Every element calls this, so the look changes in one place.
    static func draw(in box: CGRect, phase: CGFloat) {
        let a = animation
        guard !a.frames.isEmpty, let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }
        let s = box.width / a.side
        let t = NSAffineTransform()
        // Frames are y-down; chrome views are flipped, but don't count on it.
        if ctx.isFlipped {
            t.translateX(by: box.minX, yBy: box.minY)
            t.scaleX(by: s, yBy: s)
        } else {
            t.translateX(by: box.minX, yBy: box.maxY)
            t.scaleX(by: s, yBy: -s)
        }
        t.concat()
        Theme.text.withAlphaComponent(opacity(at: phase)).setFill()
        a.frames[frame(at: phase, of: a)].fill()
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
