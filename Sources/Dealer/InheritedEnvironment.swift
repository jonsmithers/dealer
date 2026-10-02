import Foundation

/// Dealer passes its own environment down to every pane's shell (ghostty builds the child
/// environment from the process environment). When Dealer is started from inside another
/// terminal's shell, that environment carries the *other* terminal's identity, which then
/// misroutes tools in Dealer's panes. Seen in practice (#12): a Dealer launched from a cmux
/// shell gave every pane `CMUX_SURFACE_ID`, so a `claude` launcher that branches on it ran
/// `cmux claude-teams`, and Claude's hooks reported to cmux instead of Dealer.
///
/// `scrub()` runs once at app launch, after the CLI dispatch in main.swift (so `dealer` invoked
/// from a hook keeps its environment).
enum InheritedEnvironment {
    /// cmux's per-terminal `claude`/`codex` shim directories (`…/cmux-cli-shims/<surface>`).
    static func isForeignShimDirectory(_ entry: Substring) -> Bool {
        entry.contains("/cmux-cli-shims/") || entry.hasSuffix("/cmux-cli-shims")
    }

    static func scrub() {
        // A parent Claude Code session's identity (ClaudeHooks.swift).
        ClaudeHooks.scrubInheritedSessionEnvironment()
        // cmux's terminal identity: every CMUX_* variable, as cmux's own wrapper does on pass-through.
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("CMUX_") {
            unsetenv(key)
        }
        // cmux's per-surface shim directories on PATH.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            let kept = path.split(separator: ":", omittingEmptySubsequences: false).filter { !isForeignShimDirectory($0) }
            setenv("PATH", kept.joined(separator: ":"), 1)
        }
    }
}
