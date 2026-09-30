import Darwin
import Foundation

/// The control socket that `dealer` talks to: a Unix socket (mode 0600) speaking line-delimited
/// JSON. Each request line gets exactly one response line, sent only after the change has been
/// applied on the main thread, so a script can rely on `dealer focus X; dealer identify` seeing X.
///
///     → {"cmd": "create", "caller": 12, "args": {"type": "pane", "side": "down"}}
///     ← {"ok": true, "result": {"pane": 13, "tab": 4, "deck": 2, "workspace": 1, "window": 1}}
///     ← {"ok": false, "error": "no pane 99"}
///
/// Socket IO runs on background threads; `ControlHandler.handle` runs on main.
final class ControlServer {
    static let shared = ControlServer()

    private(set) var path: String?
    private var listenFD: Int32 = -1

    /// The bundle's `bin` directory holding the `dealer` symlink (scripts/bundle.sh), if any.
    static let binDirectory: String? = {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
              FileManager.default.fileExists(atPath: bin + "/dealer") else { return nil }
        return bin
    }()

    /// PATH for child shells: ours with the bundle's bin directory appended, so `dealer` works in
    /// every pane without setup. nil when there's no bundle (e.g. `swift run`).
    static let childPath: String? = {
        guard let bin = binDirectory else { return nil }
        let cur = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return cur.split(separator: ":").contains(Substring(bin)) ? cur : cur + ":" + bin
    }()

    /// The default socket location, under Application Support next to session.json.
    static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dealer", isDirectory: true)
        return dir.appendingPathComponent("dealer.sock").path
    }

    /// Starts listening. Self-test mode uses a private temp socket so it never displaces the
    /// socket of a Dealer the user is running. Returns the path, or nil on failure.
    @discardableResult
    func start(path requested: String? = nil) -> String? {
        if let path { return path }
        var p = requested ?? (SelfTest.enabled
            ? NSTemporaryDirectory() + "dealer-selftest-\(getpid()).sock"
            : Self.defaultPath)
        // Another live instance owns the default socket: don't steal it.
        if requested == nil, !SelfTest.enabled, ControlClient.isAlive(p) {
            p = (p as NSString).deletingLastPathComponent + "/dealer-\(getpid()).sock"
        }
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(p)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = ControlClient.address(p) else { close(fd); return nil }
        // Create the socket node with 0600 from the start instead of chmod-ing it afterwards.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            NSLog("Dealer: control socket \(p) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return nil
        }
        chmod(p, 0o600)
        listenFD = fd
        path = p
        setenv("DEALER_SOCKET", p, 1)

        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "dealer.control.accept"
        t.start()
        return p
    }

    func stop() {
        guard let path else { return }
        unlink(path)
        self.path = nil
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // Only the user who owns the app may drive it (the socket mode already says so).
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                close(client)
                continue
            }
            let t = Thread { Self.serve(client) }
            t.name = "dealer.control.client"
            t.start()
        }
    }

    private static func serve(_ fd: Int32) {
        defer { close(fd) }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                let response = respond(to: Data(line))
                guard ControlClient.writeAll(fd, response + Data([0x0A])) else { return }
            }
        }
    }

    /// Runs `body` on the main thread and waits for it. It's scheduled as a run-loop block in the
    /// default mode rather than on the main dispatch queue: that way it also runs inside nested
    /// default-mode run loops (the self-test's waits), but never in the middle of a mouse-tracking
    /// loop (divider or pane drags run in event-tracking mode).
    static func onMain<T>(_ body: @escaping () -> T) -> T {
        if Thread.isMainThread { return body() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            result = body()
            done.signal()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        done.wait()
        return result!
    }

    /// Parses one request line and runs it on main; always returns a JSON response.
    static func respond(to line: Data) -> Data {
        let reply: [String: Any]
        if let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
            reply = onMain { ControlHandler.handle(req) }
        } else {
            reply = ["ok": false, "error": "malformed request (expected one JSON object per line)"]
        }
        return (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"unencodable response"}"#.utf8)
    }
}

/// The client half, used by the CLI (and by the self-test's socket round-trip).
enum ControlClient {
    enum Failure: Error, CustomStringConvertible {
        case unreachable(String, String)
        case io(String)
        var description: String {
            switch self {
            case let .unreachable(path, why): return "cannot reach Dealer at \(path): \(why)"
            case let .io(why): return why
            }
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    static func connect(_ path: String) throws -> Int32 {
        guard var addr = address(path) else { throw Failure.unreachable(path, "path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unreachable(path, String(cString: strerror(errno))) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw Failure.unreachable(path, why)
        }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func isAlive(_ path: String) -> Bool {
        guard let fd = try? connect(path) else { return false }
        close(fd)
        return true
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// Sends one request and waits for its response line.
    static func send(_ request: [String: Any], to path: String) throws -> [String: Any] {
        let fd = try connect(path)
        defer { close(fd) }
        let body = try JSONSerialization.data(withJSONObject: request)
        guard writeAll(fd, body + Data([0x0A])) else { throw Failure.io("write failed: \(String(cString: strerror(errno)))") }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buffer.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw Failure.io("Dealer closed the connection without answering") }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let line = buffer[buffer.startIndex..<buffer.firstIndex(of: 0x0A)!]
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw Failure.io("malformed response from Dealer")
        }
        return obj
    }
}
