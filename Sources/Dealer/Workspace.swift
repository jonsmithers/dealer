import AppKit

/// The top level of a window. A window holds an ordered list of workspaces and shows one at a time;
/// each workspace owns its own deck tree, focus and selection.
///
/// Only `TerminalWindowController` assigns `root`, `focusedPane` and `selection`.
final class Workspace {
    private static var nextID = 1

    /// Process-unique and stable for the workspace's lifetime (for the control socket / CLI).
    let id: Int
    /// A name the user typed; otherwise `displayName` follows the focused terminal.
    var name: String?
    /// The workspace's color (#9, Colors.swift); nil is neutral.
    var color: NSColor?
    var root: Node<Deck>?
    /// The pane that had focus last time this workspace was active. It can be stale (moved to
    /// another workspace); the controller validates it.
    weak var focusedPane: Pane?
    /// A split selected with "Select Parent".
    var selection: Node<Pane>?

    init(root: Node<Deck>?, name: String? = nil) {
        id = Self.nextID
        Self.nextID += 1
        self.root = root
        self.name = name
    }

    var decks: [Deck] { root?.leaves ?? [] }
    var tabs: [Tab] { decks.flatMap(\.tabs) }
    var panes: [Pane] { tabs.flatMap(\.panes) }

    func contains(_ pane: Pane) -> Bool { tabs.contains { $0.root.node(for: pane) != nil } }
    func contains(_ deck: Deck) -> Bool { root?.node(for: deck) != nil }

    /// `focusedPane` if it still lives here.
    var validFocusedPane: Pane? { focusedPane.flatMap { contains($0) ? $0 : nil } }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (validFocusedPane ?? decks.first?.activeTab?.focusTarget)?.title ?? "shell"
    }
}

// MARK: - Workspace commands

extension TerminalWindowController {
    var activeWorkspaceIndex: Int { workspaces.firstIndex { $0 === activeWorkspace } ?? 0 }

    func index(of ws: Workspace) -> Int? { workspaces.firstIndex { $0 === ws } }

    /// Adds a workspace with one fresh pane after the active one.
    @discardableResult
    func newWorkspace(name: String? = nil, workingDirectory: String? = nil, activate: Bool = true) -> Workspace {
        let ws = Workspace(root: Node(makeDeck(workingDirectory: workingDirectory ?? WorkingDirectory.inherited(from: focusedPane, for: .window))), name: name)
        insert(workspace: ws, at: activeWorkspaceIndex + 1)
        if activate { self.activate(ws) } else { refreshChrome() }
        return ws
    }

    /// Switches to the workspace at `index` (0-based). Returns false when there isn't one.
    @discardableResult
    func activateWorkspace(index: Int) -> Bool {
        guard workspaces.indices.contains(index) else { return false }
        activate(workspaces[index])
        return true
    }

    func rename(workspace ws: Workspace, to name: String?) {
        let t = name?.trimmingCharacters(in: .whitespaces)
        ws.name = (t?.isEmpty ?? true) ? nil : t
        refreshChrome()
    }

    /// Closes a workspace and every terminal in it, asking first if something is still running.
    func close(workspace ws: Workspace) {
        if ws.panes.contains(where: { $0.surface.needsConfirmQuit }) {
            confirm("Close this workspace?", info: "A process is still running in one of its panes.") { [weak self, weak ws] in
                guard let self, let ws else { return }
                self.remove(workspace: ws)
            }
        } else {
            remove(workspace: ws)
        }
    }

    /// Moves a pane (or group of panes) into `target` as a new tab in its focused deck.
    /// A `nil` target makes a new workspace. The view stays put unless `follow` is set, or the
    /// source workspace empties.
    @discardableResult
    func move(_ node: Node<Pane>, toWorkspace target: Workspace?, follow: Bool = false) -> Workspace? {
        guard let src = node.leaves.first.flatMap({ locate($0) }) else { return nil }
        if src.tab.root === node { return move(tab: src.tab, toWorkspace: target, follow: follow) }
        guard target !== src.workspace else { return nil }
        let moved = focusedPane.flatMap { node.node(for: $0) != nil ? $0 : nil } ?? node.leaves.first
        let stay = node.sibling?.leaves.first
        detach(node: node, from: src.tab, in: src.deck)
        let dst = target ?? makeEmptyWorkspace(after: src.workspace)
        place(tab: Tab(root: node), in: dst)
        if let moved { dst.focusedPane = moved }
        finishChange(focus: follow ? moved : (src.workspace.validFocusedPane ?? stay))
        return dst
    }

    /// Moves a tab into `target` (nil: a new workspace), after the active tab of its focused deck.
    @discardableResult
    func move(tab: Tab, toWorkspace target: Workspace?, follow: Bool = false) -> Workspace? {
        guard let from = deck(of: tab), let srcWs = workspace(of: from), target !== srcWs else { return nil }
        let moved = tab.focusTarget
        detach(tab: tab, from: from)
        let dst = target ?? makeEmptyWorkspace(after: srcWs)
        place(tab: tab, in: dst)
        let followNow = follow || srcWs.root == nil
        finishChange(focus: followNow ? moved : srcWs.validFocusedPane)
        return dst
    }

    /// Moves a whole deck into `target` (nil: a new workspace), at its right edge.
    @discardableResult
    func move(deck: Deck, toWorkspace target: Workspace?, follow: Bool = false) -> Workspace? {
        guard let srcWs = workspace(of: deck), target !== srcWs else { return nil }
        let moved = focusedPane.flatMap { p in deck.tabs.contains { $0.root.node(for: p) != nil } ? p : nil }
            ?? deck.activeTab?.focusTarget
        detach(deck: deck)
        let dst = target ?? makeEmptyWorkspace(after: srcWs)
        place(deck: deck, in: dst)
        if let moved { dst.focusedPane = moved }
        let followNow = follow || srcWs.root == nil
        finishChange(focus: followNow ? moved : srcWs.validFocusedPane)
        return dst
    }

    /// An empty workspace for a move to fill before `finishChange` runs (which would close it).
    private func makeEmptyWorkspace(after ws: Workspace) -> Workspace {
        let new = Workspace(root: nil)
        insert(workspace: new, at: (index(of: ws) ?? workspaces.count - 1) + 1)
        return new
    }

    func renameWorkspaceInteractively(_ ws: Workspace) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Leave empty to follow the terminal title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = ws.name ?? ""
        field.placeholderString = ws.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, weak ws] resp in
            guard resp == .alertFirstButtonReturn, let ws else { return }
            self?.rename(workspace: ws, to: field.stringValue)
        }
    }

    // MARK: Menu actions

    /// Menu tags for "Move … to Workspace" items: 1–9 name a workspace, this one a new workspace.
    static let newWorkspaceTag = 100

    @objc func newWorkspace(_ sender: Any?) { newWorkspace() }

    @objc func closeWorkspace(_ sender: Any?) { close(workspace: activeWorkspace) }

    @objc func renameWorkspace(_ sender: Any?) { renameWorkspaceInteractively(activeWorkspace) }

    @objc func nextWorkspace(_ sender: Any?) {
        guard workspaces.count > 1 else { return NSSound.beep() }
        activateWorkspace(index: (activeWorkspaceIndex + 1) % workspaces.count)
    }

    @objc func previousWorkspace(_ sender: Any?) {
        guard workspaces.count > 1 else { return NSSound.beep() }
        activateWorkspace(index: (activeWorkspaceIndex - 1 + workspaces.count) % workspaces.count)
    }

    @objc func moveWorkspaceLeft(_ sender: Any?) { move(workspace: activeWorkspace, to: activeWorkspaceIndex - 1) }
    @objc func moveWorkspaceRight(_ sender: Any?) { move(workspace: activeWorkspace, to: activeWorkspaceIndex + 1) }

    @objc func gotoWorkspaceFromMenu(_ sender: NSMenuItem) {
        if !activateWorkspace(index: sender.tag - 1) { NSSound.beep() }
    }

    private func menuTarget(_ sender: NSMenuItem) -> Workspace? {
        sender.tag == Self.newWorkspaceTag ? nil : workspaces[sender.tag - 1]
    }

    @objc func movePaneToWorkspace(_ sender: NSMenuItem) {
        let node = selection ?? focusedPane.flatMap { locate($0)?.node }
        guard let node, move(node, toWorkspace: menuTarget(sender), follow: sender.tag == Self.newWorkspaceTag) != nil else { return NSSound.beep() }
    }

    @objc func moveTabToWorkspace(_ sender: NSMenuItem) {
        guard let tab = focusedDeck?.activeTab,
              move(tab: tab, toWorkspace: menuTarget(sender), follow: sender.tag == Self.newWorkspaceTag) != nil else { return NSSound.beep() }
    }

    @objc func moveDeckToWorkspace(_ sender: NSMenuItem) {
        guard let deck = focusedDeck,
              move(deck: deck, toWorkspace: menuTarget(sender), follow: sender.tag == Self.newWorkspaceTag) != nil else { return NSSound.beep() }
    }

    /// Titles, visibility and enabled state of the Workspace menu. `nil` for items it doesn't own.
    func validateWorkspaceMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(gotoWorkspaceFromMenu(_:)):
            let i = item.tag - 1
            item.isHidden = i >= max(workspaces.count, 1) && i > 0
            item.title = workspaces.indices.contains(i) ? workspaces[i].displayName : "Workspace \(item.tag)"
            item.state = workspaces.indices.contains(i) && workspaces[i] === activeWorkspace ? .on : .off
            return workspaces.indices.contains(i)
        case #selector(movePaneToWorkspace(_:)), #selector(moveTabToWorkspace(_:)), #selector(moveDeckToWorkspace(_:)):
            if item.tag == Self.newWorkspaceTag { return true }
            let i = item.tag - 1
            item.isHidden = !workspaces.indices.contains(i)
            guard workspaces.indices.contains(i) else { return false }
            item.title = "\(item.tag)  \(workspaces[i].displayName)"
            return workspaces[i] !== activeWorkspace
        case #selector(toggleWorkspaceSidebar(_:)):
            item.title = isSidebarVisible ? "Hide Workspace Sidebar" : "Show Workspace Sidebar"
            return WorkspaceSwitcher.style == .sidebar
        case #selector(useSidebarSwitcher(_:)):
            item.state = WorkspaceSwitcher.style == .sidebar ? .on : .off
            return true
        case #selector(useTopBarSwitcher(_:)):
            item.state = WorkspaceSwitcher.style == .top ? .on : .off
            return true
        case #selector(nextWorkspace(_:)), #selector(previousWorkspace(_:)):
            return workspaces.count > 1
        case #selector(moveWorkspaceLeft(_:)):
            return activeWorkspaceIndex > 0
        case #selector(moveWorkspaceRight(_:)):
            return activeWorkspaceIndex < workspaces.count - 1
        default:
            return nil
        }
    }
}
