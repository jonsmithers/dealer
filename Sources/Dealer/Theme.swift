import AppKit
import GhosttyKit

/// Central look-and-feel: colors derived from the user's ghostty config, plus shared metrics,
/// fonts and animation timings. Chrome should read its colors from here, never hard-code them.
///
/// Everything is static. `Theme.load(_:)` runs once from `GhosttyRuntime.start()`, before any
/// window exists; until then the defaults below apply.
enum Theme {
    // MARK: Colors from the ghostty config

    /// Terminal background (`background`).
    private(set) static var background = NSColor(srgbRed: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1)
    /// Terminal foreground (`foreground`).
    private(set) static var foreground = NSColor(srgbRed: 0xe7 / 255, green: 0xe9 / 255, blue: 0xee / 255, alpha: 1)
    /// Veil drawn over unfocused panes (`unfocused-split-fill`, else the background).
    private(set) static var unfocusedFill = background
    /// Alpha of that veil: 1 − `unfocused-split-opacity`.
    private(set) static var unfocusedAlpha: CGFloat = 0.3
    /// Hairline between panes (`split-divider-color`, else derived).
    private(set) static var divider = NSColor.black

    /// True when the terminal background is dark. Picks the AppKit appearance too.
    static var isDark: Bool { background.luminance < 0.25 }
    static var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    // MARK: Derived chrome colors

    /// Window, titlebar and tab-strip surface: a shade off the terminal background.
    static var chrome: NSColor { background.mixed(with: .black, isDark ? 0.28 : 0.06) }
    /// Raised surfaces that should match the terminal: active tab, pane bars.
    static var surface: NSColor { background }
    /// Hover fill on chrome.
    static var hover: NSColor { chrome.mixed(with: foreground, 0.07) }
    /// Separator lines on chrome (strip bottom edge, card edges).
    static var hairline: NSColor { foreground.withAlphaComponent(isDark ? 0.08 : 0.12) }

    static var text: NSColor { foreground }
    static var textMuted: NSColor { foreground.mixed(with: chrome, 0.45) }
    static var textFaint: NSColor { foreground.mixed(with: chrome, 0.68) }
    /// Accent for single-deck windows, where deck colors aren't shown.
    static var accentNeutral: NSColor { foreground.mixed(with: chrome, 0.35) }

    /// Agent attention (#4, #7): needs input. The accent-blue outline on pane, tab and workspace.
    /// Two shades keep ≥ 4.9:1 contrast against the chrome: #5AA2FF on dark (6.3:1 on the default
    /// dark chrome) and #0B62D6 on light (4.9:1 on white-derived chrome).
    static var attentionWaiting: NSColor {
        isDark ? NSColor(srgbRed: 0x5a / 255, green: 0xa2 / 255, blue: 0xff / 255, alpha: 1)
               : NSColor(srgbRed: 0x0b / 255, green: 0x62 / 255, blue: 0xd6 / 255, alpha: 1)
    }
    /// Agent attention (#4, #7): finished / unread output. Deliberately quiet: a neutral dot only,
    /// so it never competes with the waiting blue.
    static var attentionDone: NSColor { textMuted }

    /// Deck identity colors, used for accents when a window has more than one deck.
    static let deckColors: [NSColor] = [
        NSColor(srgbRed: 0x7e / 255, green: 0xa6 / 255, blue: 0xf4 / 255, alpha: 1),
        NSColor(srgbRed: 0xe9 / 255, green: 0xa6 / 255, blue: 0x6c / 255, alpha: 1),
        NSColor(srgbRed: 0x8f / 255, green: 0xd1 / 255, blue: 0x9e / 255, alpha: 1),
        NSColor(srgbRed: 0xc7 / 255, green: 0x9c / 255, blue: 0xf2 / 255, alpha: 1),
        NSColor(srgbRed: 0xf2 / 255, green: 0x8f / 255, blue: 0xb0 / 255, alpha: 1),
        NSColor(srgbRed: 0x6f / 255, green: 0xd3 / 255, blue: 0xd6 / 255, alpha: 1),
    ]

    // MARK: Metrics

    enum Metrics {
        static let deckRadius: CGFloat = 8
        static let tabRadius: CGFloat = 6
        static let overlayRadius: CGFloat = 6
        static let stripHeight: CGFloat = 32
        static let tabHeight: CGFloat = 24
        static let tabMaxWidth: CGFloat = 180
        static let tabSpacing: CGFloat = 2
        /// Workspace sidebar column (issue #6), and its rows with and without a status line.
        static let sidebarWidth: CGFloat = 200
        static let sidebarRowHeight: CGFloat = 28
        static let sidebarRowDetailHeight: CGFloat = 40
        static let paneBarHeight: CGFloat = 20
        /// Visible hairline between panes of one tab.
        static let paneGap: CGFloat = 1
        /// Gap between decks.
        static let deckGap: CGFloat = 6
        /// Extra grab area on each side of a thin divider.
        static let dividerSlop: CGFloat = 3
        static let overlayStroke: CGFloat = 1.5
    }

    // MARK: Fonts

    enum Fonts {
        static let tab = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let tabActive = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let paneBar = NSFont.systemFont(ofSize: 11, weight: .regular)
        static let overlay = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    // MARK: Animation

    enum Motion {
        static let quick: TimeInterval = 0.12
        static let standard: TimeInterval = 0.18
    }

    // MARK: Loading

    static func load(_ config: ghostty_config_t) {
        if let c = color(config, "background") { background = c }
        if let c = color(config, "foreground") { foreground = c }
        unfocusedFill = color(config, "unfocused-split-fill") ?? background
        var opacity: Double = 0.7
        let key = "unfocused-split-opacity"
        _ = ghostty_config_get(config, &opacity, key, UInt(key.utf8.count))
        unfocusedAlpha = CGFloat(1 - min(max(opacity, 0), 1))
        divider = color(config, "split-divider-color")
            ?? background.mixed(with: .black, isDark ? 0.4 : 0.1)
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

/// Older names, kept so existing call sites keep compiling. Prefer `Theme` in new code.
enum Palette {
    static var deckColors: [NSColor] { Theme.deckColors }
    static var window: NSColor { Theme.chrome }
    static var deck: NSColor { Theme.chrome }
    static var bar: NSColor { Theme.hover }
    static var tabActive: NSColor { Theme.surface }
    static var text: NSColor { Theme.text }
    static var muted: NSColor { Theme.textMuted }
    static var neutral: NSColor { Theme.accentNeutral }
}

extension NSColor {
    /// Linear mix in sRGB: `fraction` 0 is self, 1 is `other`.
    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        let f = min(max(fraction, 0), 1)
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f)
    }

    /// Relative luminance (WCAG), 0 = black, 1 = white.
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}
