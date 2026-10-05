import Foundation

/// Automatic Claude Code hooks (#12). Dealer ships a tiny Claude Code plugin
/// (`Resources/claude-plugin/dealer`: `hooks/hooks.json` + `hooks/dealer-hook.sh`) and names it in
/// every pane's `CLAUDE_CODE_PLUGIN_DIRS`, so any `claude` started in a pane (typed, aliased, by
/// absolute path, or by New Agent Pane) reports waiting/done through `dealer notify`.
/// An environment variable rather than a `claude` wrapper on PATH: shell rc files that prepend
/// PATH (e.g. `~/.local/bin`, where Claude's installer puts it) can't shadow it, and it never
/// rewrites argv. The research and the decision are in docs/claude-code-states.md.
enum ClaudeHooks {
    static let pluginDirsVariable = "CLAUDE_CODE_PLUGIN_DIRS"
    static let errorStateVariable = "DEALER_CLAUDE_ERROR_STATE"

    /// The bundled plugin: `Contents/Resources/claude-plugin/dealer` in Dealer.app. For a dev build
    /// (`.build/<config>/Dealer`), the repository's `Resources/claude-plugin/dealer`.
    static let pluginDirectory: String? = {
        let fm = FileManager.default
        func valid(_ dir: String) -> Bool { fm.fileExists(atPath: dir + "/hooks/hooks.json") }
        if let res = Bundle.main.resourcePath, valid(res + "/claude-plugin/dealer") { return res + "/claude-plugin/dealer" }
        guard let exe = Bundle.main.executablePath else { return nil }
        var dir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/claude-plugin/dealer").path
            if valid(candidate) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    /// Claude Code exits at startup when managed settings set `disableSideloadFlags` and
    /// CLAUDE_CODE_PLUGIN_DIRS is set, so Dealer leaves the variable out then. Only the file-based
    /// managed settings can be checked; MDM and server-delivered policy can't (use the off switch).
    static var managedSettingsBlockPlugins: Bool {
        let path = "/Library/Application Support/ClaudeCode/managed-settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["disableSideloadFlags"] as? Bool == true
    }

    /// Session-identity variables a running Claude Code exports to its children. When Dealer itself
    /// is started from inside a Claude Code session (e.g. an agent testing it), panes would inherit
    /// them, and a `claude` there then believes it's a child session (it turns transcript saving
    /// off, among other things). The list is cmux's `clear_inherited_claude_session_identity_env`
    /// (Resources/bin/cmux-claude-wrapper, cmux 7d78b6e4cb). Auth-selection variables are left alone.
    static let inheritedSessionVariables = [
        "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_PARENT_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT",
    ]

    /// Removes those variables from the app's own environment, which every pane's shell inherits
    /// (ghostty builds the child environment from it). Runs once at app launch, never in CLI mode,
    /// so `dealer` invoked from a hook keeps its environment.
    static func scrubInheritedSessionEnvironment() {
        inheritedSessionVariables.forEach { unsetenv($0) }
    }

    /// Environment to add to a pane's shell. Appends to a CLAUDE_CODE_PLUGIN_DIRS the user already
    /// set rather than replacing it.
    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment,
                            enabled: Bool = Settings.agentInjectHooks,
                            plugin: String? = pluginDirectory,
                            blocked: Bool = managedSettingsBlockPlugins) -> [String: String] {
        guard enabled, !blocked, let plugin else { return [:] }
        // What the plugin's StopFailure hook reports (#29, `[agent] errors_as_failed`).
        let errorState = [errorStateVariable: Settings.agentErrorsAsFailed ? "failed" : "waiting"]
        let existing = (inherited[pluginDirsVariable] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if existing.contains(plugin) { return errorState.merging([pluginDirsVariable: existing.joined(separator: ":")]) { $1 } }
        return errorState.merging([pluginDirsVariable: (existing + [plugin]).joined(separator: ":")]) { $1 }
    }
}
