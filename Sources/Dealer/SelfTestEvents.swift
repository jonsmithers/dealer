import AppKit

// MARK: - Self-test section: `dealer events`

extension TerminalWindowController {
    /// Subscribes over the real control socket, then changes things through the controller and the
    /// control handler and checks the events that arrive, their order against the snapshot, that a
    /// stalled or vanished subscriber costs nothing, and the CLI's exit status when Dealer goes.
    func eventsSelfTestSteps(_ t: SelfTestKit) {
        /// A client of the stream, reading on its own thread.
        final class Client {
            let fd: Int32
            private let lock = NSLock()
            private var lines: [[String: Any]] = []
            init(fd: Int32) {
                self.fd = fd
                let th = Thread { [self] in
                    var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let n = read(fd, &chunk, chunk.count)
                        if n <= 0 { return }
                        buffer.append(contentsOf: chunk[0..<n])
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = Data(buffer[buffer.startIndex..<nl])
                            buffer.removeSubrange(buffer.startIndex...nl)
                            if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                                lock.lock(); lines.append(o); lock.unlock()
                            }
                        }
                    }
                }
                th.start()
            }
            var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return lines }
            func events(_ name: String) -> [[String: Any]] { all.filter { $0["event"] as? String == name } }
            func wait(_ what: String, _ cond: ([[String: Any]]) -> Bool) -> String? {
                SelfTest.waitUntil(what, timeout: 10) { cond(all) }
            }
        }
        var ids: [String: Int] = [:]
        var client: Client?
        var snapshotSeq = -1
        func call(_ cmd: String, _ args: [String: Any] = [:]) -> [String: Any]? {
            let r = ControlHandler.handle(["cmd": cmd, "args": args])
            return r["result"] as? [String: Any]
        }
        func changed(_ e: [String: Any]) -> [String] { e["changed"] as? [String] ?? [] }
        func panes(_ name: String, id: Int?, where f: (([String: Any]) -> Bool)? = nil) -> (([[String: Any]]) -> Bool) {
            { all in all.contains { $0["event"] as? String == name && $0["pane"] as? Int == id && (f?($0) ?? true) } }
        }

        t.step("events: a pending change is in the snapshot, not after it; the stream starts with the reply", nil, {
            guard let c = client else { return "no client" }
            let tree = c.wait("the snapshot") { $0.contains { $0["event"] as? String == "snapshot" } }
            guard let snap = c.events("snapshot").first else { return tree }
            snapshotSeq = snap["seq"] as? Int ?? -1
            let inTree = ((snap["windows"] as? [[String: Any]]) ?? []).flatMap { $0["workspaces"] as? [[String: Any]] ?? [] }
                .flatMap { $0["decks"] as? [[String: Any]] ?? [] }.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
                .flatMap { $0["panes"] as? [[String: Any]] ?? [] }.first { $0["id"] as? Int == ids["e0"] }
            // Let two scans pass: the title set before connecting must not show up as a change.
            _ = SelfTest.waitUntil(timeout: 0.5) { false }
            // (A shell starting up after the snapshot is a real change; only the title is under test.)
            let early = c.events("pane-changed").first { $0["pane"] as? Int == ids["e0"] && (($0["changed"] as? [String]) ?? []).contains("title") }
            let first = c.all.first?["ok"] as? Bool == true
            let second = c.all.dropFirst().first?["event"] as? String == "snapshot"
            let title = inTree?["title"] as? String
            return [tree,
                    first ? nil : "the first line should be the ok reply",
                    second ? nil : "the snapshot should follow the reply",
                    title == "before" ? nil : "the snapshot should hold the title set before connecting: \(String(describing: title))",
                    early == nil ? nil : "pane-changed for a change the snapshot already had: \(String(describing: early?["changed"]))",
                    ControlEvents.shared.subscriberCount == 1 ? nil : "one subscriber expected"].compactMap { $0 }.first
        }) {
            let ws = self.newWorkspace(name: "events")
            ids["e0"] = ws.focusedPane?.id ?? self.focusedPane?.id
            self.focusedPane?.customTitle = "before"
            let socket = ControlServer.shared.path!
            guard let fd = try? ControlClient.connect(socket) else { return }
            _ = ControlClient.writeAll(fd, Data(#"{"cmd":"events","args":{}}"#.utf8 + [0x0A]))
            client = Client(fd: fd)
        }
        t.step("events: workspace and pane created, focus and active workspace", nil, {
            guard let c = client, let id = ids["e1"] else { return "no client" }
            return [c.wait("pane-created") { _ in c.events("pane-created").contains { $0["pane"] as? Int == id } },
                    c.wait("workspace-created") { _ in c.events("workspace-created").contains { $0["name"] as? String == "events2" } },
                    c.wait("workspace-activated") { _ in !c.events("workspace-activated").isEmpty },
                    c.wait("focus-changed") { _ in c.events("focus-changed").contains { $0["pane"] as? Int == id } },
                    (c.events("pane-created").first { $0["pane"] as? Int == id }?["describe"] as? [String: Any])?["id"] as? Int == id
                        ? nil : "pane-created should carry the pane's describe"].compactMap { $0 }.first
        }) {
            let ws = self.newWorkspace(name: "events2")
            ids["e1"] = ws.focusedPane?.id ?? self.focusedPane?.id
        }
        t.step("events: title, status record (with an id), visible and focus change as pane-changed with the full describe", nil, {
            guard let c = client, let id = ids["e1"] else { return "no client" }
            return [c.wait("title") { _ in c.events("pane-changed").contains { $0["pane"] as? Int == id && changed($0).contains("title") && ($0["describe"] as? [String: Any])?["title"] as? String == "renamed" } },
                    c.wait("program_status") { _ in c.events("pane-changed").contains { e in
                        e["pane"] as? Int == id && changed(e).contains("program_status")
                            && ((e["describe"] as? [String: Any])?["program_status"] as? [[String: Any]])?.contains { $0["id"] as? String == "build" } == true } },
                    c.wait("hidden") { _ in c.events("pane-changed").contains { $0["pane"] as? Int == id && changed($0).contains("visible")
                        && ($0["describe"] as? [String: Any])?["visible"] as? Bool == false } }].compactMap { $0 }.first
        }) {
            let id = ids["e1"]!
            _ = call("rename", ["target": "\(id)", "title": "renamed"])
            _ = call("status", ["target": "\(id)", "state": "working", "id": "build", "app": "cargo"])
            // Switching workspace hides the pane.
            if let ws = self.workspaces.first(where: { $0.name == "events" }) { self.activate(ws) }
        }
        t.step("events: a burst of titles ends on the final one, with far fewer events than titles", nil, {
            guard let c = client, let id = ids["e1"] else { return "no client" }
            let n = c.events("pane-changed").filter { $0["pane"] as? Int == id && changed($0).contains("title") }
            return [c.wait("final title") { _ in
                        (c.events("pane-changed").last { $0["pane"] as? Int == id && changed($0).contains("title") }?["describe"] as? [String: Any])?["title"] as? String == "frame 49"
                    },
                    n.count <= 12 ? nil : "50 titles in one tick should coalesce, got \(n.count) title events"].compactMap { $0 }.first
        }) {
            let pane = ControlHandler.pane(id: ids["e1"]!)!
            for i in 0..<50 { pane.customTitle = "frame \(i)" }
        }
        t.step("events: a pane moving to another tab is pane-moved; closing it is pane-closed", nil, {
            guard let c = client, let id = ids["e2"] else { return "no client" }
            return [c.wait("pane-moved") { _ in c.events("pane-moved").contains { e in
                        e["pane"] as? Int == id && (e["from"] as? [String: Int])?["tab"] != (e["to"] as? [String: Int])?["tab"] } },
                    c.wait("pane-closed") { _ in c.events("pane-closed").contains { $0["pane"] as? Int == id } }].compactMap { $0 }.first
        }) {
            guard let ws = self.workspaces.first(where: { $0.name == "events" }), let src = ws.focusedPane ?? ws.panes.first else { return }
            self.activate(ws)
            self.splitRight(nil)
            guard let moved = self.focusedPane, moved !== src, let loc = self.locate(moved) else { return }
            ids["e2"] = moved.id
            // The scan sees the split as pane-created; the move needs a scan in between.
            _ = SelfTest.waitUntil(timeout: 2) { client?.events("pane-created").contains { $0["pane"] as? Int == moved.id } == true }
            self.moveToNewTab(loc.node, deck: loc.deck, index: loc.deck.tabs.count)
            _ = SelfTest.waitUntil(timeout: 2) { client?.events("pane-moved").contains { $0["pane"] as? Int == moved.id } == true }
            _ = call("close", ["target": "pane:\(moved.id)"])
        }
        t.step("events: workspace rename, close; attention as its own event", nil, {
            guard let c = client, let id = ids["e1"] else { return "no client" }
            return [c.wait("workspace-renamed") { _ in c.events("workspace-renamed").contains { $0["name"] as? String == "events3" } },
                    c.wait("attention") { _ in c.events("attention").contains { $0["pane"] as? Int == id && $0["state"] as? String == "failed" && $0["body"] as? String == "oops" } },
                    c.wait("workspace-closed") { _ in !c.events("workspace-closed").isEmpty }].compactMap { $0 }.first
        }) {
            guard let ws = self.workspaces.first(where: { $0.name == "events2" }) else { return }
            _ = call("rename", ["target": "workspace:\(ws.id)", "level": "workspace", "title": "events3"])
            // Not the focused pane, so the mark isn't skipped as "you're looking at it".
            _ = call("notify", ["target": "pane:\(ids["e1"]!)", "state": "failed", "hold": true, "title": "T", "body": "oops"])
            _ = SelfTest.waitUntil(timeout: 2) { client?.events("attention").isEmpty == false }
            self.remove(workspace: ws)
        }
        t.step("events: seq counts up by one and every event is after the snapshot", nil, {
            guard let c = client else { return "no client" }
            let seqs = c.all.compactMap { $0["seq"] as? Int }
            return zip(seqs, seqs.dropFirst()).allSatisfy { $1 == $0 + 1 } && seqs.first == snapshotSeq && seqs.count > 8
                ? nil : "seq should be consecutive from the snapshot's: \(seqs)"
        }) {}
        t.step("events: a vanished subscriber is cleaned up, a stalled one is cut off without blocking main", nil, {
            [SelfTest.waitUntil("the subscriber to go", timeout: 5) { ControlEvents.shared.subscriberCount == 0 },
             ControlServer.shared.path.flatMap { ControlClient.isAlive($0) ? nil : "the server should still accept" }].compactMap { $0 }.first
        }) {
            Darwin.close(client!.fd)
            // A subscriber that never reads and whose buffer overflows: enqueue returns at once and
            // the subscriber closes itself instead of growing without bound.
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return }
            defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
            let saved = ControlEvents.maxBuffered
            ControlEvents.maxBuffered = 1 << 20
            defer { ControlEvents.maxBuffered = saved }
            let sub = ControlEvents.Subscriber(fd: pair[0])
            let start = Date()
            for _ in 0..<64 { sub.enqueue(Data(repeating: 0x61, count: 64 * 1024)) }
            if !sub.isClosed || Date().timeIntervalSince(start) > 1 { ids["stall-bad"] = 1 }
        }
        t.step("events: an overflowing stalled subscriber was closed at once", nil, {
            ids["stall-bad"] == nil ? nil : "a stalled subscriber should be closed instantly once over the limit"
        }) {}
        // The CLI runs as its own process.
        var out = Data()
        let outLock = NSLock()
        let proc = Process()
        t.step("events: the dealer binary prints the stream and exits 3 at shutdown", nil, {
            outLock.lock(); let text = String(decoding: out, as: UTF8.self); outLock.unlock()
            let lines = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let sawChange = lines.contains { $0["event"] as? String == "pane-changed" && $0["pane"] as? Int == ids["e0"] }
            // Dealer ending its streams (as at quit) must end the command, nonzero.
            ControlEvents.shared.shutdown()
            let ended = SelfTest.waitUntil(timeout: 10) { !proc.isRunning }
            return [lines.first?["event"] as? String == "pane-changed" ? nil : "with --no-snapshot the first line should be a change, not the reply or a snapshot: \(text.prefix(200))",
                    sawChange ? nil : "the CLI should print the change",
                    ended ? nil : "the CLI should exit when the stream ends",
                    proc.terminationStatus == 3 ? nil : "exit status should be 3, was \(proc.terminationStatus)"].compactMap { $0 }.first
        }) {
            proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            proc.arguments = ["events", "--no-snapshot"]
            var env = ProcessInfo.processInfo.environment
            env["DEALER_SOCKET"] = ControlServer.shared.path!
            env.removeValue(forKey: "DEALER_SELFTEST")
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                outLock.lock(); out.append(d); outLock.unlock()
            }
            guard (try? proc.run()) != nil else { return }
            _ = SelfTest.waitUntil(timeout: 5) { ControlEvents.shared.subscriberCount == 1 }
            self.focusedPane?.customTitle = "cli-saw-this"
            if let id = ids["e0"] { ControlHandler.pane(id: id)?.customTitle = "cli-saw-this" }
            _ = SelfTest.waitUntil(timeout: 5) { outLock.lock(); defer { outLock.unlock() }; return !out.isEmpty }
        }
        t.step("events: close the test workspace", nil, {
            self.workspaces.contains { $0.name == "events" } ? "workspace should be gone" : nil
        }) {
            if let ws = self.workspaces.first(where: { $0.name == "events" }) { self.remove(workspace: ws) }
        }
    }
}
