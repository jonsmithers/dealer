import AppKit

/// A non-modal banner at the bottom of the deck area listing settings.toml problems (#10).
/// It shows while `Settings.problems` is non-empty, until the user dismisses that set of problems.
final class SettingsBannerView: FlippedView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open Settings File", target: nil, action: nil)
    private let closeButton = NSButton(title: "Dismiss", target: nil, action: nil)
    /// The problems the user dismissed; a different set shows the banner again.
    private(set) var dismissed: [String] = []
    private(set) var message = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = Theme.Metrics.overlayRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.attentionWaiting.cgColor
        label.font = Theme.Fonts.paneBar
        label.textColor = Theme.text
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

    /// Whether the banner wants to show for the current problems.
    var wanted: Bool { !Settings.problems.isEmpty && Settings.problems != dismissed }

    func update() {
        let p = Settings.problems
        message = p.isEmpty ? "" : "settings.toml has \(p.count == 1 ? "a problem" : "\(p.count) problems"); "
            + "defaults are used for the bad parts.\n" + p.prefix(3).joined(separator: "\n") + (p.count > 3 ? "\n…" : "")
        label.stringValue = message
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

    @objc private func open() { Settings.openFile() }

    func undismiss() { dismissed = [] }

    @objc func dismiss() {
        dismissed = Settings.problems
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

// App menu actions (Dealer › Open Settings File… / Reload Settings).
extension AppDelegate {
    @objc func openSettingsFile(_ sender: Any?) { Settings.openFile() }

    @objc func reloadSettings(_ sender: Any?) {
        Settings.reload(force: true)
        Settings.watch()
        // A forced reload re-shows problems the user had dismissed.
        windowControllers.forEach { $0.settingsBanner.undismiss(); $0.layoutNow() }
    }
}
