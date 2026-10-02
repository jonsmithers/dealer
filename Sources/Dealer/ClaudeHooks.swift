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

    /// Environment to add to a pane's shell. Appends to a CLAUDE_CODE_PLUGIN_DIRS the user already
    /// set rather than replacing it.
    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment,
                            enabled: Bool = Settings.agentInjectHooks,
                            plugin: String? = pluginDirectory,
                            blocked: Bool = managedSettingsBlockPlugins) -> [String: String] {
        guard enabled, !blocked, let plugin else { return [:] }
        let existing = (inherited[pluginDirsVariable] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if existing.contains(plugin) { return [pluginDirsVariable: existing.joined(separator: ":")] }
        return [pluginDirsVariable: (existing + [plugin]).joined(separator: ":")]
    }
}
