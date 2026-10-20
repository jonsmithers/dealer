import AppKit
import GhosttyKit

/// Central look-and-feel: colors derived from the user's ghostty config, plus shared metrics,
/// fonts and animation timings. Chrome should read its colors from here, never hard-code them.
///
/// Everything is static. `Theme.load(_:)` runs from `GhosttyRuntime.start()`, before any window
/// exists (until then the defaults below apply), and again on every config reload (#33), which
/// posts `Theme.didChange`. Views that copy a color into a layer or control conform to
/// `ThemeApplying`; draw-time reads only need a redraw.
enum Theme {
    /// Posted on the main thread after a config reload changed the theme (#33). Each window
    /// re-applies its chrome (`TerminalWindowController.applyTheme`).
    static let didChange = Notification.Name("DealerThemeDidChange")

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

    /// The theme's 16 ANSI colors (`palette = 0..15`), so chrome can borrow theme accents
    /// (e.g. blue = 4, bright blue = 12). Empty until `load`. Not used for drawing yet (#23).
    private(set) static var ansi: [NSColor] = []

    /// `background-opacity` and `background-blur` (#67), read together through `transparency`.
    private(set) static var transparency = Transparency()

    /// True when the terminal background is dark. Picks the AppKit appearance too.
    static var isDark: Bool { background.luminance < 0.25 }

    /// Self-test only (#14): runs `body` with `background` (and so `isDark` and every derived
    /// color) temporarily replaced, to check light and dark variants of draw-time colors.
    /// `foreground` replaces the foreground too, for a whole light or dark theme (#52).
    static func withBackground<T>(_ bg: NSColor, foreground fg: NSColor? = nil, _ body: () -> T) -> T {
        let old = (background, foreground)
        background = bg
        if let fg { foreground = fg }
        defer { (background, foreground) = old }
        return body()
    }
    static var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    // MARK: Derived chrome colors

    /// Window, titlebar and tab-strip surface: a shade off the terminal background.
    static var chrome: NSColor { background.mixed(with: .black, isDark ? 0.28 : 0.06) }
    /// Raised surfaces that should match the terminal: active tab, pane bars.
    static var surface: NSColor { background }
    /// Pane bar background: between the surface and the chrome.
    static var paneBar: NSColor { surface.mixed(with: chrome, 0.4) }
    /// Hover fill on chrome.
    static var hover: NSColor { chrome.mixed(with: foreground, 0.07) }
    /// Separator lines on chrome (strip bottom edge, card edges).
    static var hairline: NSColor { foreground.withAlphaComponent(isDark ? 0.08 : 0.12) }

    static var text: NSColor { foreground }
    static var textMuted: NSColor { foreground.mixed(with: chrome, 0.45) }
    static var textFaint: NSColor { foreground.mixed(with: chrome, 0.68) }
    /// Accent for single-deck windows, where deck colors aren't shown.
    static var accentNeutral: NSColor { foreground.mixed(with: chrome, 0.35) }
    /// The selected workspace's switcher entry (#52): a neutral fill a fifth of the way from the
    /// chrome to the foreground, well past `hover` (7%), in light and dark themes. Never an
    /// outline (outlines mean attention) and never an attention color.
    static var workspaceSelection: NSColor { chrome.mixed(with: foreground, 0.20) }

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
    /// Attention (#29): something failed (`dealer run` exited non-zero, a Claude API error, a shell
    /// command failed). Same treatment as waiting, in red: #FF453A on dark (4.8:1 on the default
    /// dark chrome), #C9190B on light (5.1:1). Kept well away from the red workspace/tab swatch
    /// (#e06c75 / #c8414c, ≥ 59/255 on a channel). Colors are tints and chips, never outlines,
    /// and the failed dot also carries a `!` (AttentionStyle), so it isn't color-only.
    static var attentionFailed: NSColor {
        isDark ? NSColor(srgbRed: 0xff / 255, green: 0x45 / 255, blue: 0x3a / 255, alpha: 1)
               : NSColor(srgbRed: 0xc9 / 255, green: 0x19 / 255, blue: 0x0b / 255, alpha: 1)
    }

    /// Deck identity colors, used for accents when a window has more than one deck.
    static let deckColors: [NSColor] = [
        NSColor(srgbRed: 0x7e / 255, green: 0xa6 / 255, blue: 0xf4 / 255, alpha: 1),
        NSColor(srgbRed: 0xe9 / 255, green: 0xa6 / 255, blue: 0x6c / 255, alpha: 1),
        NSColor(srgbRed: 0x8f / 255, green: 0xd1 / 255, blue: 0x9e / 255, alpha: 1),
        NSColor(srgbRed: 0xc7 / 255, green: 0x9c / 255, blue: 0xf2 / 255, alpha: 1),
        NSColor(srgbRed: 0xf2 / 255, green: 0x8f / 255, blue: 0xb0 / 255, alpha: 1),
        NSColor(srgbRed: 0x6f / 255, green: 0xd3 / 255, blue: 0xd6 / 255, alpha: 1),
    ]

    /// Chrome fills (strips, bars, sidebar, gaps, the titlebar row) go through this (#67): at the
    /// window's translucency they take `background-opacity` as alpha, so the window reads as one
    /// translucent surface the way Ghostty's own titlebar follows its background. Opaque (the
    /// default) returns `c` itself, so nothing changes. Never use it for text, outlines, dots,
    /// glyphs or the spinner, which stay opaque.
    static func fill(_ c: NSColor) -> NSColor {
        let a = transparency.chromeAlpha
        return a >= 1 ? c : c.withAlphaComponent(c.alphaComponent * a)
    }

    // MARK: Metrics

    enum Metrics {
        static let deckRadius: CGFloat = 8
        static let tabRadius: CGFloat = 6
        static let overlayRadius: CGFloat = 6
        static let stripHeight: CGFloat = 32
        static let tabHeight: CGFloat = 24
        /// Tabs fit their titles (#46): leading pad + title + a trailing slot that always holds
        /// room for the hover × (and the attention dot, which shares it), so hovering never
        /// resizes a tab. Widths lie in tabMinWidth…tabMaxWidth.
        static let tabMaxWidth: CGFloat = 200
        static let tabMinWidth: CGFloat = 40
        static let tabLeadingPad: CGFloat = 8
        static let tabTrailingSlot: CGFloat = 22
        static let tabSpacing: CGFloat = 2
        /// Workspace sidebar column (issue #6), and its rows with and without a status line.
        static let sidebarWidth: CGFloat = 200
        static let sidebarRowHeight: CGFloat = 28
        static let sidebarRowDetailHeight: CGFloat = 40
        /// Workspace groups (#80): a header row, and how far its members' rows are indented.
        static let groupHeaderHeight: CGFloat = 24
        static let groupIndent: CGFloat = 12
        /// Extra space between a top-bar group's run of pills and its neighbours.
        static let groupPillGap: CGFloat = 6
        /// The attention dot on sidebar rows and pills: 8pt like a tab's (was 6), so the waiting `?`
        /// and the failed `!` stay legible at 1x (#65).
        static let switcherDotSize: CGFloat = 8
        /// The selected workspace's bar at the left edge of its sidebar row or pill (#52), in the
        /// workspace's color or `Theme.text`. Unselected colored rows keep a 3pt chip.
        static let workspaceBarWidth: CGFloat = 5
        static let workspacePillBarWidth: CGFloat = 3
        /// The selected entry's neutral outline (#52): the attention outline's width and path, so an
        /// attention outline covers it exactly.
        static var workspaceSelectionOutline: CGFloat { AttentionStyle.outlineWidth }
        static let paneBarHeight: CGFloat = 20
        /// The hover-only × on a pane bar (#24).
        static let paneBarCloseSize: CGFloat = 16
        /// Visible hairline between panes of one tab.
        static let paneGap: CGFloat = 1
        /// Gap between decks.
        static let deckGap: CGFloat = 6
        /// Extra grab area on each side of a thin divider.
        static let dividerSlop: CGFloat = 3
        static let overlayStroke: CGFloat = 1.5
        /// The titlebar's coffee cup while the display is kept awake (#69, Caffeinate.swift).
        static let caffeineIconWidth: CGFloat = 24
        static let caffeineGlyphSize: CGFloat = 13
    }

    // MARK: Fonts

    enum Fonts {
        static let tab = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let tabActive = NSFont.systemFont(ofSize: 12, weight: .medium)
        /// The selected workspace's name (#52): a step heavier than an active tab.
        static let workspaceActive = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let paneBar = NSFont.systemFont(ofSize: 11, weight: .regular)
        /// A workspace group's name on its header row or label pill (#80).
        static let groupHeader = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let overlay = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    // MARK: Animation

    enum Motion {
        static let quick: TimeInterval = 0.12
        static let standard: TimeInterval = 0.18
    }

    // MARK: Loading

    /// Re-reads the colors from a reloaded config and tells every window (#33).
    static func reload(_ config: ghostty_config_t) {
        load(config)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func load(_ config: ghostty_config_t) {
        if let c = color(config, "background") { background = c }
        if let c = color(config, "foreground") { foreground = c }
        unfocusedFill = color(config, "unfocused-split-fill") ?? background
        var opacity: Double = 0.7
        let key = "unfocused-split-opacity"
        _ = ghostty_config_get(config, &opacity, key, UInt(key.utf8.count))
        unfocusedAlpha = CGFloat(1 - min(max(opacity, 0), 1))
        var palette = ghostty_config_palette_s()
        let pkey = "palette"
        if ghostty_config_get(config, &palette, pkey, UInt(pkey.utf8.count)) {
            ansi = withUnsafeBytes(of: &palette.colors) { raw in
                raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map {
                    NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
                }
            }
        }
        divider = color(config, "split-divider-color")
            ?? background.mixed(with: .black, isDark ? 0.4 : 0.1)
        transparency = Transparency.ignoresConfig ? Transparency() : Transparency(config)
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

/// The window's translucency (#67): ghostty's `background-opacity` and `background-blur`. The one
/// place drawers and the window ask, through `Theme.transparency` and `Theme.fill`.
struct Transparency: Equatable {
    /// `background-blur`. ghostty hands it to the C API as an `Int16` (`BackgroundBlur.cval` at the
    /// pin): 0 off, a positive radius (`true` = 20), and the sentinels -1/-2 for the two glass
    /// styles. Upstream calls those sentinels temporary, so recheck them on a pin bump.
    enum Blur: Equatable {
        case off
        case radius(Int)
        case glassRegular
        case glassClear

        init(cval: Int16) {
            switch cval {
            case -1: self = .glassRegular
            case -2: self = .glassClear
            case let r where r > 0: self = .radius(Int(r))
            default: self = .off
            }
        }

        var isGlass: Bool { self == .glassRegular || self == .glassClear }
    }

    /// `background-opacity`, clamped to 0…1. 1 is ghostty's default.
    var opacity: CGFloat = 1
    var blur: Blur = .off

    /// Ghostty's rule (`TerminalWindow.syncAppearance`): the window is non-opaque when the
    /// background is translucent or a glass style is set.
    var isTranslucent: Bool { opacity < 1 || blur.isGlass }
    /// Alpha for chrome fills: the background's own opacity while translucent, else 1.
    var chromeAlpha: CGFloat { isTranslucent ? opacity : 1 }
    /// Glass shows only on macOS 26+; older systems fall back to a radius blur (`glassFallbackRadius`).
    var showsGlass: Bool {
        guard blur.isGlass else { return false }
        if #available(macOS 26.0, *) { return !Self.forceGlassFallback }
        return false
    }
    /// One switch for the self-test (like `Confirmation.autoAccept`): the user's own ghostty config
    /// (which the self-test loads on purpose, for its colors) never makes the test windows
    /// translucent, so pixel checks don't depend on their `background-opacity`/`background-blur`.
    /// Only a test config (`GhosttyRuntime.configFileOverride`, as `SelfTestTransparency` uses) does.
    static var ignoresConfig: Bool { SelfTest.enabled && GhosttyRuntime.configFileOverride == nil }
    /// The radius blur used for glass where glass can't show (ghostty's `background-blur = true`).
    static let glassFallbackRadius = 20
    /// Self-test only: behave as if glass were unavailable, to check the fallback on macOS 26.
    static var forceGlassFallback = false

    init() {}
    init(opacity: CGFloat, blur: Blur) { self.opacity = min(max(opacity, 0), 1); self.blur = blur }

    init(_ config: ghostty_config_t) {
        var o: Double = 1
        let ok = "background-opacity"
        _ = ghostty_config_get(config, &o, ok, UInt(ok.utf8.count))
        var b: Int16 = 0
        let bk = "background-blur"
        _ = ghostty_config_get(config, &b, bk, UInt(bk.utf8.count))
        self.init(opacity: CGFloat(o), blur: Blur(cval: b))
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

extension Theme {
    /// The × used by every close control (tab, pane bar), so they read as one family.
    static func drawCross(in r: CGRect, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: r.origin)
        path.line(to: CGPoint(x: r.maxX, y: r.maxY))
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        path.line(to: CGPoint(x: r.maxX, y: r.minY))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// Chrome that copies `Theme` colors into layers or controls instead of reading them at draw time
/// (#33). Conformers call `applyTheme()` from `init` and must set every such color there, so a
/// config reload re-themes them; `applyThemeRecursively` walks a view tree and redraws it.
protocol ThemeApplying: NSView {
    func applyTheme()
}

extension NSView {
    /// Re-applies theme colors to this view and everything under it, and redraws them.
    func applyThemeRecursively() {
        (self as? ThemeApplying)?.applyTheme()
        needsDisplay = true
        subviews.forEach { $0.applyThemeRecursively() }
    }
}
