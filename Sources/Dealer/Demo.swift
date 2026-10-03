import AppKit

/// Scripted demos for the README recordings (#26). `DEALER_SELFTEST=1 DEALER_DEMO=<name>` runs one
/// at a watchable pace instead of the self-test, with the self-test's isolation (no session,
/// temp settings). Names: `panes`, `workspaces`, `attention`. `scripts/record-demo.sh` records them.
///
/// Every pane gets a neutral shell: `ZDOTDIR=$DEALER_DEMO_DIR` (default /tmp/demo, prepared by the
/// script) so the user's prompt, history and paths never show.
enum Demo {
    static var name: String? { SelfTest.enabled ? SelfTest.env("DEMO") : nil }
    static var directory: String { SelfTest.env("DEMO_DIR") ?? "/tmp/demo" }
    /// Seconds between steps.
    static var pace: TimeInterval { Double(SelfTest.env("DEMO_PACE") ?? "") ?? 1.6 }

    /// Pane hooks: where demo shells start and what they read.
    static var workingDirectory: String? { name == nil ? nil : directory }
    static var environment: [String: String] { name == nil ? [:] : ["ZDOTDIR": directory, "HISTFILE": "/dev/null"] }
}

/// The caption shown at the bottom of the window during a demo.
final class DemoCaptionView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Theme.foreground.withAlphaComponent(0.16).cgColor
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Theme.text
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, in parent: NSView) {
        label.stringValue = text
        label.sizeToFit()
        let w = label.frame.width + 32, h: CGFloat = 32
        let b = parent.bounds
        frame = CGRect(x: ((b.width - w) / 2).rounded(), y: b.height - h - 20, width: w, height: h)
        label.frame = CGRect(x: 16, y: (h - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        isHidden = text.isEmpty
    }
}

extension TerminalWindowController {
    func runDemo(_ name: String) {
        window?.setContentSize(NSSize(width: 1000, height: 600))
        window?.center()
        // Recorded as a screen region (no cursor, no capture badge), so nothing may cover it.
        window?.level = .floating
        window?.orderFrontRegardless()
        let caption = DemoCaptionView()
        var steps: [(String, () -> Void)] = []
        func step(_ text: String, _ run: @escaping () -> Void = {}) { steps.append((text, run)) }
        // A new shell needs a moment before its prompt is up; typing earlier echoes the text twice.
        func type(_ p: Pane?, _ s: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak p] in p?.surface.typeText(s) }
        }
        func named(_ p: Pane?, _ n: String) { p?.customTitle = n }

        let first = focusedPane
        named(first, "server")
        switch name {
        case "panes":
            var logs: Pane?, build: Pane?, logsDeck: Deck?
            step("A deck with one tab") { type(first, "ls\r") }
            step("⌘T  new tab") {
                self.newTab(nil); named(self.focusedPane, "tests"); type(self.focusedPane, "make test\r")
            }
            step("⌘1  back to the first tab") { self.gotoTab(index: 0) }
            step("⌘D  split the tab into panes") {
                self.splitRight(nil); logs = self.focusedPane; named(logs, "logs"); type(logs, "cat server.log\r")
            }
            step("⌘⇧D  split again") {
                self.splitDown(nil); build = self.focusedPane; named(build, "build"); type(build, "git --no-pager log --oneline\r")
            }
            step("⌘⇧P  promote: the pane becomes a deck") {
                if let n = build.flatMap({ self.locate($0)?.node }) { _ = self.promote(n) }
            }
            step("⌘⇧F  fold: back where it came from") {
                if let d = build.flatMap({ self.locate($0)?.deck }) { _ = self.fold(d) }
            }
            step("Promote another pane") {
                if let n = logs.flatMap({ self.locate($0)?.node }) { _ = self.promote(n) }
                logsDeck = logs.flatMap { self.locate($0)?.deck }
            }
            step("Each deck has its own tabs") {
                if let d = logsDeck { self.newTab(in: d); named(self.focusedPane, "shell") }
            }
            step("Drop a pane on a deck's tab strip: it becomes a tab there") {
                if let n = build.flatMap({ self.locate($0)?.node }), let d = logsDeck { self.moveToNewTab(n, deck: d, index: d.tabs.count) }
            }
            step("⌘1  tabs switch per deck") { if let d = logsDeck, let t = d.tabs.first { self.select(tab: t, in: d) } }
            step("")
        case "workspaces":
            var web: Workspace?, tests: Tab?
            step("Workspaces: separate layouts in one window") {
                type(first, "ls\r")
                self.newTab(nil); named(self.focusedPane, "tests"); type(self.focusedPane, "make test\r"); tests = self.focusedDeck?.activeTab
                self.gotoTab(index: 0)
                if let ws = self.workspaces.first { self.rename(workspace: ws, to: "api") }
            }
            step("⌃⌘N  new workspace: the sidebar appears") {
                web = self.newWorkspace(name: "web"); named(self.focusedPane, "dev server"); type(self.focusedPane, "ls src\r")
            }
            step("⌘D  it has its own panes") { self.splitRight(nil); named(self.focusedPane, "styles") }
            step("⌃1  switch back") { self.activateWorkspace(index: 0) }
            step("⌃2") { self.activateWorkspace(index: 1) }
            step("⌃⌘N  and another") { _ = self.newWorkspace(name: "docs"); named(self.focusedPane, "notes") }
            step("⌃1") { self.activateWorkspace(index: 0) }
            step("Move a tab to another workspace") {
                if let tests, let web { _ = self.move(tab: tests, toWorkspace: web) }
            }
            step("It's there now") { if let web { self.activate(web) } }
            step("")
        case "attention":
            var agent: Pane?
            step("An agent runs in the right pane") {
                if let ws = self.workspaces.first { self.rename(workspace: ws, to: "app") }
                named(first, "editor")
                self.splitRight(nil); agent = self.focusedPane; named(agent, "agent")
                named(self.newWorkspace(name: "docs", activate: false).panes.first, "notes")
                if let first { self.focus(first) }
            }
            step("It asks for permission: dealer notify --state waiting") {
                type(agent, "sleep 1; dealer notify --state waiting --title Agent --body 'Permission needed'\r")
            }
            step("Waiting: a blue outline on the pane, its tab and its workspace")
            step("Visible from other workspaces too") { self.activateWorkspace(index: 1) }
            step("⌘⇧U  jumps to it (and clears it)") { self.jumpToNextUnread(nil) }
            step("It finishes: dealer notify --state done") {
                type(agent, "sleep 1; dealer notify --state done --title Agent --body Finished\r")
                if let first { self.focus(first) }
            }
            step("Done: a quiet dot, nothing urgent")
            step("")
        default:
            step("unknown demo \(name)")
        }

        var i = 0
        func next() {
            guard i < steps.count else { return }
            let (text, run) = steps[i]
            i += 1
            run()
            layoutNow()
            if let cv = window?.contentView { caption.show(text, in: cv) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Demo.pace) { next() }
        }
        // Let the shells start before the first step.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { next() }
    }
}
