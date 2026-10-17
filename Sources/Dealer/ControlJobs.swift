import AppKit

/// `dealer run <cmd>` (#21): run a command next to the caller without taking focus, and report how
/// it went through attention instead of a user-side notifier.
///
/// The job pane is an ordinary interactive shell (aliases, functions and rc environment work, and a
/// failed job leaves you at a prompt). The command is typed into it with a reporting tail:
///
///      <cmd>; "$DEALER_CLI" job-done $?
///
/// `job-done` hands the exit status back here and exits with it, so shell integration sees the
/// job's own status (a kept success isn't marked failed by `failed_commands`, #50). The shell never
/// exits on its own: on success Dealer closes the pane itself (see `done`), and otherwise, or if
/// Dealer can't be reached, the pane stays at a prompt. The leading space keeps the line out of
/// history with HIST_IGNORE_SPACE.
enum ControlJobs {
    struct Job {
        let command: String
        let notify: Bool
        let closeOnSuccess: Bool
        /// The job's tab when it was placed as a tab (its title follows the outcome).
        weak var tab: Tab?
        let cwd: String?
        /// Set once the job reports back; later `job-done` calls from that pane are ignored.
        var status: Int?
    }

    /// Jobs by pane ID, kept (with their status) until the pane is gone.
    private(set) static var jobs: [Int: Job] = [:]

    static func job(for pane: Pane) -> Job? { jobs[pane.id] }

    /// Succeeded jobs whose delayed close hasn't run yet (the self-test waits for 0).
    private(set) static var lingering = 0

    static func run(_ args: [String: Any], _ ctx: ControlHandler.Context) throws -> [String: Any] {
        typealias F = ControlHandler.Failure
        let command = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw F(message: "run needs a command") }
        guard !command.contains("\n") else { throw F(message: "run takes a single-line command") }
        let here = try ControlHandler.resolve(args["target"], ctx)
        guard var anchor = here.focusPane else { throw F(message: "no pane to run next to") }
        var wc = here.wc

        let placement = (args["placement"] as? String ?? Settings.jobPlacement).lowercased()
        guard ["split", "pane", "tab"].contains(placement) else {
            throw F(message: "bad placement '\(placement)' (expected split or tab)")
        }
        // The CLI sends its own cwd (b's "$PWD"); otherwise the anchor pane's.
        var cwd = args["cwd"] as? String
        if cwd == nil { cwd = anchor.pwd ?? ControlHandler.currentDirectory(of: anchor) }
        if let c = cwd {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue else {
                throw F(message: "no such directory: \(c)")
            }
        }
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "RUN \(command)"
        let focus = args["focus"] as? Bool ?? false

        // Route by cwd unless a target was given (or `--here`).
        var route: [String: Any]?
        let explicit = (args["target"] as? String).map { !$0.isEmpty } ?? false
        if !explicit, args["route"] as? Bool ?? true, let c = cwd {
            let r = Self.route(cwd: c, from: anchor)
            route = r.info
            switch r.best {
            case let (p, w)?:
                anchor = p
                wc = w
            case nil:
                // Nothing owns $PWD: the job gets a new workspace of its own, named after the
                // directory, as its only pane. On success Dealer closes it and the workspace goes too.
                let callerWS = wc.locate(anchor)?.workspace
                let name = (c as NSString).lastPathComponent
                // The title goes on the pane only: the tab follows it, so it doesn't keep a stale
                // RUN title once later jobs share the tab and this one has closed.
                let pane = wc.controlNewWorkspace(after: callerWS, name: name.isEmpty ? c : name, workingDirectory: c,
                                                  command: nil, title: nil, focus: focus)
                pane.customTitle = title
                var info = r.info
                if let ws = wc.locate(pane)?.workspace { info["workspace"] = ws.id; info["name"] = ws.displayName }
                route = info
                return try start(pane, command: command, tab: wc.locate(pane)?.tab,
                                 cwd: c, args: args, wc: wc, focus: focus, route: route)
            }
        }

        let pane: Pane
        var tab: Tab?
        switch placement {
        case "split", "pane":
            let size = args["size"] as? String ?? Settings.jobSize
            let f = try ControlHandler.fraction(size, for: anchor, side: .bottom)
            pane = wc.controlSplit(anchor, side: .bottom, fraction: f, workingDirectory: cwd, command: nil,
                                   title: title, focus: focus)
        case "tab":
            guard let l = wc.locate(anchor) else { throw F(message: "no tab to run next to") }
            pane = wc.controlNewTab(in: l.deck, after: l.tab, workingDirectory: cwd, command: nil, title: title, focus: focus)
            tab = wc.locate(pane)?.tab
        default:
            throw F(message: "bad placement '\(placement)' (expected split or tab)")
        }
        // The caller's pane gets the success mark, even when the job was routed elsewhere.
        return try start(pane, command: command, tab: tab, cwd: cwd, args: args,
                         wc: wc, focus: focus, route: route)
    }

    private static func start(_ pane: Pane, command: String, tab: Tab?, cwd: String?, args: [String: Any],
                              wc: TerminalWindowController, focus: Bool, route: [String: Any]?) throws -> [String: Any] {
        jobs = jobs.filter { ControlHandler.pane(id: $0.key) != nil }
        jobs[pane.id] = Job(command: command, notify: args["notify"] as? Bool ?? true,
                            closeOnSuccess: args["close"] as? Bool ?? Settings.jobCloseOnSuccess, tab: tab, cwd: cwd)
        if let s = pane.surface.surface {
            pane.surface.perform("text:" + ControlHandler.escapeForBinding(" \(command); \"$DEALER_CLI\" job-done $?"))
            try ControlHandler.parseKey("enter").send(to: s)
        }
        if focus { ControlHandler.bringForward(wc) }
        var r = ControlHandler.ids(pane)
        if let route { r["route"] = route }
        return r
    }

    // MARK: - Route by cwd

    /// A pane's directory for routing: the shell-reported one, else its foreground process's.
    static func directory(of p: Pane) -> String? {
        (p.pwd ?? ControlHandler.currentDirectory(of: p)).map(canonical)
    }

    /// `/var/…` and `/private/var/…` (and other symlinked spellings) compare equal.
    static func canonical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// The workspace that best fits `cwd` (#21): the pane whose current directory is the deepest
    /// one containing `cwd`; ties go to the caller's workspace, then the caller's pane, then the
    /// pane that has focus in its workspace. `best` is nil when no pane's directory contains `cwd`.
    /// `info` says which outcome applied, for the CLI to log.
    static func route(cwd: String, from caller: Pane) -> (best: (Pane, TerminalWindowController)?, info: [String: Any]) {
        let target = canonical(cwd)
        let home = ControlHandler.locate(caller)
        var best: (pane: Pane, wc: TerminalWindowController, ws: Workspace, key: [Int])?
        var callerMatched = false
        for wc in ControlHandler.controllers {
            for ws in wc.workspaces {
                for p in ws.panes {
                    guard let dir = directory(of: p) else { continue }
                    let contains = target == dir || target.hasPrefix(dir == "/" ? "/" : dir + "/")
                    guard contains else { continue }
                    if ws === home?.ws { callerMatched = true }
                    // Deeper wins; then the caller's workspace, the caller itself, the workspace's focus.
                    let key = [dir.count, ws === home?.ws ? 1 : 0, p === caller ? 1 : 0, p === ws.validFocusedPane ? 1 : 0]
                    if best == nil || key.lexicographicallyPrecedes(best!.key) == false && key != best!.key {
                        best = (p, wc, ws, key)
                    }
                }
            }
        }
        guard let b = best else {
            return (nil, ["outcome": "created", "cwd": cwd])
        }
        let outcome = b.ws === home?.ws ? "caller" : "other"
        return ((b.pane, b.wc), ["outcome": outcome, "workspace": b.ws.id, "name": b.ws.displayName,
                                 "pane": b.pane.id, "owner": b.pane.pwd ?? directory(of: b.pane) ?? cwd, "cwd": cwd,
                                 "caller_matched": callerMatched])
    }

    /// Called from the job's own shell (`caller` is the job pane) with the command's exit status.
    /// Returns `close` = whether Dealer is closing the pane.
    static func done(_ args: [String: Any], _ ctx: ControlHandler.Context) throws -> [String: Any] {
        guard let id = ctx.caller, let pane = ControlHandler.pane(id: id),
              let loc = ControlHandler.locate(pane) else {
            throw ControlHandler.Failure(message: "job-done must run inside a job pane")
        }
        let status = ControlHandler.int(args["status"]) ?? 1
        let event = "job-done(status=\(status))"
        guard let job = jobs[id], job.status == nil else {
            // Not a job, or one that already reported (the tail retyped by hand): keep the shell.
            NotificationLog.decision(pane: pane, event: event, outcome: "ignored",
                                     reason: jobs[id] == nil ? "not a dealer run job pane" : "this job already reported")
            return ["close": false, "status": status]
        }
        jobs[id]?.status = status
        let wc = loc.wc
        // The notification is the outcome and command, then the workspace it ran in. The pane's
        // title (DONE/FAILED <cmd>) would only repeat the first line.
        let workspace = loc.ws?.displayName ?? ""
        if status == 0 {
            let title = "✓ \(job.command)"
            // Every outcome marks the job pane, never the pane `dealer run` was called from (#63:
            // marking the caller was never wanted). A succeeded job that closes first lingers,
            // titled DONE and marked done, so the success can be seen.
            retitle(pane, job: job, "DONE \(job.command)", wc)
            if job.notify {
                wc.setAttention(.done, on: pane, title: title, subtitle: workspace, event: event)
            } else {
                NotificationLog.decision(pane: pane, event: event, outcome: "attention:skipped",
                                         reason: "--quiet: no mark, no notification", title: title, subtitle: workspace)
            }
            if job.closeOnSuccess {
                closeAfterLinger(pane, seconds: Settings.jobLinger)
                return ["close": true, "status": status]
            }
        } else {
            retitle(pane, job: job, "FAILED (\(status)) \(job.command)", wc)
            wc.setAttention(.failed, on: pane, title: "✗ \(job.command)", subtitle: workspace, event: event)
        }
        return ["close": false, "status": status]
    }

    /// Closes a succeeded job's pane after `seconds` (0: right after replying). The shell never
    /// `exit`s: besides putting a non-zero status on kept jobs (#50), ghostty on macOS keeps a shell
    /// that exits within abnormal-command-exit-runtime (250 ms) of starting open as "abnormal", so a
    /// quick job (`dealer run true`) would never close. Focus or typing doesn't cancel it (#63); the
    /// pane is looked up again when the time comes, since it may have moved or closed meanwhile.
    /// Runs in default mode, like ControlServer.onMain.
    private static func closeAfterLinger(_ pane: Pane, seconds: TimeInterval) {
        lingering += 1
        let close = { [weak pane] in
            lingering -= 1
            guard let pane, let wc = ControlHandler.locate(pane)?.wc else { return }
            wc.remove(pane)
        }
        guard seconds > 0 else { return RunLoop.main.perform(inModes: [.default], block: close) }
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in close() }
        RunLoop.main.add(timer, forMode: .default)
    }

    private static func retitle(_ pane: Pane, job: Job, _ title: String, _ wc: TerminalWindowController) {
        pane.customTitle = title
        if let tab = job.tab, tab.customTitle != nil { tab.customTitle = title }
        wc.refreshChrome()
    }
}
