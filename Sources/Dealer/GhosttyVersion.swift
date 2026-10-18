import AppKit
import GhosttyKit

/// Checks that the linked libghostty is the Ghostty commit Dealer is pinned to (#35, #20).
/// `ghostty.h` is Ghostty's unstable internal API: header drift fails the build, but a framework
/// from another commit can compile and still behave differently, so the app checks at launch.
enum GhosttyVersion {
    /// Must equal `scripts/ghostty.version`; the self-test enforces that.
    static let pinnedCommit = "81598385d608dda4946093d6d6a234d204a2f225"

    /// The version libghostty was built with, e.g. `1.3.2-main-+243f7df7c` (git describe).
    static var linked: String {
        let info = ghostty_info()
        guard let p = info.version else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(info.version_len)), as: UTF8.self)
    }

    /// The abbreviated commit after the `+`, or nil when the build recorded none (no git).
    static func commit(of version: String) -> String? {
        guard let plus = version.lastIndex(of: "+") else { return nil }
        let c = version[version.index(after: plus)...]
        return c.count >= 7 && c.allSatisfy(\.isHexDigit) ? String(c) : nil
    }

    /// A user-facing description of the mismatch, or nil when `version` is the pinned commit or
    /// records no commit at all (that case is only logged).
    static func mismatch(version: String, pin: String = pinnedCommit) -> String? {
        guard let c = commit(of: version) else { return nil }
        if pin.lowercased().hasPrefix(c.lowercased()) { return nil }
        return "GhosttyKit is Ghostty \(version), but Dealer is pinned to \(pin.prefix(9)) "
            + "(scripts/ghostty.version). Expect broken or odd terminal behavior. "
            + "Rebuild it with scripts/build-ghosttykit.sh."
    }

    /// The current mismatch, shown in every window's banner until dismissed.
    static var problem: String?
    static var dismissed = false

    /// Called once from `GhosttyRuntime.start()`, after `ghostty_init`.
    static func check() {
        let v = linked
        problem = mismatch(version: v)
        if let problem {
            NSLog("Dealer: WARNING: %@", problem)
        } else if commit(of: v) == nil {
            NSLog("Dealer: libghostty version \"%@\" records no commit; can't check it against the pin %@", v, pinnedCommit)
        }
    }

    /// `scripts/ghostty.version` in the source tree this binary was compiled from. Only meaningful
    /// for builds run in place (self-test, merge.sh), not for a copied app bundle.
    static func sourcePin() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/ghostty.version")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// A loud banner at the top of the deck area while `GhosttyVersion.problem` is set.
final class GhosttyVersionBannerView: FlippedView, ThemeApplying {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton(title: "Dismiss", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Theme.Metrics.overlayRadius
        layer?.borderWidth = 2
        label.font = Theme.Fonts.paneBar
        applyTheme()
        label.maximumNumberOfLines = 3
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        [label, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.attentionFailed.cgColor
        label.textColor = Theme.text
    }

    var message: String { label.stringValue }

    func update() {
        label.stringValue = GhosttyVersion.problem ?? ""
        isHidden = GhosttyVersion.problem == nil || GhosttyVersion.dismissed
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        closeButton.frame = CGRect(x: bounds.width - pad - 70, y: pad, width: 70, height: 22)
        label.frame = CGRect(x: pad, y: pad, width: max(closeButton.frame.minX - 2 * pad, 0), height: bounds.height - 2 * pad)
    }

    @objc func dismiss() {
        GhosttyVersion.dismissed = true
        isHidden = true
    }
}

extension TerminalWindowController {
    /// The window's Ghostty version banner, if one has been created.
    var ghosttyBanner: GhosttyVersionBannerView? {
        contentView.subviews.lazy.compactMap { $0 as? GhosttyVersionBannerView }.first
    }

    /// Called from `layoutSettingsBanner` (every layout pass). Creates the banner only when needed.
    func layoutGhosttyBanner() {
        guard GhosttyVersion.problem != nil || ghosttyBanner != nil else { return }
        let banner = ghosttyBanner ?? GhosttyVersionBannerView()
        banner.update()
        guard !banner.isHidden else { return }
        let area = deckArea
        let w = min(area.width - 24, 640)
        banner.frame = CGRect(x: area.midX - w / 2, y: area.minY + 12, width: w, height: 64)
        // Stay above the deck views, but below the settings banner (which then keeps its own
        // "last subview" spot without the two re-adding themselves on every pass).
        let above = contentView.subviews.drop { $0 !== banner }.dropFirst()
        if banner.superview !== contentView || above.contains(where: { !($0 is SettingsBannerView) }) {
            contentView.addSubview(banner, positioned: .above, relativeTo: nil)
        }
    }
}
