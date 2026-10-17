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

    /// Whether the state is drawn with an outline (pane ring, tab and workspace outline, tint and
    /// dot) rather than a muted dot only. `waiting` and `failed` always are; `done` and `unread`
    /// follow `[attention] done` / `unread` (#61; by default done is outlined, unread a dot).
    /// The one place every drawer asks, so the setting applies everywhere at once. Read live.
    var outlined: Bool {
        switch self {
        case .none: return false
        case .waiting, .failed: return true
        case .done: return Settings.attentionDoneOutlined
        case .unread: return Settings.attentionUnreadOutlined
        }
    }

    /// Badge/ring colour, or nil for none. An outlined done/unread looks exactly like waiting.
    var color: NSColor? {
        switch self {
        case .none: return nil
        case .unread, .done: return outlined ? Theme.attentionWaiting : Theme.attentionDone
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

    /// Marks a pane. `raiseOnly` keeps a stronger existing state (a bell doesn't downgrade
    /// "waiting" to "unread"); explicit `dealer notify` calls set the state exactly.
    /// `event` names the source in the notification log (#56): `bell`, `notify`, `claude:stop`, ….
    /// `subtitle` replaces the notification's default second line, the pane's title.
    func setAttention(_ a: Attention, on pane: Pane, raiseOnly: Bool = false, title: String? = nil, subtitle: String? = nil,
                      body: String? = nil, event: String = "attention") {
        func skipped(_ why: String) {
            NotificationLog.decision(pane: pane, event: event, outcome: "attention:skipped",
                                     reason: "wanted \(a.name): \(why); no notification", title: title, body: body)
        }
        guard locate(pane) != nil else { return skipped("the pane isn't in this window") }
        if a != .none && isLookingAt(pane) {
            return skipped("you're looking at it (focused pane, \(NotificationLog.context(self)))")
        }
        let new = raiseOnly ? max(pane.attention, a) : a
        guard new != pane.attention else {
            return skipped(new == a ? "already \(a.name)"
                           : "already \(pane.attention.name), which outranks it (this source only raises)")
        }
        let old = pane.attention
        pane.attention = new
        NotificationLog.decision(pane: pane, event: event, outcome: new == .none ? "attention:cleared" : "attention:set",
                                 reason: "\(old.name) → \(new.name)", title: title, body: body)
        refreshChrome()
        if new > .none {
            AttentionNotifier.shared.post(for: pane, in: self, state: new, title: title, subtitle: subtitle, body: body, event: event)
        }
    }

    /// `cause` says what cleared it, for the notification log.
    func clearAttention(_ pane: Pane, cause: String) {
        guard pane.attention != .none else { return }
        NotificationLog.decision(pane: pane, event: cause, outcome: "attention:cleared",
                                 reason: "\(pane.attention.name) → none (\(NotificationLog.context(self)))")
        NotificationLog.withClearCause(cause) { pane.attention = .none }  // withdraws its banner (#78)
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
        setAttention(a, on: pane, raiseOnly: true, title: a == .failed ? "Command failed" : "Command finished", body: body,
                     event: "command-finished(exit=\(exitCode),\(Self.seconds(durationNs)))")
    }

    /// "12.3s", for log lines.
    static func seconds(_ ns: UInt64) -> String { String(format: "%.1fs", Double(ns) / 1e9) }

    @objc func jumpToNextUnread(_ sender: Any?) {
        guard let (wc, pane) = Self.nextUnread(after: focusedPane) else {
            NotificationLog.decision(pane: nil, event: "jump-to-next-unread", outcome: "ignored", reason: "no pane needs attention")
            return NSSound.beep()
        }
        wc.reveal(pane, cause: "jump-to-next-unread")
    }

    /// Brings the pane's window forward and focuses it; focusing clears its attention.
    /// `cause` names who asked, for the notification log.
    func reveal(_ pane: Pane, cause: String) {
        AttentionFade.noteReveal()  // the clear below fades after a short hold (#34)
        // The focus below may clear it (didFocus) before clearAttention does; log it as ours.
        NotificationLog.clearCause = cause
        defer { NotificationLog.clearCause = nil }
        window?.makeKeyAndOrderFront(nil)
        focus(pane)
        clearAttention(pane, cause: cause)
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        if let p = focusedPane { clearAttention(p, cause: "window-became-key") }
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

    /// Whether macOS lets Dealer post. Set by the launch request, and re-read from the current
    /// settings on every app activation and before a post while false (#71), so allowing
    /// notifications in System Settings takes effect without a relaunch.
    private(set) var authorized = false
    /// What the launch-time authorization request answered.
    private var launchAnswer = "not requested yet"
    /// The latest `UNNotificationSettings.authorizationStatus`, logged when it changes (#56).
    private var status: String?
    /// Self-test seam: reads the authorization status instead of `UNUserNotificationCenter`
    /// (which needs the bundle).
    var statusReader: ((@escaping (UNAuthorizationStatus) -> Void) -> Void)?

    /// For the notification log's header and suppress reasons.
    var authorizationDescription: String {
        if Bundle.main.bundleIdentifier == nil { return "none (unbundled)" }
        if SelfTest.enabled { return "not requested (self-test)" }
        return "launch request \(launchAnswer), current status \(status ?? "unknown")"
    }

    func start() {
        // Re-read the authorization whenever Dealer comes forward (the user may have just changed it).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.refreshStatus() }
        guard let center, !SelfTest.enabled else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, error in
            DispatchQueue.main.async {
                self.authorized = ok
                self.launchAnswer = ok ? "granted" : "refused" + (error.map { " (\($0.localizedDescription))" } ?? "")
                NotificationLog.decision(pane: nil, event: "authorization", outcome: ok ? "granted" : "refused",
                                         reason: "launch request \(self.launchAnswer)")
                self.refreshStatus()
            }
        }
    }

    /// Re-reads the authorization status and updates `authorized`; `done` gets the result on main.
    func refreshStatus(_ done: ((Bool) -> Void)? = nil) {
        let read: (@escaping (UNAuthorizationStatus) -> Void) -> Void
        if let statusReader { read = statusReader }
        else if let center, !SelfTest.enabled { read = { reply in center.getNotificationSettings { reply($0.authorizationStatus) } } }
        else { done?(authorized); return }
        read { st in
            DispatchQueue.main.async {
                let s = Self.describe(st)
                self.authorized = st == .authorized || st == .provisional
                if s != self.status {
                    let before = self.status
                    self.status = s
                    NotificationLog.decision(pane: nil, event: "authorization", outcome: "status",
                                             reason: "\(before ?? "first read") → \(s); posting \(self.authorized ? "allowed" : "not allowed")")
                }
                done?(self.authorized)
            }
        }
    }

    static func describe(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        @unknown default: return "unknown (\(s.rawValue))"
        }
    }

    func post(for pane: Pane, in wc: TerminalWindowController, state: Attention, title: String?, subtitle: String? = nil,
              body: String?, event: String = "attention") {
        let shownTitle = title ?? (state == .failed ? "Failed" : state == .waiting ? "Waiting for input" : state == .done ? "Finished" : "Terminal")
        // The second line is the pane's title unless the caller gives one, and is left out when it
        // would only repeat the first.
        let second = (subtitle ?? pane.title).trimmingCharacters(in: .whitespaces)
        let shownSubtitle = second.isEmpty || second == shownTitle ? nil : second
        func log(_ outcome: String, _ why: String) {
            NotificationLog.decision(pane: pane, event: event, outcome: outcome, reason: why, title: shownTitle,
                                     subtitle: shownSubtitle, body: body)
        }
        // While Dealer is in front the marks carry it: no desktop notification, whichever window
        // or pane (#71). A locked screen counts as away, so the banner reaches the lock screen.
        if Presence.inFront {
            let which = Presence.isKey(wc.window) ? "the pane's window is key" : "another Dealer window is key"
            return log("notification:suppressed", "Dealer is the active app (\(which)); the mark shows in the window")
        }
        if !SelfTest.enabled { NSApp.requestUserAttention(.informationalRequest) }
        if Bundle.main.bundleIdentifier == nil {
            return log("notification:suppressed", "unbundled (no bundle identifier, so no macOS notifications)"
                       + (SelfTest.enabled ? "" : "; dock bounce only"))
        }
        guard !SelfTest.enabled else { return log("notification:suppressed", "self-test mode") }
        guard let center else { return }
        guard authorized else {
            // Maybe allowed since the last read: ask again, and post if so.
            refreshStatus { [weak self, weak pane, weak wc] ok in
                guard let self, let pane, let wc else { return }
                if ok { self.deliver(center, pane: pane, in: wc, title: shownTitle, subtitle: shownSubtitle, body: body, event: event) }
                else { log("notification:suppressed", "not authorized (\(self.authorizationDescription)); dock bounce only") }
            }
            return
        }
        deliver(center, pane: pane, in: wc, title: shownTitle, subtitle: shownSubtitle, body: body, event: event)
    }

    // MARK: Withdrawing (#78)

    /// Panes (by id) that got a banner this run and haven't had it withdrawn. Only these are ever
    /// withdrawn, so a focus change on an unannounced pane never calls into UNUserNotificationCenter.
    private(set) var posted: Set<Int> = []
    /// Every withdrawal this run, in order (the self-test reads it; unbundled runs have no center).
    private(set) var withdrawals: [(id: String, event: String)] = []

    static func requestID(_ paneID: Int) -> String { "pane-\(paneID)" }

    /// Records that `pane` has a banner up. `deliver` calls it; the self-test calls it to stand in
    /// for a post, since self-test and unbundled runs never deliver one.
    func notePosted(_ pane: Pane) { posted.insert(pane.id) }

    /// Removes the pane's banner from Notification Center (delivered or still pending), if it got
    /// one. Called from `Pane.attention`'s didSet the moment the model clears, not after the fade.
    func withdraw(_ pane: Pane, event: String) {
        guard posted.remove(pane.id) != nil else { return }
        remove(Self.requestID(pane.id), event: event, pane: pane, why: "the pane's attention cleared")
    }

    /// Withdraws the banners of panes that are in no window any more (closed by hand, shell exit,
    /// a closed tab, workspace or window). Coalesced to the end of the current main-queue turn, so
    /// structural changes settle first.
    func withdrawClosed() {
        guard !posted.isEmpty, !sweepQueued else { return }
        sweepQueued = true
        DispatchQueue.main.async { [self] in
            sweepQueued = false
            let open = Set(Pane.all.map(\.1.id))
            for id in posted.subtracting(open).sorted() {
                posted.remove(id)
                remove(Self.requestID(id), event: "pane-closed", pane: nil, why: "pane \(id) closed")
            }
        }
    }
    private var sweepQueued = false

    private func remove(_ id: String, event: String, pane: Pane?, why: String) {
        withdrawals.append((id, event))
        let note: String
        if let center, !SelfTest.enabled {
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
            note = "removed from Notification Center"
        } else {
            note = Bundle.main.bundleIdentifier == nil ? "unbundled, so nothing to remove" : "self-test mode, so nothing to remove"
        }
        NotificationLog.decision(pane: pane, event: event, outcome: "notification:withdrawn", reason: "id \(id): \(why); \(note)")
    }

    private func deliver(_ center: UNUserNotificationCenter, pane: Pane, in wc: TerminalWindowController,
                         title shownTitle: String, subtitle: String?, body: String?, event: String) {
        // The authorization re-read is asynchronous: the mark may have cleared meanwhile (#78).
        guard pane.attention != .none else {
            return NotificationLog.decision(pane: pane, event: event, outcome: "notification:suppressed",
                                            reason: "the pane's attention cleared before the post went out", title: shownTitle,
                                            subtitle: subtitle, body: body)
        }
        let content = UNMutableNotificationContent()
        content.title = shownTitle
        content.subtitle = subtitle ?? ""
        content.body = body ?? ""
        content.userInfo = ["pane": pane.id]
        let id = "pane-\(pane.id)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            guard let error else { return }
            DispatchQueue.main.async { [weak pane] in
                NotificationLog.decision(pane: pane, event: event, outcome: "notification:error",
                                         reason: "UNUserNotificationCenter refused it: \(error.localizedDescription)")
            }
        }
        notePosted(pane)
        NotificationLog.decision(pane: pane, event: event, outcome: "notification:posted",
                                 reason: "id \(id), replacing any earlier one for this pane", title: shownTitle,
                                 subtitle: subtitle, body: body)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["pane"] as? Int
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id, let (wc, pane) = Pane.with(id: id) {
                NotificationLog.decision(pane: pane, event: "notification-click", outcome: "notification:clicked",
                                         reason: "revealing the pane (attention \(pane.attention.name))")
                wc.reveal(pane, cause: "notification-click")
            } else {
                NotificationLog.decision(pane: nil, event: "notification-click", outcome: "notification:clicked",
                                         reason: id.map { "pane \($0) no longer exists; nothing to reveal" } ?? "no pane id in the notification")
            }
            done()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.content.userInfo["pane"] as? Int
        DispatchQueue.main.async {
            NotificationLog.decision(pane: id.flatMap { Pane.with(id: $0)?.1 }, event: "notification", outcome: "notification:presented",
                                     reason: "shown as a banner while Dealer is frontmost")
        }
        done([.banner, .sound])
    }
}

// MARK: - Drawing (these only read `attention`)

extension PaneView {
    private static let ringName = "dealer.attentionRing"

    /// An accent ring over the whole pane while its state is outlined (#7: waiting and failed, plus
    /// done/unread when `[attention]` outlines them, #61). Its own layer, above the
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
    var attentionDotRect: CGRect { CGRect(x: closeRect.midX - 4, y: (bounds.height - 8) / 2, width: 8, height: 8) }

    /// The outline stays while hovering; only the dot gives way to the close button.
    func drawAttentionDot(hidden: Bool) {
        AttentionStyle.draw(attentionFade.shown, in: bounds, cornerRadius: Theme.Metrics.tabRadius,
                            dotRect: hidden ? nil : attentionDotRect, alpha: attentionFade.alpha)
    }
}

/// The one look for attention on chrome (tabs, workspace pills and sidebar rows), #7.
/// - waiting: a 1.5pt accent-blue outline on the element's outer edge, a faint blue tint and a blue dot;
/// - failed (#29): the same in red, and the dot carries a `!` so the state isn't color-only;
/// - done / unread: drawn like waiting when `Attention.outlined` says so (`[attention] done` /
///   `unread`, #61; done is outlined by default), else a muted dot only;
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
            if attention == .waiting { drawQuestion(in: dotRect, alpha: alpha) }
        }
    }

    /// A `?` knocked out of the waiting dot (#65), drawn like the `!`: since #61 an outlined *done*
    /// has the same blue as *waiting*, and the `?` is what says "this one needs an answer". A hook
    /// (stroked arc and stem, round caps) and the `!`'s point, in the chrome color. *done* stays a
    /// bare dot.
    static func drawQuestion(in r: CGRect, alpha: CGFloat = 1) {
        let q = questionGeometry(in: r)
        let hook = NSBezierPath()
        // Flipped views: angle 180° is the bowl's left, 270° its top, 360°+40° just right of bottom.
        hook.appendArc(withCenter: q.center, radius: q.radius, startAngle: 180, endAngle: 400, clockwise: false)
        hook.line(to: q.stemEnd)
        hook.lineWidth = q.width
        hook.lineCapStyle = .round
        hook.lineJoinStyle = .round
        Theme.chrome.withAlphaComponent(alpha).set()
        hook.stroke()
        NSBezierPath(ovalIn: q.point).fill()
    }

    /// The `?`'s parts in a dot of rect `r` (the self-test samples them, #65): the bowl's centre and
    /// radius (its stroke centreline), the stroke width (the `!`'s bar width), where the stem ends,
    /// and the point (the `!`'s point). Flipped views: y grows downward.
    static func questionGeometry(in r: CGRect) -> (center: CGPoint, radius: CGFloat, width: CGFloat, stemEnd: CGPoint, point: CGRect) {
        let w = max(r.width * 0.18, 1)
        let center = CGPoint(x: r.midX, y: r.minY + r.height * 0.34)
        // The stem's round cap ends at 58% of the height, where the `!`'s bar ends, leaving the same
        // gap above the point.
        return (center, r.height * 0.17, w, CGPoint(x: r.midX, y: r.minY + r.height * 0.58 - w / 2),
                CGRect(x: r.midX - w / 2, y: r.minY + r.height * 0.68, width: w, height: w))
    }

    /// A `!` knocked out of the failed dot: a bar and a point, as vector shapes so it stays crisp
    /// at 6–8pt. Drawn in the chrome color, so it reads as a hole in the red dot.
    static func drawBang(in r: CGRect, alpha: CGFloat = 1) {
        let bar = bangBar(in: r), w = bar.width
        Theme.chrome.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
        NSBezierPath(ovalIn: CGRect(x: r.midX - w / 2, y: r.minY + r.height * 0.68, width: w, height: w)).fill()
    }

    /// The `!`'s bar in a dot of rect `r` (the self-test samples it, #48). Flipped views: y grows
    /// downward. Bar from 18% to 58% of the height, point at 68–86%.
    static func bangBar(in r: CGRect) -> CGRect {
        let w = max(r.width * 0.18, 1)
        return CGRect(x: r.midX - w / 2, y: r.minY + r.height * 0.18, width: w, height: r.height * 0.40)
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
