import Foundation

/// `dealer <command>`: a client for the control socket. It runs instead of the app when the binary
/// is invoked as `dealer` (the bundle's bin/dealer symlink) or with a known subcommand
/// (`Dealer list`). See docs/cli.md.
enum CLI {
    static let commands: Set<String> = [
        "identify", "list", "ls", "find", "create", "new", "send-text", "send", "focus", "resize",
        "rename", "color", "notify", "close", "help", "--help", "-h",
    ]

    /// True when this process should act as the CLI rather than launch the app.
    static func shouldRun(_ argv: [String]) -> Bool {
        let invokedAs = (argv.first.map { ($0 as NSString).lastPathComponent } ?? "")
        if invokedAs == "dealer" { return true }
        return argv.count > 1 && commands.contains(argv[1])
    }

    static let usage = """
    usage: dealer <command> [options]

    Targets (-t/--target): pane:N (or just N), tab:N, deck:N, workspace:N, window:N, focused.
    Default target: $DEALER_PANE_ID (the pane you're running in), else the focused pane.

      identify [--caller | --focused] [--json]   the calling and the focused pane
      list [--json]                              window > workspace > deck > tab > pane tree
      find [--process RE] [--title RE] [--cwd DIR] [--after ID | --next]
                                                 matching pane IDs in tree order
      create [pane|tab|deck|workspace] [-t T] [--side left|right|up|down] [--size 12|30%|0.3]
             [--cwd DIR] [--command CMD] [--title T] [--name WS] [--no-focus] [--json]
                                                 prints the new pane's ID
      send-text [-t T] [--key K]... [--enter] [--paste] [--stdin] [TEXT...]
                                                 type text/keys (enter, tab, esc, ctrl+c, up, f5, ...)
      focus [TARGET]                             focus a pane/tab/deck/workspace/window
      resize [-t T] [--axis width|height] (--to 0.3|30% | --by +5|-3|+10%)
      rename [-t T] [--tab | --workspace] [TITLE]  empty title follows the terminal again
      color [-t T] [--tab | --workspace] COLOR|none  swatch name or number, or #rrggbb
      notify [-t T] [--state unread|done|waiting|none] [--title T] [--body B]
      close [-t T]

    Environment: DEALER_SOCKET (socket path), DEALER_PANE_ID (default target).
    """

    struct Usage: Error { let message: String }

    static func run(_ argv: [String]) -> Int32 {
        var args = Array(argv.dropFirst())
        guard let first = args.first else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        args.removeFirst()
        if ["help", "--help", "-h"].contains(first) {
            print(usage)
            return 0
        }
        do {
            let (cmd, reqArgs, output) = try parse(first, args)
            let env = ProcessInfo.processInfo.environment
            let path = output.socket ?? env["DEALER_SOCKET"] ?? ControlServer.defaultPath
            var req: [String: Any] = ["cmd": cmd, "args": reqArgs]
            if let id = env["DEALER_PANE_ID"].flatMap(Int.init) { req["caller"] = id }
            let resp: [String: Any]
            do {
                resp = try ControlClient.send(req, to: path)
            } catch {
                FileHandle.standardError.write(Data("dealer: \(error)\n".utf8))
                return 3
            }
            guard resp["ok"] as? Bool == true else {
                FileHandle.standardError.write(Data("dealer: \(resp["error"] as? String ?? "failed")\n".utf8))
                return 1
            }
            let result = resp["result"] as? [String: Any] ?? [:]
            print(format(cmd, result, output), terminator: "")
            return 0
        } catch let u as Usage {
            FileHandle.standardError.write(Data("dealer: \(u.message)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("dealer: \(error)\n".utf8))
            return 1
        }
    }

    struct Output {
        var json = false
        var only: String?
        var socket: String?
    }

    // MARK: - Parsing

    static func parse(_ command: String, _ argv: [String]) throws -> (String, [String: Any], Output) {
        var out = Output()
        var a: [String: Any] = [:]
        var positional: [String] = []
        var items: [[String: Any]] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < argv.count else { throw Usage(message: "\(flag) needs a value") }
            return argv[i]
        }
        var cmd = command
        if cmd == "ls" { cmd = "list" }
        if cmd == "new" { cmd = "create" }
        if cmd == "send" { cmd = "send-text" }
        var textEnded = false
        while i < argv.count {
            let arg = argv[i]
            // Split --flag=value.
            var flag = arg
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flag = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            func val() throws -> String { try inline ?? value(flag) }
            if textEnded || !arg.hasPrefix("-") || arg == "-" {
                positional.append(arg)
                if cmd == "send-text" { items.append(["text": arg, "word": true]) }
                i += 1
                continue
            }
            switch flag {
            case "--": textEnded = true
            case "--json": out.json = true
            case "--socket": out.socket = try val()
            case "-t", "--target", "--match", "-m": a["target"] = try val()
            case "--caller": out.only = "caller"
            case "--focused": out.only = "focused"
            case "--side", "--location": a["side"] = try val()
            case "--size", "--bias": a["size"] = try val()
            case "--cwd": a["cwd"] = try val()
            case "--command", "-e": a["command"] = try val()
            case "--title": a["title"] = try val()
            case "--name": a["name"] = try val()
            case "--no-focus", "--keep-focus": a["focus"] = false
            case "--focus": a["focus"] = true
            case "--key", "-k": items.append(["key": try val()])
            case "--enter": a["enter"] = true
            case "--paste": a["paste"] = true
            case "--stdin":
                let data = FileHandle.standardInput.readDataToEndOfFile()
                items.append(["text": String(decoding: data, as: UTF8.self)])
            case "--process": a["process"] = try val()
            case "--after": a["after"] = try val()
            case "--next": a["after"] = "focused"
            case "--axis": a["axis"] = try val()
            case "--to": a["to"] = try val()
            case "--by", "--increment": a["by"] = try val()
            case "--tab": a["level"] = "tab"
            case "--workspace": a["level"] = "workspace"
            case "--pane": a["level"] = "pane"
            case "--state": a["state"] = try val()
            case "--body": a["body"] = try val()
            default:
                // Negative numbers are values (`resize --by -3` is written `--by=-3` or `--by -3`).
                throw Usage(message: "unknown option \(arg) for '\(cmd)' (see dealer help)")
            }
            i += 1
        }

        switch cmd {
        case "create":
            if let t = positional.first { a["type"] = t }
            if positional.count > 1 { throw Usage(message: "create takes one type: pane, tab, deck or workspace") }
        case "send-text":
            // Consecutive words join with spaces, like echo.
            var merged: [[String: Any]] = []
            for item in items {
                if item["word"] != nil, let prev = merged.last, prev["word"] != nil, let p = prev["text"] as? String {
                    merged[merged.count - 1]["text"] = p + " " + (item["text"] as! String)
                } else {
                    merged.append(item)
                }
            }
            a["items"] = merged
        case "focus", "close":
            if let t = positional.first { a["target"] = t }
        case "rename":
            a["title"] = positional.joined(separator: " ")
        case "color":
            guard positional.count == 1 else { throw Usage(message: "color takes one COLOR: a swatch name or number, #rrggbb, or none") }
            a["color"] = positional[0]
        case "notify":
            if !positional.isEmpty, a["body"] == nil { a["body"] = positional.joined(separator: " ") }
        case "identify", "list", "find", "resize":
            if !positional.isEmpty { throw Usage(message: "unexpected argument '\(positional[0])'") }
        default:
            throw Usage(message: "unknown command '\(cmd)' (see dealer help)")
        }
        return (cmd, a, out)
    }

    // MARK: - Output

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}\n" }
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    static func format(_ cmd: String, _ r: [String: Any], _ out: Output) -> String {
        if out.json { return json(r) }
        switch cmd {
        case "identify":
            func line(_ v: Any?) -> String {
                guard let d = v as? [String: Any], let p = d["pane"] else { return "none" }
                return ["pane", "tab", "deck", "workspace", "window"].compactMap { k in d[k].map { "\(k):\($0)" } }
                    .joined(separator: " ") + ((d["gone"] as? Bool) == true ? " (gone)" : "") + (p is NSNull ? "" : "")
            }
            if let only = out.only {
                return ((r[only] as? [String: Any])?["pane"]).map { "\($0)\n" } ?? ""
            }
            return "caller  \(line(r["caller"]))\nfocused \(line(r["focused"]))\n"
        case "create":
            return "\(r["pane"] ?? "")\n"
        case "find":
            return (r["panes"] as? [Int] ?? []).map { "\($0)\n" }.joined()
        case "list":
            return tree(r)
        case "resize":
            return ""
        default:
            return ""
        }
    }

    static func tree(_ r: [String: Any]) -> String {
        var s = ""
        let home = NSHomeDirectory()
        func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        for w in r["windows"] as? [[String: Any]] ?? [] {
            s += "window:\(w["id"]!)\((w["front"] as? Bool) == true ? " (front)" : "")\n"
            for ws in w["workspaces"] as? [[String: Any]] ?? [] {
                s += "  workspace:\(ws["id"]!) \"\(ws["name"] as? String ?? "")\"\((ws["active"] as? Bool) == true ? " (active)" : "")\n"
                for d in ws["decks"] as? [[String: Any]] ?? [] {
                    s += "    deck:\(d["id"]!)\n"
                    for t in d["tabs"] as? [[String: Any]] ?? [] {
                        s += "      tab:\(t["id"]!) \"\(t["title"] as? String ?? "")\"\((t["active"] as? Bool) == true ? " (active)" : "")\n"
                        for p in t["panes"] as? [[String: Any]] ?? [] {
                            let mark = (p["focused"] as? Bool) == true ? " *focused*" : ""
                            let cwd = (p["cwd"] as? String).map(short) ?? "?"
                            s += "        pane:\(p["id"]!)\(mark) \"\(p["title"] as? String ?? "")\" cwd=\(cwd)\n"
                            if let fg = p["foreground"] as? [String: Any] {
                                s += "          fg [\(fg["pid"] ?? "?")] \(fg["command"] as? String ?? "")\n"
                            }
                        }
                    }
                }
            }
        }
        return s
    }
}
