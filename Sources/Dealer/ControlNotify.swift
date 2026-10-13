import AppKit

/// `dealer notify`: marks the pane with an attention state (Attention.swift). The mark is skipped
/// while the user is looking at the pane; a raised mark then posts a desktop notification unless
/// Dealer is active and the pane's window is key (any pane of that window, not just the focused one).
enum ControlNotify {
    /// `event` labels the call in the notification log: `notify`, or the hook's `claude:<event>`.
    static func post(pane: Pane, in wc: TerminalWindowController, state: String, title: String?, body: String?,
                     event: String = "notify") throws {
        guard let a = Attention(name: state) else {
            throw ControlHandler.Failure(message: "bad state '\(state)' (expected unread, done, waiting, failed or none)")
        }
        wc.setAttention(a, on: pane, title: title, body: body, event: event)
    }
}
