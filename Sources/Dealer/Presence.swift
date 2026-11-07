import AppKit

/// Is the user at the machine with Dealer in front (#71)? One place for the facts every attention
/// decision uses:
/// - desktop notifications are suppressed only while Dealer is `inFront` (active, screen unlocked);
/// - a window's user is present (`TerminalWindowController.userPresent`) when Dealer is in front
///   and that window is key; a focus change clears a mark only then;
/// - `isLookingAt(pane)` adds that the pane is focused and drawn; marking skips only that pane.
/// A locked screen counts as away everywhere (the user's call on #71).
enum Presence {
    struct Facts {
        var appActive: Bool
        var screenLocked: Bool
        /// The window that counts as key (nil: none).
        var keyWindow: NSWindow?
    }

    /// Self-test seam: when set, every decision uses these facts instead of AppKit and the session.
    static var override: Facts?

    /// A self-test run without an `override` takes the user as away (#100): Dealer not active, no
    /// key window, unlocked. Whether a run's app is really active isn't up to the run (a click,
    /// ⌘-Tab, an app switch), and an active run skipped marks on its focused pane (`isLookingAt`),
    /// so steps passed or failed by chance. Steps about presence set `override`.
    static let selfTestFacts = Facts(appActive: false, screenLocked: false, keyWindow: nil)

    /// The facts in force instead of AppKit's and the session's, if any.
    private static var fixed: Facts? { override ?? (SelfTest.enabled ? selfTestFacts : nil) }

    /// Self-test runs count as away (`selfTestFacts`). With no `override`, a focus change there still
    /// counts as seen, as it did before #71, so steps that clear marks by focusing keep their meaning.
    static var focusCountsAsSeen: Bool { SelfTest.enabled && override == nil }

    static var appActive: Bool { fixed?.appActive ?? NSApp.isActive }

    static var screenLocked: Bool {
        if let o = fixed { return o.screenLocked }
        return (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Dealer is the active app and the screen is unlocked: no desktop notifications, the marks carry it.
    static var inFront: Bool { appActive && !screenLocked }

    static func isKey(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        if let o = fixed { return o.keyWindow === w }
        return w.isKeyWindow
    }

    /// Listens for the screen being unlocked (called once at launch).
    static func start() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                                            queue: .main) { _ in screenUnlocked() }
    }

    /// Back at the machine: the focused pane of the key window is read, as when the window becomes
    /// key (`windowDidBecomeKey`), with the same fade. The window usually stayed key while locked.
    static func screenUnlocked() {
        for wc in AppDelegate.shared.windowControllers where wc.userPresent() {
            if let p = wc.focusedPane { wc.clearAttention(p, cause: "screen-unlocked") }
        }
    }
}

extension TerminalWindowController {
    /// The user is here and this window has the keyboard: Dealer in front, unlocked, window key.
    func userPresent() -> Bool { Presence.inFront && Presence.isKey(window) }

    /// True when the user can currently see this pane with the keyboard in it.
    func isLookingAt(_ pane: Pane) -> Bool {
        pane === focusedPane && pane.surface.isEffectivelyVisible && userPresent()
    }
}
