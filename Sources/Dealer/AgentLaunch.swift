import AppKit

/// Launch presets (#4): Shell > New Agent Pane starts a coding agent in a new pane beside the
/// focused one, optionally in a fresh git worktree.
///
/// The command is `Settings.agentCommand`: `[agent] command` in settings.toml (default `claude`),
/// overridden by `DEALER_AGENT_COMMAND`. It is typed into the new pane's shell, so the shell stays
/// when the agent exits.
enum AgentPreset {
    /// Set by the self-test so it doesn't start a real agent.
    static var commandOverride: String?

    static var command: String {
        if let c = commandOverride { return c }
        return Settings.agentCommand
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell line that creates a worktree beside the repo on a new branch, cd's in, and runs
    /// the agent. The shell does the work, so any git error shows up in the pane.
    static func worktreeCommand(repoRoot: String, name: String) -> String {
        let root = URL(fileURLWithPath: repoRoot)
        let path = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".worktrees")
            .appendingPathComponent(name).path
        return "git -C \(shellQuote(repoRoot)) worktree add -b \(shellQuote(name)) \(shellQuote(path)) && cd \(shellQuote(path)) && \(command)"
    }
}

extension TerminalWindowController {
    /// Splits the focused pane and starts the agent in the new pane. Returns the new pane.
    @discardableResult
    func newAgentPane(beside pane: Pane, inWorktree: Bool = false) -> Pane? {
        var line = AgentPreset.command
        if inWorktree {
            guard let pwd = pane.pwd, let git = GitInfo.lookup(pwd) else { return nil }
            let stamp = Int(Date().timeIntervalSince1970) % 1_000_000
            line = AgentPreset.worktreeCommand(repoRoot: git.root, name: "agent-\(stamp)")
        }
        split(pane, side: .right)
        guard let new = focusedPane, new !== pane else { return nil }
        // The pty buffers this until the shell reads its first line.
        new.surface.typeText(line + "\r")
        return new
    }

    @objc func newAgentPane(_ sender: Any?) {
        guard let p = focusedPane, newAgentPane(beside: p) != nil else { return NSSound.beep() }
    }

    @objc func newAgentPaneInWorktree(_ sender: Any?) {
        guard let p = focusedPane, newAgentPane(beside: p, inWorktree: true) != nil else { return NSSound.beep() }
    }
}

extension SurfaceView {
    /// Writes bytes to the pty as if typed (not a bracketed paste), so "\r" presses Enter.
    /// Goes through ghostty's `text:` binding action, which parses Zig string escapes.
    func typeText(_ text: String) {
        var escaped = "text:"
        for b in text.utf8 {
            switch b {
            case UInt8(ascii: "\\"): escaped += "\\\\"
            case 0..<0x20, 0x7f: escaped += String(format: "\\x%02x", b)
            default: escaped.unicodeScalars.append(UnicodeScalar(b))
            }
        }
        perform(escaped)
    }
}
