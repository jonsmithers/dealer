import Foundation

/// Port of Ghostty's `Ghostty.Shell` (macos/Sources/Ghostty/Ghostty.Shell.swift at the pin).
enum ShellEscape {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Backslash-escapes shell-sensitive characters, for typing a path or URL into a live shell (#51).
    static func escape(_ str: String) -> String {
        var result = str
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}
