import AppKit

// MARK: - Tab style and the one shape tab drawing follows (#84)
//
// `[tabs] style`: "connected" (default) or "pill". Connected tabs follow VS Code's walk-back from
// pills: the active tab has rounded top corners and square bottom ones, has the terminal's
// background, and runs straight into its deck's content card, whose top corners go square where the
// strip sits on it. Pill tabs are the earlier look: a rounded rect floating in the strip over a
// fully rounded card.
//
// Both styles go through one drawing path. A `ChromeShape` is the outline an element's fill, its
// color tint (`ColorStyle.drawTint`) and its attention mark (`AttentionStyle.draw`) follow; tab
// buttons pass theirs, every other element passes a plain rounded rect (`cornerRadius:` forwards).

enum TabStyle: String, CaseIterable {
    case connected, pill

    /// The style every strip draws in. Titlebar strips (#16) connect too (the user's call, #84):
    /// the titlebar row's bottom edge is the top deck's card edge, so the active tab runs down into
    /// its deck the same way.
    static var current: TabStyle { Settings.tabStyle }

    /// How connected tabs draw on a translucent window (#87). Pill tabs are opaque either way (#67).
    enum Translucent {
        /// The active tab is opaque, the terminal's background (#87 option a), over an opaque chrome
        /// pill for each inactive tab: the same contrast as an opaque window.
        case opaque
        /// The active tab is part of its terminal (#84): it shows what the terminal shows (the
        /// background at `background-opacity`, nothing under glass), cut out of the chrome with its
        /// card, plus a faint foreground tint (`activeTint`, #87 option b) so it outranks the
        /// opaque inactive pills.
        case tinted
        /// As `tinted`, but inactive tabs get no pill: only the active tab has a shape (#87 option c).
        case clearInactive
    }
    /// One switch, the user's call after the #87 screenshots.
    static var translucent: Translucent = .opaque
    /// Whether a connected active tab shows its terminal through a translucent window (#84), cut out
    /// of the chrome with its card, instead of an opaque fill.
    static var connectedMatchesTerminal: Bool { translucent != .opaque }
    /// The foreground tint over a translucent connected active tab (`.tinted`, `.clearInactive`).
    static let activeTint: CGFloat = 0.08

    /// How far a connected strip reaches down into its deck's card: the card's 1pt hairline border
    /// (`DeckView.content`'s layer border), which the active tab paints over so there's no seam.
    var overlap: CGFloat { self == .connected ? 1 : 0 }
}

/// The outline of a chrome element: a rounded rect, or a connected tab (rounded top, square bottom,
/// and an outline with no bottom edge, since that edge is where the tab joins its content).
struct ChromeShape: Equatable {
    var radius: CGFloat
    var openBottom = false

    static func rounded(_ radius: CGFloat) -> ChromeShape { ChromeShape(radius: radius) }
    static var connectedTab: ChromeShape { ChromeShape(radius: Theme.Metrics.tabRadius, openBottom: true) }

    /// The filled area, `inset` in from every edge but an open bottom (which stays on `rect.maxY`).
    func fillPath(in rect: CGRect, inset: CGFloat = 0) -> NSBezierPath {
        let r = max(radius - inset, 0)
        guard openBottom else {
            return NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: r, yRadius: r)
        }
        let b = CGRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - 2 * inset, height: rect.height - inset)
        let p = topRounded(b, r)
        p.close()
        return p
    }

    /// A stroke path centred `inset` in from the edges (pass half the line width to keep the
    /// stroke inside `rect`). An open bottom isn't stroked.
    func outlinePath(in rect: CGRect, inset: CGFloat) -> NSBezierPath {
        guard openBottom else { return fillPath(in: rect, inset: inset) }
        let b = CGRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - 2 * inset, height: rect.height - inset)
        return topRounded(b, max(radius - inset, 0))
    }

    /// Bottom-left, up, round the top corners, down to bottom-right (flipped: minY is the top).
    private func topRounded(_ b: CGRect, _ r: CGFloat) -> NSBezierPath {
        let r = min(r, b.width / 2, b.height)
        let p = NSBezierPath()
        p.move(to: CGPoint(x: b.minX, y: b.maxY))
        p.line(to: CGPoint(x: b.minX, y: b.minY + r))
        p.appendArc(from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.minX + r, y: b.minY), radius: r)
        p.line(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.appendArc(from: CGPoint(x: b.maxX, y: b.minY), to: CGPoint(x: b.maxX, y: b.minY + r), radius: r)
        p.line(to: CGPoint(x: b.maxX, y: b.maxY))
        return p
    }

    /// A deck card's outline for the translucent chrome's cut-out (#67): rounded `radius` corners,
    /// square top ones when `squareTop`, and, with a connected active `tab` sitting on it, that
    /// tab's shape joined on as one outline (rect coordinates are the same flipped space).
    static func cardOutline(_ card: CGRect, radius: CGFloat, squareTop: Bool, tab: CGRect?) -> NSBezierPath {
        let R = min(radius, card.width / 2, card.height / 2)
        let rt = squareTop ? 0 : R
        let p = NSBezierPath()
        p.move(to: CGPoint(x: card.minX, y: card.minY + rt))
        if rt > 0 { p.appendArc(from: CGPoint(x: card.minX, y: card.minY), to: CGPoint(x: card.minX + rt, y: card.minY), radius: rt) }
        if let tab, tab.minY < card.minY, tab.minX >= card.minX, tab.maxX <= card.maxX {
            let r = min(Theme.Metrics.tabRadius, tab.width / 2, card.minY - tab.minY)
            p.line(to: CGPoint(x: tab.minX, y: card.minY))
            p.line(to: CGPoint(x: tab.minX, y: tab.minY + r))
            p.appendArc(from: CGPoint(x: tab.minX, y: tab.minY), to: CGPoint(x: tab.minX + r, y: tab.minY), radius: r)
            p.line(to: CGPoint(x: tab.maxX - r, y: tab.minY))
            p.appendArc(from: CGPoint(x: tab.maxX, y: tab.minY), to: CGPoint(x: tab.maxX, y: tab.minY + r), radius: r)
            p.line(to: CGPoint(x: tab.maxX, y: card.minY))
        }
        p.line(to: CGPoint(x: card.maxX - rt, y: card.minY))
        if rt > 0 { p.appendArc(from: CGPoint(x: card.maxX, y: card.minY), to: CGPoint(x: card.maxX, y: card.minY + rt), radius: rt) }
        p.line(to: CGPoint(x: card.maxX, y: card.maxY - R))
        p.appendArc(from: CGPoint(x: card.maxX, y: card.maxY), to: CGPoint(x: card.maxX - R, y: card.maxY), radius: R)
        p.line(to: CGPoint(x: card.minX + R, y: card.maxY))
        p.appendArc(from: CGPoint(x: card.minX, y: card.maxY), to: CGPoint(x: card.minX, y: card.maxY - R), radius: R)
        p.close()
        return p
    }
}

extension DeckView {
    /// Sets the strip's style and the card's matching corners together.
    func setTabStyle(_ style: TabStyle) {
        strip.style = style
        squareTop = style == .connected
        needsLayout = true
    }
}
