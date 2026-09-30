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

    static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }

    init?(name: String) {
        switch name.lowercased() {
        case "none", "clear": self = .none
        case "unread", "info": self = .unread
        case "done", "stop", "finished": self = .done
        case "waiting", "wait", "input": self = .waiting
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .none: return "none"
        case .unread: return "unread"
        case .done: return "done"
        case .waiting: return "waiting"
        }
    }

    /// Only `waiting` gets outlines (pane ring, tab and workspace outline); the rest get a dot.
    var outlined: Bool { self == .waiting }

    /// Badge/ring colour, or nil for none.
    var color: NSColor? {
        switch self {
        case .none: return nil
        case .unread, .done: return Theme.attentionDone
        case .waiting: return Theme.attentionWaiting
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

    @objc func jumpToNextUnread(_ sender: Any?) {
        guard let (wc, pane) = Self.nextUnread(after: focusedPane) else { return NSSound.beep() }
        wc.reveal(pane)
    }

    /// Brings the pane's window forward and focuses it; focusing clears its attention.
    func reveal(_ pane: Pane) {
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
        content.title = title ?? (state == .waiting ? "Waiting for input" : state == .done ? "Finished" : "Terminal")
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
        guard let layer else { return }
        let existing = layer.sublayers?.first { $0.name == Self.ringName }
        guard let a = pane?.attention, a.outlined, let color = a.color else {
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
        CATransaction.commit()
    }
}

extension TabButton {
    /// Where the badge sits: the close button's slot, which only shows on hover.
    var attentionDotRect: CGRect { CGRect(x: bounds.width - 17, y: (bounds.height - 8) / 2, width: 8, height: 8) }

    /// The outline stays while hovering; only the dot gives way to the close button.
    func drawAttentionDot(hidden: Bool) {
        AttentionStyle.draw(attention, in: bounds, cornerRadius: Theme.Metrics.tabRadius, dotRect: hidden ? nil : attentionDotRect)
    }
}

/// The one look for attention on chrome (tabs, workspace pills and sidebar rows), #7.
/// - waiting: a 1.5pt accent-blue outline on the element's outer edge, a faint blue tint and a blue dot;
/// - done / unread: a muted dot only;
/// - none: nothing.
/// Call it last in `draw(_:)`, so the outline sits on top of the element's own fill.
enum AttentionStyle {
    static let outlineWidth: CGFloat = 1.5

    static func draw(_ attention: Attention, in rect: CGRect, cornerRadius: CGFloat, dotRect: CGRect?) {
        guard let color = attention.color else { return }
        if attention.outlined {
            let inset = rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2)
            let r = max(cornerRadius - outlineWidth / 2, 0)
            let path = NSBezierPath(roundedRect: inset, xRadius: r, yRadius: r)
            color.withAlphaComponent(0.10).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = outlineWidth
            path.stroke()
        }
        if let dotRect {
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}
