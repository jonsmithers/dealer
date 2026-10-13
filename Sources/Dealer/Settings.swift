import AppKit

/// Dealer's own settings (#10), read from `$XDG_CONFIG_HOME/dealer/settings.toml` (default
/// `~/.config/dealer/settings.toml`). Terminal settings stay in the ghostty config.
///
/// Everything reads settings through the accessors at the bottom of this enum; nothing else reads
/// the file or the legacy UserDefaults keys. Precedence per setting: environment variable (where
/// one exists) > settings.toml > legacy UserDefaults value (pre-#10, read as a fallback, never
/// deleted) > built-in default.
///
/// The file is watched and reloaded live. A reload that changes effective values, or the set of
/// problems, posts `Settings.didChange`; windows observe it (`observeSettings()`). A bad file never
/// blocks launch: bad keys fall back as if unset, and problems are logged and shown in a banner.
enum Settings {
    static let didChange = Notification.Name("DealerSettingsDidChange")

    // MARK: Schema

    enum Kind {
        case string
        case bool
        case oneOf([String])
        case stringArray
        /// An array of "#rrggbb" strings.
        case colorArray
        /// A pane size like `dealer create --size`: rows/columns (an integer, or a string of
        /// digits), a percentage ("30%") or a fraction ("0.3").
        case size

        func validate(_ v: TOML.Value) -> String? {
            switch (self, v) {
            case (.string, .string), (.bool, .bool): return nil
            case (.size, .integer(let n)): return n > 0 ? nil : "must be a positive number of rows"
            case (.size, .string(let s)): return Settings.isSizeSpec(s) ? nil : "must be rows (12), a percentage (\"30%\") or a fraction (\"0.3\")"
            case (.size, _): return "must be rows (12), a percentage (\"30%\") or a fraction (\"0.3\"), not \(v.typeName)"
            case (.oneOf(let options), .string(let s)):
                return options.contains(s) ? nil : "must be one of \(options.map { "\"\($0)\"" }.joined(separator: ", "))"
            case (.colorArray, .array(let a)):
                return a.allSatisfy { if case .string(let s) = $0 { return NSColor(hex: s) != nil } else { return false } }
                    ? nil : "must be an array of \"#rrggbb\" colors"
            case (.colorArray, _): return "must be an array of \"#rrggbb\" colors, not \(v.typeName)"
            case (.stringArray, .array(let a)):
                return a.allSatisfy { if case .string = $0 { return true } else { return false } } ? nil : "must be an array of strings"
            case (.string, _), (.oneOf, _): return "must be a string, not \(v.typeName)"
            case (.bool, _): return "must be true or false, not \(v.typeName)"
            case (.stringArray, _): return "must be an array of strings, not \(v.typeName)"
            }
        }
    }

    /// Every key the file may contain, by dotted name. Unknown keys are reported and ignored.
    /// #9 adds its `[colors]` keys here (plus accessors below); nothing else needs to change.
    static let schema: [String: Kind] = [
        "agent.command": .string,
        "agent.inject_hooks": .bool,
        "agent.errors_as_failed": .bool,
        "attention.failed_commands": .bool,
        "workspaces.switcher": .oneOf(WorkspaceSwitcherStyle.allCases.map(\.rawValue)),
        "colors.auto_assign": .bool,
        "window.tabs_in_titlebar": .bool,
        "colors.palette": .colorArray,
        "jobs.placement": .oneOf(["split", "tab"]),
        "jobs.size": .size,
        "jobs.close_on_success": .bool,
        "notifications.log": .bool,
    ]

    /// Pre-#10 UserDefaults keys, read only when the file doesn't set the setting.
    static let legacyKeys: [String: String] = [
        "agent.command": "agentCommand",
        "workspaces.switcher": "workspaceSwitcher",
        "agent.inject_hooks": "agentInjectHooks",
    ]

    // MARK: State

    /// Where the file lives. Set by `start()`; the self-test points it at a temp config home.
    private(set) static var fileURL = defaultFileURL(environment: ProcessInfo.processInfo.environment)
    /// Validated values from the file.
    private(set) static var values: [String: TOML.Value] = [:]
    /// Human-readable problems from the last load (syntax errors, unknown keys, wrong types).
    private(set) static var problems: [String] = []
    /// Environment used for env-var overrides; the self-test swaps it.
    static var environment = ProcessInfo.processInfo.environment
    /// Legacy UserDefaults lookup (a String or Bool); the self-test swaps it so it never reads the
    /// user's defaults.
    static var legacy: (String) -> Any? = { UserDefaults.standard.object(forKey: $0) }

    private static var lastText: String?
    private static var watcher: SettingsWatcher?

    static func defaultFileURL(environment env: [String: String], home: String = NSHomeDirectory()) -> URL {
        let base: URL
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty, x.hasPrefix("/") {
            base = URL(fileURLWithPath: x, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("dealer", isDirectory: true).appendingPathComponent("settings.toml")
    }

    /// Called once at launch, before any window opens. In self-test mode the file lives in a fresh
    /// temp config home, and the environment and legacy defaults are blanked.
    static func start() {
        if SelfTest.enabled {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("dealer-selftest-config-\(getpid())", isDirectory: true)
            try? FileManager.default.removeItem(at: home)
            fileURL = defaultFileURL(environment: ["XDG_CONFIG_HOME": home.path])
            environment = [:]
            legacy = { _ in nil }
        } else {
            fileURL = defaultFileURL(environment: environment)
        }
        reload(force: true)
        watch()
    }

    /// Re-reads the file. Posts `didChange` when effective values or problems changed.
    @discardableResult
    static func reload(force: Bool = false) -> Set<String> {
        let text = try? String(contentsOf: fileURL, encoding: .utf8)
        // The file may have been created or replaced since the watcher was armed.
        watcher?.arm()
        if !force && text == lastText { return [] }
        lastText = text
        let before = effective()
        let oldProblems = problems

        var newValues: [String: TOML.Value] = [:]
        var newProblems: [String] = []
        if let text {
            let doc = TOML.parse(text)
            newProblems += doc.problems.map(\.description)
            for (key, v) in doc.values.sorted(by: { (doc.lines[$0.key] ?? 0) < (doc.lines[$1.key] ?? 0) }) {
                let line = doc.lines[key].map { "line \($0): " } ?? ""
                guard let kind = schema[key] else {
                    newProblems.append("\(line)unknown setting \(key) (ignored)")
                    continue
                }
                if let err = kind.validate(v) {
                    newProblems.append("\(line)\(key) \(err); using the default")
                } else {
                    newValues[key] = v
                }
            }
        }
        values = newValues
        // In file order: "line N: …" sorts by N; problems without a line go last.
        func lineNumber(_ p: String) -> Int {
            guard p.hasPrefix("line "), let n = Int(p.dropFirst(5).prefix { $0.isNumber }) else { return .max }
            return n
        }
        problems = newProblems.enumerated().sorted { (lineNumber($0.element), $0.offset) < (lineNumber($1.element), $1.offset) }.map(\.element)

        if problems != oldProblems {
            problems.forEach { NSLog("Dealer: \(fileURL.path): \($0)") }
        }
        let after = effective()
        let changed = Set(after.keys.filter { before[$0] != after[$0] })
        if !changed.isEmpty || problems != oldProblems {
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["keys": changed])
        }
        return changed
    }

    /// Effective value of every schema key, for change detection.
    private static func effective() -> [String: String] {
        var out: [String: String] = [:]
        for key in schema.keys { out[key] = raw(key).map(TOML.literal) ?? "" }
        out["agent.command"] = agentCommand
        return out
    }

    /// The file's value, else the legacy default (strings only).
    private static func raw(_ key: String) -> TOML.Value? {
        if let v = values[key] { return v }
        guard let lk = legacyKeys[key], let old = legacy(lk) else { return nil }
        let v: TOML.Value
        if case .bool? = schema[key] {
            // Written as a real bool (`defaults write … -bool false`) or, by #12's pre-#10 setter, a string.
            if let n = old as? NSNumber { v = .bool(n.boolValue) }
            else if let s = (old as? String)?.lowercased() { v = .bool(!["0", "false", "no", "off"].contains(s)) }
            else { return nil }
        } else if let s = old as? String, !s.isEmpty { v = .string(s) }
        else { return nil }
        return schema[key]?.validate(v) == nil ? v : nil
    }

    private static func string(_ key: String) -> String? {
        if case .string(let s)? = raw(key) { return s }
        return nil
    }

    private static func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = raw(key) { return b }
        return nil
    }

    // MARK: Watching and writing

    static func watch() {
        watcher = SettingsWatcher(url: fileURL) { reload() }
    }

    /// Writes one key back to the file, touching only that key's line (SettingsFile.rewrite).
    /// Creates the file from the example if it doesn't exist yet.
    static func write(_ key: String, _ value: TOML.Value) {
        precondition(schema[key]?.validate(value) == nil, "writing an invalid value for \(key)")
        let fm = FileManager.default
        let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? SettingsFile.exampleText
        let updated = SettingsFile.rewrite(current, key: key, literal: TOML.literal(value))
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Dealer: couldn't write \(fileURL.path): \(error)")
        }
        reload()
        watch()
    }

    /// Creates the file from the example if missing (the only time Dealer creates it unasked-for
    /// is a menu toggle's write-back), then opens it in the user's editor.
    static func openFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? SettingsFile.exampleText.write(to: fileURL, atomically: true, encoding: .utf8)
            reload()
            watch()
        }
        guard !SelfTest.enabled else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: fileURL) != nil {
            NSWorkspace.shared.open(fileURL)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Accessors

    /// `[agent] command`: the agent New Agent Pane types into the shell.
    /// `DEALER_AGENT_COMMAND` > file > legacy `agentCommand` default > "claude".
    static var agentCommand: String {
        if let c = environment["DEALER_AGENT_COMMAND"], !c.isEmpty { return c }
        if let c = string("agent.command"), !c.isEmpty { return c }
        return "claude"
    }

    /// `[agent] inject_hooks` (#12, ClaudeHooks.swift): whether `claude` started in a pane loads
    /// Dealer's Claude Code plugin. Read when a pane's shell starts; default true.
    static var agentInjectHooks: Bool { bool("agent.inject_hooks") ?? true }

    /// `[agent] errors_as_failed` (#29): a Claude Code turn that ends in an API error (`StopFailure`)
    /// marks the pane *failed* (red); false marks it *waiting* (blue) instead. Default true. Read when
    /// a pane's shell starts (exported as DEALER_CLAUDE_ERROR_STATE for the plugin's hook).
    static var agentErrorsAsFailed: Bool { bool("agent.errors_as_failed") ?? true }

    /// `[attention] failed_commands` (#29): a shell command that exits non-zero in a pane you aren't
    /// looking at marks it *failed* (red). Needs shell integration. Default true. Read live.
    static var attentionFailedCommands: Bool { bool("attention.failed_commands") ?? true }

    /// `[window] tabs_in_titlebar` (#16): top-edge decks' tab strips sit in the titlebar row.
    static var tabsInTitlebar: Bool { bool("window.tabs_in_titlebar") ?? false }

    /// `[colors] auto_assign` (#9): new workspaces take the next unused swatch. Default false.
    static var autoAssignColors: Bool { bool("colors.auto_assign") ?? false }

    /// `[colors] palette` (#9): replaces the default swatches (Theme.swatches). Nil when unset.
    static var colorPalette: [NSColor]? {
        guard case .array(let a)? = values["colors.palette"] else { return nil }
        return a.compactMap { if case .string(let s) = $0 { return NSColor(hex: s) } else { return nil } }
    }

    /// `[jobs] placement` (#21): where `dealer run` puts a job: "split" (a short pane below the
    /// caller, default) or "tab" (a background tab next to the caller's).
    static var jobPlacement: String { string("jobs.placement") ?? "split" }

    /// `[jobs] size` (#21): the job split's height, as `dealer create --size` takes it. Default 12 rows.
    static var jobSize: String {
        switch values["jobs.size"] {
        case .integer(let n)?: return String(n)
        case .string(let s)?: return s
        default: return "12"
        }
    }

    /// `[jobs] close_on_success` (#21): close a job's pane when its command succeeds. Default true.
    static var jobCloseOnSuccess: Bool { bool("jobs.close_on_success") ?? true }

    /// `[notifications] log` (#56): append every attention/notification decision, with the reason
    /// for each "no", to `NotificationLog.path` (/tmp/dealer-notifications.log). Default false. Read live.
    static var notificationLog: Bool { bool("notifications.log") ?? false }

    static func isSizeSpec(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%"), let v = Double(t.dropLast()) { return v > 0 && v < 100 }
        if t.contains("."), let v = Double(t) { return v > 0 && v < 1 }
        if let n = Int(t) { return n > 0 }
        return false
    }

    /// `[workspaces] switcher` (#8): "sidebar" (default) or "top". Setting it writes the file.
    static var workspaceSwitcher: WorkspaceSwitcherStyle {
        get { string("workspaces.switcher").flatMap(WorkspaceSwitcherStyle.init(rawValue:)) ?? .sidebar }
        set {
            guard newValue != workspaceSwitcher || values["workspaces.switcher"] == nil else { return }
            write("workspaces.switcher", .string(newValue.rawValue))
        }
    }
}

/// Watches the settings file and its directory. Editors that save by writing a temp file and
/// renaming it over the original replace the inode, so the sources are re-armed after every event
/// (and after every reload); the directory source catches the file being created, deleted or
/// renamed into place. If the directory doesn't exist yet, the nearest existing ancestor is
/// watched instead, so creating `dealer/` (and then the file) is noticed too.
final class SettingsWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let url: URL
    private let onChange: () -> Void
    private var pending = false
    /// Sources fire here, then hop to the main run loop (default mode, like ControlServer.onMain)
    /// rather than the main dispatch queue, so a reload also lands during a nested default-mode
    /// run loop wait (the self-test waits that way inside a main-queue block).
    private let queue = DispatchQueue(label: "dealer.settings.watch")

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { sources.forEach { $0.cancel() } }

    func arm() {
        sources.forEach { $0.cancel() }
        sources = []
        var dir = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        for (path, mask) in [(dir.path, DispatchSource.FileSystemEvent.write),
                             (url.path, [.write, .extend, .delete, .rename, .attrib])] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
            src.setEventHandler { [weak self] in
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { self?.fire() }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    /// Coalesces a burst of events (an atomic save is several) into one reload.
    private func fire() {
        guard !pending else { return }
        pending = true
        // A run-loop timer (default mode), for the same reason as the hop above.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pending = false
            self.arm()
            self.onChange()
        }
    }
}

