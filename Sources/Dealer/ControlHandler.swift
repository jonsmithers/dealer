import AppKit
import Carbon.HIToolbox
import GhosttyKit

/// Executes control-socket requests. A plain function from request to response, called on main,
/// so the self-test can drive it without a socket. Everything goes through the same controller
/// methods the menus use.
///
/// Targets are written `pane:N`, `tab:N`, `deck:N`, `workspace:N`, `window:N`, a bare `N` (a pane),
/// or `focused`. With no target, a command acts on the caller's pane (`caller`, which the CLI fills
/// from `$DEALER_PANE_ID`), else on the focused pane.
enum ControlHandler {
    struct Failure: Error { let message: String }

    static func handle(_ req: [String: Any]) -> [String: Any] {
        precondition(Thread.isMainThread)
        let cmd = req["cmd"] as? String ?? ""
        let args = req["args"] as? [String: Any] ?? [:]
        let ctx = Context(caller: int(req["caller"]))
        do {
            let result: [String: Any]
            switch cmd {
            case "identify": result = try identify(ctx)
            case "list": result = list(args)
            case "find": result = try find(args)
            case "create": result = try create(args, ctx)
            case "send-text": result = try sendText(args, ctx)
            case "read": result = try read(args, ctx)
            case "focus": result = try focus(args, ctx)
            case "resize": result = try resize(args, ctx)
            case "rename": result = try rename(args, ctx)
            case "color": result = try color(args, ctx)
            case "notify": result = try notify(args, ctx)
            case "status": result = try status(args, ctx)
            case "close": result = try close(args, ctx)
            case "run": result = try ControlJobs.run(args, ctx)
            case "job-done": result = try ControlJobs.done(args, ctx)
            case "diagnose": result = try Diagnostics.control(args)
            default: throw Failure(message: "unknown command '\(cmd)'")
            }
            return ["ok": true, "result": result]
        } catch let f as Failure {
            if cmd == "notify" || cmd == "job-done" {
                // An error reply the hook script throws away: the log is the only trace (#56).
                NotificationLog.decision(pane: nil, event: cmd == "notify" ? notifyEvent(args) : cmd, outcome: "error",
                                         reason: f.message + (ctx.caller.map { " (caller pane \($0))" } ?? ""))
            }
            return ["ok": false, "error": f.message]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    // MARK: - Lookup

    struct Context { let caller: Int? }

    /// Where something lives. `pane` is nil for a tab/deck/workspace/window target.
    struct Loc {
        let wc: TerminalWindowController
        var ws: Workspace?
        var deck: Deck?
        var tab: Tab?
        var pane: Pane?

        /// The pane a pane-level command should act on: the pane itself, or the one that
        /// would get focus in the tab/deck/workspace/window.
        var focusPane: Pane? {
            if let pane { return pane }
            if let tab { return tab.focusTarget }
            if let deck { return deck.activeTab?.focusTarget }
            let w = ws ?? wc.activeWorkspace
            return w.validFocusedPane ?? w.decks.first?.activeTab?.focusTarget
        }
    }

    /// Every Dealer window, oldest first (stable order for listing and cycling).
    static var controllers: [TerminalWindowController] {
        AppDelegate.shared.windowControllers.sorted { $0.id < $1.id }
    }

    /// The window the user is looking at: key, else main, else frontmost.
    static var frontController: TerminalWindowController? {
        if let wc = NSApp.keyWindow?.windowController as? TerminalWindowController { return wc }
        if let wc = NSApp.mainWindow?.windowController as? TerminalWindowController { return wc }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
            ?? controllers.first
    }

    static var focusedPane: Pane? {
        guard let wc = frontController else { return nil }
        return wc.focusedPane ?? wc.focusedDeck?.activeTab?.focusTarget
    }

    static func locate(_ pane: Pane) -> Loc? {
        for wc in controllers {
            if let l = wc.locate(pane) { return Loc(wc: wc, ws: l.workspace, deck: l.deck, tab: l.tab, pane: pane) }
        }
        return nil
    }

    static func pane(id: Int) -> Pane? {
        for wc in controllers {
            for p in wc.workspaces.flatMap(\.panes) where p.id == id { return p }
        }
        return nil
    }

    /// Resolves a target string; nil/empty means the caller's pane, else the focused pane.
    static func resolve(_ target: Any?, _ ctx: Context) throws -> Loc {
        let ref = (target as? String)?.trimmingCharacters(in: .whitespaces) ?? (target.map { "\($0)" } ?? "")
        if ref.isEmpty {
            if let id = ctx.caller {
                guard let p = pane(id: id), let l = locate(p) else {
                    throw Failure(message: "the calling pane (\(id), from DEALER_PANE_ID) no longer exists")
                }
                return l
            }
            return try resolve("focused", ctx)
        }
        if ref == "focused" {
            guard let p = focusedPane, let l = locate(p) else { throw Failure(message: "no pane has focus") }
            return l
        }
        let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.count == 2 ? parts[0].lowercased() : "pane"
        guard let id = Int(parts.last ?? "") else {
            throw Failure(message: "bad target '\(ref)' (expected pane:N, tab:N, deck:N, workspace:N, window:N, N or focused)")
        }
        switch kind {
        case "pane", "p":
            guard let p = pane(id: id), let l = locate(p) else { throw Failure(message: "no pane \(id)") }
            return l
        case "tab", "t":
            for wc in controllers {
                for ws in wc.workspaces {
                    for d in ws.decks {
                        if let t = d.tabs.first(where: { $0.id == id }) { return Loc(wc: wc, ws: ws, deck: d, tab: t) }
                    }
                }
            }
            throw Failure(message: "no tab \(id)")
        case "deck", "d":
            for wc in controllers {
                for ws in wc.workspaces {
                    if let d = ws.decks.first(where: { $0.id == id }) { return Loc(wc: wc, ws: ws, deck: d) }
                }
            }
            throw Failure(message: "no deck \(id)")
        case "workspace", "ws", "w":
            for wc in controllers {
                if let ws = wc.workspaces.first(where: { $0.id == id }) { return Loc(wc: wc, ws: ws) }
            }
            throw Failure(message: "no workspace \(id)")
        case "window", "win":
            guard let wc = controllers.first(where: { $0.id == id }) else { throw Failure(message: "no window \(id)") }
            return Loc(wc: wc)
        default:
            throw Failure(message: "bad target kind '\(kind)'")
        }
    }

    static func ids(_ p: Pane) -> [String: Any] {
        guard let l = locate(p) else { return ["pane": p.id] }
        return ["pane": p.id, "tab": l.tab!.id, "deck": l.deck!.id, "workspace": l.ws!.id, "window": l.wc.id]
    }

    // MARK: - identify

    static func identify(_ ctx: Context) throws -> [String: Any] {
        var r: [String: Any] = [:]
        if let id = ctx.caller {
            r["caller"] = pane(id: id).map(ids) ?? ["pane": id, "gone": true]
        } else {
            r["caller"] = NSNull()
        }
        r["focused"] = focusedPane.map(ids) ?? NSNull()
        r["socket"] = ControlServer.shared.path ?? NSNull()
        return r
    }

    // MARK: - list

    static func list(_ args: [String: Any]) -> [String: Any] {
        let procs = ProcessTree.all()
        let byTTY = Dictionary(grouping: procs, by: \.tdev)
        let focused = focusedPane
        let front = frontController
        let windows: [[String: Any]] = controllers.map { wc in
            [
                "id": wc.id,
                "key": wc.window?.isKeyWindow ?? false,
                "front": wc === front,
                "title": wc.window?.title ?? "",
                "workspaces": wc.workspaces.map { ws -> [String: Any] in
                    [
                        "id": ws.id,
                        "name": ws.displayName,
                        "custom_name": ws.name ?? NSNull(),
                        "color": ws.color?.hexString ?? NSNull(),
                        "group": ws.group.map { g -> [String: Any] in ["id": g.id, "name": g.name, "collapsed": g.isCollapsed] } ?? NSNull(),
                        "active": ws === wc.activeWorkspace,
                        "decks": ws.decks.map { d -> [String: Any] in
                            [
                                "id": d.id,
                                "color": d.colorIndex,
                                "tabs": d.tabs.map { t -> [String: Any] in
                                    [
                                        "id": t.id,
                                        "title": t.title,
                                        "custom_title": t.customTitle ?? NSNull(),
                                        "tab_color": t.color?.hexString ?? NSNull(),
                                        "active": t === d.activeTab,
                                        "panes": t.panes.map { describe($0, ws: ws, byTTY: byTTY, focused: focused) },
                                    ]
                                },
                            ]
                        },
                    ]
                },
            ]
        }
        return ["windows": windows, "focused": focused?.id ?? NSNull()]
    }

    static func describe(_ p: Pane, ws: Workspace, byTTY: [dev_t: [ProcessTree.Proc]], focused: Pane?) -> [String: Any] {
        var d: [String: Any] = [
            "id": p.id,
            "title": p.title,
            "custom_title": p.customTitle ?? NSNull(),
            "focused": p === focused,
            "workspace_focus": p === ws.validFocusedPane,
            "visible": p.view.window != nil && !p.view.isHiddenOrHasHiddenAncestor,
            "agent_state": p.agentState.rawValue,
            "progress": [
                "reporting": p.isReportingProgress,
                "percent": p.progressPercent ?? NSNull(),
                "from_claude": p.progressFromClaude,
                "foreground_pgid": Int(p.progressForeground),
            ] as [String: Any],
            // OSC 7501 records (#89), root first; text sanitized, `app` inherited.
            "program_status": p.programStatus.sorted.map { r -> [String: Any] in
                [
                    "id": r.id,
                    "state": r.state.rawValue,
                    "kind": r.kind?.rawValue ?? NSNull(),
                    "progress": r.progress ?? NSNull(),
                    "app": p.programStatus.app(of: r.id) ?? NSNull(),
                    "title": r.title ?? NSNull(),
                    "msg": r.msg ?? NSNull(),
                ]
            },
        ]
        guard let s = p.surface.surface else { return d }
        let size = ghostty_surface_size(s)
        d["columns"] = Int(size.columns)
        d["rows"] = Int(size.rows)
        let fg = Int32(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
        let ttyStr = ghostty_surface_tty_name(s)
        let tty = ttyStr.ptr.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(ttyStr.len)), as: UTF8.self) }
        ghostty_string_free(ttyStr)
        d["tty"] = tty ?? NSNull()
        let cwd = p.pwd ?? (fg > 0 ? ProcessTree.cwd(of: fg) : nil)
        d["cwd"] = cwd ?? NSNull()
        func proc(_ x: ProcessTree.Proc) -> [String: Any] {
            let argv = ProcessTree.arguments(of: x.pid) ?? [x.name]
            return ["pid": Int(x.pid), "ppid": Int(x.ppid), "pgid": Int(x.pgid), "name": x.name,
                    "argv": argv, "command": argv.joined(separator: " ")]
        }
        let onTTY = tty.flatMap(ProcessTree.device(ofTTY:)).flatMap { byTTY[$0] } ?? []
        d["processes"] = onTTY.sorted { $0.pid < $1.pid }.map { x -> [String: Any] in
            var e = proc(x)
            e["foreground"] = x.pgid == x.tpgid
            return e
        }
        if fg > 0 {
            if let x = onTTY.first(where: { $0.pid == fg }) {
                d["foreground"] = proc(x)
            } else {
                let argv = ProcessTree.arguments(of: fg) ?? []
                d["foreground"] = ["pid": Int(fg), "argv": argv, "command": argv.joined(separator: " ")]
            }
        } else {
            d["foreground"] = NSNull()
        }
        return d
    }

    // MARK: - find

    /// Pane IDs in list order whose processes / title / cwd match. `after` rotates the result
    /// so it starts just after that pane, which makes "focus the next match" a one-liner.
    static func find(_ args: [String: Any]) throws -> [String: Any] {
        func regex(_ key: String) throws -> NSRegularExpression? {
            guard let s = args[key] as? String, !s.isEmpty else { return nil }
            do { return try NSRegularExpression(pattern: s) } catch { throw Failure(message: "bad --\(key) regex: \(s)") }
        }
        let process = try regex("process"), title = try regex("title"), cwd = args["cwd"] as? String
        func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
            guard let re else { return true }
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        var hits: [Int] = []
        let tree = list([:])
        for w in tree["windows"] as! [[String: Any]] {
            for ws in w["workspaces"] as! [[String: Any]] {
                for d in ws["decks"] as! [[String: Any]] {
                    for t in d["tabs"] as! [[String: Any]] {
                        for p in t["panes"] as! [[String: Any]] {
                            let procs = (p["processes"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
                            guard process == nil || procs.contains(where: { matches(process, $0) }) else { continue }
                            guard matches(title, p["title"] as? String ?? "") else { continue }
                            if let cwd {
                                let pc = p["cwd"] as? String ?? ""
                                guard pc == cwd || pc.hasPrefix(cwd.hasSuffix("/") ? cwd : cwd + "/") else { continue }
                            }
                            hits.append(p["id"] as! Int)
                        }
                    }
                }
            }
        }
        let after = (args["after"] as? String) == "focused" ? focusedPane?.id : int(args["after"])
        if let after, let i = hits.firstIndex(of: after) {
            hits = Array(hits[(i + 1)...] + hits[...i])
        }
        return ["panes": hits]
    }

    // MARK: - create

    static func create(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let type = (args["type"] as? String ?? "pane").lowercased()
        let loc = try resolve(args["target"], ctx)
        let focus = args["focus"] as? Bool ?? true
        let anchor = loc.focusPane
        var cwd = args["cwd"] as? String
        if cwd == nil, let a = anchor { cwd = a.pwd ?? currentDirectory(of: a) }
        if let c = cwd {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue else {
                throw Failure(message: "no such directory: \(c)")
            }
        }
        let command = (args["command"] as? String).flatMap { $0.isEmpty ? nil : loginShellCommand($0) }
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let size = args["size"] as? String
        let wc = loc.wc

        let pane: Pane
        switch type {
        case "pane", "split":
            guard let target = anchor else { throw Failure(message: "no pane to split") }
            let side = try parseSide(args["side"] as? String ?? "right")
            let f = try size.map { try fraction($0, for: target, side: side) } ?? 0.5
            pane = wc.controlSplit(target, side: side, fraction: f, workingDirectory: cwd, command: command, title: title, focus: focus)
        case "tab":
            guard let deck = loc.deck ?? loc.focusPane.flatMap({ wc.locate($0)?.deck }) else { throw Failure(message: "no deck for the new tab") }
            pane = wc.controlNewTab(in: deck, after: loc.tab, workingDirectory: cwd, command: command, title: title, focus: focus)
        case "deck":
            guard let beside = loc.deck ?? loc.focusPane.flatMap({ wc.locate($0)?.deck }) else { throw Failure(message: "no deck to place the new deck beside") }
            let side = try parseSide(args["side"] as? String ?? "right")
            let f = try size.map { try deckFraction($0, beside: beside, in: wc, side: side, sample: anchor) } ?? 0.5
            pane = wc.controlNewDeck(beside: beside, side: side, fraction: f, workingDirectory: cwd, command: command, title: title, focus: focus)
        case "workspace":
            pane = wc.controlNewWorkspace(after: loc.ws, name: args["name"] as? String, workingDirectory: cwd, command: command, title: title, focus: focus)
        default:
            throw Failure(message: "can't create '\(type)' (expected pane, tab, deck or workspace)")
        }
        if focus { bringForward(wc) }
        return ids(pane)
    }

    static func currentDirectory(of p: Pane) -> String? {
        guard let s = p.surface.surface else { return nil }
        let fg = Int32(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
        return fg > 0 ? ProcessTree.cwd(of: fg) : nil
    }

    static func parseSide(_ s: String) throws -> Side {
        switch s.lowercased() {
        case "left", "l", "west": return .left
        case "right", "r", "east": return .right
        case "up", "top", "above", "u", "north": return .top
        case "down", "bottom", "below", "d", "south": return .bottom
        default: throw Failure(message: "bad side '\(s)' (expected left, right, up or down)")
        }
    }

    /// Cell size of a pane in points, and the non-cell padding inside its surface along an axis.
    static func cellMetrics(_ p: Pane, axis: Axis) -> (cell: CGFloat, padding: CGFloat)? {
        guard let s = p.surface.surface else { return nil }
        let size = ghostty_surface_size(s)
        let scale = p.surface.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let cellPx = axis == .row ? size.cell_width_px : size.cell_height_px
        let count = axis == .row ? size.columns : size.rows
        guard cellPx > 0 else { return nil }
        let cell = CGFloat(cellPx) / scale
        let extent = axis == .row ? p.surface.bounds.width : p.surface.bounds.height
        return (cell, max(extent - CGFloat(count) * cell, 0))
    }

    /// `--size`: `0.3` is a fraction, `30%` a percentage, `12` a number of rows/columns for the new pane.
    static func fraction(_ spec: String, for target: Pane, side: Side) throws -> CGFloat {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%"), let v = Double(s.dropLast()) { return clampFraction(v / 100) }
        if s.contains("."), let v = Double(s) {
            guard v > 0 && v < 1 else { throw Failure(message: "--size fraction must be between 0 and 1") }
            return clampFraction(v)
        }
        guard let n = Int(s), n > 0 else { throw Failure(message: "bad --size '\(spec)' (expected 0.3, 30% or a number of cells)") }
        let axis = side.axis
        let total = axis == .row ? target.view.frame.width : target.view.frame.height
        guard total > 0, let m = cellMetrics(target, axis: axis) else { return 0.5 }
        // The new pane needs its cells plus the surface padding, and a title bar when stacked.
        let chrome = (target.view.frame.height - target.surface.frame.height)
        let bar = axis == .col ? max(chrome, PaneView.barHeight) : 0
        let needed = CGFloat(n) * m.cell + m.padding + bar + TerminalWindowController.paneGap / 2
        return clampFraction(Double(needed / total))
    }

    static func deckFraction(_ spec: String, beside deck: Deck, in wc: TerminalWindowController, side: Side, sample: Pane?) throws -> CGFloat {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%") || s.contains(".") || sample == nil { return try fraction(s, forDeckOnly: ()) }
        guard let n = Int(s), n > 0, let p = sample, let m = cellMetrics(p, axis: side.axis) else {
            return try fraction(s, forDeckOnly: ())
        }
        let total = side.axis == .row ? deck.view.frame.width : deck.view.frame.height
        guard total > 0 else { return 0.5 }
        let chrome = side.axis == .row ? 16 : DeckView.stripHeight + 16
        return clampFraction(Double((CGFloat(n) * m.cell + m.padding + chrome) / total))
    }

    private static func fraction(_ s: String, forDeckOnly: Void) throws -> CGFloat {
        if s.hasSuffix("%"), let v = Double(s.dropLast()) { return clampFraction(v / 100) }
        if let v = Double(s), v > 0, v < 1 { return clampFraction(v) }
        throw Failure(message: "bad --size '\(s)' (expected 0.3, 30% or a number of cells)")
    }

    static func clampFraction(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0.1), 0.9)) }

    // MARK: - send-text

    /// `items` is a list of `{"text": "..."}` and `{"key": "ctrl+c"}` entries, sent in order.
    /// Text is written as if typed (not as a paste) unless `paste` is set.
    static func sendText(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        guard let pane = loc.focusPane, let surface = pane.surface.surface else { throw Failure(message: "no pane to send to") }
        var items = args["items"] as? [[String: Any]] ?? []
        if let t = args["text"] as? String { items.insert(["text": t], at: 0) }
        if args["enter"] as? Bool == true { items.append(["key": "enter"]) }
        let paste = args["paste"] as? Bool ?? false
        // Validate everything before sending anything.
        let keys = try items.map { item -> Key? in try (item["key"] as? String).map(parseKey) }
        for (item, key) in zip(items, keys) {
            if let key {
                key.send(to: surface)
            } else if let text = item["text"] as? String, !text.isEmpty {
                if paste {
                    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
                } else {
                    pane.surface.perform("text:" + escapeForBinding(text))
                }
            }
        }
        return ["pane": pane.id]
    }

    /// `create --command CMD` runs `$SHELL -l -c 'exec CMD'`. Ghostty starts a command with no
    /// shell startup files, so it saw Dealer's own PATH: launchd's /usr/bin:/bin:/usr/sbin:/sbin when
    /// Dealer is opened from the Finder, where Homebrew's `nvim` isn't found. A login shell reads
    /// the profile (`.zprofile`, where `brew shellenv` goes), not the interactive rc (the user's call).
    static func loginShellCommand(_ command: String, shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> String {
        let sh = shell.flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
            ?? "/bin/sh"
        return "\(CLI.shellQuote(sh)) -l -c \(CLI.shellQuote("exec " + command))"
    }

    // MARK: - read

    /// A pane's text (`SurfaceView.readText`), with trailing spaces and trailing blank lines
    /// dropped; `lines` keeps only the last N. Waiting for output (`--wait`) is the CLI's loop,
    /// so main never blocks.
    static func read(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        guard let pane = loc.focusPane else { throw Failure(message: "no pane to read") }
        let scrollback = args["scrollback"] as? Bool ?? false
        guard let raw = pane.surface.readText(scrollback: scrollback) else {
            throw Failure(message: "pane \(pane.id) has no terminal to read")
        }
        var lines = raw.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            while let c = l.last, c == " " || c == "\t" || c == "\r" { l.removeLast() }
            return String(l)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if let n = args["lines"] {
            guard let n = int(n), n > 0 else { throw Failure(message: "--lines takes a positive number") }
            lines = Array(lines.suffix(n))
        }
        return ["pane": pane.id, "text": lines.joined(separator: "\n"), "lines": lines.count]
    }

    /// ghostty's `text:` binding parses Zig string-literal escapes.
    static func escapeForBinding(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x5C: out += "\\\\"
            case 0..<0x20, 0x7F: out += String(format: "\\x%02x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    struct Key {
        let keycode: Int
        let mods: ghostty_input_mods_e
        let text: String?
        let codepoint: UInt32

        func send(to surface: ghostty_surface_t) {
            for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
                var ev = ghostty_input_key_s()
                ev.action = action
                ev.keycode = UInt32(keycode)
                ev.mods = mods
                // Shift is the only modifier that contributes to text here.
                ev.consumed_mods = ghostty_input_mods_e(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue)
                ev.unshifted_codepoint = codepoint
                if action == GHOSTTY_ACTION_PRESS, let text {
                    text.withCString { p in
                        ev.text = p
                        _ = ghostty_surface_key(surface, ev)
                    }
                } else {
                    _ = ghostty_surface_key(surface, ev)
                }
            }
        }
    }

    static let namedKeys: [String: (Int, UInt32, String?)] = [
        "enter": (kVK_Return, 0x0D, nil), "return": (kVK_Return, 0x0D, nil),
        "tab": (kVK_Tab, 0x09, nil), "space": (kVK_Space, 0x20, " "),
        "backspace": (kVK_Delete, 0x7F, "\u{7F}"), "delete": (kVK_ForwardDelete, 0, nil),
        "escape": (kVK_Escape, 0x1B, nil), "esc": (kVK_Escape, 0x1B, nil),
        "up": (kVK_UpArrow, 0, nil), "down": (kVK_DownArrow, 0, nil),
        "left": (kVK_LeftArrow, 0, nil), "right": (kVK_RightArrow, 0, nil),
        "home": (kVK_Home, 0, nil), "end": (kVK_End, 0, nil),
        "pageup": (kVK_PageUp, 0, nil), "pagedown": (kVK_PageDown, 0, nil),
        "f1": (kVK_F1, 0, nil), "f2": (kVK_F2, 0, nil), "f3": (kVK_F3, 0, nil), "f4": (kVK_F4, 0, nil),
        "f5": (kVK_F5, 0, nil), "f6": (kVK_F6, 0, nil), "f7": (kVK_F7, 0, nil), "f8": (kVK_F8, 0, nil),
        "f9": (kVK_F9, 0, nil), "f10": (kVK_F10, 0, nil), "f11": (kVK_F11, 0, nil), "f12": (kVK_F12, 0, nil),
    ]

    /// US-layout keycodes for printable keys, so ctrl+c etc. go through ghostty's key encoder.
    static let charKeys: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]

    /// `enter`, `ctrl+c`, `alt+b`, `shift+tab`, `f5`, … (`-` works as a separator too: `ctrl-c`).
    static func parseKey(_ spec: String) throws -> Key {
        var parts = spec.lowercased().split(whereSeparator: { $0 == "+" }).map(String.init)
        if parts.count == 1, spec.count > 1, let dash = spec.lastIndex(of: "-"), dash != spec.startIndex {
            parts = spec.lowercased().split(separator: "-").map(String.init)
        }
        guard let base = parts.last, !base.isEmpty else { throw Failure(message: "bad key '\(spec)'") }
        var m = GHOSTTY_MODS_NONE.rawValue
        for mod in parts.dropLast() {
            switch mod {
            case "ctrl", "control", "c": m |= GHOSTTY_MODS_CTRL.rawValue
            case "alt", "opt", "option", "meta", "m": m |= GHOSTTY_MODS_ALT.rawValue
            case "shift", "s": m |= GHOSTTY_MODS_SHIFT.rawValue
            case "cmd", "super", "command": m |= GHOSTTY_MODS_SUPER.rawValue
            default: throw Failure(message: "bad modifier '\(mod)' in key '\(spec)'")
            }
        }
        let mods = ghostty_input_mods_e(m)
        if let (code, cp, text) = namedKeys[base] {
            return Key(keycode: code, mods: mods, text: text, codepoint: cp)
        }
        if base.count == 1, let ch = base.first, let code = charKeys[ch] {
            let shifted = m & GHOSTTY_MODS_SHIFT.rawValue != 0
            let text = shifted ? String(ch).uppercased() : String(ch)
            return Key(keycode: code, mods: mods, text: text, codepoint: ch.unicodeScalars.first!.value)
        }
        throw Failure(message: "unknown key '\(spec)'")
    }

    // MARK: - focus

    static func focus(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        if loc.pane == nil && loc.tab == nil && loc.deck == nil, let ws = loc.ws {
            loc.wc.activate(ws)
        } else if let p = loc.focusPane {
            loc.wc.focus(p)
        }
        bringForward(loc.wc)
        return ["focused": focusedPane.map(ids) ?? NSNull()]
    }

    static func bringForward(_ wc: TerminalWindowController) {
        guard let window = wc.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive && !SelfTest.enabled { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - resize

    /// Moves the divider next to a pane (or deck). `to` sets the target's share of the split
    /// (`0.3` or `30%`); `by` changes it (`+5` cells, `-10%`). `axis` picks width or height;
    /// by default the nearest enclosing split is used.
    static func resize(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        var axis: Axis?
        switch (args["axis"] as? String)?.lowercased() {
        case nil, "": axis = nil
        case "width", "w", "horizontal", "x", "columns", "cols": axis = .row
        case "height", "h", "vertical", "y", "rows": axis = .col
        case let a?: throw Failure(message: "bad axis '\(a)' (expected width or height)")
        }

        // Find the split: in the pane's tab tree, or the window tree for a deck target.
        func nearest<L>(_ start: Node<L>) -> (split: Node<L>, first: Bool)? {
            var n = start
            while let p = n.parent {
                if axis == nil || p.axis == axis { return (p, p.a === n) }
                n = p
            }
            return nil
        }
        let split: (ratio: CGFloat, axis: Axis, first: Bool, extent: CGFloat?, set: (CGFloat) -> Void)
        let sample: Pane?
        if loc.pane == nil && loc.tab == nil, let deck = loc.deck {
            guard let node = loc.ws?.root?.node(for: deck), let (s, first) = nearest(node) else {
                throw Failure(message: "deck \(deck.id) has no \(axis.map { $0 == .row ? "side-by-side " : "stacked " } ?? "")neighbour to resize against")
            }
            let rects = s.leaves.map { $0.view.frame }
            let u = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
            split = (s.ratio, s.axis, first, s.axis == .row ? u.width : u.height, { s.ratio = $0 })
            sample = deck.activeTab?.focusTarget
        } else {
            guard let pane = loc.focusPane, let l = loc.wc.locate(pane), let (s, first) = nearest(l.node) else {
                throw Failure(message: "that pane has no \(axis.map { $0 == .row ? "side-by-side " : "stacked " } ?? "")split to resize")
            }
            let r = loc.wc.frame(of: s)
            split = (s.ratio, s.axis, first, r.map { s.axis == .row ? $0.width : $0.height }, { s.ratio = $0 })
            sample = pane
        }

        var share = split.first ? split.ratio : 1 - split.ratio
        if let to = args["to"] as? String {
            share = try fraction(to, forDeckOnly: ())
        } else if let by = args["by"] as? String {
            let s = by.trimmingCharacters(in: .whitespaces)
            if s.hasSuffix("%"), let v = Double(s.dropLast()) {
                share += CGFloat(v / 100)
            } else if let n = Double(s) {
                guard let extent = split.extent, extent > 0, let p = sample, let m = cellMetrics(p, axis: split.axis) else {
                    throw Failure(message: "can't resize by cells while the split is off screen; use a percentage")
                }
                share += CGFloat(n) * m.cell / extent
            } else {
                throw Failure(message: "bad --by '\(by)' (expected +5, -3 or +10%)")
            }
        } else {
            throw Failure(message: "resize needs --to or --by")
        }
        share = min(max(share, 0.05), 0.95)
        split.set(split.first ? share : 1 - share)
        loc.wc.layoutNow()
        return ["share": Double(share), "axis": split.axis == .row ? "width" : "height"]
    }

    // MARK: - rename

    /// Renames a pane, tab (`tab:N`, or `level: "tab"` for the target pane's tab) or workspace.
    /// An empty title goes back to following the terminal.
    static func rename(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        let raw = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let title: String? = raw.isEmpty ? nil : raw
        let level = (args["level"] as? String)?.lowercased()
        var r: [String: Any] = [:]
        if level == "tab" || (level == nil && loc.pane == nil && loc.tab != nil) {
            guard let tab = loc.tab ?? loc.focusPane.flatMap({ loc.wc.locate($0)?.tab }) else { throw Failure(message: "no tab to rename") }
            tab.customTitle = title
            r["tab"] = tab.id
        } else if level == "workspace" || (level == nil && loc.pane == nil && loc.deck == nil && loc.ws != nil) {
            guard let ws = loc.ws ?? loc.focusPane.flatMap({ loc.wc.locate($0)?.workspace }) else { throw Failure(message: "no workspace to rename") }
            ws.name = title
            r["workspace"] = ws.id
        } else {
            guard let pane = loc.focusPane else { throw Failure(message: "no pane to rename") }
            pane.customTitle = title
            r["pane"] = pane.id
        }
        loc.wc.refreshChrome()
        return r
    }

    // MARK: - color (#9)

    /// Colors a tab or workspace. Level: `--tab` / `--workspace`, else from the target (a workspace
    /// or window target colors the workspace; a pane or tab target colors its tab).
    static func color(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        let raw = args["color"] as? String ?? ""
        guard !raw.isEmpty else { throw Failure(message: "give a color: a swatch name (\(Theme.swatches.map(\.name).joined(separator: ", "))), a number, #rrggbb, or none") }
        guard case .some(let color) = Theme.parseColor(raw) else { throw Failure(message: "can't read color '\(raw)'") }
        let level = (args["level"] as? String)?.lowercased()
        if level == "workspace" || (level == nil && loc.pane == nil && loc.tab == nil && loc.deck == nil) {
            guard let ws = loc.ws ?? loc.focusPane.flatMap({ loc.wc.locate($0)?.workspace }) else { throw Failure(message: "no workspace to color") }
            loc.wc.setColor(color, workspace: ws)
            return ["workspace": ws.id, "color": color?.hexString ?? NSNull()]
        }
        guard level == nil || level == "tab" else { throw Failure(message: "color applies to a tab or a workspace") }
        guard let tab = loc.tab ?? loc.focusPane.flatMap({ loc.wc.locate($0)?.tab }) else { throw Failure(message: "no tab to color") }
        loc.wc.setColor(color, tab: tab)
        return ["tab": tab.id, "color": color?.hexString ?? NSNull()]
    }

    // MARK: - notify

    static func notify(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        guard let pane = loc.focusPane else { throw Failure(message: "no pane to notify for") }
        let state = args["state"] as? String ?? "unread"
        let title = args["title"] as? String
        let body = args["body"] as? String
        try ControlNotify.post(pane: pane, in: loc.wc, state: state, title: title, body: body, event: notifyEvent(args))
        return ["pane": pane.id]
    }

    // MARK: - status (#89)

    /// Sets a program status record on the target pane as an OSC 7501 report would: the same
    /// parser, limits and mapping (ProgramStatus.swift). `title` and `msg` are plain text here.
    static func status(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        guard let pane = loc.focusPane else { throw Failure(message: "no pane to set a status on") }
        let state = args["state"] as? String ?? ""
        var pairs = ["state=\(state)"]
        for key in ["id", "kind", "progress", "app"] {
            guard let v = args[key].map({ "\($0)" }) else { continue }
            // A report would read these as absent; a script asking for them deserves an error.
            if v.contains(":") || v.contains("=") || v.contains(where: \.isWhitespace) {
                throw Failure(message: "--\(key) can't contain ':', '=' or spaces")
            }
            if key == "kind", ProgramStatus.Kind(rawValue: v) == nil { throw Failure(message: "--kind is permission, question or auth") }
            if key == "progress", !(Int(v).map { (0...100).contains($0) } ?? false) { throw Failure(message: "--progress is 0 to 100") }
            if key == "app", v.utf8.count > ProgramStatus.maxAppBytes || v.contains("/") { throw Failure(message: "--app is a name of at most \(ProgramStatus.maxAppBytes) bytes: letters, digits, _ . + -") }
            pairs.append("\(key)=\(v)")
        }
        for key in ["title", "msg"] {
            guard let v = args[key] as? String else { continue }
            pairs.append("\(key)=\(Data(v.utf8).base64EncodedString())")
        }
        if let e = ProgramStatus.receive(pairs.joined(separator: ":"), on: pane, source: "status") {
            throw Failure(message: "status not set: \(e.description)")
        }
        return ["pane": pane.id]
    }

    /// `notify`, or the hook script's `--internal-log-source` label (the Claude hook sends `claude:<event>`), kept to one short word.
    static func notifyEvent(_ args: [String: Any]) -> String {
        guard let s = args["source"] as? String, !s.isEmpty else { return "notify" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":-_."))
        return String(String(s.unicodeScalars.filter(allowed.contains)).prefix(40))
    }

    // MARK: - close

    static func close(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        // No confirmation, for a tab or a pane: a script asked for it, and the reply must come
        // after the change (a sheet would leave it pending, or cancelled).
        if loc.pane == nil, let tab = loc.tab {
            loc.wc.remove(tab: tab)
            return ["tab": tab.id]
        }
        guard let pane = loc.focusPane else { throw Failure(message: "no pane to close") }
        loc.wc.remove(pane)
        return ["pane": pane.id]
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}

// MARK: - Controller commands used by the control socket

extension TerminalWindowController {
    /// Split beside `target`. Unlike the menu's split, it takes a size, a directory, a command and
    /// a title, and with `focus: false` it leaves focus where it was (no create-then-refocus race).
    func controlSplit(_ target: Pane, side: Side, fraction: CGFloat, workingDirectory: String?, command: String?,
                      title: String?, focus: Bool) -> Pane {
        let keep = focusedPane
        let new = makePane(workingDirectory: workingDirectory, command: command)
        new.customTitle = title
        guard let loc = locate(target) else { return new }
        loc.tab.root = Node.insert(Node(new), beside: loc.node, side: side, fraction: fraction, root: loc.tab.root)
        unzoom(hiding: loc.tab, in: loc.workspace)
        finishChange(focus: focus ? new : keep)
        return new
    }

    /// A new tab right after `after` (default: the active tab). Without focus it opens in the background.
    func controlNewTab(in deck: Deck, after: Tab?, workingDirectory: String?, command: String?, title: String?,
                       focus: Bool) -> Pane {
        let keep = focusedPane
        let pane = makePane(workingDirectory: workingDirectory, command: command)
        let tab = Tab(root: Node(pane))
        tab.customTitle = title
        let i = min((after.flatMap { deck.index(of: $0) } ?? deck.activeIndex) + 1, deck.tabs.count)
        deck.tabs.insert(tab, at: i)
        if focus {
            deck.activeIndex = i
        } else if i <= deck.activeIndex {
            deck.activeIndex += 1
        }
        finishChange(focus: focus ? pane : keep)
        return pane
    }

    /// A new deck beside `deck`, in the same workspace. `fraction` is the new deck's share.
    func controlNewDeck(beside deck: Deck, side: Side, fraction: CGFloat, workingDirectory: String?, command: String?,
                        title: String?, focus: Bool) -> Pane {
        let keep = focusedPane
        let pane = makePane(workingDirectory: workingDirectory, command: command)
        let tab = Tab(root: Node(pane))
        tab.customTitle = title
        guard let ws = workspace(of: deck), let root = ws.root, let node = root.node(for: deck) else { return pane }
        let new = Deck(colorIndex: nextColorIndex(in: ws))
        new.tabs = [tab]
        ws.root = Node.insert(Node(new), beside: node, side: side, fraction: fraction, root: root)
        finishChange(focus: focus ? pane : keep)
        return pane
    }

    /// A new workspace after `after` (default: at the end) holding one deck.
    func controlNewWorkspace(after: Workspace?, name: String?, workingDirectory: String?, command: String?,
                             title: String?, focus: Bool) -> Pane {
        let pane = makePane(workingDirectory: workingDirectory, command: command)
        let tab = Tab(root: Node(pane))
        tab.customTitle = title
        let deck = Deck(colorIndex: 0)
        deck.tabs = [tab]
        let ws = Workspace(root: Node(deck), name: name.flatMap { $0.isEmpty ? nil : $0 })
        let i = after.flatMap { a in workspaces.firstIndex { $0 === a } }.map { $0 + 1 } ?? workspaces.count
        insert(workspace: ws, at: i)
        ws.focusedPane = pane
        if focus { activate(ws) } else { refreshChrome() }
        return pane
    }
}
