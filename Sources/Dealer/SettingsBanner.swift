import AppKit

/// A non-modal banner at the bottom of the deck area listing settings.toml problems (#10).
/// It shows while `Settings.problems` is non-empty, until the user dismisses that set of problems.
final class SettingsBannerView: FlippedView, ThemeApplying {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open Settings File", target: nil, action: nil)
    private let closeButton = NSButton(title: "Dismiss", target: nil, action: nil)
    /// The problems the user dismissed; a different set shows the banner again.
    private(set) var dismissed: [String] = []
    private(set) var message = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Theme.Metrics.overlayRadius
        layer?.borderWidth = 1
        label.font = Theme.Fonts.paneBar
        applyTheme()
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        for b in [openButton, closeButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        openButton.action = #selector(open)
        closeButton.action = #selector(dismiss)
        [label, openButton, closeButton].forEach(addSubview)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.attentionWaiting.cgColor
        label.textColor = Theme.text
    }

    /// settings.toml problems, then ghostty config problems (#33), each with its source.
    static var problems: [String] { Settings.problems + GhosttyRuntime.shared.configProblems.map { "ghostty: " + $0 } }

    /// Whether the banner wants to show for the current problems.
    var wanted: Bool { !Self.problems.isEmpty && Self.problems != dismissed }

    func update() {
        let s = Settings.problems, g = GhosttyRuntime.shared.configProblems
        func count(_ n: Int) -> String { n == 1 ? "a problem" : "\(n) problems" }
        var heads: [String] = []
        if !s.isEmpty { heads.append("settings.toml has \(count(s.count)); defaults are used for the bad parts.") }
        if !g.isEmpty { heads.append("The ghostty config has \(count(g.count)); the previous config stays in effect.") }
        let p = Self.problems
        message = p.isEmpty ? "" : heads.joined(separator: " ") + "\n" + p.prefix(3).joined(separator: "\n") + (p.count > 3 ? "\n…" : "")
        label.stringValue = message
        openButton.title = s.isEmpty && !g.isEmpty ? "Open Ghostty Config" : "Open Settings File"
        isHidden = !wanted
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let bw: CGFloat = 130
        closeButton.frame = CGRect(x: bounds.width - pad - 70, y: pad, width: 70, height: 22)
        openButton.frame = CGRect(x: closeButton.frame.minX - 6 - bw, y: pad, width: bw, height: 22)
        label.frame = CGRect(x: pad, y: pad, width: max(openButton.frame.minX - 2 * pad, 0), height: bounds.height - 2 * pad)
    }

    @objc private func open() {
        if Settings.problems.isEmpty, !GhosttyRuntime.shared.configProblems.isEmpty {
            GhosttyRuntime.openConfigFile()
        } else {
            Settings.openFile()
        }
    }

    func undismiss() { dismissed = [] }

    @objc func dismiss() {
        dismissed = Self.problems
        isHidden = true
    }
}

extension TerminalWindowController {
    /// Keeps the settings banner at the bottom of the deck area, above the terminals.
    /// Called from `layoutWorkspaceSidebar` (every layout pass).
    func layoutSettingsBanner() {
        let banner = settingsBanner
        banner.update()
        guard !banner.isHidden else { return }
        let area = deckArea
        let w = min(area.width - 24, 640)
        banner.frame = CGRect(x: area.midX - w / 2, y: area.maxY - 96 - 12, width: w, height: 96)
        // Deck views added later in the pass would cover it; keep it on top.
        if banner.superview !== contentView || contentView.subviews.last !== banner {
            contentView.addSubview(banner, positioned: .above, relativeTo: nil)
        }
    }
}

// App menu actions (Dealer › Open Settings File… / Reload Configuration).
extension AppDelegate {
    @objc func openSettingsFile(_ sender: Any?) { Settings.openFile() }

    /// ⌘⇧, (#33): reloads the ghostty config (terminals and chrome re-theme live, nothing restarts)
    /// and settings.toml. Ghostty's `reload_config` keybind lands here too.
    @objc func reloadConfiguration(_ sender: Any?) {
        GhosttyRuntime.shared.reloadConfig()
        Settings.reload(force: true)
        Settings.watch()
        // A forced reload re-shows problems the user had dismissed.
        windowControllers.forEach { $0.settingsBanner.undismiss(); $0.layoutNow() }
    }
}
