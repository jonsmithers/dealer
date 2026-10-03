import AppKit

/// `dealer run <cmd>` (#21): run a command next to the caller without taking focus, and report how
/// it went through attention instead of a user-side notifier.
///
/// The job pane is an ordinary interactive shell (aliases, functions and rc environment work, and a
/// failed job leaves you at a prompt). The command is typed into it with a reporting tail:
///
///      <cmd>; "$DEALER_CLI" job-done $? && exit
///
/// `job-done` hands the exit status back here, and its own exit status tells the shell whether to
/// close: 0 on success (with `close_on_success`), 1 otherwise. If Dealer can't be reached the pane
/// simply stays open. The leading space keeps the line out of history with HIST_IGNORE_SPACE.
enum ControlJobs {
    struct Job {
        let command: String
        /// The pane `dealer run` was called from; it gets the "done" mark on success.
        weak var origin: Pane?
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

    static func run(_ args: [String: Any], _ ctx: ControlHandler.Context) throws -> [String: Any] {
        typealias F = ControlHandler.Failure
        let command = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw F(message: "run needs a command") }
        guard !command.contains("\n") else { throw F(message: "run takes a single-line command") }
        let loc = try ControlHandler.resolve(args["target"], ctx)
        guard let anchor = loc.focusPane else { throw F(message: "no pane to run next to") }
        let wc = loc.wc

        let placement = (args["placement"] as? String ?? Settings.jobPlacement).lowercased()
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

        jobs = jobs.filter { ControlHandler.pane(id: $0.key) != nil }
        jobs[pane.id] = Job(command: command, origin: anchor, notify: args["notify"] as? Bool ?? true,
                            closeOnSuccess: args["close"] as? Bool ?? Settings.jobCloseOnSuccess, tab: tab, cwd: cwd)
        if let s = pane.surface.surface {
            pane.surface.perform("text:" + ControlHandler.escapeForBinding(" \(command); \"$DEALER_CLI\" job-done $? && exit"))
            try ControlHandler.parseKey("enter").send(to: s)
        }
        if focus { ControlHandler.bringForward(wc) }
        return ControlHandler.ids(pane)
    }

    /// Called from the job's own shell (`caller` is the job pane) with the command's exit status.
    /// Returns `close` = whether the shell should exit.
    static func done(_ args: [String: Any], _ ctx: ControlHandler.Context) throws -> [String: Any] {
        guard let id = ctx.caller, let pane = ControlHandler.pane(id: id),
              let loc = ControlHandler.locate(pane) else {
            throw ControlHandler.Failure(message: "job-done must run inside a job pane")
        }
        let status = ControlHandler.int(args["status"]) ?? 1
        guard let job = jobs[id], job.status == nil else {
            // Not a job, or one that already reported (the tail retyped by hand): keep the shell.
            return ["close": false, "status": status]
        }
        jobs[id]?.status = status
        let wc = loc.wc
        if status == 0 {
            if job.notify, let origin = job.origin, let o = ControlHandler.locate(origin) {
                o.wc.setAttention(.done, on: origin, title: "✓ \(job.command)", body: "Finished in \(pane.pwd.map(short) ?? "job")")
            }
            if job.closeOnSuccess { return ["close": true, "status": status] }
            retitle(pane, job: job, "DONE \(job.command)", wc)
        } else {
            retitle(pane, job: job, "FAILED (\(status)) \(job.command)", wc)
            wc.setAttention(.waiting, on: pane, title: "✗ \(job.command)", body: "Exited with status \(status)")
        }
        return ["close": false, "status": status]
    }

    private static func retitle(_ pane: Pane, job: Job, _ title: String, _ wc: TerminalWindowController) {
        pane.customTitle = title
        if let tab = job.tab, tab.customTitle != nil { tab.customTitle = title }
        wc.refreshChrome()
    }

    private static func short(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
