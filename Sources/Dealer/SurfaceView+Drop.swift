import AppKit
import GhosttyKit

// MARK: - Dropping files, URLs and text onto a pane (#51)
//
// Ported from Ghostty's NSDraggingDestination extension (SurfaceView_AppKit.swift at the pin).
// Only the terminal surface registers, so drops on a pane bar or tab strip are ignored.
// Internal tab/pane drags use DragController's own tracking loop, not NSDraggingSession.

extension SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy  // the copy icon
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = Self.dropText(from: sender.draggingPasteboard) else { return false }
        DispatchQueue.main.async { self.receiveDrop(text) }
        return true
    }

    /// What a drop types: a URL escaped as-is, else file paths each escaped and joined by spaces,
    /// else a plain string unescaped (it may be a command the user means to run).
    static func dropText(from pb: NSPasteboard) -> String? {
        if let url = pb.string(forType: .URL) { return ShellEscape.escape(url) }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { ShellEscape.escape($0.path) }.joined(separator: " ")
        }
        return pb.string(forType: .string)
    }

    /// Focuses this pane (the drop implies intent), then sends the text with paste semantics (as
    /// Ghostty does since 550151882; `insertText` now types key events), no newline.
    func receiveDrop(_ text: String) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }
}
