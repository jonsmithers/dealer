import AppKit

/// The one switch for close/quit confirmations (#38). Self-test and README-demo mode (demos run
/// in self-test mode) never show them: a sheet or modal alert left on screen swallows every later
/// click and drag in the run, and stays up on the user's screen. They're accepted and logged.
enum Confirmation {
    static var autoAccept: Bool { SelfTest.enabled }
    /// Confirmations accepted automatically in this process, oldest first (the self-test reads it).
    private(set) static var autoAccepted: [String] = []

    /// True when the caller should go ahead without asking; logs the skipped question.
    static func skip(_ message: String, _ info: String) -> Bool {
        guard autoAccept else { return false }
        autoAccepted.append(message)
        print("      (auto-accepted confirmation: \(message) \(info))")
        return true
    }
}
