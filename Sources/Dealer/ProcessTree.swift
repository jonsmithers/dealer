import Darwin
import Foundation

/// Process-unique counters for the IDs the control socket hands out. Each kind counts separately,
/// so `pane 3` and `tab 3` can coexist; IDs never change while the object lives.
enum StableID {
    enum Kind: CaseIterable { case tab, deck, window }
    private static var counters: [Kind: Int] = [:]

    static func next(_ kind: Kind) -> Int {
        let n = (counters[kind] ?? 0) + 1
        counters[kind] = n
        return n
    }
}

/// Reads the process table with sysctl, to report what runs in each pane.
enum ProcessTree {
    struct Proc {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tdev: dev_t
        let name: String
    }

    /// Every process with a controlling terminal.
    static func all() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        // The table can grow between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { k in
            let e = k.kp_eproc
            guard e.e_tdev != -1, k.kp_proc.p_pid > 0 else { return nil }
            var comm = k.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return Proc(pid: k.kp_proc.p_pid, ppid: e.e_ppid, pgid: e.e_pgid, tpgid: e.e_tpgid,
                        tdev: e.e_tdev, name: name)
        }
    }

    /// The device number of a tty path such as `/dev/ttys004`.
    static func device(ofTTY path: String) -> dev_t? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_rdev
    }

    /// Full argv of a process (KERN_PROCARGS2), or nil when it's gone or not ours.
    static func arguments(of pid: Int32) -> [String]? { command(of: pid)?.argv }

    /// The executable path the kernel recorded at exec, and the full argv (KERN_PROCARGS2), or nil
    /// when the process is gone or not ours.
    static func command(of pid: Int32) -> (path: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // The executable path, then NUL padding.
        let pathStart = i
        while i < size && buf[i] != 0 { i += 1 }
        let path = String(decoding: buf[pathStart..<i], as: UTF8.self)
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return (path, args)
    }

    /// The processes in one process group (KERN_PROC_PGRP): a terminal's foreground job.
    static func members(ofGroup pgid: Int32) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid).filter { $0 > 0 }
    }

    /// Current working directory of a process, via proc_pidinfo.
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        var path = info.pvi_cdir.vip_path
        return withUnsafeBytes(of: &path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
