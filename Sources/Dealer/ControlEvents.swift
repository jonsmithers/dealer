import AppKit
import GhosttyKit

/// `dealer events`: a long-lived stream of changes over the control socket, so a client can follow
/// panes without polling `list --json`. See docs/cli.md.
///
/// After the usual one-line reply (`{"ok":true,"result":{"stream":"events"}}`) the connection
/// carries one JSON object per line, each with an `event` name and a `seq` that counts up by one
/// per event across the whole run. By default the first is a `snapshot` (the `list` tree), then
/// changes.
///
/// **Ordering.** Everything here runs on main, as every control command does. A subscriber is
/// registered and handed its snapshot in one main-thread block, so no event can fall between the
/// two: events with `seq` greater than the snapshot's come after it, and the snapshot already
/// includes everything up to its own `seq`. Before taking the snapshot the hub scans, so changes
/// the periodic scan hasn't noticed yet are published (to the others) first, and the new
/// subscriber's baseline is exactly the state it was shown.
///
/// **How changes are found.** The model has no single change point (titles arrive from libghostty
/// callbacks, status from OSC 7501, moves from a dozen controller paths), so while anyone
/// subscribes a main-thread timer compares the tree with the last one it published. That coalesces
/// bursts (a spinner redrawing its title ten times a second is one event per tick, never two for
/// the same state) and cannot drop the final state: each tick compares against what was last
/// *sent*. Attention marks are the exception: they are momentary, so `ControlEvents.attention` is
/// called where they are set.
///
/// **Slow clients.** Main never writes to a socket. It appends the line to the subscriber's
/// buffer; that subscriber's own thread writes. A subscriber whose buffer passes `maxBuffered` is
/// cut off (it sees EOF and re-lists) rather than letting memory grow or events silently vanish.
final class ControlEvents {
    static let shared = ControlEvents()

    /// How often main compares the tree while someone subscribes (seconds).
    static let interval: TimeInterval = 0.1
    /// Every this many ticks the process table is read too, so a change in a pane's processes alone
    /// is noticed within about a second.
    static let processEvery = 10
    /// Bytes a subscriber may fall behind before it's dropped.
    static var maxBuffered = 8 << 20

    // MARK: - Subscribers

    final class Subscriber {
        let fd: Int32
        private let cond = NSCondition()
        private var chunks: [Data] = []
        private var buffered = 0
        private(set) var closed = false
        private let finished = DispatchSemaphore(value: 0)

        init(fd: Int32) { self.fd = fd }

        /// Called from main; never blocks on the socket.
        func enqueue(_ line: Data) {
            cond.lock()
            if !closed {
                chunks.append(line)
                buffered += line.count
                if buffered > ControlEvents.maxBuffered {
                    chunks.removeAll()
                    buffered = 0
                    closed = true
                    Darwin.shutdown(fd, SHUT_RDWR)  // wakes the reader and a blocked write
                }
                cond.signal()
            }
            cond.unlock()
        }

        func cancel() {
            cond.lock()
            closed = true
            cond.broadcast()
            cond.unlock()
            Darwin.shutdown(fd, SHUT_RDWR)
        }

        var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return closed }

        func startWriter() {
            let t = Thread { [self] in
                while true {
                    cond.lock()
                    while chunks.isEmpty && !closed { cond.wait() }
                    if closed { cond.unlock(); break }
                    let batch = chunks.reduce(into: Data()) { $0.append($1) }
                    chunks.removeAll()
                    buffered = 0
                    cond.unlock()
                    if !ControlClient.writeAll(fd, batch) { cancel(); break }
                }
                finished.signal()
            }
            t.name = "dealer.control.events"
            t.start()
        }

        func waitUntilWriterEnds() { finished.wait() }
    }

    private var subscribers: [Subscriber] = []
    /// Live streams, for the self-test.
    var subscriberCount: Int { subscribers.count }
    private var timer: Timer?
    private var seq = 0
    private var ticks = 0
    private var last: Scan?

    /// Runs the connection for a `dealer events` request until the client goes away. Called on the
    /// connection's own thread, which it keeps.
    static func serve(fd: Int32, args: [String: Any]) {
        let sub = Subscriber(fd: fd)
        let wantSnapshot = (args["snapshot"] as? Bool) ?? true
        ControlServer.onMain { shared.attach(sub, snapshot: wantSnapshot) }
        sub.startWriter()
        // Anything the client sends is ignored; EOF (or our own shutdown) ends the stream.
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !sub.isClosed {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }
        sub.cancel()
        sub.waitUntilWriterEnds()
        // The hub drops it on its next tick; nothing to do on main here.
    }

    private func attach(_ sub: Subscriber, snapshot: Bool) {
        precondition(Thread.isMainThread)
        scan()  // publish what's pending to the others; the baseline then equals what we show
        subscribers.append(sub)
        sub.enqueue(Self.line(["ok": true, "result": ["stream": "events"]]))
        if snapshot {
            var tree = ControlHandler.list([:])
            tree["event"] = "snapshot"
            tree["seq"] = seq
            sub.enqueue(Self.line(tree))
        }
        if timer == nil {
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .default)  // like onMain: not mid-drag
            timer = t
        }
    }

    /// Ends every stream (the app is quitting): clients see EOF and know to reconnect.
    func shutdown() {
        subscribers.forEach { $0.cancel() }
        subscribers.removeAll()
        timer?.invalidate()
        timer = nil
        last = nil
    }

    private func tick() {
        subscribers.removeAll { $0.isClosed }
        guard !subscribers.isEmpty else {
            timer?.invalidate()
            timer = nil
            last = nil
            return
        }
        ticks += 1
        scan(withProcesses: ticks % Self.processEvery == 0)
    }

    private static func line(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { $0 + Data([0x0A]) } ?? Data(#"{"event":"error","error":"unencodable event"}"#.utf8 + [0x0A])
    }

    private func emit(_ name: String, _ fields: [String: Any]) {
        guard !subscribers.isEmpty else { return }
        seq += 1
        var e = fields
        e["event"] = name
        e["seq"] = seq
        let data = Self.line(e)
        for s in subscribers { s.enqueue(data) }
    }

    // MARK: - Attention

    /// A bell, desktop notification, `dealer notify` or hook raised a mark on `pane`. Called from
    /// `setAttention`, on main.
    static func attention(_ pane: Pane, state: Attention, source: String, title: String?, body: String?) {
        let hub = shared
        guard !hub.subscribers.isEmpty else { return }
        hub.scan()  // anything that happened before the mark is published before it
        hub.emit("attention", ["pane": pane.id, "state": state.name, "source": source,
                               "title": title ?? NSNull(), "body": body ?? NSNull()])
    }

    // MARK: - Scanning

    struct PaneState {
        var loc: [String: Int]
        /// Everything `describe` reports that can change, by field name.
        var fields: [String: Any]
    }

    struct Scan {
        var panes: [Int: PaneState] = [:]
        var order: [Int] = []
        /// Workspace ID → (name, custom_name, window).
        var workspaces: [Int: (name: String, custom: Any, window: Int)] = [:]
        var workspaceOrder: [Int] = []
        var active: [Int: Int] = [:]
        var focused: Int?
    }

    private func scan(withProcesses: Bool = true) {
        precondition(Thread.isMainThread)
        let focusedPane = ControlHandler.focusedPane
        var byTTY: [dev_t: [ProcessTree.Proc]]?
        func table() -> [dev_t: [ProcessTree.Proc]] {
            if byTTY == nil { byTTY = Dictionary(grouping: ProcessTree.all(), by: \.tdev) }
            return byTTY!
        }
        var now = Scan()
        now.focused = focusedPane?.id
        var describeNow: [Int: () -> [String: Any]] = [:]
        for wc in ControlHandler.controllers {
            now.active[wc.id] = wc.activeWorkspace.id
            for ws in wc.workspaces {
                now.workspaces[ws.id] = (ws.displayName, ws.name ?? NSNull(), wc.id)
                now.workspaceOrder.append(ws.id)
                for d in ws.decks {
                    for t in d.tabs {
                        for p in t.panes {
                            let loc = ["pane": p.id, "tab": t.id, "deck": d.id, "workspace": ws.id, "window": wc.id]
                            var f = ControlHandler.describeModel(p, ws: ws, focused: focusedPane)
                            if let s = p.surface.surface {
                                let size = ghostty_surface_size(s)
                                f["columns"] = Int(size.columns)
                                f["rows"] = Int(size.rows)
                                let fg = Int32(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
                                f["foreground"] = Int(fg)
                            }
                            f["cwd"] = p.pwd ?? NSNull()
                            if withProcesses {
                                f["processes"] = Self.processes(of: p, table())
                            } else {
                                f["processes"] = last?.panes[p.id]?.fields["processes"] ?? NSNull()
                            }
                            now.panes[p.id] = PaneState(loc: loc, fields: f)
                            now.order.append(p.id)
                            describeNow[p.id] = { ControlHandler.describe(p, ws: ws, byTTY: table(), focused: focusedPane) }
                        }
                    }
                }
            }
        }
        defer { last = now }
        guard let old = last else { return }

        for id in now.workspaceOrder where old.workspaces[id] == nil {
            let w = now.workspaces[id]!
            emit("workspace-created", ["workspace": id, "window": w.window, "name": w.name, "custom_name": w.custom])
        }
        for id in now.order where old.panes[id] == nil {
            emit("pane-created", ["pane": id, "location": now.panes[id]!.loc, "describe": describeNow[id]!()])
        }
        for id in now.order {
            guard let o = old.panes[id], let n = now.panes[id] else { continue }
            if o.loc != n.loc {
                emit("pane-moved", ["pane": id, "from": o.loc, "to": n.loc])
            }
            let changed = Set(o.fields.keys).union(n.fields.keys).filter { k in
                let a = o.fields[k], b = n.fields[k]
                if a == nil || b == nil { return true }
                return !(a! as AnyObject).isEqual(b!)
            }.sorted()
            if !changed.isEmpty {
                emit("pane-changed", ["pane": id, "changed": changed, "location": n.loc, "describe": describeNow[id]!()])
            }
        }
        for id in old.order where now.panes[id] == nil {
            emit("pane-closed", ["pane": id, "location": old.panes[id]!.loc])
        }
        for id in now.workspaceOrder {
            guard let o = old.workspaces[id], let n = now.workspaces[id] else { continue }
            if o.name != n.name || !(o.custom as AnyObject).isEqual(n.custom) {
                emit("workspace-renamed", ["workspace": id, "window": n.window, "name": n.name, "custom_name": n.custom])
            }
        }
        for id in old.workspaceOrder where now.workspaces[id] == nil {
            emit("workspace-closed", ["workspace": id, "window": old.workspaces[id]!.window])
        }
        for (win, ws) in now.active.sorted(by: { $0.key < $1.key }) where old.active[win] != ws {
            emit("workspace-activated", ["window": win, "workspace": ws])
        }
        if old.focused != now.focused {
            emit("focus-changed", ["pane": now.focused ?? NSNull(), "previous": old.focused ?? NSNull()])
        }
    }

    /// pid and whether it is in the foreground group, for each process on the pane's tty.
    private static func processes(of p: Pane, _ table: [dev_t: [ProcessTree.Proc]]) -> [[Int]] {
        guard let s = p.surface.surface else { return [] }
        let name = ghostty_surface_tty_name(s)
        defer { ghostty_string_free(name) }
        guard let ptr = name.ptr else { return [] }
        let tty = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(name.len)), as: UTF8.self)
        guard let dev = ProcessTree.device(ofTTY: tty) else { return [] }
        return (table[dev] ?? []).sorted { $0.pid < $1.pid }.map { [Int($0.pid), $0.pgid == $0.tpgid ? 1 : 0] }
    }
}
