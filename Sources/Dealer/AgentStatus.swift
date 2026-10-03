import AppKit

/// Per-pane status (#4): what an agent in the pane is doing, plus the cwd and git branch.
/// Shown right-aligned in the pane bar and as the tab's tooltip.
enum AgentState: String {
    case idle, running, waiting, done
}

extension Pane {
    /// Attention wins over progress: a waiting or finished agent is what you need to know about.
    var agentState: AgentState {
        switch attention {
        case .waiting: return .waiting
        case .done: return .done
        default: return isReportingProgress ? .running : .idle
        }
    }

    /// e.g. `waiting · ~/git/dealer · main`. Empty parts are left out.
    var statusLine: String {
        var parts: [String] = []
        if agentState != .idle { parts.append(agentState.rawValue) }
        if let pwd {
            parts.append(Self.abbreviate(pwd))
            if let git = GitInfo.lookup(pwd) { parts.append(git.branch) }
        }
        return parts.joined(separator: " · ")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        return comps.count > 4 ? "…/" + comps.suffix(2).joined(separator: "/") : p
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
            let color: NSColor
            switch state {
            case .waiting: color = Theme.attentionWaiting
            case .done: color = Theme.attentionDone
            default: color = Theme.textMuted
            }
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
