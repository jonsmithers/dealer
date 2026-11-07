import Foundation

/// The coding-agent session a pane is running (#93), so a relaunch can resume it.
///
/// Claude Code only for now: the bundled plugin's `SessionStart` hook reports the session id (and
/// its transcript) through `dealer agent-session`, and `SessionEnd` forgets it. The snapshot keeps
/// it (`PaneSnapshot.agentSession`), and session restore types the resume command into the
/// restored pane's shell. `agent` names the agent so the record could take others later.
struct AgentSession: Codable, Equatable {
    var agent: String
    var id: String
    /// Where Claude Code keeps the conversation (the hook's `transcript_path`); a resume is
    /// skipped when it no longer exists. Nil when the hook didn't say.
    var transcript: String?

    static let agents: Set = ["claude"]

    /// Session ids as Claude Code writes them (UUIDs), with some slack. Anything else is refused
    /// at report time; the resume line shell-quotes it all the same.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.".unicodeScalars.contains($0)
        }
    }

    /// The line session restore types into a restored pane's shell, or nil to leave it a plain shell.
    /// The executable is the agent command's first word, and only when it is Claude Code's
    /// (`claude`, by basename): the user's own path or alias wins over a bare `claude`.
    static func resumeLine(for session: AgentSession?,
                           enabled: Bool = Settings.agentRestoreSessions,
                           agentCommand: String = AgentPreset.command,
                           fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard enabled, let session, session.agent == "claude", validID(session.id) else { return nil }
        // `claude --resume <missing id>` says "No conversation found" and exits 1 (Claude Code
        // 2.1.319), which would mark the pane failed; skip it when the transcript is known gone.
        if let t = session.transcript, !t.isEmpty, !fileExists(t) { return nil }
        guard let exe = agentCommand.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
              (exe as NSString).lastPathComponent == "claude" else { return nil }
        return "\(exe) --resume \(AgentPreset.shellQuote(session.id))"
    }
}

extension ControlHandler {
    /// `dealer agent-session` (#93). `AGENT ID` records the target pane's session, replacing any
    /// other (SessionStart: startup, resume, clear and compact all start or switch one); `--end`
    /// forgets it only while it is still that id, so `/clear`'s SessionEnd can't race the new
    /// SessionStart. No id: just answers with the pane's session.
    static func agentSession(_ args: [String: Any], _ ctx: Context) throws -> [String: Any] {
        let loc = try resolve(args["target"], ctx)
        guard let pane = loc.focusPane else { throw Failure(message: "no pane to record a session for") }
        if let agent = args["agent"] as? String, let id = args["id"] as? String {
            guard AgentSession.agents.contains(agent) else {
                throw Failure(message: "unknown agent '\(agent)' (expected \(AgentSession.agents.sorted().joined(separator: ", ")))")
            }
            guard AgentSession.validID(id) else { throw Failure(message: "bad session id '\(id)'") }
            if args["end"] as? Bool == true {
                if pane.agentSession?.agent == agent, pane.agentSession?.id == id { pane.agentSession = nil }
            } else {
                let t = (args["transcript"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                pane.agentSession = AgentSession(agent: agent, id: id, transcript: t)
            }
        }
        return ["pane": pane.id, "session": pane.agentSession.map(agentSessionJSON) ?? NSNull()]
    }

    static func agentSessionJSON(_ s: AgentSession) -> [String: Any] {
        ["agent": s.agent, "id": s.id, "transcript": s.transcript ?? NSNull()]
    }
}
