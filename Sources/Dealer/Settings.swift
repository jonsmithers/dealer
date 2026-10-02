import Foundation

/// User settings. Everything reads and writes them through this one accessor so the backing store
/// can change (#10 moves it to ~/.config/dealer/settings.toml); nothing else reads UserDefaults for
/// these keys. Writes post `Settings.didChange`, which open windows observe to apply changes live.
enum Settings {
    static let didChange = Notification.Name("DealerSettingsDidChange")

    /// Self-test mode keeps settings in memory, so tests never write the user's preferences.
    private static var memory: [String: String] = [:]

    private static func string(_ key: String) -> String? {
        SelfTest.enabled ? memory[key] : UserDefaults.standard.string(forKey: key)
    }

    private static func set(_ value: String, for key: String) {
        guard string(key) != value else { return }
        if SelfTest.enabled { memory[key] = value } else { UserDefaults.standard.set(value, forKey: key) }
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": key])
    }

    /// Where the workspace switcher lives (#8). Stored as `workspaceSwitcher` = `sidebar` | `top`
    /// (`defaults write dev.smithers.dealer workspaceSwitcher top`); anything else means sidebar.
    static var workspaceSwitcher: WorkspaceSwitcherStyle {
        get { string("workspaceSwitcher").flatMap(WorkspaceSwitcherStyle.init(rawValue:)) ?? .sidebar }
        set { set(newValue.rawValue, for: "workspaceSwitcher") }
    }

    /// Load Dealer's Claude Code hooks into every `claude` started in a pane (#12, ClaudeHooks.swift).
    /// Default on. Read when a pane's shell starts. Until #10 lands it's the UserDefaults key
    /// `agentInjectHooks` (`defaults write dev.smithers.dealer agentInjectHooks -bool false`);
    /// #10 maps it to `[agent] inject_hooks` in settings.toml.
    static var agentInjectHooks: Bool {
        get { string("agentInjectHooks").map { !["0", "false", "no", "off"].contains($0.lowercased()) } ?? true }
        set { set(newValue ? "true" : "false", for: "agentInjectHooks") }
    }
}
