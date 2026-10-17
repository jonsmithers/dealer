import AppKit
import GhosttyKit

/// Where a new pane starts (#32). Like Ghostty, a new split, tab or window starts in the source
/// pane's current directory: the one its shell last reported (OSC 7, via shell integration), else
/// the directory the pane was created in. Ghostty's `split-`, `tab-` and
/// `window-inherit-working-directory` settings (all default true) turn that off per context, and
/// then the new pane gets nil: ghostty's own `working-directory`.
enum WorkingDirectory {
    /// The kind of thing being created, mapped onto Ghostty's three settings. Workspaces count as
    /// windows: Ghostty has no workspaces, and a workspace is a fresh top-level context.
    enum Context: String {
        case split, tab, window
        var configKey: String { "\(rawValue)-inherit-working-directory" }
    }

    /// Reads a boolean from the user's ghostty config. Swappable for the self-test.
    static var configBool: (String) -> Bool? = { key in
        guard let cfg = GhosttyRuntime.shared.config else { return nil }
        var v = false
        return ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)) ? v : nil
    }

    /// `path` with a leading home directory shown as `~`. Only a whole path component counts:
    /// `/Users/jonx/p` stays as it is for home `/Users/jon` (it used to become `~x/p`, #57).
    static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func inherits(_ context: Context) -> Bool { configBool(context.configKey) ?? true }

    /// The directory a new pane created from `source` should start in, or nil for ghostty's default.
    static func inherited(from source: Pane?, for context: Context) -> String? {
        guard inherits(context), let dir = source?.pwd, !dir.isEmpty else { return nil }
        return dir
    }
}
