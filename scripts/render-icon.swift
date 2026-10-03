#!/usr/bin/env swift
// Renders Dealer's 1024x1024 app icon master (#22): a hand of glowing terminal "cards"
// fanned out on a dark-blue macOS squircle, the front card showing a prompt and a small agent face.
// Usage: swift scripts/render-icon.swift OUT.png   (scripts/make-icon.sh drives this)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work top-down (y grows downward) like the design grid.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// MARK: squircle body (macOS grid: 824pt body centred on the 1024 canvas)

/// Superellipse-ish continuous-corner rounded rect, close to Apple's icon shape.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.28 // corner extends past the circular radius for a continuous curve
    let c = radius * k
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    p.move(to: CGPoint(x: x0 + c, y: y0))
    p.addLine(to: CGPoint(x: x1 - c, y: y0))
    p.addCurve(to: CGPoint(x: x1, y: y0 + c), control1: CGPoint(x: x1 - c * 0.24, y: y0),
               control2: CGPoint(x: x1, y: y0 + c * 0.24))
    p.addLine(to: CGPoint(x: x1, y: y1 - c))
    p.addCurve(to: CGPoint(x: x1 - c, y: y1), control1: CGPoint(x: x1, y: y1 - c * 0.24),
               control2: CGPoint(x: x1 - c * 0.24, y: y1))
    p.addLine(to: CGPoint(x: x0 + c, y: y1))
    p.addCurve(to: CGPoint(x: x0, y: y1 - c), control1: CGPoint(x: x0 + c * 0.24, y: y1),
               control2: CGPoint(x: x0, y: y1 - c * 0.24))
    p.addLine(to: CGPoint(x: x0, y: y0 + c))
    p.addCurve(to: CGPoint(x: x0 + c, y: y0), control1: CGPoint(x: x0, y: y0 + c * 0.24),
               control2: CGPoint(x: x0 + c * 0.24, y: y0))
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body, radius: 160)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x0d2148))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
// Vertical navy gradient.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1f4a82), rgb(0x112a5a), rgb(0x0a1a3c)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// Soft blue bloom behind the cards.
let bloom = CGGradient(colorsSpace: space, colors: [rgb(0x3d8bff, 0.45), rgb(0x3d8bff, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 540, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 540, y: 540), endRadius: 420, options: [])
ctx.restoreGState()

// Rim: a faint light edge, brighter at the top.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.setLineWidth(6)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: space, colors: [rgb(0x9cc4ff, 0.55), rgb(0x5d86c8, 0.15)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

// MARK: cards

let glow = rgb(0x48b4ff, 0.9)

/// Strokes the current path with a neon glow: a wide blurred pass then a crisp line.
func neon(_ path: CGPath, width: CGFloat, color: CGColor, glowBlur: CGFloat = 22) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glowBlur, color: glow)
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width * 0.6)
    ctx.strokePath()
}

func text(_ s: String, at p: CGPoint, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: glow)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = p
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let cardW: CGFloat = 330, cardH: CGFloat = 450, cardR: CGFloat = 34

/// Card outline in card-local coordinates (origin top-left). The front card gets a folder-like
/// tab cut into its top-right corner.
func cardPath(tab: Bool) -> CGPath {
    let r = CGRect(x: 0, y: 0, width: cardW, height: cardH)
    if !tab { return CGPath(roundedRect: r, cornerWidth: cardR, cornerHeight: cardR, transform: nil) }
    let p = CGMutablePath()
    let tabX: CGFloat = cardW - 150, notch: CGFloat = 44
    p.move(to: CGPoint(x: cardR, y: 0))
    p.addLine(to: CGPoint(x: tabX - 8, y: 0))
    p.addQuadCurve(to: CGPoint(x: tabX + 14, y: 12), control: CGPoint(x: tabX + 6, y: 0))
    p.addLine(to: CGPoint(x: tabX + notch - 14, y: notch - 12))
    p.addQuadCurve(to: CGPoint(x: tabX + notch + 8, y: notch), control: CGPoint(x: tabX + notch - 6, y: notch))
    p.addArc(tangent1End: CGPoint(x: cardW, y: notch), tangent2End: CGPoint(x: cardW, y: cardH), radius: cardR)
    p.addArc(tangent1End: CGPoint(x: cardW, y: cardH), tangent2End: CGPoint(x: 0, y: cardH), radius: cardR)
    p.addArc(tangent1End: CGPoint(x: 0, y: cardH), tangent2End: CGPoint(x: 0, y: 0), radius: cardR)
    p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: cardW, y: 0), radius: cardR)
    p.closeSubpath()
    return p
}

struct Card { var x: CGFloat; var y: CGFloat; var angle: CGFloat; var label: String; var front: Bool }
// Dealt left to right; the front card sits rightmost, like a hand being fanned.
let cards = [
    Card(x: 228, y: 300, angle: -10, label: "$_", front: false),
    Card(x: 322, y: 288, angle: -4, label: "%", front: false),
    Card(x: 406, y: 292, angle: 2, label: "#", front: false),
    Card(x: 478, y: 316, angle: 7, label: ">_", front: true),
]

for (i, c) in cards.enumerated() {
    ctx.saveGState()
    // Rotate about the card's bottom-centre so the hand fans from below.
    ctx.translateBy(x: c.x + cardW / 2, y: c.y + cardH)
    ctx.rotate(by: c.angle * .pi / 180)
    ctx.translateBy(x: -cardW / 2, y: -cardH)

    let path = cardPath(tab: c.front)
    // Glass fill: dark enough that the cards behind read as layered, light enough to glow.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let top = c.front ? rgb(0x1f5aa8, 0.92) : rgb(0x17437f, 0.88)
    let bottom = c.front ? rgb(0x0f2d66, 0.94) : rgb(0x0d2552, 0.9)
    let fill = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: .zero, end: CGPoint(x: 0, y: cardH), options: [])
    if c.front {
        // Header band below the tab, like a window title bar.
        ctx.setFillColor(rgb(0x5fb8ff, 0.18))
        ctx.fill(CGRect(x: 0, y: 44, width: cardW, height: 30))
    }
    ctx.restoreGState()

    let brightness = 0.55 + 0.15 * CGFloat(i)
    let stroke = c.front ? rgb(0x7fd6ff) : rgb(0x5aaef5, brightness)
    neon(path, width: c.front ? 9 : 7, color: stroke)

    let ink = c.front ? rgb(0xbfeaff) : rgb(0x8cc8ff, brightness)
    text(c.label, at: CGPoint(x: 34, y: c.front ? 128 : 92), size: c.front ? 64 : 58, color: ink)

    if c.front {
        // Agent face: rounded head, antenna, ears, smiling closed eyes.
        let cx: CGFloat = cardW / 2 + 6, cy: CGFloat = 290
        let face = CGMutablePath()
        face.addRoundedRect(in: CGRect(x: cx - 70, y: cy - 50, width: 140, height: 104),
                            cornerWidth: 44, cornerHeight: 44)
        face.move(to: CGPoint(x: cx, y: cy - 50))
        face.addLine(to: CGPoint(x: cx, y: cy - 86))
        face.addRoundedRect(in: CGRect(x: cx - 88, y: cy - 20, width: 18, height: 44), cornerWidth: 9, cornerHeight: 9)
        face.addRoundedRect(in: CGRect(x: cx + 70, y: cy - 20, width: 18, height: 44), cornerWidth: 9, cornerHeight: 9)
        for ex in [cx - 32, cx + 32] {
            face.move(to: CGPoint(x: ex - 15, y: cy - 2))
            face.addQuadCurve(to: CGPoint(x: ex + 15, y: cy - 2), control: CGPoint(x: ex, y: cy - 20))
        }
        face.move(to: CGPoint(x: cx - 14, y: cy + 26))
        face.addQuadCurve(to: CGPoint(x: cx + 14, y: cy + 26), control: CGPoint(x: cx, y: cy + 36))
        neon(face, width: 10, color: rgb(0x8fdcff), glowBlur: 18)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: glow)
        ctx.setFillColor(rgb(0xbfeaff))
        ctx.fillEllipse(in: CGRect(x: cx - 12, y: cy - 108, width: 24, height: 24))
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print(out)
