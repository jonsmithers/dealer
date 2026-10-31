import AppKit

// MARK: - Self-test pixel probe (#14)
//
// The only way self-test checks read rendered pixels. Don't call `cacheDisplay` / `colorAt`
// anywhere else: `NSBitmapImageRep.colorAt` labels its components "calibrated RGB" although
// they're in the bitmap's color space (the display's, e.g. "Color LCD") for window-backed
// bitmaps, so converting them directly to sRGB is off by up to ~0.25 per channel on saturated
// colors. `sample` re-tags mislabeled components with `rep.colorSpace` (and leaves correctly
// tagged ones alone), and renders into an sRGB bitmap of its own so the result doesn't depend on the
// display or on whether the view is in a window. Reads are accurate to about 1/255.

enum PixelProbe {
    /// Largest per-channel sRGB difference two colors may have and still count as the same
    /// rendered color: two 8-bit steps. Reads through `sample` are exact for solid fills; the
    /// slack only absorbs rounding. Nearby wrong colors (the other theme's blue is ~0.31 away)
    /// fail by a wide margin.
    static let tolerance: CGFloat = 2.0 / 255

    /// Pixels per point of every render (#48). Fixed, not the window's `backingScaleFactor`, so a
    /// check reads the same pixels whatever display the window opens on: at 1x, thin strokes such
    /// as the failed dot's `!` cover no whole pixel, and a sample lands on an antialiased edge.
    /// Only `atEachScale` changes it, to run checks at 1x as well.
    private(set) static var scale: CGFloat = 2

    /// Runs `body` once per scale (2x, then 1x), so the 1x case is covered on Retina-only machines.
    /// Returns the problems found, each prefixed with its scale.
    static func atEachScale(_ body: (CGFloat) -> [String]) -> [String] {
        defer { scale = 2 }
        return [2, 1].flatMap { s -> [String] in
            scale = s
            return body(s).map { "@\(Int(s))x: \($0)" }
        }
    }

    /// Renders `v` offscreen (`cacheDisplay`) and returns the sRGB color at `p`, in the view's own
    /// (flipped) points. Works for views in a window and for detached views.
    /// Renders `rect` (default: all) of `v` into an sRGB bitmap of our own, not
    /// `bitmapImageRepForCachingDisplay`: that one is in the display's space for a window-backed
    /// view and Generic RGB for a detached one, where saturated sRGB colors (e.g. #aa00ff) are out
    /// of gamut and come back clipped.
    static func render(_ v: NSView?, rect: CGRect? = nil) -> NSBitmapImageRep? {
        guard let v else { return nil }
        let r = (rect ?? v.bounds).intersection(v.bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let scale = Self.scale
        guard let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(r.width * scale)),
                                           pixelsHigh: Int(ceil(r.height * scale)), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let rep = blank.retagging(with: .sRGB) else { return nil }
        rep.size = r.size
        v.cacheDisplay(in: r, to: rep)
        return rep
    }

    /// The raw pixels of `rect` in `v`, for "renders exactly the same" checks.
    static func pixels(_ v: NSView?, rect: CGRect? = nil) -> Data? {
        guard let rep = render(v, rect: rect), let bytes = rep.bitmapData else { return nil }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    static func sample(_ v: NSView?, at p: CGPoint) -> NSColor? {
        guard let v, let rep = render(v) else { return nil }
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        let x = min(max(Int(p.x * sx), 0), rep.pixelsWide - 1), y = min(max(Int(p.y * sy), 0), rep.pixelsHigh - 1)
        return color(in: rep, x: x, y: y)
    }

    /// Every pixel of `v` whose centre lies in `rect` (view points), from one render.
    static func samples(_ v: NSView?, in rect: CGRect) -> [NSColor] {
        guard let v, let rep = render(v) else { return [] }
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        var out: [NSColor] = []
        for y in 0..<rep.pixelsHigh where rect.minY...rect.maxY ~= (CGFloat(y) + 0.5) / sy {
            for x in 0..<rep.pixelsWide where rect.minX...rect.maxX ~= (CGFloat(x) + 0.5) / sx {
                if let c = color(in: rep, x: x, y: y) { out.append(c) }
            }
        }
        return out
    }

    /// How far `c` is from `base` toward `over` (0 = base, 1 = over), when `c` is a blend of the
    /// two, as on an antialiased edge of `over` drawn on `base`; nil when it isn't such a blend
    /// (some channel is off the line by more than `tolerance`), so a wrong color never counts.
    static func coverage(of over: NSColor, on base: NSColor, in c: NSColor?) -> CGFloat? {
        guard let c = c?.usingColorSpace(.sRGB), let o = over.usingColorSpace(.sRGB),
              let b = base.usingColorSpace(.sRGB) else { return nil }
        let ch: [(CGFloat, CGFloat, CGFloat)] = [(c.redComponent, b.redComponent, o.redComponent),
                                                 (c.greenComponent, b.greenComponent, o.greenComponent),
                                                 (c.blueComponent, b.blueComponent, o.blueComponent)]
        // The channel with the largest spread gives the fraction; the others must agree with it.
        guard let (cv, bv, ov) = ch.max(by: { abs($0.2 - $0.1) < abs($1.2 - $1.1) }), abs(ov - bv) > 0.1 else { return nil }
        let f = (cv - bv) / (ov - bv)
        guard ch.allSatisfy({ abs($0.1 + f * ($0.2 - $0.1) - $0.0) <= tolerance * 2 }) else { return nil }
        return min(max(f, 0), 1)
    }

    private static func color(in rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        guard let raw = rep.colorAt(x: x, y: y) else { return nil }
        // Correctly tagged (e.g. a detached view's sRGB bitmap): just convert.
        if raw.colorSpace == rep.colorSpace { return raw.usingColorSpace(.sRGB) }
        // Mislabeled (a window-backed bitmap): take the components as stored, no conversion, and
        // give them the bitmap's real color space.
        guard raw.numberOfComponents == rep.colorSpace.numberOfColorComponents + 1 else { return nil }
        var c = [CGFloat](repeating: 0, count: raw.numberOfComponents)
        raw.getComponents(&c)
        return NSColor(colorSpace: rep.colorSpace, components: &c, count: c.count).usingColorSpace(.sRGB)
    }

    /// Largest per-channel difference in sRGB, alpha included (`.infinity` if either is missing).
    /// Alpha counts since #67: a chrome fill drawn translucent matched its opaque color on RGB alone,
    /// so the sidebar/pill selection steps passed with the window translucent.
    static func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
    }

    static func matches(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = tolerance) -> Bool {
        distance(a, b) <= tolerance
    }

    /// Where the #7 waiting outline is sampled: the middle of the top edge, inside the 1.5pt stroke.
    static func outlinePoint(in v: NSView) -> CGPoint { CGPoint(x: v.bounds.midX, y: AttentionStyle.outlineWidth / 2) }

    /// Whether `v` shows the failed outline (#29) in exactly `Theme.attentionFailed`.
    static func isFailedOutlined(_ v: NSView?) -> Bool {
        guard let v else { return false }
        return matches(sample(v, at: outlinePoint(in: v)), Theme.attentionFailed)
    }

    /// Whether `v` shows the waiting outline in exactly `Theme.attentionWaiting`.
    static func isWaitingOutlined(_ v: NSView?) -> Bool {
        guard let v else { return false }
        return matches(sample(v, at: outlinePoint(in: v)), Theme.attentionWaiting)
    }

    /// Sidebar entries (#91) show attention as a large dot and no outline: the dot's color, sampled
    /// left of its `?`/`!`, or nil when `v` isn't a sidebar row or header or its dot isn't the large size.
    static func sidebarDot(_ v: NSView?) -> NSColor? {
        guard let v, let r = (v as? WorkspaceRow)?.attentionDotRect ?? (v as? GroupHeaderView)?.attentionDotRect,
              r.width == Theme.Metrics.sidebarDotSize else { return nil }
        return sample(v, at: CGPoint(x: r.minX + r.width * 0.15, y: r.midY))
    }

    /// Whether a sidebar row or header shows the large waiting dot, and no waiting outline (#91).
    static func hasWaitingDot(_ v: NSView?) -> Bool { matches(sidebarDot(v), Theme.attentionWaiting) && !isWaitingOutlined(v) }

    /// Whether a sidebar row or header shows the large failed dot, and no failed outline (#91).
    static func hasFailedDot(_ v: NSView?) -> Bool { matches(sidebarDot(v), Theme.attentionFailed) && !isFailedOutlined(v) }

    /// Whether the failed dot (#29) in `dotRect` of `v` carries its `!` in `Theme.chrome`, or why not.
    /// Takes the bar's pixel closest to chrome instead of one fixed point, which can land on the
    /// bar's antialiased edge (#48). At 2x the bar covers whole pixels, so that pixel must be chrome
    /// exactly; at 1x it is 1.44 px wide and may cover none, so it must be a red-to-chrome blend
    /// that is at least 60% chrome (the bar always covers some pixel by 72% or more). A missing `!`
    /// (all red) or one in another color fails at both scales.
    static func bangProblem(_ v: NSView?, dotRect: CGRect) -> String? {
        let bar = AttentionStyle.bangBar(in: dotRect)
        let px = samples(v, in: bar)
        guard let best = px.min(by: { distance($0, Theme.chrome) < distance($1, Theme.chrome) }) else { return "no pixels in the `!`" }
        let want = Theme.chrome.hexString
        if scale >= 2 { return matches(best, Theme.chrome) ? nil : "the dot's `!` is \(best.hexString), want \(want)" }
        let f = coverage(of: Theme.chrome, on: Theme.attentionFailed, in: best)
        return (f ?? 0) >= 0.6 ? nil
            : "the dot's `!` is \(best.hexString), want \(want) or a mostly-\(want) blend with red (\(f.map { String(format: "%.2f", $0) } ?? "not a blend"))"
    }

    /// A detached view that fills itself with one color, for the sampler sanity check.
    final class Swatch: NSView {
        var color: NSColor = .black
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }
}

extension TerminalWindowController {
    /// Sanity checks for the probe itself, so a color-space regression in the tooling fails here
    /// rather than silently loosening every pixel check.
    func pixelSelfTestSteps(_ t: SelfTestKit) {
        let saturated = ["#ff0000", "#00c853", "#2962ff", "#ffd600", "#aa00ff", "#11a08f", "#5aa2ff"].compactMap { NSColor(hex: $0) }

        t.step("pixels: the sampler reads saturated swatches exactly, in a window and detached, at 2x and 1x", nil, {
            let attached = PixelProbe.Swatch(frame: CGRect(x: 40, y: 40, width: 24, height: 24))
            self.contentView.addSubview(attached, positioned: .above, relativeTo: nil)
            defer { attached.removeFromSuperview() }
            let detached = PixelProbe.Swatch(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            let problems = PixelProbe.atEachScale { scale -> [String] in
                var worst: (CGFloat, String) = (0, "")
                for c in saturated {
                    for v in [attached, detached] {
                        v.color = c
                        let d = PixelProbe.distance(PixelProbe.sample(v, at: CGPoint(x: 12, y: 12)), c)
                        if d > worst.0 { worst = (d, "\(c.hexString) \(v === attached ? "in window" : "detached")") }
                    }
                }
                let w = PixelProbe.render(attached).map { $0.pixelsWide } ?? 0
                print("      pixel probe @\(Int(scale))x: worst swatch error \(String(format: "%.4f", worst.0)) (\(worst.1)), tolerance \(PixelProbe.tolerance), 24pt = \(w) px")
                return [worst.0 <= PixelProbe.tolerance ? nil : "sampler off by \(worst.0) for \(worst.1)",
                        w == Int(24 * scale) ? nil : "24pt rendered as \(w) px, want \(Int(24 * scale)) (the probe must not follow the display's scale)"].compactMap { $0 }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        t.step("pixels: the waiting outline is exactly Theme.attentionWaiting, in dark and light themes, at 2x and 1x", nil, {
            var problems: [String] = []
            let dark = NSColor(hex: "#282c34")!, light = NSColor(hex: "#fafafa")!
            let variants = [("dark", dark), ("light", light)].map { name, bg in
                Theme.withBackground(bg) { (name, Theme.isDark, Theme.attentionWaiting) }
            }
            if variants[0].1 != true || variants[1].1 != false { problems.append("withBackground didn't switch isDark") }
            if PixelProbe.matches(variants[0].2, variants[1].2) { problems.append("light and dark waiting colors should differ") }
            for (i, (name, bg)) in [("dark", dark), ("light", light)].enumerated() {
                problems += PixelProbe.atEachScale { _ in Theme.withBackground(bg) {
                    var problems: [String] = []
                    let b = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
                    b.title = "tab"
                    b.attention = .waiting
                    let px = PixelProbe.sample(b, at: PixelProbe.outlinePoint(in: b))
                    let d = PixelProbe.distance(px, Theme.attentionWaiting)
                    print("      pixel probe @\(Int(PixelProbe.scale))x: \(name) outline \(px?.hexString ?? "nil") vs \(Theme.attentionWaiting.hexString), error \(String(format: "%.4f", d))")
                    if !PixelProbe.isWaitingOutlined(b) { problems.append("\(name): outline is \(px?.hexString ?? "nil"), want \(Theme.attentionWaiting.hexString)") }
                    // The other theme's blue is a near miss and must not pass.
                    if PixelProbe.matches(px, variants[1 - i].2) { problems.append("\(name): the other theme's blue would pass too") }
                    // A dot-only state must not pass the probe (#61 outlines done by default; unread stays a dot).
                    b.attention = .unread
                    if PixelProbe.isWaitingOutlined(b) { problems.append("\(name): unread (a dot by default) must not draw the outline") }
                    return problems
                } }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
    }
}
