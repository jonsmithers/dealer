import AppKit
import UserNotifications

/// Whether a pane wants the user to look at it. Ordered: a tab, deck or workspace shows the
/// highest state of anything inside it.
enum Attention: Int, Comparable, CaseIterable {
    case none
    /// Something happened (bell, OSC notification, long command finished).
    case unread
    /// An agent finished its turn.
    case done
    /// An agent is blocked on the user (permission prompt, question).
    case waiting
    /// Something failed (#29): `dealer run` exited non-zero, a Claude API error, a shell command
    /// failed. Outranks everything, for roll-up and for Jump to Next Unread.
    case failed

    static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }

    init?(name: String) {
        switch name.lowercased() {
        case "none", "clear": self = .none
        case "unread", "info": self = .unread
        case "done", "stop", "finished": self = .done
        case "waiting", "wait", "input": self = .waiting
        case "failed", "fail", "error": self = .failed
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .none: return "none"
        case .unread: return "unread"
        case .done: return "done"
        case .waiting: return "waiting"
        case .failed: return "failed"
        }
    }

    /// `waiting` and `failed` get outlines (pane ring, tab and workspace outline); the rest a dot.
    var outlined: Bool { self == .waiting || self == .failed }

    /// Badge/ring colour, or nil for none.
    var color: NSColor? {
        switch self {
        case .none: return nil
        case .unread, .done: return Theme.attentionDone
        case .waiting: return Theme.attentionWaiting
        case .failed: return Theme.attentionFailed
        }
    }
}

extension Tab {
    var attention: Attention { panes.map(\.attention).max() ?? .none }
}

extension Deck {
    var attention: Attention { tabs.map(\.attention).max() ?? .none }
}

extension Workspace {
    var attention: Attention { decks.map(\.attention).max() ?? .none }
}

extension Pane {
    /// Every live pane in every window, in window → deck → tab → pane order.
    static var all: [(TerminalWindowController, Pane)] {
        AppDelegate.shared.windowControllers.flatMap { wc in wc.allPanes.map { (wc, $0) } }
    }

    static func with(id: Int) -> (TerminalWindowController, Pane)? {
        all.first { $0.1.id == id }
    }
}

extension TerminalWindowController {
    /// Every pane in this window, in reading order (workspaces, decks, tabs, panes).
    var allPanes: [Pane] { workspaces.flatMap(\.panes) }

    /// True when the user can currently see this pane with the keyboard in it.
    func isLookingAt(_ pane: Pane) -> Bool {
        pane === focusedPane && (window?.isKeyWindow ?? false) && NSApp.isActive
    }

    /// Marks a pane. `raiseOnly` keeps a stronger existing state (a bell doesn't downgrade
    /// "waiting" to "unread"); explicit `dealer notify` calls set the state exactly.
    func setAttention(_ a: Attention, on pane: Pane, raiseOnly: Bool = false, title: String? = nil, body: String? = nil) {
        guard locate(pane) != nil else { return }
        if a != .none && isLookingAt(pane) { return }
        let new = raiseOnly ? max(pane.attention, a) : a
        guard new != pane.attention else { return }
        pane.attention = new
        refreshChrome()
        if new > .none { AttentionNotifier.shared.post(for: pane, in: self, state: new, title: title, body: body) }
    }

    func clearAttention(_ pane: Pane) {
        guard pane.attention != .none else { return }
        pane.attention = .none
        refreshChrome()
    }

    /// The next pane needing attention after the focused one, across all windows.
    /// Higher states win; ties go in reading order, wrapping around.
    static func nextUnread(after current: Pane?) -> (TerminalWindowController, Pane)? {
        let all = Pane.all
        let start = all.firstIndex { $0.1 === current }.map { $0 + 1 } ?? 0
        let rotated = Array(all[start...] + all[..<start])
        guard let top = rotated.map(\.1.attention).max(), top > .none else { return nil }
        return rotated.first { $0.1.attention == top && $0.1 !== current }
            ?? rotated.first { $0.1.attention == top }
    }

    /// What a finished shell command (COMMAND_FINISHED, via shell integration) marks, if anything:
    /// a non-zero exit is *failed* (#29, `[attention] failed_commands`, any duration); a success
    /// that ran ≥ 10 s is *unread*. Exit code -1 means unknown and counts as success.
    static func commandFinishedAttention(exitCode: Int, durationNs: UInt64,
                                         failedCommands: Bool = Settings.attentionFailedCommands) -> Attention? {
        if exitCode > 0 && failedCommands { return .failed }
        return durationNs >= 10_000_000_000 ? .unread : nil
    }

    func commandFinished(_ pane: Pane, exitCode: Int, durationNs: UInt64) {
        guard let a = Self.commandFinishedAttention(exitCode: exitCode, durationNs: durationNs) else { return }
        let body = exitCode >= 0 ? "Exited with status \(exitCode)" : nil
        setAttention(a, on: pane, raiseOnly: true, title: a == .failed ? "Command failed" : "Command finished", body: body)
    }

    @objc func jumpToNextUnread(_ sender: Any?) {
        guard let (wc, pane) = Self.nextUnread(after: focusedPane) else { return NSSound.beep() }
        wc.reveal(pane)
    }

    /// Brings the pane's window forward and focuses it; focusing clears its attention.
    func reveal(_ pane: Pane) {
        AttentionFade.noteReveal()  // the clear below fades after a short hold (#34)
        window?.makeKeyAndOrderFront(nil)
        focus(pane)
        clearAttention(pane)
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        if let p = focusedPane { clearAttention(p) }
    }
}

/// Posts macOS notifications for panes that want attention while the user is elsewhere,
/// and focuses the pane when one is clicked. Only works from a bundled app.
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifier()

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter raises without a bundle identifier (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private var authorized = false

    func start() {
        guard let center, !SelfTest.enabled else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { self.authorized = ok }
        }
    }

    func post(for pane: Pane, in wc: TerminalWindowController, state: Attention, title: String?, body: String?) {
        guard !SelfTest.enabled else { return }
        // Only interrupt when the user isn't already looking at this window.
        if NSApp.isActive && (wc.window?.isKeyWindow ?? false) { return }
        NSApp.requestUserAttention(.informationalRequest)
        guard let center, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? (state == .failed ? "Failed" : state == .waiting ? "Waiting for input" : state == .done ? "Finished" : "Terminal")
        content.subtitle = pane.title
        content.body = body ?? ""
        content.userInfo = ["pane": pane.id]
        center.add(UNNotificationRequest(identifier: "pane-\(pane.id)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["pane"] as? Int
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id, let (wc, pane) = Pane.with(id: id) { wc.reveal(pane) }
            done()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - Drawing (visuals #2 owns the styling; these only read `attention`)

extension PaneView {
    private static let ringName = "dealer.attentionRing"

    /// An accent ring over the whole pane while an agent in it is waiting (#7; done/unread get no ring). Its own layer, above the
    /// Metal surface, so it doesn't fight the pane's focus styling.
    func updateAttentionRing() {
        if attentionFade.onChange == nil { attentionFade.onChange = { [weak self] in self?.applyAttentionRing() } }
        attentionFade.set(pane?.attention ?? .none, subject: pane)
        applyAttentionRing()
    }

    /// Renders the ring from `attentionFade` (#34): the current state, or a cleared one fading out.
    func applyAttentionRing() {
        guard let layer else { return }
        let existing = layer.sublayers?.first { $0.name == Self.ringName }
        let a = attentionFade.shown
        guard a.outlined, let color = a.color else {
            existing?.removeFromSuperlayer()
            return
        }
        let ring = existing ?? {
            let l = CALayer()
            l.name = Self.ringName
            l.zPosition = 20
            l.borderWidth = 2
            l.cornerRadius = layer.cornerRadius
            layer.addSublayer(l)
            return l
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = layer.bounds
        ring.borderColor = color.cgColor
        ring.opacity = Float(attentionFade.alpha)
        CATransaction.commit()
    }
}

extension TabButton {
    /// Where the badge sits: the close button's slot, which only shows on hover.
    var attentionDotRect: CGRect { CGRect(x: bounds.width - 17, y: (bounds.height - 8) / 2, width: 8, height: 8) }

    /// The outline stays while hovering; only the dot gives way to the close button.
    func drawAttentionDot(hidden: Bool) {
        AttentionStyle.draw(attentionFade.shown, in: bounds, cornerRadius: Theme.Metrics.tabRadius,
                            dotRect: hidden ? nil : attentionDotRect, alpha: attentionFade.alpha)
    }
}

/// The one look for attention on chrome (tabs, workspace pills and sidebar rows), #7.
/// - waiting: a 1.5pt accent-blue outline on the element's outer edge, a faint blue tint and a blue dot;
/// - failed (#29): the same in red, and the dot carries a `!` so the state isn't color-only;
/// - done / unread: a muted dot only;
/// - none: nothing.
/// Call it last in `draw(_:)`, so the outline sits on top of the element's own fill.
enum AttentionStyle {
    static let outlineWidth: CGFloat = 1.5

    /// `alpha` < 1 while a cleared state fades out (#34).
    static func draw(_ attention: Attention, in rect: CGRect, cornerRadius: CGFloat, dotRect: CGRect?, alpha: CGFloat = 1) {
        guard alpha > 0, let base = attention.color else { return }
        let color = base.withAlphaComponent(base.alphaComponent * alpha)
        if attention.outlined {
            let inset = rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2)
            let r = max(cornerRadius - outlineWidth / 2, 0)
            let path = NSBezierPath(roundedRect: inset, xRadius: r, yRadius: r)
            color.withAlphaComponent(0.10 * alpha).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = outlineWidth
            path.stroke()
        }
        if let dotRect {
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            if attention == .failed { drawBang(in: dotRect, alpha: alpha) }
        }
    }

    /// A `!` knocked out of the failed dot: a bar and a point, as vector shapes so it stays crisp
    /// at 6–8pt. Drawn in the chrome color, so it reads as a hole in the red dot.
    static func drawBang(in r: CGRect, alpha: CGFloat = 1) {
        let w = max(r.width * 0.18, 1)
        Theme.chrome.withAlphaComponent(alpha).setFill()
        // Flipped views: y grows downward. Bar from 18% to 58% of the height, point at 70–84%.
        NSBezierPath(roundedRect: CGRect(x: r.midX - w / 2, y: r.minY + r.height * 0.18, width: w, height: r.height * 0.40),
                     xRadius: w / 2, yRadius: w / 2).fill()
        NSBezierPath(ovalIn: CGRect(x: r.midX - w / 2, y: r.minY + r.height * 0.68, width: w, height: w)).fill()
    }
}

// MARK: - Fading out (#34)

/// Timing and switches for the attention fade-out (#34). When a pane's attention clears, the model
/// changes at once (roll-up, ⌘⇧U and `dealer` see `none` immediately); only the drawing lingers:
/// the pane ring, the tab outline and dot, and the workspace row/pill keep showing the old state
/// at a decreasing alpha, so you can see which pane called you.
enum AttentionFade {
    /// Seconds from solid to gone.
    static let duration: TimeInterval = 0.8
    /// Extra solid time before fading when the clear came from `reveal` (⌘⇧U, a notification click),
    /// so the color registers before it goes.
    static let revealHold: TimeInterval = 0.5
    /// A fade that starts within this long after `noteReveal()` gets the hold.
    static let revealWindow: TimeInterval = 0.3

    /// Off in self-test mode so existing checks see clears immediately; SelfTestFade turns it on.
    /// On for README demos (`DEALER_DEMO`), which run in self-test mode but should look like the app.
    static var enabled = !SelfTest.enabled || Demo.name != nil
    /// Self-test override for the system's Reduce Motion setting.
    static var reduceMotionOverride: Bool?
    static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private(set) static var lastReveal: Date?
    /// Called by `reveal(_:)` just before it focuses the pane.
    static func noteReveal() { lastReveal = Date() }

    /// Hold and fade lengths for a fade starting now. Reduce Motion keeps the hold (no motion) but
    /// drops the fade: the state disappears at once.
    static func timing(now: Date = Date()) -> (hold: TimeInterval, fade: TimeInterval) {
        let hold = lastReveal.map { now.timeIntervalSince($0) <= revealWindow } == true ? revealHold : 0
        return (hold, reduceMotion ? 0 : duration)
    }
}

/// What one chrome element (pane ring, tab button, workspace row or pill) should draw. Feed it the
/// model's value with `set(_:subject:)` on every refresh; draw `shown` at `alpha`.
/// Colors are never cached here: elements read `shown.color` (Theme) at draw time.
final class AttentionFadeState {
    /// The state to draw. During a fade this is the state that cleared.
    private(set) var shown: Attention = .none
    /// 1 when solid, falling to 0 during a fade.
    private(set) var alpha: CGFloat = 1
    var isFading: Bool { start != nil }
    /// Called on every fade tick and when the fade ends; the element redraws.
    var onChange: (() -> Void)?

    private var model: Attention = .none
    private weak var subject: AnyObject?
    private var hasSubject = false
    private var start: Date?
    private var hold: TimeInterval = 0
    private var length: TimeInterval = 0

    /// `subject` is what the element currently represents (its pane, tab or workspace). A recycled
    /// view that now shows a different subject jumps to the new state instead of fading.
    func set(_ a: Attention, subject: AnyObject?) {
        let sameSubject = hasSubject && subject === self.subject
        self.subject = subject
        hasSubject = true
        defer { model = a }
        if a == .none, model != .none, sameSubject, AttentionFade.enabled {
            let t = AttentionFade.timing()
            guard t.hold + t.fade > 0 else { return finish(.none) }
            shown = model
            alpha = 1
            start = Date()
            hold = t.hold
            length = t.fade
            AttentionFader.shared.add(self)
            return
        }
        if a == .none && isFading && sameSubject { return }  // already fading out; keep going
        finish(a)  // a raise (cancels any fade) or a non-fading change
    }

    /// Advances the fade; returns false once it's over.
    func tick(now: Date = Date()) -> Bool {
        guard let start else { return false }
        let t = now.timeIntervalSince(start)
        if t < hold { alpha = 1; onChange?(); return true }
        let p = length > 0 ? (t - hold) / length : 1
        if p >= 1 { finish(.none); return false }
        alpha = CGFloat(1 - p)
        onChange?()
        return true
    }

    private func finish(_ a: Attention) {
        let changed = shown != a || alpha != 1 || start != nil
        start = nil
        shown = a
        alpha = 1
        AttentionFader.shared.remove(self)
        if changed { onChange?() }
    }
}

/// One 60 Hz timer for every fading element, running only while something fades. Scheduled in the
/// common run-loop modes, so fades keep going during tracking loops and the self-test's waits.
final class AttentionFader {
    static let shared = AttentionFader()
    private var states: [AttentionFadeState] = []
    private var timer: Timer?

    func add(_ s: AttentionFadeState) {
        if !states.contains(where: { $0 === s }) { states.append(s) }
        s.onChange?()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tickAll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func remove(_ s: AttentionFadeState) {
        states.removeAll { $0 === s }
        if states.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func tickAll() {
        let now = Date()
        for s in states { _ = s.tick(now: now) }
    }
}
