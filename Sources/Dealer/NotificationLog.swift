import AppKit

/// Opt-in log of every attention and notification decision (#56), so "why didn't Dealer notify
/// me?" can be answered afterwards. On with `[notifications] log = true`; read live, so turning it
/// on takes effect at the next event. Every "no" carries its reason.
///
/// One line per event, appended to `/tmp/dealer-notifications.log` (renamed to `.1` once it passes
/// `maxBytes`, one old file kept):
///
///     2026-10-12T10:22:33.123-07:00 claude:permission attention:set pane=12 ws="api" tab="claude" reason="none → waiting" title="Claude Code" body="Permission: Bash"
///
/// Never logs environment values or terminal contents. Titles and bodies are truncated.
/// Callers are on main (lines name panes by their model); the file I/O runs on a serial queue.
enum NotificationLog {
    static let defaultPath = "/tmp/dealer-notifications.log"
    /// The self-test points this into a temp dir, so it never touches the user's log.
    static var path = SelfTest.enabled
        ? NSTemporaryDirectory() + "dealer-notifications-test-\(getpid()).log" : defaultPath
    /// Rotation threshold. The self-test shrinks it to check rotation.
    static var maxBytes = 5_000_000
    static let fieldLimit = 120

    static var isEnabled: Bool { Settings.notificationLog }

    /// Set while `reveal` runs, so a clear by the focus it causes is logged as ⌘⇧U or a click
    /// rather than a plain focus change. Main thread only.
    static var clearCause: String?

    private static let queue = DispatchQueue(label: "dev.smithers.dealer.notification-log")
    private static let clock: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// Records one decision. `event` is the input (`bell`, `notify`, `claude:stop`, `job-done`,
    /// `focus`, …); `outcome` is what happened (`attention:set`, `attention:skipped`,
    /// `notification:suppressed`, …); `reason` says why, and is required for every "no".
    static func decision(pane: Pane?, event: String, outcome: String, reason: String? = nil,
                         title: String? = nil, body: String? = nil) {
        guard isEnabled else { return }
        var parts = [clock.string(from: Date()), event, outcome]
        if let pane { parts.append(identity(pane)) }
        if let reason { parts.append("reason=" + quote(reason)) }
        if let title { parts.append("title=" + quote(title)) }
        if let body { parts.append("body=" + quote(body)) }
        write(parts.joined(separator: " ") + "\n")
    }

    /// The pane as `dealer list` shows it: its id, plus the workspace and tab names the user saw.
    static func identity(_ pane: Pane) -> String {
        guard let loc = ControlHandler.locate(pane) else { return "pane=\(pane.id) (in no window)" }
        let ws = loc.ws.map { "ws=" + quote($0.displayName, limit: 60) } ?? "ws=?"
        let tab = loc.tab.map { "tab=" + quote($0.title, limit: 60) } ?? "tab=?"
        return "pane=\(pane.id) \(ws) \(tab)"
    }

    /// Double-quoted, truncated, on one line.
    static func quote(_ s: String, limit: Int = fieldLimit) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: " ")
        if t.count > limit { t = String(t.prefix(limit)) + "…" }
        return "\"" + t + "\""
    }

    /// Whether the user's view of the window matches "looking": logged with skips and clears, so a
    /// locked screen or a covered window shows up next to the decision.
    static func context(_ wc: TerminalWindowController?) -> String {
        let key = wc?.window?.isKeyWindow ?? false
        let visible = wc?.window.map(WindowVisibility.isVisible) ?? false
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return "app \(NSApp.isActive ? "active" : "inactive"), window \(key ? "key" : "not key")"
            + "\(visible ? "" : ", window hidden")\(locked ? ", screen locked" : "")"
    }

    /// Waits for queued writes (self-test and diagnostics).
    static func flush() { queue.sync {} }

    /// Size of the current file, for `dealer diagnose`.
    static var fileSize: Int? {
        flush()
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    }

    // MARK: Lifecycle

    /// Writes a header line when the setting turns on (at launch or on a settings reload), with the
    /// facts every later line depends on: bundled or not, and the authorization status.
    static func start() {
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { n in
            let keys = n.userInfo?["keys"] as? Set<String> ?? []
            if keys.contains("notifications.log"), isEnabled { header("log turned on") }
        }
        if isEnabled { header("Dealer launched") }
    }

    private static func header(_ why: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let bundled = Bundle.main.bundleIdentifier == nil ? "unbundled (no macOS notifications)" : "bundled"
        decision(pane: nil, event: "log", outcome: "started",
                 reason: "\(why); Dealer \(version), \(bundled), authorization: \(AttentionNotifier.shared.authorizationDescription)")
        AttentionNotifier.shared.refreshStatus()
    }

    // MARK: File

    private static func write(_ line: String) {
        let path = self.path, cap = maxBytes
        queue.async { append(line, to: path, cap: cap) }
    }

    private static func append(_ line: String, to path: String, cap: Int) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? nil, size > 0, size + line.utf8.count > cap {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        // O_NOFOLLOW: /tmp is shared, so don't follow a planted symlink. 0600: titles stay private.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
