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
