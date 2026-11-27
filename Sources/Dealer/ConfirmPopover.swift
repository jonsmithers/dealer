import AppKit
import GhosttyKit

/// Where a close confirmation points: a popover hanging from the thing being closed (the tab
/// button, the pane's bar or top edge, the workspace's sidebar row, pill or titlebar switcher),
/// rather than a sheet from the window's titlebar. `confirm` falls back to a sheet without one.
struct ConfirmAnchor {
    let view: NSView
    let rect: NSRect
    let edge: NSRectEdge
    /// Whether `view` still shows what's being closed (recycled views can show another).
    let shows: () -> Bool

    /// Below `rect` in `view` (all our views are flipped), or beside it with `edge: .maxX`.
    init?(_ view: NSView, rect: NSRect? = nil, edge: NSRectEdge? = nil, shows: @escaping () -> Bool = { true }) {
        guard Self.isShown(view) else { return nil }
        self.view = view
        self.rect = rect ?? view.bounds
        self.edge = edge ?? (view.isFlipped ? .maxY : .minY)
        self.shows = shows
    }

    static func isShown(_ view: NSView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0
    }
}

/// The popover `confirm` shows for an anchored question: title, what's still running, and
/// Cancel / a destructive accept button (return accepts, esc cancels, a click outside cancels).
final class ConfirmPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    let message: String
    let acceptButton: NSButton
    let cancelButton: NSButton
    private var action: (() -> Void)?
    private var otherwise: (() -> Void)?
    private var onClose: ((ConfirmPopover) -> Void)?
    private(set) weak var anchorView: NSView?
    private var anchorShows: () -> Bool = { true }

    init(message: String, info: String, accept: String, cancel: String,
         action: @escaping () -> Void, otherwise: (() -> Void)?) {
        self.message = message
        self.action = action
        self.otherwise = otherwise
        acceptButton = NSButton(title: accept, target: nil, action: nil)
        cancelButton = NSButton(title: cancel, target: nil, action: nil)
        super.init()

        let title = NSTextField(labelWithString: message)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(wrappingLabelWithString: info)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 260

        acceptButton.target = self
        acceptButton.action = #selector(accepted)
        // Red text, not a default button's fill; return reaches it through `ConfirmPopoverView`.
        acceptButton.hasDestructiveAction = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelled)
        cancelButton.keyEquivalent = "\u{1b}"
        for b in [cancelButton, acceptButton] { b.controlSize = .large }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        acceptButton.attributedTitle = NSAttributedString(string: accept, attributes: [
            .foregroundColor: NSColor.systemRed, .paragraphStyle: centered,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large)),
        ])
        let buttons = NSStackView(views: [cancelButton, acceptButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        let stack = ConfirmPopoverView(views: [title, detail, buttons])
        stack.onReturn = { [weak self] in self?.accepted() }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: detail)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let vc = NSViewController()
        vc.view = stack
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = !AttentionFade.reduceMotion
        // Light or dark like the chrome, which follows the terminal background, not macOS.
        popover.appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
        popover.delegate = self
    }

    func show(at anchor: ConfirmAnchor, onClose: @escaping (ConfirmPopover) -> Void) {
        self.onClose = onClose
        anchorView = anchor.view
        anchorShows = anchor.shows
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
        // Take the keys from the terminal, so return and esc answer the question.
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func accepted() { finish(accepted: true) }
    @objc private func cancelled() { finish(accepted: false) }

    /// Cancels it once what it hangs from is gone or hidden (closed by its shell, another
    /// workspace shown); the controller asks after every layout pass.
    func cancelIfAnchorGone() {
        guard popover.isShown, !(anchorView.map(ConfirmAnchor.isShown) ?? false) || !anchorShows() else { return }
        finish(accepted: false)
    }

    /// Closes it without running either answer's action, as if never asked (a window closing).
    func abandon() {
        action = nil
        otherwise = nil
        popover.close()
    }

    private func finish(accepted: Bool) {
        let run = accepted ? action : otherwise
        action = nil
        otherwise = nil
        popover.close()
        run?()
    }

    /// A click outside or a lost anchor: Cancel.
    func popoverDidClose(_ notification: Notification) {
        let run = otherwise
        action = nil
        otherwise = nil
        onClose?(self)
        onClose = nil
        run?()
    }
}

/// The popover's content: return (or enter) accepts, like the alert's default button did.
final class ConfirmPopoverView: NSStackView {
    var onReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard event.type == .keyDown, mods.isEmpty, event.charactersIgnoringModifiers == "\r" || event.keyCode == 76,
              let onReturn else { return super.performKeyEquivalent(with: event) }
        onReturn()
        return true
    }
}

extension TerminalWindowController {
    /// Where a question about closing `pane` hangs: its bar (at the × while the pointer is on
    /// it), or the top edge of a pane with no bar.
    func confirmAnchor(pane: Pane) -> ConfirmAnchor? {
        let view = pane.view
        let shows = { [weak self, weak pane] in pane.map { self?.locate($0) != nil } ?? false }
        if view.showsBar, !view.bar.isHidden {
            return ConfirmAnchor(view.bar, rect: view.bar.hovering ? view.bar.closeButton.frame : nil, shows: shows)
        }
        return ConfirmAnchor(view, rect: CGRect(x: 0, y: 0, width: view.bounds.width, height: 1), shows: shows)
    }

    /// A tab's button, in its deck's strip or the titlebar (at the × while the pointer is on it).
    func confirmAnchor(tab: Tab) -> ConfirmAnchor? {
        guard let deck = deck(of: tab), let b = deck.view.strip.buttons.first(where: { $0.tab === tab }) else {
            return nil
        }
        return ConfirmAnchor(b, rect: b.hoveringClose ? b.closeRect : nil) { [weak b, weak tab] in
            tab != nil && b?.tab === tab
        }
    }

    /// A workspace's switcher entry: its sidebar row (beside it), its pill, or the titlebar
    /// switcher naming it. None for a member of a collapsed group, or with every switcher hidden.
    func confirmAnchor(workspace ws: Workspace) -> ConfirmAnchor? {
        let shows = { [weak self, weak ws] in ws.map { w in self?.workspaces.contains { $0 === w } ?? false } ?? false }
        if let row = workspaceSidebar.row(for: ws) {
            if let a = ConfirmAnchor(row, edge: .maxX, shows: { [weak row, weak ws] in shows() && row?.workspace === ws }) { return a }
        }
        if let pill = workspaceBar.button(for: ws) {
            if let a = ConfirmAnchor(pill, shows: { [weak pill, weak ws] in shows() && pill?.workspace === ws }) { return a }
        }
        if ws === activeWorkspace, showsTitlebarSwitcher {
            return ConfirmAnchor(titlebarSwitcher) { [weak self, weak ws] in shows() && self?.activeWorkspace === ws }
        }
        return nil
    }

    /// What's keeping `panes` busy, for a close question: "Claude Code is still working",
    /// "“vim” is still running", "“vim” and “npm” are still running"; `fallback` when no busy
    /// pane's program can be named.
    static func stillRunning(_ panes: [Pane], fallback: String) -> String {
        let busy = panes.filter { $0.surface.needsConfirmQuit }
        if busy.count == 1, busy[0].workingMark == .claude { return "Claude Code is still working" }
        var names: [String] = []
        for p in busy {
            guard let n = runningProgram(p), !names.contains(n) else { continue }
            names.append(n)
        }
        switch names.count {
        case 0: return fallback
        case 1: return "\(names[0]) is still running"
        case 2: return "\(names[0]) and \(names[1]) are still running"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more are still running"
        }
    }

    /// The pane's foreground program, quoted ("“vim”"), or "Claude Code"; nil at a bare shell.
    private static func runningProgram(_ p: Pane) -> String? {
        guard let s = p.surface.surface else { return nil }
        let fg = Int32(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
        // A shell that is still starting counts as busy too; it isn't what's "still running".
        guard fg > 0, !ControlHandler.atShellPrompt(p) else { return nil }
        // A native Claude's process name is its version, so ask ProgressSource (#81).
        if p.workingMark == .claude || ProgressSource.isClaude(foregroundGroup: fg) { return "Claude Code" }
        return ProcessTree.arguments(of: fg)?.first.map { "“\(($0 as NSString).lastPathComponent)”" }
    }
}
