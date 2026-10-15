import AppKit
import GhosttyKit

/// Memory diagnostics (#43): one text report with what's useful for "Dealer is using N GB" and
/// nothing private. Reached from Help › Capture Memory Diagnostics… and `dealer diagnose`; both call
/// `capture(_:)`. What it collects is listed in docs/diagnostics.md; keep the two in sync.
///
/// Privacy: no terminal contents, titles, working directories, commands or environment. Panes are
/// numbered in tree order instead of using their IDs. Paths in tool output have the home
/// directory and user name replaced.
enum Diagnostics {
    struct Options {
        /// Also run `leaks` on Dealer: slow, suspends the app while it runs, and its report can
        /// quote bytes from leaked memory. Off unless asked for.
        var leaks = false
    }

    /// `~/Library/Logs/Dealer`, or a temp directory in self-test mode.
    static var directory: URL {
        if SelfTest.enabled {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dealer-diagnostics-\(getpid())")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dealer")
    }

    /// Writes a report and returns its file. Main thread: it reads the model. The external tools
    /// (`vmmap`, `heap`, optionally `leaks`) take a few seconds on a large process.
    static func capture(_ options: Options = Options()) throws -> URL {
        dispatchPrecondition(condition: .onQueue(.main))
        let text = report(options)
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.fileStamp.string(from: Date())
        let url = dir.appendingPathComponent("dealer-diagnostics-\(stamp).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Help › Capture Memory Diagnostics…: capture, then show the file in Finder.
    static func captureFromMenu() {
        do {
            let url = try capture()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("Dealer: diagnostics failed: \(error)")
            NSSound.beep()
        }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    // MARK: - Report

    static func report(_ options: Options) -> String {
        var out: [String] = []
        func section(_ title: String, _ lines: [String]) {
            out.append("## \(title)")
            out.append(contentsOf: lines)
            out.append("")
        }
        out.append("# Dealer memory diagnostics")
        out.append("captured: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("")
        section("Versions", versionLines())
        section("Process memory", processLines())
        section("Objects", objectLines())
        section("Panes", paneLines())
        section("vmmap --summary", tool("/usr/bin/vmmap", ["--summary", "\(getpid())"], timeout: 60))
        section("heap (classes by size, top 60)", Array(tool("/usr/bin/heap", ["-q", "-s", "\(getpid())"], timeout: 60).prefix(70)))
        if options.leaks {
            section("leaks", tool("/usr/bin/leaks", ["\(getpid())"], timeout: 180))
        }
        return out.joined(separator: "\n")
    }

    private static func versionLines() -> [String] {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let exe = Bundle.main.executableURL
        let built = exe.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return [
            "dealer: \(info?["CFBundleShortVersionString"] as? String ?? "dev (unbundled)")"
                + (Bundle.main.bundleIdentifier == nil ? "" : " bundle"),
            "dealer binary built: \(built.map { ISO8601DateFormatter().string(from: $0) } ?? "?")",
            "dealer source HEAD: \(sourceCommit() ?? "unknown") (the checkout this binary was built from, as it is now)",
            "ghostty pin: \(GhosttyVersion.pinnedCommit)",
            "ghostty linked: \(GhosttyVersion.linked)" + (GhosttyVersion.problem == nil ? "" : " (MISMATCH)"),
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "hardware: \(String(cString: model)), \(ProcessInfo.processInfo.physicalMemory >> 20) MB RAM, \(ProcessInfo.processInfo.activeProcessorCount) cores",
            "app uptime: \(duration(Date().timeIntervalSince(launchDate)))",
            "system uptime: \(duration(ProcessInfo.processInfo.systemUptime))",
            // ghostty_config_get has no conversion for usize keys at the pin, so the value can't be read.
            "scrollback-limit: not readable through libghostty's C API (ghostty's default is 10000000 bytes per surface)",
        ]
    }

    /// When this process started (kernel record), for the app uptime line.
    private static var launchDate = processStart() ?? Date()

    private static func processStart() -> Date? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return nil }
        let tv = kp.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }

    private static func duration(_ s: TimeInterval) -> String {
        let t = Int(s)
        return String(format: "%dd %02dh %02dm", t / 86400, t / 3600 % 24, t / 60 % 60)
    }

    private static func sourceCommit() -> String? {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let r = tool("/usr/bin/git", ["-C", dir, "rev-parse", "--short=9", "HEAD"], timeout: 5)
        return r.count == 1 && r[0].allSatisfy(\.isHexDigit) ? r[0] : nil
    }

    // MARK: Process

    struct Memory {
        var footprint: UInt64 = 0
        /// The part of `footprint` tagged as graphics (IOSurface, Metal), compressed included.
        var graphics: UInt64 = 0
        var footprintPeak: UInt64 = 0
        var resident: UInt64 = 0
        var residentPeak: UInt64 = 0
        var virtual: UInt64 = 0
        var threads = 0
    }

    static func memory() -> Memory {
        var m = Memory()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if kr == KERN_SUCCESS {
            m.footprint = info.phys_footprint
            m.graphics = UInt64(max(0, info.ledger_tag_graphics_footprint + info.ledger_tag_graphics_footprint_compressed))
            m.footprintPeak = UInt64(max(info.ledger_phys_footprint_peak, 0))
            m.resident = info.resident_size
            m.residentPeak = info.resident_size_peak
            m.virtual = info.virtual_size
        }
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list {
            m.threads = Int(n)
            for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride))
        }
        return m
    }

    private static func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }

    private static func processLines() -> [String] {
        let m = memory()
        return [
            "phys_footprint: \(mb(m.footprint)) (peak \(mb(m.footprintPeak)))  <- Activity Monitor's \"Memory\"",
            "resident: \(mb(m.resident)) (peak \(mb(m.residentPeak)))",
            "virtual: \(mb(m.virtual))",
            "threads: \(m.threads)",
            "open file descriptors: \(openFileCount())",
        ]
    }

    private static func openFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    // MARK: Model

    /// Counts from the model next to `LiveObjects`: live objects beyond what the windows hold
    /// are leaks (or, briefly, objects being torn down).
    static func modelCounts() -> [String: Int] {
        let wcs = AppDelegate.shared.windowControllers
        let workspaces = wcs.flatMap(\.workspaces)
        let decks = workspaces.flatMap(\.decks)
        let tabs = decks.flatMap(\.tabs)
        let panes = tabs.flatMap(\.panes)
        return ["window": wcs.count, "workspace": workspaces.count, "deck": decks.count, "tab": tabs.count,
                "pane": panes.count, "surface": panes.filter { $0.surface.surface != nil }.count]
    }

    private static func objectLines() -> [String] {
        let live = LiveObjects.snapshot
        let model = modelCounts()
        var lines = ["kind            in windows   alive"]
        for k in LiveObjects.Kind.allCases {
            let inModel: Int? = switch k {
            case .window, .workspace, .deck, .tab, .pane: model[k.rawValue]
            case .paneView, .surfaceView: model["pane"]
            case .deckView: model["deck"]
            case .ghosttySurface: model["surface"]
            }
            let alive = live[k] ?? 0
            let flag = inModel.map { alive > $0 ? "   <- \(alive - $0) not in any window" : "" } ?? ""
            lines.append(k.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
                + String(inModel ?? 0).padding(toLength: 13, withPad: " ", startingAt: 0) + "\(alive)\(flag)")
        }
        lines.append("windows on screen (NSApp.windows, visible): \(NSApp.windows.filter(\.isVisible).count) of \(NSApp.windows.count)")
        lines.append("dealer run jobs tracked: \(ControlJobs.jobs.count)")
        lines.append("notification log: \(notificationLogSummary)")
        return lines
    }

    /// One line per pane, numbered in tree order: where it is, whether it's on screen, its grid and
    /// pixel size. No IDs, titles, cwds or processes.
    private static func paneLines() -> [String] {
        var lines: [String] = []
        var n = 0
        for (wi, wc) in AppDelegate.shared.windowControllers.enumerated() {
            for (si, ws) in wc.workspaces.enumerated() {
                for (di, deck) in ws.decks.enumerated() {
                    for (ti, tab) in deck.tabs.enumerated() {
                        for p in tab.panes {
                            n += 1
                            let shown = p.view.window != nil && !p.view.isHiddenOrHasHiddenAncestor
                            var s = "pane \(n): window \(wi + 1) workspace \(si + 1) deck \(di + 1) tab \(ti + 1)"
                                + (shown ? " visible" : " hidden")
                                + (shown && !p.surface.windowVisible ? " window-occluded" : "")  // #54
                            if let surface = p.surface.surface {
                                let z = ghostty_surface_size(surface)
                                s += " grid \(z.columns)x\(z.rows) px \(z.width_px)x\(z.height_px) cell \(z.cell_width_px)x\(z.cell_height_px)"
                                if ghostty_surface_needs_confirm_quit(surface) { s += " busy" }
                                if ghostty_surface_process_exited(surface) { s += " exited" }
                            } else {
                                s += " no-surface"
                            }
                            lines.append(s)
                        }
                    }
                }
            }
        }
        lines.append("(libghostty's C API reports no per-surface memory or scrollback usage; sizes above are the grid and drawable)")
        return lines
    }

    // MARK: Tools

    /// Runs a tool, returning its output lines (stderr included) with the home directory and user
    /// name replaced. Times out rather than hang the app.
    static func tool(_ path: String, _ args: [String], timeout: TimeInterval) -> [String] {
        guard FileManager.default.isExecutableFile(atPath: path) else { return ["(\(path) not available)"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var data = Data()
        let reader = DispatchQueue(label: "dealer.diagnostics.read")
        let done = DispatchSemaphore(value: 0)
        do { try p.run() } catch { return ["(\(path) failed to start: \(error.localizedDescription))"] }
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return ["(\((path as NSString).lastPathComponent) timed out after \(Int(timeout)) s)"]
        }
        p.waitUntilExit()
        return redact(String(decoding: data, as: UTF8.self))
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .reversed().drop { $0.isEmpty }.reversed()
    }

    static func redact(_ s: String) -> String {
        var s = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let user = NSUserName()
        if user.count >= 3 { s = s.replacingOccurrences(of: user, with: "USER") }
        return s
    }
}

// MARK: - Entry points

extension Diagnostics {
    /// `dealer diagnose [--leaks]`: writes the report and answers with its path.
    static func control(_ args: [String: Any]) throws -> [String: Any] {
        do {
            let url = try capture(Options(leaks: args["leaks"] as? Bool ?? false))
            return ["path": url.path, "notification_log": notificationLogSummary]
        } catch {
            throw ControlHandler.Failure(message: "could not write diagnostics: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate {
    @objc func captureDiagnostics(_ sender: Any?) { Diagnostics.captureFromMenu() }
}

extension Diagnostics {
    /// Whether `[notifications] log` is on, where the log is, and how big (#56). `dealer diagnose`
    /// prints it too, so the path is easy to find.
    static var notificationLogSummary: String {
        let path = NotificationLog.path
        func size(_ p: String) -> String? {
            ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? nil)
                .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        }
        NotificationLog.flush()
        let current = size(path).map { "\(path), \($0)" } ?? "\(path) (no file)"
        let old = size(path + ".1").map { "; previous \(path).1, \($0)" } ?? ""
        return (NotificationLog.isEnabled ? "on ([notifications] log = true), " : "off (set [notifications] log = true to record), ")
            + current + old
    }
}
