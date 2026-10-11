import AppKit

/// Whether a window's contents can be seen, for pane occlusion (#54). Minimized, fully covered
/// and other-Space windows report no `.visible` occlusion bit. A window that has never reported
/// `.visible` (e.g. on a display that never sets it) counts as visible, as cmux does, so its
/// panes are never left undrawn.
enum WindowVisibility {
    private static let reportedVisible = NSHashTable<NSWindow>.weakObjects()
    /// Self-test only: forces the answer for a window, to test the rule without the window server.
    static let overrides = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()

    static func isVisible(_ window: NSWindow) -> Bool {
        if let forced = overrides.object(forKey: window) { return forced.boolValue }
        if window.isMiniaturized || !window.isVisible { return false }
        if window.occlusionState.contains(.visible) {
            reportedVisible.add(window)
            return true
        }
        return !reportedVisible.contains(window)
    }
}
