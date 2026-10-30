import AppKit
import GhosttyKit

// MARK: - Program Status Protocol (OSC 7501, #89)
//
// A program tells the terminal what it is doing: `OSC 7501 ; state=working:id=build:progress=40 ST`.
// Spec: https://www.superlogical.com/rex/docs/build/program-status (rev 0.4). Ghostty parses and
// validates the sequence; Dealer's runtime patch (scripts/ghostty-build/<pin12>.runtime.patch)
// passes each report's body here as GHOSTTY_ACTION_PROGRAM_STATUS (an empty body means a full
// reset) and answers the support query itself. `dealer status` (ControlHandler) sets records
// through the same parser, so the validation below is the spec's, not a re-check of Ghostty's.

/// Parsing and sanitizing. Everything that reads a record's text reads the sanitized value.
enum ProgramStatus {
    /// The report states. `clear` isn't a state: it removes records.
    enum State: String, CaseIterable {
        case idle, working, done, blocked, error, clear

        /// Roll-up order (#89): error > blocked > done > working > idle, like attention's.
        var rank: Int {
            switch self {
            case .clear: return -1
            case .idle: return 0
            case .working: return 1
            case .done: return 2
            case .blocked: return 3
            case .error: return 4
            }
        }
    }

    /// What a blocked program needs from the user.
    enum Kind: String, CaseIterable { case permission, question, auth }

    // The spec's limits (bytes). A report that breaks one is discarded whole.
    static let maxSequenceBytes = 4096
    /// Everything after `7501;`, assuming the longer terminator (`ESC \`), as Ghostty does.
    static let maxBodyBytes = maxSequenceBytes - "\u{1b}]7501;".utf8.count - "\u{1b}\\".utf8.count
    static let maxKeyBytes = 16
    static let maxMsgEncodedBytes = 2732, maxMsgBytes = 2048
    static let maxTitleEncodedBytes = 256, maxTitleBytes = 192
    static let maxAppBytes = 32
    static let maxIdBytes = 128, maxIdSegmentBytes = 32, maxIdDepth = 8
    /// Records per pane (the spec's maximum; 64 is the minimum a terminal must allow).
    static var maxRecords = 256

    private static let nameBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-".utf8)
    private static let valueBytes = nameBytes.union(",/=".utf8)

    /// One valid report. `title` and `msg` are decoded and sanitized.
    struct Report: Equatable {
        var state: State
        /// nil for the root record.
        var id: String?
        var kind: Kind?
        /// 0…100, nil for indeterminate (only for working and blocked).
        var progress: Int?
        var app: String?
        var title: String?
        var msg: String?
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooLong(String), invalidId, invalidText(String), invalidState

        var description: String {
            switch self {
            case .tooLong(let what): return "\(what) over its limit"
            case .invalidId: return "invalid id"
            case .invalidText(let key): return "\(key) isn't valid base64 of one line of text"
            case .invalidState: return "missing or unknown state"
            }
        }
    }

    /// Parses a report body (everything after `7501;`), following the spec and Ghostty's parser
    /// (`src/terminal/osc/parsers/program_status.zig`): malformed pairs and unknown keys are
    /// skipped, the last value of a key wins, and a broken limit, a bad id, bad base64 or a control
    /// character discards the whole report.
    static func parse(_ body: String) -> Result<Report, ParseError> {
        guard body.utf8.count <= maxBodyBytes else { return .failure(.tooLong("report")) }
        // (key, value) for every pair with an `=`, whitespace around both trimmed.
        let pairs: [(String, String)] = body.split(separator: ":", omittingEmptySubsequences: false).compactMap { pair in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (pair[..<eq].trimmingCharacters(in: .whitespaces), pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        if pairs.contains(where: { $0.0.utf8.count > maxKeyBytes }) { return .failure(.tooLong("a key")) }
        func all(_ key: String) -> [String] { pairs.filter { $0.0 == key }.map(\.1) }
        /// The last value of `key` made of value bytes only; others are skipped, as Ghostty does.
        func last(_ key: String) -> String? { all(key).last { $0.utf8.allSatisfy(valueBytes.contains) } }

        // Every value counts against its limit, even one a later pair replaces.
        for id in all("id") {
            if let e = validateId(id) { return .failure(e) }
        }
        for (key, limit) in [("app", maxAppBytes), ("title", maxTitleEncodedBytes), ("msg", maxMsgEncodedBytes)] {
            if all(key).contains(where: { $0.utf8.count > limit }) { return .failure(.tooLong(key)) }
        }
        var title: String?, msg: String?
        if let v = last("title") {
            guard let t = decodeText(v) else { return .failure(.invalidText("title")) }
            guard t.utf8.count <= maxTitleBytes else { return .failure(.tooLong("title")) }
            title = t
        }
        if let v = last("msg") {
            guard let m = decodeText(v) else { return .failure(.invalidText("msg")) }
            guard m.utf8.count <= maxMsgBytes else { return .failure(.tooLong("msg")) }
            msg = m
        }
        guard let s = last("state"), let state = State(rawValue: s) else { return .failure(.invalidState) }

        var r = Report(state: state)
        r.id = last("id")
        if state == .blocked { r.kind = last("kind").flatMap(Kind.init(rawValue:)) }
        if state == .working || state == .blocked { r.progress = last("progress").flatMap(parseProgress) }
        r.app = last("app").flatMap { isName($0) ? $0 : nil }
        r.title = title.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        r.msg = msg.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        return .success(r)
    }

    private static func isName(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy(nameBytes.contains) }

    /// Names joined by single slashes, within the limits.
    private static func validateId(_ v: String) -> ParseError? {
        if v.utf8.count > maxIdBytes { return .tooLong("id") }
        let segments = v.split(separator: "/", omittingEmptySubsequences: false)
        if segments.count > maxIdDepth { return .tooLong("id") }
        for s in segments {
            if s.utf8.count > maxIdSegmentBytes { return .tooLong("id") }
            if !isName(String(s)) { return .invalidId }
        }
        return nil
    }

    /// A whole number from 0 to 100; anything else counts as absent.
    private static func parseProgress(_ v: String) -> Int? {
        guard !v.isEmpty, v.count <= 3, v.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(v), n <= 100 else { return nil }
        return n
    }

    /// Standard base64 with optional padding, decoding to UTF-8 without control characters.
    static func decodeText(_ encoded: String) -> String? {
        var e = encoded
        guard e.utf8.allSatisfy({ isBase64Byte($0) }) else { return nil }
        if !e.hasSuffix("=") {
            guard e.count % 4 != 1 else { return nil }
            e += String(repeating: "=", count: (4 - e.count % 4) % 4)
        }
        guard let data = Data(base64Encoded: e), let text = String(data: data, encoding: .utf8) else { return nil }
        // Control characters (C0, DEL, C1) make the report invalid, as the spec requires.
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return nil }
        return text
    }

    private static func isBase64Byte(_ b: UInt8) -> Bool {
        (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || b == 43 || b == 47 || b == 61
    }

    /// The one place record text is made safe to show (#89): invisible formatting characters
    /// (bidi overrides and isolates, zero-width characters, the BOM: Unicode's Cf category) are
    /// removed, and any control character left becomes a space. Every drawer, notification and
    /// `dealer list` reads text that went through here.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .format: continue
            case .control, .lineSeparator, .paragraphSeparator: out.append(" ")
            default: out.append(u)
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// The working mark for an `app` (#81): only Claude Code has its own.
    static func mark(app: String?, progress: Int?) -> WorkingMark {
        if app == "claude-code" || app == "claude" { return .claude }
        return progress.map(WorkingMark.ring) ?? .arc
    }
}

/// A pane's OSC 7501 records (#89). The terminal (here, the pane) keeps one record per id; each
/// report replaces its record whole. Pure model: no surface, no window, so the self-test checks
/// it directly, locked screen or not.
final class ProgramStatusStore {
    struct Record: Equatable {
        /// "" for the root record.
        var id: String
        var state: ProgramStatus.State
        var kind: ProgramStatus.Kind?
        var progress: Int?
        /// The record's own `app`; `app(of:)` applies inheritance.
        var app: String?
        var title: String?
        var msg: String?
        /// Update order, for least-recently-updated eviction and roll-up ties.
        var seq: Int

        /// The attention this record's state maps to.
        var attentionEquivalent: Attention {
            switch state {
            case .error: return .failed
            case .blocked: return .waiting
            case .done: return .done
            default: return .none
            }
        }
    }

    private(set) var records: [String: Record] = [:]
    private var seq = 0
    /// The pane has sent OSC 7501 since its last full reset: its OSC 9;4 is ignored (#89, the spec).
    private(set) var inUse = false

    var isEmpty: Bool { records.isEmpty }

    /// Applies one report. Returns whether anything changed.
    @discardableResult
    func apply(_ r: ProgramStatus.Report) -> Bool {
        inUse = true
        let id = r.id ?? ""
        if r.state == .clear { return clear(id: r.id) }
        seq += 1
        let new = Record(id: id, state: r.state, kind: r.kind, progress: r.progress, app: r.app,
                         title: r.title, msg: r.msg, seq: seq)
        let changed = records[id].map { !Self.sameContent($0, new) } ?? true
        if records[id] == nil, records.count >= ProgramStatus.maxRecords,
           let oldest = records.values.min(by: { $0.seq < $1.seq }) {
            records[oldest.id] = nil
        }
        records[id] = new
        return changed
    }

    private static func sameContent(_ a: Record, _ b: Record) -> Bool {
        var a = a
        a.seq = b.seq
        return a == b
    }

    /// `state=clear`: the record and everything beneath it, or every record without an id.
    @discardableResult
    func clear(id: String?) -> Bool {
        let before = records.count
        if let id {
            records = records.filter { $0.key != id && !$0.key.hasPrefix(id + "/") }
        } else {
            records.removeAll()
        }
        return records.count != before
    }

    /// A full reset (RIS): no records, and OSC 9;4 counts again.
    @discardableResult
    func reset() -> Bool {
        let changed = !records.isEmpty || inUse
        records.removeAll()
        inUse = false
        return changed
    }

    /// At the next prompt or when the program exits, `working` and `blocked` records go; `done`,
    /// `error` and `idle` stay.
    @discardableResult
    func dropTransient() -> Bool {
        let before = records.count
        records = records.filter { $0.value.state != .working && $0.value.state != .blocked }
        return records.count != before
    }

    var hasTransient: Bool { records.values.contains { $0.state == .working || $0.state == .blocked } }

    /// The user has seen the pane: `done` and `error` records are dismissed.
    @discardableResult
    func dismissFinished() -> Bool {
        let before = records.count
        records = records.filter { $0.value.state != .done && $0.value.state != .error }
        return records.count != before
    }

    /// The highest record (error > blocked > done > working > idle), the latest on ties. Child
    /// records roll up to the pane the way panes roll up to tabs.
    var summary: Record? {
        records.values.max { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.seq < b.seq
        }
    }

    /// A record's `app`, or its nearest ancestor's.
    func app(of id: String) -> String? {
        var cur = id
        while true {
            if let a = records[cur]?.app { return a }
            guard !cur.isEmpty else { return nil }
            cur = cur.lastIndex(of: "/").map { String(cur[..<$0]) } ?? ""
        }
    }

    /// The attention level the records ask for: error → failed, blocked → waiting, done → done.
    var attentionLevel: Attention { summary?.attentionEquivalent ?? .none }

    /// The working mark of the working records (#81's ranking), nil when none works.
    var workingMark: WorkingMark? {
        WorkingMark.strongest(records.values.filter { $0.state == .working }.map {
            ProgramStatus.mark(app: app(of: $0.id), progress: $0.progress)
        })
    }

    /// Records in id order (root first), for `dealer list`.
    var sorted: [Record] { records.values.sorted { $0.id < $1.id } }
}

// MARK: - Applying reports to panes

extension ProgramStatus {
    /// Seconds between checks for a reporter that left the foreground (the spec drops working and
    /// blocked records when the program exits). Off in self-test mode unless a step turns it on.
    static var exitCheckInterval: TimeInterval = 2
    static var exitCheckEnabled = !SelfTest.enabled

    /// One report body from GHOSTTY_ACTION_PROGRAM_STATUS (empty: a full reset) or `dealer status`.
    /// Main thread. Returns the parse error, if any (logged, nothing applied).
    @discardableResult
    static func receive(_ body: String, on pane: Pane, source: String = "osc7501") -> ParseError? {
        dispatchPrecondition(condition: .onQueue(.main))
        let store = pane.programStatus
        if body.isEmpty {
            NSLog("Dealer: pane %d full reset: program status records cleared", pane.id)
            if store.reset() { update(pane, event: "\(source):reset") }
            return nil
        }
        let report: Report
        switch parse(body) {
        case .success(let r): report = r
        case .failure(let e):
            NSLog("Dealer: pane %d OSC 7501 report discarded: %@", pane.id, e.description)
            return e
        }
        if !store.inUse, pane.isReportingProgress {
            // The hand-off (#89): from now until a full reset, OSC 9;4 is ignored for this pane.
            _ = ProgressSource.note(pane, active: false, percent: nil, foreground: 0)
        }
        store.apply(report)
        if report.state == .working || report.state == .blocked {
            pane.programReporter = ProgressSource.currentForeground(of: pane)
        }
        update(pane, event: "\(source):\(report.state.rawValue)")
        return nil
    }

    /// The shell is back at a prompt (COMMAND_FINISHED): working and blocked records go.
    static func promptReturned(_ pane: Pane) {
        guard pane.programStatus.dropTransient() else { return }
        update(pane, event: "osc7501:prompt")
    }

    /// Brings the pane's attention and chrome in line with its records. 7501's attention is a level
    /// (#89): it raises when the records ask for more than they last did, and lowers what it raised
    /// itself when they ask for less (`blocked` → `working` drops *waiting*). It never lowers
    /// another source's mark. Done and error records the user is already looking at count as seen.
    static func update(_ pane: Pane, event: String) {
        let wc = AppDelegate.shared.windowControllers.first { $0.locate(pane) != nil }
        let store = pane.programStatus
        if let wc, wc.isLookingAt(pane) { store.dismissFinished() }
        let level = store.attentionLevel
        let previous = pane.programAttention
        pane.programAttention = level
        if let wc {
            if level > previous {
                let top = store.summary
                wc.setAttention(level, on: pane, raiseOnly: true, title: notificationTitle(top), body: top?.msg, event: event)
            } else if level < previous, pane.attention == previous {
                if level == .none {
                    wc.clearAttention(pane, cause: event)
                } else {
                    let top = store.summary
                    wc.setAttention(level, on: pane, title: notificationTitle(top), body: top?.msg, event: event)
                }
            }
            wc.refreshChrome()
        }
        armExitCheck(pane)
    }

    /// The notification's first line for the top record.
    static func notificationTitle(_ r: ProgramStatusStore.Record?) -> String? {
        guard let r else { return nil }
        if let t = r.title { return t }
        switch r.state {
        case .blocked:
            switch r.kind {
            case .permission: return "Waiting for permission"
            case .question: return "Waiting for an answer"
            case .auth: return "Waiting to sign in"
            case nil: return "Waiting for input"
            }
        case .done: return "Finished"
        case .error: return "Failed"
        default: return nil
        }
    }

    // MARK: The program exits

    /// While working or blocked records are kept, checks every `exitCheckInterval` whether the
    /// process group that reported them is still the terminal's foreground; when it isn't (the
    /// program exited, maybe without shell integration to mark the prompt), they're dropped.
    static func armExitCheck(_ pane: Pane) {
        pane.programExitTimer?.invalidate()
        pane.programExitTimer = nil
        guard exitCheckEnabled, pane.programStatus.hasTransient, pane.programReporter > 0 else { return }
        let t = Timer(timeInterval: exitCheckInterval, repeats: false) { [weak pane] _ in
            guard let pane else { return }
            pane.programExitTimer = nil
            checkExit(pane)
        }
        RunLoop.main.add(t, forMode: .common)
        pane.programExitTimer = t
    }

    static func checkExit(_ pane: Pane) {
        let fg = ProgressSource.currentForeground(of: pane)
        if fg > 0, fg == pane.programReporter { return armExitCheck(pane) }
        NSLog("Dealer: pane %d program status: reporter's group %d left the foreground (now %d); working/blocked records dropped",
              pane.id, pane.programReporter, fg)
        pane.programReporter = 0
        if pane.programStatus.dropTransient() { update(pane, event: "osc7501:exit") }
    }
}
