import AppKit
import IOKit.pwr_mgt

// MARK: - Keep the display awake while agents work (#69, `[power] caffeinate`)
//
// "Working" is exactly #64's spinner condition, `Pane.isWorking` (AgentStatus.swift), counted over
// every pane of every window. `Caffeinate.shared` is the one owner of the IOKit power assertion
// (`kIOPMAssertPreventUserIdleDisplaySleep`, what `caffeinate -d` takes; no child process, and
// macOS drops it with the process). It is re-counted at the same change points that redraw the
// spinner: `refreshChrome()` (progress reports and attention changes end there), `finishChange`
// (panes closed or moved), a window closing, and a settings reload. No polling.
//
// When the last working pane stops, the assertion is kept for `grace` (30 s) so the gaps between
// an agent's steps don't release and retake it. While it's held every window shows a coffee cup at
// the right end of its titlebar row (`CaffeineIconView`), whose space is reserved whenever the
// setting is on so titlebar strips and pills don't reflow when agents start and stop.

final class Caffeinate {
    static let shared = Caffeinate()
    /// Posted when `isHeld` or the label changes; windows update their cup.
    static let didChange = Notification.Name("DealerCaffeinateDidChange")

    /// Seconds the assertion outlives the last working pane.
    static let defaultGrace: TimeInterval = 30
    /// The self-test shortens the grace; nil everywhere else.
    static var graceOverride: TimeInterval?
    static var grace: TimeInterval { graceOverride ?? defaultGrace }

    private var assertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var graceTimer: Timer?
    /// Working panes at the last count.
    private(set) var working = 0
    /// The assertion's current name, e.g. "Dealer: 2 agents working".
    private(set) var assertionName: String?
    private var started = false

    var isHeld: Bool { assertion != IOPMAssertionID(kIOPMNullAssertionID) }
    /// True between the last working pane stopping and the release.
    var isInGrace: Bool { graceTimer != nil }

    /// What the cup's tooltip and the assertion name say after their prefix.
    var label: String {
        if working > 0 { return "\(working) agent\(working == 1 ? "" : "s") working" }
        return "no agents working, releasing in \(Int(Self.grace.rounded())) s"
    }

    /// When the grace ends, while it runs.
    private(set) var graceEndsAt: Date?

    /// The cup's tooltip: what the cup means, when it stops, and how to turn it off. Built when
    /// the tooltip shows (`CaffeineIconView` owns it lazily), so the grace countdown is current.
    func toolTip(now: Date = Date()) -> String {
        let off = "Turn this off with [power] caffeinate = false in settings.toml."
        if working > 0 {
            let who = working == 1 ? "an agent works" : "\(working) agents work"
            return "Dealer is keeping your display awake while \(who). It'll sleep normally about "
                + "\(Int(Self.grace.rounded())) s after \(working == 1 ? "it finishes" : "they finish"). \(off)"
        }
        let left = max(Int((graceEndsAt ?? now).timeIntervalSince(now).rounded(.up)), 0)
        return "Dealer is keeping your display awake for \(left) more second\(left == 1 ? "" : "s"), in case "
            + "an agent picks up again, then it'll sleep normally. \(off)"
    }

    /// Called once at launch, after `Settings.start()`.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)), name: Settings.didChange, object: nil)
        update()
    }

    @objc private func settingsDidChange(_ note: Notification) { update() }

    /// Re-counts working panes and takes, renames or (after the grace) releases the assertion.
    /// Cheap and idempotent: callers invoke it on every chrome refresh.
    func update() {
        dispatchPrecondition(condition: .onQueue(.main))
        let count = Settings.caffeinate ? Self.countWorking() : 0
        let before = (isHeld, assertionName, isInGrace)
        working = count
        if !Settings.caffeinate {
            release()
        } else if count > 0 {
            graceTimer?.invalidate()
            graceTimer = nil
            graceEndsAt = nil
            hold()
        } else if isHeld, graceTimer == nil {
            let t = Timer(timeInterval: Self.grace, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.graceTimer = nil
                self.graceEndsAt = nil
                if self.working == 0 { self.release() }
                self.post()
            }
            RunLoop.main.add(t, forMode: .common)
            graceTimer = t
            graceEndsAt = Date().addingTimeInterval(Self.grace)
            hold()  // renames it to the grace label
        }
        if before != (isHeld, assertionName, isInGrace) { post() }
    }

    /// Lets go at once (quit; the setting turned off).
    func release() {
        graceTimer?.invalidate()
        graceTimer = nil
        graceEndsAt = nil
        guard isHeld else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(kIOPMNullAssertionID)
        assertionName = nil
        post()
    }

    private func hold() {
        let name = "Dealer: \(label)"
        if isHeld {
            guard name != assertionName else { return }
            IOPMAssertionSetProperty(assertion, kIOPMAssertionNameKey as CFString, name as CFString)
            assertionName = name
            return
        }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        guard r == kIOReturnSuccess else {
            NSLog("Dealer: couldn't take the display-awake power assertion (IOReturn \(r))")
            return
        }
        assertion = id
        assertionName = name
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    static func countWorking() -> Int {
        AppDelegate.shared.windowControllers.reduce(0) { n, wc in
            n + wc.allDecks.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.panes.filter(\.isWorking).count } }
        }
    }

    /// This process's display-sleep assertions as IOKit reports them (name per assertion), for
    /// the self-test and `dealer diagnose`-style checks.
    static func ownAssertionNames() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = dict.first { $0.key.int32Value == getpid() }?.value ?? []
        return mine.filter { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertPreventUserIdleDisplaySleep }
            .compactMap { $0[kIOPMAssertionNameKey] as? String }
    }
}

// MARK: - The titlebar cup

/// `cup.and.saucer.fill` at the right end of the titlebar row, shown only while the assertion is
/// held. No click action: it answers `mouseDownCanMoveWindow` like empty titlebar, so pressing it
/// drags the window (#27).
///
/// The tooltip is one tooltip rect owned by the view (`addToolTip(_:owner:userData:)`), registered
/// when the size changes and asked for its text only when it shows, never a `toolTip` string
/// re-set on each layout: setting `toolTip` removes and re-adds the rect, which restarts AppKit's
/// hover delay, and layout passes come often while agents work (titles change, progress flips).
final class CaffeineIconView: FlippedView, ThemeApplying, NSViewToolTipOwner {
    private var toolTipTag: NSView.ToolTipTag?

    static var width: CGFloat { Theme.Metrics.caffeineIconWidth }
    static var glyphSize: CGFloat { Theme.Metrics.caffeineGlyphSize }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = nil
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed || toolTipTag == nil {
            if let tag = toolTipTag { removeToolTip(tag) }
            toolTipTag = addToolTip(bounds, owner: self, userData: nil)
        }
    }

    /// The live text (`Caffeinate.toolTip`), asked for by AppKit when the tooltip is about to show.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        Caffeinate.shared.isHeld ? Caffeinate.shared.toolTip() : ""
    }

    /// What the tooltip would say now (the self-test reads it).
    var currentToolTip: String { view(self, stringForToolTip: 0, point: .zero, userData: nil) }

    func applyTheme() { needsDisplay = true }

    /// The symbol in `Theme.text`, read at draw time so a live theme change applies.
    static func image(color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keeping the display awake")?
            .withSymbolConfiguration(config)
    }

    /// Where the glyph is drawn, centred in the view.
    var glyphRect: CGRect {
        guard let img = Self.image(color: Theme.text) else { return .zero }
        let s = img.size
        return CGRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                      width: s.width, height: s.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = Self.image(color: Theme.text) else { return }
        img.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension TerminalWindowController {
    /// Width reserved at the right end of the titlebar row for the cup: whenever `[power]
    /// caffeinate` is on, held or not, so strips and pills don't reflow as agents start and stop.
    var titlebarTrailingReserve: CGFloat {
        Settings.caffeinate ? CaffeineIconView.width + Self.deckGap : 0
    }

    /// The x where titlebar strips and pills must end.
    var titlebarTrailingX: CGFloat { contentView.bounds.width - titlebarTrailingReserve }

    /// Places the cup and shows it while the assertion is held. Called from `layoutWindow` and on
    /// `Caffeinate.didChange`.
    func layoutCaffeineIcon() {
        guard !isClosed else { return }
        let icon = caffeineIcon
        if icon.superview !== contentView { contentView.addSubview(icon) }
        let h = deckArea.minY
        icon.frame = CGRect(x: contentView.bounds.width - Self.deckGap - CaffeineIconView.width, y: 0,
                            width: CaffeineIconView.width, height: h)
        let c = Caffeinate.shared
        icon.isHidden = !c.isHeld
        icon.needsDisplay = true
    }

    /// Called once from `init`.
    func observeCaffeinate() {
        NotificationCenter.default.addObserver(self, selector: #selector(caffeinateDidChange(_:)), name: Caffeinate.didChange, object: nil)
    }

    @objc private func caffeinateDidChange(_ note: Notification) { layoutCaffeineIcon() }
}
