import AppKit

// MARK: - Self-test section: what Theme reads from the ghostty config (issue #23)

extension TerminalWindowController {
    func themeSelfTestSteps(_ t: SelfTestKit) {
        t.step("theme: the 16 ANSI palette colors are read from the ghostty config", nil, {
            // Ghostty always has a palette (its built-in default when no theme sets one), so an
            // empty or short list means the C getter or the struct layout drifted.
            Theme.ansi.count == 16 ? nil : "expected 16 palette colors, got \(Theme.ansi.count)"
        }) {}
    }
}
