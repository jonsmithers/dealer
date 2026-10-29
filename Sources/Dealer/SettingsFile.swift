import Foundation

/// Text-level editing of settings.toml, so in-app changes keep the user's comments and layout.
enum SettingsFile {
    /// The commented default file, identical to `docs/settings.example.toml` (the self-test checks).
    /// "Open Settings File" and the first menu write-back create the user's file from it.
    static let exampleText = """
    # Dealer settings. Terminal settings (font, colors, keybinds) stay in the ghostty config;
    # this file is only for Dealer's own behaviour.
    #
    # Location: $XDG_CONFIG_HOME/dealer/settings.toml (default ~/.config/dealer/settings.toml).
    # Dealer reloads it when it changes. Mistakes never block launch: a bad value falls back to
    # its default, and the problem is shown in a banner and logged.
    # Menu toggles (e.g. Workspace › Workspace Switcher) edit only their own line here.

    [agent]
    # The coding agent New Agent Pane (⌥⌘A) types into the new pane's shell.
    # The DEALER_AGENT_COMMAND environment variable overrides it.
    # command = "claude"

    # Whether `claude` started in a pane loads Dealer's Claude Code plugin, which reports
    # waiting/done to Dealer. Applies to panes opened after the change.
    # inject_hooks = true
    # Mark the pane failed (red) when a Claude turn ends in an API error (rate limit, overload,
    # auth); false marks it waiting (blue) instead. Applies to panes opened after the change.
    # errors_as_failed = true

    [attention]
    # The four attention states, most urgent first (a tab or workspace shows its most urgent pane,
    # and ⌘⇧U visits them in this order). A mark is skipped on the pane you're looking at.
    #
    #   state    set by                                                   default look  setting
    #   failed   `dealer run` job exits non-zero; Claude turn ends in an  red outline   not configurable
    #            API error; shell command exits non-zero (failed_commands);
    #            `dealer notify --state failed`
    #   waiting  Claude permission prompt or question; MCP input request;  blue outline  not configurable
    #            `dealer notify --state waiting`
    #   done     Claude finishes a turn; `dealer run` succeeds (the job    blue outline  done = "outline" | "dot"
    #            pane, never the pane you ran it from);
    #            `dealer notify --state done`
    #   unread   bell; desktop notification (OSC 9, 99, 777) from any      dot           unread = "dot" | "outline"
    #            program; shell command that succeeded after 10 s or more;
    #            `dealer notify` (its default state)
    #
    # "outline" draws the state exactly like waiting: a blue ring around the pane and a blue outline,
    # tint and dot on its tab and workspace. "dot" is a muted dot on the tab and workspace only.
    # done = "outline"
    # unread = "dot"

    # Mark a pane failed (red) when a shell command exits non-zero while you're not looking at it.
    # Needs shell integration (Ghostty's, which Dealer bundles).
    # failed_commands = true

    [workspaces]
    # Where the workspace switcher lives: "sidebar" (a collapsible left column) or "top"
    # (numbered pills in the titlebar row).
    # switcher = "sidebar"

    [window]
    # Put the tab strips of decks along the window's top edge into the titlebar row, like
    # Safari's compact tabs. Empty titlebar space still drags the window.
    # tabs_in_titlebar = true

    [tabs]
    # How tabs look: "connected" (the active tab joins its deck's content below it, one continuous
    # area) or "pill" (rounded tabs floating in the strip, the content a separate card).
    # style = "connected"

    [colors]
    # Workspace and tab colors: right-click a workspace or tab for Color › swatches, Custom…, None.
    # Give each new workspace the next unused swatch automatically.
    # auto_assign = false
    # Replace the preset swatches (numbered 1, 2, … in menus and `dealer color`).
    # palette = ["#e06c75", "#98c379", "#61afef", "#c678dd"]
    # How far the chrome (titlebar, tab strips, sidebar, pane bars) stands off the terminal's
    # background, as a WCAG contrast ratio between the two: 1.0 is none, about 1.6 is strong
    # (1.0 to 2.5). Dark themes darken the chrome, or lighten it when they are too dark for that.
    # chrome_contrast = 1.35

    [jobs]
    # `dealer run <cmd>` (#21) opens a job: the command runs in a new shell next to yours, focus
    # stays where it is, and the outcome shows as attention. Where the job goes: "split" (a short
    # pane below the caller) or "tab" (a background tab next to the caller's).
    # placement = "split"
    # Height of a job split: rows (12), a percentage ("30%") or a fraction ("0.3").
    # size = 12
    # Close the job's pane when the command succeeds. A failed job always stays open.
    # close_on_success = true
    # Seconds a succeeded job's pane stays, marked done and titled DONE, before it closes
    # (0 closes it at once). Focusing it doesn't keep it; use `dealer run --keep` for that.
    # linger = 5

    [notifications]
    # Log every attention and notification decision to /tmp/dealer-notifications.log, one line
    # each, with the reason whenever Dealer didn't mark a pane or didn't post a notification.
    # For answering "why didn't Dealer notify me?". Titles and bodies are logged, truncated; no
    # terminal contents. Capped at ~5 MB (the previous file is kept as .1). macOS clears /tmp
    # files untouched for ~3 days. `dealer diagnose` shows whether it's on and its size.
    # log = false

    [power]
    # Keep the display (and so the Mac) awake while any agent is working: whenever a tab or
    # workspace shows the working spinner, and for 30 s after the last one stops. A coffee cup
    # in the titlebar shows while it's on. It doesn't stop a manual lock or closing the lid.
    # caffeinate = false

    """

    /// Returns `text` with `key` (dotted, e.g. "workspaces.switcher") set to `literal`.
    ///
    /// Only the value on the key's line changes; its indentation, spacing and trailing comment
    /// stay. A missing key goes into its table: right after a commented-out `# key = …` line if
    /// there is one, else after the table's last line. A missing table is appended.
    /// Limits: the key's existing value must fit on one line (settings Dealer writes are scalars).
    static func rewrite(_ text: String, key: String, literal: String) -> String {
        var parts = key.split(separator: ".").map(String.init)
        let leaf = parts.removeLast()
        let table = parts
        var lines = text.components(separatedBy: "\n")

        var current: [String] = []
        var headerIndex: Int?          // our table's header line
        var sectionEnd: Int?           // index after our section's last non-blank line
        var commentedIndex: Int?       // a "# leaf = …" line inside our section

        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let h = header(t) {
                current = h
                if h == table { headerIndex = i; sectionEnd = i + 1 }
                continue
            }
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                if current == table, commentedKey(t) == leaf { commentedIndex = i }
                if current == table, headerIndex != nil { sectionEnd = i + 1 }
                continue
            }
            if let (k, valueRange) = keyValue(line), current + k == table + [leaf] {
                lines[i] = line.replacingCharacters(in: valueRange, with: literal)
                return lines.joined(separator: "\n")
            }
            if current == table, headerIndex != nil { sectionEnd = i + 1 }
        }

        let newLine = "\(leaf) = \(literal)"
        if let c = commentedIndex {
            lines.insert(newLine, at: c + 1)
        } else if let end = sectionEnd {
            lines.insert(newLine, at: end)
        } else {
            while lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(table.joined(separator: "."))]")
            lines.append(newLine)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `[a.b]  # comment` → ["a", "b"].
    private static func header(_ t: String) -> [String]? {
        guard t.hasPrefix("["), !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else { return nil }
        let rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return splitKey(String(t[t.index(after: t.startIndex)..<close]))
    }

    /// `# switcher = "top"` → "switcher".
    private static func commentedKey(_ t: String) -> String? {
        let body = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let k = body[..<eq].trimmingCharacters(in: .whitespaces)
        return k.isEmpty || k.contains(" ") ? nil : k
    }

    /// For `  key = value  # c`: the key path and the range of `value` (without the comment and
    /// the spaces before it).
    private static func keyValue(_ line: String) -> ([String], Range<String.Index>)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = splitKey(String(line[..<eq]))
        guard !key.isEmpty, !key.contains(where: \.isEmpty) else { return nil }
        var start = line.index(after: eq)
        while start < line.endIndex, line[start] == " " || line[start] == "\t" { start = line.index(after: start) }
        // The value ends at a # outside quotes, then trailing spaces are left alone.
        var end = line.endIndex
        var quote: Character?
        var i = start
        while i < line.endIndex {
            let c = line[i]
            if let q = quote {
                if c == "\\" && q == "\"" { i = line.index(after: i); if i < line.endIndex { i = line.index(after: i) }; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                end = i
                break
            }
            i = line.index(after: i)
        }
        while end > start, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" { end = line.index(before: end) }
        return (key, start..<end)
    }

    private static func splitKey(_ s: String) -> [String] {
        s.split(separator: ".", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
}
