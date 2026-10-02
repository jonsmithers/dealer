import AppKit

// Per-workspace and per-tab colors (#9).
//
// A color is an optional NSColor on `Workspace.color` / `Tab.color`, persisted as "#rrggbb".
// It shows as a chip plus a faint tint on the workspace's sidebar row / top-bar pill, and as the
// underline plus a faint tint on a tab button (overriding the deck color there). While a colored
// workspace is active, a hairline runs along the top of the deck area. Colors are never drawn as
// an outline: that look belongs to #7's attention (AttentionStyle), and the tint is inset so the
// attention outline always sits outside it.

extension NSColor {
    /// "#rgb", "#rrggbb" (the "#" is optional). Nil for anything else.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// "#rrggbb" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    /// Same color for display purposes (compares the hex form).
    func sameColor(as other: NSColor?) -> Bool { other.map { $0.hexString == hexString } ?? false }
}

extension Theme {
    /// The preset swatches offered in color menus, tuned per light/dark so chips and tints read
    /// on either chrome. `[colors] palette` in settings.toml replaces them (named by number).
    static var swatches: [(name: String, color: NSColor)] {
        if let custom = Settings.colorPalette, !custom.isEmpty {
            return custom.enumerated().map { ("\($0.offset + 1)", $0.element) }
        }
        let dark: [(String, String)] = [
            ("red", "#e06c75"), ("orange", "#e5a46b"), ("yellow", "#e5c76b"), ("green", "#98c379"),
            ("teal", "#56c2b5"), ("blue", "#61afef"), ("purple", "#c678dd"), ("pink", "#e584b6"),
        ]
        let light: [(String, String)] = [
            ("red", "#c8414c"), ("orange", "#c66a1c"), ("yellow", "#a88400"), ("green", "#3f8f3a"),
            ("teal", "#11887a"), ("blue", "#2f6fd0"), ("purple", "#8e44ad"), ("pink", "#c2407e"),
        ]
        return (isDark ? dark : light).map { ($0.0, NSColor(hex: $0.1)!) }
    }

    /// The faint fill behind a colored row, pill or tab. Low enough that `Theme.text` stays readable
    /// on it in light and dark themes.
    static func colorTint(_ c: NSColor) -> NSColor { c.withAlphaComponent(isDark ? 0.20 : 0.16) }

    /// Parses a user-given color: "none"/"" (nil), a swatch name, a swatch number (1-based), or hex.
    /// Returns `.none` when it can't be read.
    static func parseColor(_ s: String) -> NSColor?? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "none" || t == "clear" { return .some(nil) }
        if let sw = swatches.first(where: { $0.name.lowercased() == t }) { return .some(sw.color) }
        if let n = Int(t), swatches.indices.contains(n - 1) { return .some(swatches[n - 1].color) }
        if let c = NSColor(hex: t) { return .some(c) }
        return .none
    }
}

/// Drawing shared by rows, pills and tab buttons.
enum ColorStyle {
    /// The tint, inset by the attention outline's width so a waiting outline stays outside it.
    static func drawTint(_ color: NSColor?, in rect: CGRect, cornerRadius: CGFloat) {
        guard let color else { return }
        let inset = AttentionStyle.outlineWidth + 0.5
        let r = rect.insetBy(dx: inset, dy: inset)
        Theme.colorTint(color).setFill()
        NSBezierPath(roundedRect: r, xRadius: max(cornerRadius - inset, 0), yRadius: max(cornerRadius - inset, 0)).fill()
    }

    static func drawChip(_ color: NSColor?, in rect: CGRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(rect.width, rect.height) / 2, yRadius: min(rect.width, rect.height) / 2).fill()
    }

    static func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

enum ColorMenu {
    /// "<title> ▸" with the swatches, Custom… and None. `apply` gets nil for None.
    static func item(_ title: String, current: NSColor?, apply: @escaping (NSColor?) -> Void) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for sw in Theme.swatches {
            let i = ClosureMenuItem(sw.name.prefix(1).uppercased() + sw.name.dropFirst()) { apply(sw.color) }
            i.image = ColorStyle.swatchImage(sw.color)
            i.state = sw.color.sameColor(as: current) ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Custom…") { ColorPanelSession.begin(initial: current, apply: apply) })
        let none = ClosureMenuItem("None") { apply(nil) }
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Routes the shared NSColorPanel to one target at a time; every change applies live.
final class ColorPanelSession: NSObject {
    private static var current: ColorPanelSession?
    private let apply: (NSColor?) -> Void

    private init(apply: @escaping (NSColor?) -> Void) { self.apply = apply }

    static func begin(initial: NSColor?, apply: @escaping (NSColor?) -> Void) {
        let s = ColorPanelSession(apply: apply)
        current = s
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        if let initial { panel.color = initial }
        panel.setTarget(s)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        guard ColorPanelSession.current === self else { return }
        apply(sender.color.usingColorSpace(.sRGB))
    }
}

extension TerminalWindowController {
    func setColor(_ color: NSColor?, workspace ws: Workspace) {
        ws.color = color
        layoutNow()
        refreshChrome()
    }

    func setColor(_ color: NSColor?, tab: Tab) {
        tab.color = color
        refreshChrome()
    }

    /// With `[colors] auto_assign = true`, a new workspace takes the first swatch no other
    /// workspace in the window uses (cycling when all are taken). Called from `insert(workspace:)`.
    func autoAssignColor(_ ws: Workspace) {
        guard Settings.autoAssignColors, ws.color == nil else { return }
        let swatches = Theme.swatches.map(\.color)
        guard !swatches.isEmpty else { return }
        let used = workspaces.compactMap(\.color)
        ws.color = swatches.first { c in !used.contains { $0.sameColor(as: c) } }
            ?? swatches[workspaces.count % swatches.count]
    }

    /// The hairline along the top of the deck area while a colored workspace is active.
    /// Called from `layoutWorkspaceSidebar` (every layout pass).
    func layoutWorkspaceAccent() {
        let v = workspaceAccent
        if v.superview !== contentView { contentView.addSubview(v) }
        guard let color = activeWorkspace.color else { v.isHidden = true; return }
        let area = deckArea
        v.isHidden = false
        v.layer?.backgroundColor = color.cgColor
        v.layer?.cornerRadius = 1
        v.frame = CGRect(x: area.minX + Theme.Metrics.deckRadius, y: area.minY - 3, width: max(area.width - 2 * Theme.Metrics.deckRadius, 0), height: 2)
    }
}
