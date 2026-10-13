import AppKit

/// `dealer notify`: marks the pane with an attention state (Attention.swift) and lets the
/// attention notifier post a desktop notification when the user isn't looking at it.
enum ControlNotify {
    /// `event` labels the call in the notification log: `notify`, or the hook's `claude:<event>`.
    static func post(pane: Pane, in wc: TerminalWindowController, state: String, title: String?, body: String?,
                     event: String = "notify") throws {
        guard let a = Attention(name: state) else {
            throw ControlHandler.Failure(message: "bad state '\(state)' (expected unread, done, waiting or none)")
        }
        wc.setAttention(a, on: pane, title: title, body: body, event: event)
    }
}
