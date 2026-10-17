import AppKit

/// Just enough of SVG path data (`d="…"`) to draw a shape copied from the web, such as the
/// claude.ai working mark (#73): every command (absolute and relative M L H V C S Q T A Z), in the
/// compact form minifiers write (`1-.684`, `.4.3`, arc flags without separators). Coordinates stay
/// in the SVG's own space (y down), so draw into a flipped view or flip the transform.
enum SVGPath {
    /// One path per subpath (each `M`/`m` starts one), in source order.
    static func subpaths(_ d: String) -> [NSBezierPath] {
        var s = Scanner(Array(d.utf8))
        var paths: [NSBezierPath] = []
        var path = NSBezierPath()
        var cur = CGPoint.zero, start = CGPoint.zero
        // The last control point, for S and T's reflection, and which command set it.
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0

        while true {
            s.skipSeparators()
            guard let c = s.peek else { break }
            if s.isCommand(c) { cmd = c; s.i += 1 } else if cmd == 0 { break }
            let rel = cmd >= UInt8(ascii: "a")
            func pt() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            var cubic: CGPoint?, quad: CGPoint?
            switch cmd | 0x20 {  // lowercased
            case UInt8(ascii: "m"):
                guard let p = pt() else { return paths }
                if !path.isEmpty { paths.append(path) }
                path = NSBezierPath()
                path.move(to: p)
                cur = p; start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")  // further pairs are line-tos
            case UInt8(ascii: "l"):
                guard let p = pt() else { return paths }
                path.line(to: p); cur = p
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return paths }
                cur.x = rel ? cur.x + x : x
                path.line(to: cur)
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return paths }
                cur.y = rel ? cur.y + y : y
                path.line(to: cur)
            case UInt8(ascii: "c"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return paths }
                path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
                cubic = c2; cur = p
            case UInt8(ascii: "s"):
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let c2 = pt(), let p = pt() else { return paths }
                path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
                cubic = c2; cur = p
            case UInt8(ascii: "q"):
                guard let q = pt(), let p = pt() else { return paths }
                quadratic(path, from: cur, control: q, to: p)
                quad = q; cur = p
            case UInt8(ascii: "t"):
                let q = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let p = pt() else { return paths }
                quadratic(path, from: cur, control: q, to: p)
                quad = q; cur = p
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = pt() else { return paths }
                arc(path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p
            case UInt8(ascii: "z"):
                path.close()
                cur = start
                cmd = 0  // a command letter must follow
            default:
                return paths
            }
            lastCubic = cubic; lastQuad = quad
        }
        if !path.isEmpty { paths.append(path) }
        return paths
    }

    private static func quadratic(_ path: NSBezierPath, from p0: CGPoint, control q: CGPoint, to p: CGPoint) {
        path.curve(to: p, controlPoint1: CGPoint(x: p0.x + 2 / 3 * (q.x - p0.x), y: p0.y + 2 / 3 * (q.y - p0.y)),
                   controlPoint2: CGPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y)))
    }

    /// An SVG elliptical arc as cubic Béziers (SVG 1.1 appendix F.6.5–F.6.6), at most a quarter
    /// turn per segment.
    private static func arc(_ path: NSBezierPath, from p0: CGPoint, to p: CGPoint, rx: CGFloat, ry: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p else { path.line(to: p); return }
        let phi = rotation * .pi / 180, cosφ = cos(phi), sinφ = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cosφ * dx + sinφ * dy, y1 = -sinφ * dx + cosφ * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = (max(num, 0) / den).squareRoot()
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosφ * cx1 - sinφ * cy1 + (p0.x + p.x) / 2
        let cy = sinφ * cx1 + cosφ * cy1 + (p0.y + p.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }

        let n = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let step = delta / CGFloat(n)
        let t = 4 / 3 * tan(step / 4)
        func onEllipse(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosφ - ry * sin(a) * sinφ, y: cy + rx * cos(a) * sinφ + ry * sin(a) * cosφ)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosφ - ry * cos(a) * sinφ, y: -rx * sin(a) * sinφ + ry * cos(a) * cosφ)
        }
        var a = theta
        for i in 0..<n {
            let b = a + step
            let s0 = onEllipse(a), d0 = derivative(a), d1 = derivative(b)
            let e = i == n - 1 ? p : onEllipse(b)
            path.curve(to: e, controlPoint1: CGPoint(x: s0.x + t * d0.x, y: s0.y + t * d0.y),
                       controlPoint2: CGPoint(x: e.x - t * d1.x, y: e.y - t * d1.y))
            a = b
        }
    }

    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        var peek: UInt8? { i < b.count ? b[i] : nil }

        func isCommand(_ c: UInt8) -> Bool {
            "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
        }

        mutating func skipSeparators() {
            while let c = peek, c == 0x20 || c == 0x2C || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 }
        }

        /// An arc flag: one `0` or `1`, which may be followed directly by the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek, c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else { return nil }
            i += 1
            return c == UInt8(ascii: "1")
        }

        /// A number: sign, digits, at most one dot (a second dot starts the next number), exponent.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let from = i
            if let c = peek, c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { i += 1 }
            var dot = false, digits = false
            while let c = peek {
                if c >= 0x30 && c <= 0x39 { digits = true; i += 1 }
                else if c == UInt8(ascii: "."), !dot { dot = true; i += 1 }
                else { break }
            }
            if digits, let c = peek, c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                i += 1
                if let c = peek, c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { i += 1 }
                while let c = peek, c >= 0x30 && c <= 0x39 { i += 1 }
            }
            guard digits else { i = from; return nil }
            return CGFloat(Double(String(decoding: b[from..<i], as: UTF8.self)) ?? 0)
        }
    }
}
