import AppKit

/// Per-pane status (#4): what an agent in the pane is doing, plus the cwd and git branch.
/// Shown right-aligned in the pane bar and as the tab's tooltip.
enum AgentState: String {
    case idle, running, waiting, done, failed
}

extension Pane {
    /// Attention wins over progress: a waiting or finished agent is what you need to know about.
    var agentState: AgentState {
        switch attention {
        case .failed: return .failed
        case .waiting: return .waiting
        case .done: return .done
        default: return isReportingProgress ? .running : .idle
        }
    }

    /// Whether an agent is working in this pane right now: the state the chrome spins for
    /// (RunningSpinner.swift). Reads `agentState`, not `isReportingProgress`, so a pane waiting on
    /// a permission prompt — where Claude keeps OSC 9;4 progress set — doesn't count as working.
    var isWorking: Bool { agentState == .running }

    /// What the chrome draws for this pane while it works (#81), nil when it doesn't: Claude's
    /// sprite when the progress comes from Claude Code, else a ring for a percentage, else an arc.
    var workingMark: WorkingMark? {
        guard isWorking else { return nil }
        if progressFromClaude || titleSaysClaudeWorking { return .claude }
        return progressPercent.map(WorkingMark.ring) ?? .arc
    }

    /// e.g. `waiting · ~/git/dealer · main`. Empty parts are left out.
    var statusLine: String { status(path: Self.abbreviate) }

    /// The workspace sidebar row's line (#68): the cwd's name only, e.g. `waiting · dealer · main`.
    /// The row is narrow, and the branch matters more than the rest of the path.
    var shortStatusLine: String { status(path: Self.leafName) }

    private func status(path: (String) -> String) -> String {
        var parts: [String] = []
        if agentState != .idle { parts.append(agentState.rawValue) }
        if let pwd {
            parts.append(path(pwd))
            if let git = GitInfo.lookup(pwd) { parts.append(git.branch) }
        }
        return parts.joined(separator: " · ")
    }

    /// The last path component, `~` for the home directory.
    static func leafName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func abbreviate(_ path: String) -> String {
        let p = WorkingDirectory.tilde(path)
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        return comps.count > 4 ? "…/" + comps.suffix(2).joined(separator: "/") : p
    }
}

// A tab or workspace is working when any pane inside it is, the way attention rolls up
// (Attention.swift). Computed, never stored: the switcher entries pick it up in `refreshChrome()`.
extension Tab {
    var isWorking: Bool { panes.contains(where: \.isWorking) }
    var workingMark: WorkingMark? { WorkingMark.strongest(of: panes) }
}

extension Workspace {
    var isWorking: Bool { decks.contains { $0.tabs.contains(where: \.isWorking) } }
    var workingMark: WorkingMark? { WorkingMark.strongest(of: decks.flatMap { $0.tabs.flatMap(\.panes) }) }
}

/// The mark a working element shows (#81, drawn by `RunningSpinner.draw`). Every one is
/// `Theme.text`, never a hue: colours and outlines mean attention.
enum WorkingMark: Equatable {
    /// Claude Code is working: claude.ai's sprite (`SpinnerAnimation.claude`).
    case claude
    /// Some other program reports progress without a percentage (OSC 9;4;3): a turning arc.
    case arc
    /// A program reports a percentage (OSC 9;4;1;N, e.g. cargo): a ring filled to N (0…100).
    case ring(Int)

    /// Claude outranks other programs, and an open-ended arc outranks a ring (the user's call, #81).
    var rank: Int {
        switch self {
        case .claude: return 2
        case .arc: return 1
        case .ring: return 0
        }
    }

    /// The one roll-up for a set of panes (a tab, a workspace, or a group of workspaces): the
    /// highest-ranked mark, and of several rings the least complete. Nil when none is working.
    static func strongest(of panes: some Sequence<Pane>) -> WorkingMark? {
        strongest(panes.compactMap(\.workingMark))
    }

    static func strongest(_ marks: some Sequence<WorkingMark>) -> WorkingMark? {
        marks.reduce(nil) { best, m in
            guard let best else { return m }
            if m.rank != best.rank { return m.rank > best.rank ? m : best }
            if case .ring(let a) = m, case .ring(let b) = best { return .ring(min(a, b)) }
            return best
        }
    }
}

/// Who is reporting a pane's progress (#81). OSC 9;4 isn't Claude's: cargo and zig send it in every
/// Dealer pane, and so do other coding agents (#81 has the survey). The pane's foreground process
/// group says who; Claude Code's working title (`◐ `/`◑ `) is the fallback where it can't, e.g. a
/// Claude on the far side of `ssh`.
enum ProgressSource {
    /// Interpreters a launcher script or an npm install runs Claude under: their next argument names it.
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "node", "bun", "deno"]

    /// Whether one process is Claude Code, from its argv and executable path, never its process
    /// name: a native install's name is its *version* (`2.1.304`), because `~/.local/bin/claude`
    /// links to `~/.local/share/claude/versions/2.1.304`.
    static func isClaude(path: String, argv: [String]) -> Bool {
        func name(_ s: String) -> String { (s as NSString).lastPathComponent }
        if path.contains("/claude/versions/") || path.contains("@anthropic-ai/claude-code") { return true }
        guard let first = argv.first else { return false }
        if name(first) == "claude" { return true }
        guard argv.count > 1, interpreters.contains(name(first)) else { return false }
        return name(argv[1]) == "claude" || argv[1].contains("@anthropic-ai/claude-code")
    }

    /// Whether any process in a foreground group is Claude Code. All members, not just the
    /// leader: a launcher script that runs `claude` without `exec` leads the group itself.
    static func isClaude(foregroundGroup pgid: Int32) -> Bool {
        guard pgid > 0 else { return false }
        let pids = Set([pgid] + ProcessTree.members(ofGroup: pgid))
        return pids.contains { ProcessTree.command(of: $0).map { isClaude(path: $0.path, argv: $0.argv) } ?? false }
    }

    /// Self-test only: stands in for the process table.
    static var foregroundOverride: ((Pane) -> Bool)?

    /// Records one OSC 9;4 report on `pane` (`GhosttyRuntime`, PROGRESS_REPORT) and returns whether
    /// what the chrome shows changed. Looks at the process table only when the foreground group
    /// changed since the last look, so a chatty reporter (zig sends hundreds) costs one look per job.
    static func note(_ pane: Pane, active: Bool, percent: Int?, foreground: Int32) -> Bool {
        let before = (pane.isReportingProgress, pane.workingMark)
        pane.isReportingProgress = active
        pane.progressPercent = active ? percent : nil
        if !active {
            pane.progressForeground = 0
            pane.progressFromClaude = false
        } else if let override = foregroundOverride {
            pane.progressFromClaude = override(pane)
        } else if foreground != pane.progressForeground {
            pane.progressForeground = foreground
            pane.progressFromClaude = isClaude(foregroundGroup: foreground)
        }
        return before != (pane.isReportingProgress, pane.workingMark)
    }
}

/// Cheap git branch lookup: reads `.git/HEAD` directly (worktrees included), no subprocess.
/// Results are cached briefly because the status line is recomputed on every chrome refresh.
enum GitInfo {
    struct Info: Equatable {
        /// The working tree's top-level directory.
        let root: String
        /// Branch name, or a short commit hash when detached.
        let branch: String
    }

    private static var cache: [String: (info: Info?, at: Date)] = [:]

    static func lookup(_ dir: String) -> Info? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let c = cache[dir], Date().timeIntervalSince(c.at) < 3 { return c.info }
        let info = read(dir)
        if cache.count > 256 { cache.removeAll() }
        cache[dir] = (info, Date())
        return info
    }

    private static func read(_ start: String) -> Info? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: start).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // A worktree or submodule: `.git` is a file saying `gitdir: <path>`.
                    guard let s = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                    let path = String(line.dropFirst("gitdir: ".count))
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                let branch = head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst("ref: refs/heads/".count)) : String(head.prefix(7))
                return Info(root: dir.path, branch: branch)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }
}

extension PaneBarView {
    /// Draws `status` right-aligned (the agent state in its attention colour) and returns the
    /// width it took, so the title can truncate before it.
    func drawStatus(font: NSFont, height h: CGFloat) -> CGFloat {
        guard !status.isEmpty else { return 0 }
        let state = (superview as? PaneView)?.pane?.agentState ?? .idle
        let faint: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textFaint]
        let text = NSMutableAttributedString(string: status, attributes: faint)
        if state != .idle {
            // The attention colour (an outlined done is blue, #61); "running" has none.
            let color = state == .running ? Theme.textMuted
                : ((superview as? PaneView)?.pane?.attention.color ?? Theme.textMuted)
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: state.rawValue.utf16.count))
        }
        let maxWidth = max(bounds.width * 0.55 - 10, 0)
        let width = min(ceil(text.size().width), maxWidth)
        guard width > 20 else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        text.draw(in: CGRect(x: bounds.width - statusTrailing - width, y: (bounds.height - h) / 2, width: width, height: h))
        return width + statusTrailing + 2
    }
}
