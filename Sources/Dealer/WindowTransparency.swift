import AppKit
import GhosttyKit

// MARK: - Window transparency, blur and glass (#67)
//
// ghostty's `background-opacity` and `background-blur`, read once into `Theme.transparency`.
// Opaque (the default), nothing here changes how the window draws. Translucent:
// - the window is non-opaque, with Ghostty's almost-clear background;
// - the terminals paint their own background at the opacity (libghostty), or none at all for the
//   glass styles ("the glass effect handles it", `renderer/generic.zig`);
// - the chrome (strips, bars, sidebar, deck and pane gaps, titlebar row) is drawn at the same alpha
//   (`Theme.fill`). The window's chrome fill is `WindowBackdropView`'s shape, with holes where the
//   deck cards are, so it never stacks under a terminal;
// - a radius blur comes from the window server (`ghostty_set_window_background_blur`), and glass
//   from an `NSGlassEffectView` at the bottom of the backdrop (macOS 26+), tinted like Ghostty's
//   (`TerminalViewContainer.swift` at the pin).

extension TerminalWindowController {
    /// Applies `Theme.transparency` to this window. Runs from `init` and from every theme reload
    /// (⌘⇧,), so switching between opaque, radius and glass works on open windows.
    func applyTransparency() {
        guard let window else { return }
        let t = Theme.transparency
        if t.isTranslucent {
            window.isOpaque = false
            // Ghostty's value (`TerminalWindow.syncAppearance`): not `.clear`, which looks different
            // from Terminal.app's translucency.
            window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        } else {
            window.isOpaque = true
            window.backgroundColor = Theme.chrome
        }
        contentView.applyTheme()  // its own fill, and the backdrop's shape and glass
        contentView.layoutBackdrop()
        applyBlur()
    }

    /// The window server's radius blur. Needs a visible window (a window number), so
    /// `showAndFocus` calls it again; harmless before.
    func applyBlur() {
        guard let window, window.windowNumber > 0, let app = GhosttyRuntime.shared.app else { return }
        let t = Theme.transparency
        guard t.isTranslucent else { return }  // an opaque window hides any blur behind it
        switch t.blur {
        case .off, .radius:
            // Reads the app config's radius (0 for off, which also clears an earlier one). It does
            // nothing at opacity 1, which only a glass style makes translucent.
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        case .glassRegular, .glassClear:
            // ghostty passes the glass sentinels (-1/-2) straight to the window server, so set the
            // radius ourselves: none under glass, a plain blur where glass can't show.
            WindowBlur.set(window, radius: t.showsGlass ? 0 : Transparency.glassFallbackRadius)
        }
    }
}

/// The private CoreGraphics call every terminal uses for a window's background blur, the one
/// `ghostty_set_window_background_blur` makes. Looked up at runtime so a missing symbol is a no-op.
enum WindowBlur {
    private typealias Connection = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias SetRadius = @convention(c) (UnsafeMutableRawPointer?, Int, Int32) -> Int32

    private static let functions: (Connection, SetRadius)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let c = dlsym(handle, "CGSDefaultConnectionForThread"),
              let s = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(c, to: Connection.self), unsafeBitCast(s, to: SetRadius.self))
    }()

    /// Self-test hook: the last radius set per window number.
    private(set) static var lastRadius: [Int: Int] = [:]

    static func set(_ window: NSWindow, radius: Int) {
        lastRadius[window.windowNumber] = radius
        guard let (connection, setRadius) = functions else { return }
        _ = setRadius(connection(), window.windowNumber, Int32(radius))
    }
}

extension WindowContentView {
    /// Lays the backdrop over the whole view and cuts the deck cards out of its chrome fill.
    func layoutBackdrop() {
        backdrop.frame = bounds
        if subviews.first !== backdrop { addSubview(backdrop, positioned: .below, relativeTo: nil) }
        let cards = subviews.compactMap { $0 as? DeckView }.filter { !$0.isHidden }
            .map { $0.content.convert($0.content.bounds, to: backdrop) }
        backdrop.layoutChrome(holes: cards)
    }
}

/// The bottom of a window's content view (#67), hidden while the window is opaque. Translucent,
/// `chrome` draws the chrome fill everywhere but the deck cards (a terminal shows its own
/// translucent background, or the glass, never the chrome under it); in glass mode the glass view
/// sits under that, so the chrome is drawn over glass at the same alpha.
final class WindowBackdropView: FlippedView, ThemeApplying {
    /// The glass (`NSGlassEffectView`, macOS 26+) in glass mode, else nil.
    private(set) var glassView: NSView?
    /// The chrome fill with the deck cards cut out.
    let chrome = ChromeFillView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(chrome)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme() {
        let t = Theme.transparency
        isHidden = !t.isTranslucent
        updateGlass(t)
        chrome.needsDisplay = true
    }

    func layoutChrome(holes: [CGRect]) {
        chrome.frame = bounds
        chrome.holes = holes
        glassView?.frame = bounds
        if let g = glassView { configureGlassCorner(g) }
    }

    // MARK: Glass

    private func updateGlass(_ t: Transparency) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), t.showsGlass {
            // Attached synchronously, like Ghostty's first attach, so a new window never shows a
            // frame without it.
            let g = (glassView as? NSGlassEffectView) ?? {
                let v = NSGlassEffectView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                addSubview(v, positioned: .below, relativeTo: chrome)
                glassView = v
                return v
            }()
            g.style = t.blur == .glassClear ? .clear : .regular
            // Ghostty draws the background color at `background-opacity` over the glass
            // (`model.color.glassEffect(…)`); the tint is AppKit's equivalent.
            g.tintColor = Theme.background.withAlphaComponent(t.opacity)
            configureGlassCorner(g)
            return
        }
        #endif
        glassView?.removeFromSuperview()
        glassView = nil
    }

    private func configureGlassCorner(_ g: NSView) {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *), let g = g as? NSGlassEffectView else { return }
        // The window's own corner radius (private, as Ghostty reads it), so the glass meets the frame.
        if let w = window, w.responds(to: Selector(("_cornerRadius"))), let r = w.value(forKey: "_cornerRadius") as? CGFloat {
            g.cornerRadius = r
        }
        #endif
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let g = glassView { configureGlassCorner(g) }
    }
}

/// The translucent chrome fill (#67): `Theme.fill(Theme.chrome)` over the whole window but the
/// deck cards (even-odd). Drawn in `draw(_:)`, not as a shape layer, so `PixelProbe` sees it.
final class ChromeFillView: FlippedView {
    /// The deck cards, in this view's coordinates (the backdrop's).
    var holes: [CGRect] = [] { didSet { if holes != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        let r = Theme.Metrics.deckRadius
        for h in holes where h.width > 2 * r && h.height > 2 * r {
            path.appendRoundedRect(h, xRadius: r, yRadius: r)
        }
        path.windingRule = .evenOdd
        Theme.fill(Theme.chrome).setFill()
        path.fill()
    }
}
