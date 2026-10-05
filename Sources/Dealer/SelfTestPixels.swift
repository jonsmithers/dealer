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
        let scale = v.window?.backingScaleFactor ?? 2
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

    /// Largest per-channel difference in sRGB (`.infinity` if either is missing).
    static func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent))
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

        t.step("pixels: the sampler reads saturated swatches exactly, in a window and detached", nil, {
            var worst: (CGFloat, String) = (0, "")
            let attached = PixelProbe.Swatch(frame: CGRect(x: 40, y: 40, width: 24, height: 24))
            self.contentView.addSubview(attached, positioned: .above, relativeTo: nil)
            defer { attached.removeFromSuperview() }
            let detached = PixelProbe.Swatch(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            for c in saturated {
                for v in [attached, detached] {
                    v.color = c
                    let d = PixelProbe.distance(PixelProbe.sample(v, at: CGPoint(x: 12, y: 12)), c)
                    if d > worst.0 { worst = (d, "\(c.hexString) \(v === attached ? "in window" : "detached")") }
                }
            }
            print("      pixel probe: worst swatch error \(String(format: "%.4f", worst.0)) (\(worst.1)), tolerance \(PixelProbe.tolerance)")
            return worst.0 <= PixelProbe.tolerance ? nil : "sampler off by \(worst.0) for \(worst.1)"
        }) {}

        t.step("pixels: the waiting outline is exactly Theme.attentionWaiting, in dark and light themes", nil, {
            var problems: [String] = []
            let dark = NSColor(hex: "#282c34")!, light = NSColor(hex: "#fafafa")!
            let variants = [("dark", dark), ("light", light)].map { name, bg in
                Theme.withBackground(bg) { (name, Theme.isDark, Theme.attentionWaiting) }
            }
            if variants[0].1 != true || variants[1].1 != false { problems.append("withBackground didn't switch isDark") }
            if PixelProbe.matches(variants[0].2, variants[1].2) { problems.append("light and dark waiting colors should differ") }
            for (i, (name, bg)) in [("dark", dark), ("light", light)].enumerated() {
                Theme.withBackground(bg) {
                    let b = TabButton(frame: CGRect(x: 0, y: 0, width: 160, height: Theme.Metrics.tabHeight))
                    b.title = "tab"
                    b.attention = .waiting
                    let px = PixelProbe.sample(b, at: PixelProbe.outlinePoint(in: b))
                    let d = PixelProbe.distance(px, Theme.attentionWaiting)
                    print("      pixel probe: \(name) outline \(px?.hexString ?? "nil") vs \(Theme.attentionWaiting.hexString), error \(String(format: "%.4f", d))")
                    if !PixelProbe.isWaitingOutlined(b) { problems.append("\(name): outline is \(px?.hexString ?? "nil"), want \(Theme.attentionWaiting.hexString)") }
                    // The other theme's blue is a near miss and must not pass.
                    if PixelProbe.matches(px, variants[1 - i].2) { problems.append("\(name): the other theme's blue would pass too") }
                    b.attention = .done
                    if PixelProbe.isWaitingOutlined(b) { problems.append("\(name): done must not draw the outline") }
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}
    }
}
